-- 044_operating_supplies.sql
-- Operating supplies (gloves, napkins, cleaning...) kept apart from food stock:
--   * an item can be marked "operating supply" (owner, items screen);
--   * its value sits in 1210 مخزون مستلزمات تشغيل instead of 1200: every stock move of a supply item (receipt, waste,
--     count, transfer, recipe...) posts its own small entry moving that value between 1200 and 1210, so none of the
--     existing postings had to change and 1200 holds food only;
--   * "supply use" in the stores screen takes supplies out of stock as an expense:
--       Dr 6810 مصروف مستلزمات تشغيل / Cr 1210 (through 1200 and the move above);
--   * marking / unmarking an item moves the value of its current stock between 1200 and 1210 once;
--   * a list of the supplies used per period (inventory view period applies).
-- Accounts 1210 and 6810 are added to every company that does not have them.
-- New: ingredients.is_supply, movement type supply_use, pos_supply_reclass (trigger), ingredient_supply_secure,
-- inv_supply_use_secure, inv_supply_uses_secure; ingredients_review_secure (043) returns is_supply. No function of
-- 001-043 changed except that one.
-- Rules: begin/commit, preflight (needs 043), version bump to 044, grants loop, rolled-back self-test.

begin;

do $preflight$
begin
  if length('إكراميات') <> 8 then
    raise exception 'file_encoding_broken: read the file as UTF-8';
  end if;
  if public.motionpos_version_public() not in ('043', '044') then
    raise exception 'schema_preflight_failed: run 043 first';
  end if;
end;
$preflight$;

-- ---------------------------------------------------------------- 1) tables and accounts
alter table public.ingredients add column if not exists is_supply boolean not null default false;

alter table public.stock_movements drop constraint if exists stock_movements_movement_type_check;
alter table public.stock_movements add constraint stock_movements_movement_type_check
  check (movement_type = any (array['opening_balance', 'purchase', 'sale', 'waste', 'transfer_in', 'transfer_out', 'adjustment',
                                    'hospitality', 'supply_use']));

do $accounts$
declare
  co record;
  v_parent uuid;
begin
  for co in select id from public.companies loop
    if not exists (select 1 from public.accounts a where a.company_id = co.id and a.code = '1210') then
      select a.parent_id into v_parent from public.accounts a where a.company_id = co.id and a.code = '1200';
      insert into public.accounts (company_id, code, name_ar, name_en, account_type, normal_balance, parent_id, is_system_account, is_active)
      values (co.id, '1210', 'مخزون مستلزمات تشغيل', 'Operating supplies stock', 'asset', 'debit', v_parent, true, true);
    end if;
    if not exists (select 1 from public.accounts a where a.company_id = co.id and a.code = '6810') then
      select a.parent_id into v_parent from public.accounts a
       where a.company_id = co.id and a.account_type = 'expense' and a.code ~ '^6[0-9]{3}$' and a.parent_id is not null
       group by a.parent_id order by count(*) desc limit 1;
      insert into public.accounts (company_id, code, name_ar, name_en, account_type, normal_balance, parent_id, is_system_account, is_active)
      values (co.id, '6810', 'مصروف مستلزمات تشغيل', 'Operating supplies used', 'expense', 'debit', v_parent, true, true);
    end if;
  end loop;
end;
$accounts$;

-- ---------------------------------------------------------------- 2) the value of supply items lives in 1210
-- one move of a supply item = one entry: in (qty > 0) Dr 1210 / Cr 1200, out (qty < 0) Dr 1200 / Cr 1210.
create or replace function public.pos_supply_reclass()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_co uuid;
  v_br uuid;
  v_val numeric;
  v_name text;
begin
  -- copies coming from the other side of the sync carry their own entries; the program reset skips it too
  if coalesce(current_setting('motionpos.sync_apply', true), '') = 'on' or coalesce(current_setting('motionpos.system_reset', true), '') = 'on' then
    return null;
  end if;
  select i.name into v_name from public.ingredients i where i.id = new.ingredient_id and i.is_supply;
  if v_name is null then
    return null;
  end if;
  v_val := round(abs(coalesce(new.quantity, 0) * coalesce(new.unit_cost, 0)), 2);
  if v_val = 0 then
    return null;
  end if;
  v_br := coalesce(new.branch_id, (select w.branch_id from public.warehouses w where w.id = new.warehouse_id));
  v_co := coalesce(new.company_id, (select br.company_id from public.branches b join public.brands br on br.id = b.brand_id where b.id = v_br));
  if v_co is null then
    return null;
  end if;
  perform public.pos_post_je(v_co, v_br, 'inventory', 'adjustment', new.id, 'مستلزمات تشغيل: ' || v_name,
    case when new.quantity > 0
         then jsonb_build_array(public.pos_je_line('1210', v_val, 0, 'مستلزمات تشغيل'), public.pos_je_line('1200', 0, v_val, 'مستلزمات تشغيل'))
         else jsonb_build_array(public.pos_je_line('1200', v_val, 0, 'مستلزمات تشغيل'), public.pos_je_line('1210', 0, v_val, 'مستلزمات تشغيل')) end,
    new.created_by);
  return null;
end;
$$;

drop trigger if exists trg_supply_reclass on public.stock_movements;
create trigger trg_supply_reclass after insert on public.stock_movements
  for each row execute function public.pos_supply_reclass();

-- ---------------------------------------------------------------- 3) owner: mark / unmark an item as an operating supply
create or replace function public.ingredient_supply_secure(p_token text, p_ingredient_id uuid, p_is_supply boolean)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
  v_now boolean;
  v_name text;
  v_qty numeric;
  v_cost numeric;
  v_val numeric;
begin
  select * into c from public.pos_ctx(p_token, null);
  if c.role_name <> 'owner' then
    return jsonb_build_object('ok', false, 'reason', 'owner_only');
  end if;
  select i.is_supply, i.name, coalesce(i.cost_per_unit, 0) into v_now, v_name, v_cost from public.ingredients i where i.id = p_ingredient_id for update;
  if v_name is null then
    return jsonb_build_object('ok', false, 'reason', 'not_found');
  end if;
  if v_now = coalesce(p_is_supply, false) then
    return jsonb_build_object('ok', true, 'is_supply', v_now, 'moved', 0);
  end if;
  update public.ingredients set is_supply = coalesce(p_is_supply, false) where id = p_ingredient_id;
  -- the value of what is on the shelf now moves once between 1200 and 1210
  select greatest(coalesce(sum(ws.quantity), 0), 0) into v_qty from public.warehouse_stock ws where ws.ingredient_id = p_ingredient_id;
  v_val := round(v_qty * v_cost, 2);
  if v_val > 0 then
    perform public.pos_post_je(c.company_id, c.branch_id, 'inventory', 'adjustment', p_ingredient_id,
      case when p_is_supply then 'تحويل رصيد إلى مستلزمات تشغيل: ' else 'تحويل رصيد من مستلزمات التشغيل: ' end || v_name,
      case when p_is_supply
           then jsonb_build_array(public.pos_je_line('1210', v_val, 0, null), public.pos_je_line('1200', 0, v_val, null))
           else jsonb_build_array(public.pos_je_line('1200', v_val, 0, null), public.pos_je_line('1210', 0, v_val, null)) end,
      c.staff_id);
  end if;
  insert into public.settings_logs (staff_id, action, details)
  values (c.staff_id, 'ingredient_supply', jsonb_build_object('ingredient', p_ingredient_id, 'name', v_name, 'is_supply', p_is_supply, 'value_moved', v_val));
  return jsonb_build_object('ok', true, 'is_supply', p_is_supply, 'moved', v_val);
end;
$$;

-- ---------------------------------------------------------------- 4) supply use: out of stock, into the expense 6810
-- p_lines: [{ingredient_id, qty}] (supply items only)
create or replace function public.inv_supply_use_secure(p_token text, p_warehouse_id uuid, p_lines jsonb, p_notes text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
  l jsonb;
  v_ing uuid;
  v_qty numeric;
  v_val numeric;
  v_total numeric := 0;
  v_wh_branch uuid;
  v_ref uuid := gen_random_uuid();
  v_note text := nullif(btrim(coalesce(p_notes, '')), '');
  v_names text := '';
begin
  select * into c from public.pos_ctx(p_token, 'inventory');
  if not public.pos_perm_ok(c.role_name, 'inv_waste') then
    return jsonb_build_object('ok', false, 'reason', 'not_allowed', 'perm', 'inv_waste');
  end if;
  if not public.pos_warehouse_ok(p_warehouse_id, c.branch_id, c.role_name) then
    return jsonb_build_object('ok', false, 'reason', 'warehouse_not_allowed');
  end if;
  if jsonb_typeof(p_lines) is distinct from 'array' or jsonb_array_length(p_lines) = 0 or jsonb_array_length(p_lines) > 100 then
    return jsonb_build_object('ok', false, 'reason', 'invalid_value');
  end if;
  for l in select e.value from jsonb_array_elements(p_lines) e(value) loop
    v_ing := public.pos_uuid(l->>'ingredient_id');
    v_qty := public.pos_num(l->>'qty');
    if v_qty is null or v_qty <= 0 or v_qty > 999999 then
      return jsonb_build_object('ok', false, 'reason', 'invalid_quantity');
    end if;
    if not exists (select 1 from public.ingredients i where i.id = v_ing and i.is_supply) then
      return jsonb_build_object('ok', false, 'reason', 'not_a_supply');
    end if;
  end loop;
  select w.branch_id into v_wh_branch from public.warehouses w where w.id = p_warehouse_id;

  for l in select e.value from jsonb_array_elements(p_lines) e(value) loop
    v_ing := public.pos_uuid(l->>'ingredient_id');
    v_qty := public.pos_num(l->>'qty');
    v_val := public.pos_stock_move(c.company_id, v_wh_branch, p_warehouse_id, v_ing, 'supply_use', -v_qty, null,
                                   'adjustment', v_ref, left('صرف مستلزمات' || coalesce(': ' || v_note, ''), 300), c.staff_id);
    v_total := v_total + coalesce(v_val, 0);
    v_names := v_names || case when v_names = '' then '' else '، ' end
               || (select i.name from public.ingredients i where i.id = v_ing) || ' ' || trim(to_char(v_qty, 'FM999999990.###'));
  end loop;
  -- Cr 1200 here; the supply move above already took the value from 1210 back to 1200, so in total Dr 6810 / Cr 1210
  perform public.pos_post_je(c.company_id, coalesce(v_wh_branch, c.branch_id), 'expense', 'adjustment', v_ref,
    left('صرف مستلزمات تشغيل: ' || v_names || coalesce(' - ' || v_note, ''), 500),
    jsonb_build_array(public.pos_je_line('6810', v_total, 0, 'مستلزمات تشغيل مستهلكة'),
                      public.pos_je_line('1200', 0, v_total, 'صرف من المخزن')), c.staff_id);
  return jsonb_build_object('ok', true, 'value', round(v_total, 2), 'ref', v_ref);
end;
$$;

-- what was used, per period (inventory view period applies)
create or replace function public.inv_supply_uses_secure(p_token text, p_warehouse_id uuid, p_from date, p_to date)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_lim date;
  c record;
  v_from date := coalesce(p_from, date_trunc('month', public.pos_local_date(now()))::date);
  v_to date := coalesce(p_to, public.pos_local_date(now()));
begin
  select * into c from public.pos_ctx(p_token, 'inventory');
  v_lim := public.pos_view_min(c.company_id, c.role_name, 'inventory');
  if v_lim is not null then
    if v_to < v_lim then
      return public.pos_view_refusal(c.company_id, c.role_name, 'inventory');
    end if;
    v_from := greatest(v_from, v_lim);
  end if;
  if not public.pos_warehouse_ok(p_warehouse_id, c.branch_id, c.role_name) then
    return jsonb_build_object('ok', false, 'reason', 'warehouse_not_allowed');
  end if;
  return jsonb_build_object('ok', true, 'from', v_from, 'to', v_to,
    'items', coalesce((
      select jsonb_agg(jsonb_build_object('name', q.name, 'unit', q.unit, 'qty', q.qty, 'value', q.value) order by q.value desc)
        from (select i.name, i.unit, -sum(sm.quantity) as qty, round(sum(abs(sm.quantity) * sm.unit_cost), 2) as value
                from public.stock_movements sm join public.ingredients i on i.id = sm.ingredient_id
               where sm.warehouse_id = p_warehouse_id and sm.movement_type = 'supply_use'
                 and public.pos_local_date(sm.created_at) between v_from and v_to
               group by i.name, i.unit) q), '[]'::jsonb),
    'moves', coalesce((
      select jsonb_agg(jsonb_build_object('at', sm.created_at, 'name', i.name, 'unit', i.unit, 'qty', -sm.quantity,
                                          'value', round(abs(sm.quantity) * sm.unit_cost, 2), 'notes', sm.notes, 'by', st.name)
                       order by sm.created_at desc)
        from public.stock_movements sm join public.ingredients i on i.id = sm.ingredient_id left join public.staff st on st.id = sm.created_by
       where sm.warehouse_id = p_warehouse_id and sm.movement_type = 'supply_use'
         and public.pos_local_date(sm.created_at) between v_from and v_to), '[]'::jsonb));
end;
$$;

-- ---------------------------------------------------------------- 5) the items review (043) also says which ones are supplies
create or replace function public.ingredients_review_secure(p_token text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
declare
  c record;
begin
  select * into c from public.pos_ctx(p_token, 'settings');
  return jsonb_build_object('ok', true, 'items', coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', i.id, 'name', i.name, 'unit', i.unit, 'pack_unit', i.pack_unit, 'pack_size', i.pack_size,
             'cost_per_unit', i.cost_per_unit, 'min_stock_alert', i.min_stock_alert, 'is_supply', i.is_supply,
             'stock', coalesce((select sum(ws.quantity) from public.warehouse_stock ws where ws.ingredient_id = i.id), 0),
             'came_in', coalesce((select sum(sm.quantity) from public.stock_movements sm where sm.ingredient_id = i.id and sm.quantity > 0), 0),
             'went_out', coalesce((select -sum(sm.quantity) from public.stock_movements sm where sm.ingredient_id = i.id and sm.quantity < 0), 0),
             'receipts', (select count(*) from public.goods_receipt_items gi where gi.ingredient_id = i.id),
             'used_in', coalesce((select jsonb_agg(jsonb_build_object('product', p.name, 'qty', r.quantity_required) order by p.name)
                                    from public.recipes r join public.products p on p.id = r.product_id where r.ingredient_id = i.id), '[]'::jsonb),
             'extras', (select count(*) from public.modifiers m where m.ingredient_id = i.id))
           order by i.name)
      from public.ingredients i
     where i.brand_id is null or i.brand_id in (select b.brand_id from public.branches b join public.brands br on br.id = b.brand_id
                                                 where br.company_id = c.company_id)), '[]'::jsonb));
end;
$$;

create or replace function public.motionpos_version_public()
returns text
language sql
immutable
as $$
  select '044'
$$;

do $grants$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and (p.proname like 'pos\_%' or p.proname like 'trg\_%')
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
  end loop;
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and (p.proname like '%\_secure' or p.proname like '%\_public')
  loop
    execute format('revoke all on function %s from public', f.sig);
    execute format('grant execute on function %s to anon, authenticated, service_role', f.sig);
  end loop;
end;
$grants$;

do $selftest$
declare
  v_co uuid;
  v_brand uuid;
  v_br uuid;
  v_wh uuid;
  v_ing uuid;
  v_tok text;
  v_res jsonb;
  v_1200 numeric;
  v_1210 numeric;
  v_6810 numeric;
begin
  begin
    perform set_config('motionpos.sync_apply', 'off', true);
    insert into public.companies (name) values ('selftest044') returning id into v_co;
    insert into public.brands (name, company_id) values ('selftest044', v_co) returning id into v_brand;
    insert into public.branches (name, brand_id) values ('selftest044', v_brand) returning id into v_br;
    insert into public.warehouses (name, branch_id) values ('selftest044', v_br) returning id into v_wh;
    insert into public.accounts (company_id, code, name_ar, account_type, normal_balance) values
      (v_co, '1200', 'stock', 'asset', 'debit'), (v_co, '1210', 'supplies', 'asset', 'debit'), (v_co, '6810', 'supplies used', 'expense', 'debit'),
      (v_co, '2100', 'suppliers', 'liability', 'credit');
    insert into public.staff (name, company_id, branch_id, is_active, pin_hash, role_id)
    values ('selftest044', v_co, v_br, true, extensions.crypt('4744', extensions.gen_salt('bf')), (select id from public.roles where name = 'owner' limit 1));
    v_tok := public.staff_login('4744')->>'session_token';
    insert into public.ingredients (name, unit, cost_per_unit, brand_id) values ('st044 napkins', 'pack', 10, v_brand) returning id into v_ing;
    -- 5 packs already on the shelf (bought as food stock), then marked as a supply: 50 moves to 1210
    perform public.pos_stock_move(v_co, v_br, v_wh, v_ing, 'purchase', 5, 10, 'purchase_order', null, 'st', null);
    perform public.pos_post_je(v_co, v_br, 'purchase', 'purchase_order', null, 'st', jsonb_build_array(public.pos_je_line('1200', 50, 0, null), public.pos_je_line('2100', 0, 50, null)), null);
    v_res := public.ingredient_supply_secure(v_tok, v_ing, true);
    if (v_res->>'moved')::numeric <> 50 then raise exception 'SELFTEST mark %', v_res; end if;
    -- 3 more packs received: the move itself puts 30 in 1210
    perform public.pos_stock_move(v_co, v_br, v_wh, v_ing, 'purchase', 3, 10, 'purchase_order', null, 'st', null);
    perform public.pos_post_je(v_co, v_br, 'purchase', 'purchase_order', null, 'st', jsonb_build_array(public.pos_je_line('1200', 30, 0, null), public.pos_je_line('2100', 0, 30, null)), null);
    -- 2 packs used
    v_res := public.inv_supply_use_secure(v_tok, v_wh, jsonb_build_array(jsonb_build_object('ingredient_id', v_ing, 'qty', 2)), 'tables');
    if not (v_res->>'ok')::boolean or (v_res->>'value')::numeric <> 20 then raise exception 'SELFTEST use %', v_res; end if;
    select coalesce(sum(l.debit - l.credit), 0) into v_1200 from public.journal_entry_lines l join public.journal_entries j on j.id = l.journal_entry_id join public.accounts a on a.id = l.account_id where j.company_id = v_co and a.code = '1200';
    select coalesce(sum(l.debit - l.credit), 0) into v_1210 from public.journal_entry_lines l join public.journal_entries j on j.id = l.journal_entry_id join public.accounts a on a.id = l.account_id where j.company_id = v_co and a.code = '1210';
    select coalesce(sum(l.debit - l.credit), 0) into v_6810 from public.journal_entry_lines l join public.journal_entries j on j.id = l.journal_entry_id join public.accounts a on a.id = l.account_id where j.company_id = v_co and a.code = '6810';
    if v_1200 <> 0 or v_1210 <> 60 or v_6810 <> 20 then raise exception 'SELFTEST balances 1200=% 1210=% 6810=%', v_1200, v_1210, v_6810; end if;
    if (select quantity from public.warehouse_stock where ingredient_id = v_ing) <> 6 then raise exception 'SELFTEST stock'; end if;
    if jsonb_array_length(public.inv_supply_uses_secure(v_tok, v_wh, null, null)->'items') <> 1 then raise exception 'SELFTEST uses list'; end if;
    if public.motionpos_version_public() <> '044' then raise exception 'SELFTEST version'; end if;
    raise notice 'MOTIONPOS-044-SELFTEST-OK';
    raise exception using errcode = 'P0099', message = 'selftest_rollback';
  exception when sqlstate 'P0099' then
    null;
  end;
end;
$selftest$;

notify pgrst, 'reload schema';

commit;
