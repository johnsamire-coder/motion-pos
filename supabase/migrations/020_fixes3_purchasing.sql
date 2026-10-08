-- 020_fixes3_purchasing.sql
-- Fixes pack 3B:
--   * purchasing in 3 steps: purchase order -> receiving (counts only, stock NOT moved) -> posting to the warehouse
--     (stock, average cost, supplier prices and the journal entry happen only at posting; posting needs 'inventory_approve')
--   * pending receipts can be cancelled before posting (quantities go back to the purchase order)
--   * purchase order: reject with a reason (manager PIN)
--   * supplier opening balance when the supplier is created (we owe him / he owes us) with its journal entry (account 3900)
--   * owner can add / delete custom roles (built-in roles are protected, a role with staff cannot be deleted)

begin;

do $preflight$
begin
  if length('إكراميات') <> 8 then
    raise exception 'file_encoding_broken: read the file as UTF-8';
  end if;
  if public.motionpos_version_public() not in ('019', '020') then
    raise exception 'schema_preflight_failed: run 019 first';
  end if;
end;
$preflight$;

-- 1) receipts get a status (old receipts were already posted) -----------------------------------------------
alter table public.goods_receipts add column if not exists status text not null default 'posted';
alter table public.goods_receipts add column if not exists posted_by uuid;
alter table public.goods_receipts add column if not exists posted_at timestamptz;
alter table public.goods_receipts add column if not exists value numeric(15,2) not null default 0;
do $c$
begin
  if not exists (select 1 from pg_constraint where conname = 'goods_receipts_status_check') then
    alter table public.goods_receipts add constraint goods_receipts_status_check check (status in ('pending', 'posted', 'voided'));
  end if;
end;
$c$;

-- 2) opening balance account --------------------------------------------------------------------------------
create or replace function public.pos_ensure_opening_account(p_company_id uuid)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not exists (select 1 from public.accounts a where a.code = '3900' and (a.company_id = p_company_id or a.company_id is null)) then
    insert into public.accounts (company_id, code, name_ar, name_en, account_type, normal_balance, is_system_account)
    values (p_company_id, '3900', 'أرصدة افتتاحية', 'Opening balances', 'equity', 'credit', true);
  end if;
end;
$$;

create or replace function public.suppliers_secure(p_token text, p_data jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
  v_id uuid;
  v_name text;
  v_open numeric;
  v_sign int;
begin
  select * into c from public.pos_ctx(p_token, 'purchasing');
  if p_data is not null then
    v_id := public.pos_uuid(p_data->>'id');
    v_name := nullif(btrim(coalesce(p_data->>'name', '')), '');
    if v_name is null or length(v_name) > 150 then
      return jsonb_build_object('ok', false, 'reason', 'invalid_name');
    end if;
    if v_id is null then
      insert into public.suppliers (company_id, name, phone, company_name, tax_number, payment_terms, is_active)
      values (c.company_id, v_name, left(coalesce(p_data->>'phone', ''), 30), left(coalesce(p_data->>'company_name', ''), 150),
              left(coalesce(p_data->>'tax_number', ''), 50), left(coalesce(p_data->>'payment_terms', 'cash'), 50), true)
      returning id into v_id;
      -- opening balance (only when the supplier is created): we_owe = we owe him, they_owe = he owes us
      v_open := coalesce(public.pos_amount(p_data->>'opening_amount'), 0);
      if v_open > 0 then
        v_sign := 1;
        if coalesce(p_data->>'opening_side', 'we_owe') = 'they_owe' then
          v_sign := -1;
        end if;
        perform public.pos_ensure_opening_account(c.company_id);
        perform public.pos_supplier_add(c.company_id, v_id, 'adjustment', v_sign * v_open, 'رصيد أول المدة', c.staff_id);
        if v_sign > 0 then
          perform public.pos_post_je(c.company_id, c.branch_id, 'adjustment', 'adjustment', v_id, 'رصيد أول المدة للمورد ' || v_name,
            jsonb_build_array(public.pos_je_line('3900', v_open, 0, 'أرصدة افتتاحية'), public.pos_je_line('2100', 0, v_open, 'مستحق للمورد')), c.staff_id);
        else
          perform public.pos_post_je(c.company_id, c.branch_id, 'adjustment', 'adjustment', v_id, 'رصيد أول المدة للمورد ' || v_name,
            jsonb_build_array(public.pos_je_line('2100', v_open, 0, 'مستحق من المورد'), public.pos_je_line('3900', 0, v_open, 'أرصدة افتتاحية')), c.staff_id);
        end if;
      end if;
    else
      update public.suppliers
         set name = v_name, phone = left(coalesce(p_data->>'phone', ''), 30),
             company_name = left(coalesce(p_data->>'company_name', ''), 150),
             tax_number = left(coalesce(p_data->>'tax_number', ''), 50),
             payment_terms = left(coalesce(p_data->>'payment_terms', 'cash'), 50),
             is_active = coalesce(p_data->>'is_active', 'true') = 'true'
       where id = v_id and company_id = c.company_id;
    end if;
  end if;
  return jsonb_build_object('ok', true, 'id', v_id, 'suppliers', coalesce((
    select jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name, 'phone', s.phone, 'company_name', s.company_name,
                                        'tax_number', s.tax_number, 'payment_terms', s.payment_terms, 'is_active', s.is_active,
                                        'balance', coalesce((select sum(l.amount) from public.supplier_ledger l where l.supplier_id = s.id), 0))
                     order by s.is_active desc, s.name)
      from public.suppliers s where s.company_id = c.company_id), '[]'::jsonb));
end;
$$;

drop function if exists public.po_action_secure(text, uuid, text, text);

create or replace function public.po_action_secure(p_token text, p_po_id uuid, p_action text, p_manager_pin text, p_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
  po public.purchase_orders%rowtype;
  v_manager uuid;
begin
  select * into c from public.pos_ctx(p_token, 'purchasing');
  select x.* into po from public.purchase_orders x where x.id = p_po_id and x.company_id = c.company_id for update;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'po_not_found');
  end if;
  if p_action = 'approve' then
    if po.status <> 'draft' then return jsonb_build_object('ok', false, 'reason', 'wrong_po_status'); end if;
    v_manager := public.verify_manager_pin(p_manager_pin, c.branch_id);
    if v_manager is null then return jsonb_build_object('ok', false, 'reason', 'manager_pin'); end if;
    update public.purchase_orders set status = 'approved', approved_by = v_manager, approved_at = now() where id = po.id;
  elsif p_action = 'reject' then
    if po.status <> 'draft' then return jsonb_build_object('ok', false, 'reason', 'wrong_po_status'); end if;
    if nullif(btrim(coalesce(p_reason, '')), '') is null then return jsonb_build_object('ok', false, 'reason', 'reason_required'); end if;
    v_manager := public.verify_manager_pin(p_manager_pin, c.branch_id);
    if v_manager is null then return jsonb_build_object('ok', false, 'reason', 'manager_pin'); end if;
    update public.purchase_orders
       set status = 'cancelled', notes = left('مرفوض: ' || btrim(p_reason) || coalesce(' | ' || nullif(notes, ''), ''), 500)
     where id = po.id;
  elsif p_action = 'cancel' then
    if po.status not in ('draft', 'approved') then return jsonb_build_object('ok', false, 'reason', 'wrong_po_status'); end if;
    update public.purchase_orders set status = 'cancelled' where id = po.id;
  elsif p_action = 'close' then
    if po.status not in ('partially_received', 'fully_received') then return jsonb_build_object('ok', false, 'reason', 'wrong_po_status'); end if;
    update public.purchase_orders set status = 'closed' where id = po.id;
  else
    return jsonb_build_object('ok', false, 'reason', 'unknown_action');
  end if;
  return jsonb_build_object('ok', true);
end;
$$;

-- 3) receiving: counts only --------------------------------------------------------------------------------------
create or replace function public.pos_po_receive(p_po_id uuid, p_lines jsonb, p_notes text, p_staff uuid, p_company uuid, p_branch uuid, p_role text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  po public.purchase_orders%rowtype;
  v_item public.purchase_order_items%rowtype;
  l jsonb;
  v_qty numeric;
  v_cost numeric;
  v_grn uuid;
  v_grn_num text;
  v_value numeric := 0;
  v_line numeric;
  v_remaining numeric;
begin
  select x.* into po from public.purchase_orders x where x.id = p_po_id and x.company_id = p_company for update;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'po_not_found');
  end if;
  if po.status not in ('approved', 'partially_received') then
    return jsonb_build_object('ok', false, 'reason', 'wrong_po_status');
  end if;
  if not public.pos_warehouse_ok(po.warehouse_id, p_branch, p_role) then
    return jsonb_build_object('ok', false, 'reason', 'warehouse_not_allowed');
  end if;
  if jsonb_typeof(p_lines) is distinct from 'array' or jsonb_array_length(p_lines) < 1 then
    return jsonb_build_object('ok', false, 'reason', 'invalid_items');
  end if;
  for l in select e.value from jsonb_array_elements(p_lines) e(value) loop
    select x.* into v_item from public.purchase_order_items x
     where x.id = public.pos_uuid(l->>'po_item_id') and x.purchase_order_id = po.id;
    v_qty := public.pos_amount(l->>'qty');
    if v_item.id is null or v_qty is null or v_qty > v_item.quantity - v_item.qty_received
       or (l ? 'unit_cost' and public.pos_amount(l->>'unit_cost') is null) then
      return jsonb_build_object('ok', false, 'reason', 'invalid_items');
    end if;
  end loop;

  v_grn_num := 'GRN-' || to_char(now(), 'YYYYMMDD') || '-' || lpad(((select count(*) from public.goods_receipts) + 1)::text, 4, '0');
  insert into public.goods_receipts (purchase_order_id, warehouse_id, grn_number, received_by, notes, status)
  values (po.id, po.warehouse_id, v_grn_num, p_staff, left(coalesce(p_notes, ''), 500), 'pending')
  returning id into v_grn;

  for l in select e.value from jsonb_array_elements(p_lines) e(value) loop
    select x.* into v_item from public.purchase_order_items x where x.id = (l->>'po_item_id')::uuid for update;
    v_qty := (l->>'qty')::numeric;
    continue when v_qty <= 0;
    v_cost := coalesce(public.pos_amount(l->>'unit_cost'), v_item.unit_price);
    v_line := round(v_qty * v_cost, 2);
    insert into public.goods_receipt_items (goods_receipt_id, ingredient_id, ordered_qty, received_qty, unit_cost, total_cost)
    values (v_grn, v_item.ingredient_id, v_item.quantity, v_qty, v_cost, v_line);
    update public.purchase_order_items set qty_received = qty_received + v_qty where id = v_item.id;
    v_value := v_value + v_line;
  end loop;
  update public.goods_receipts set value = v_value where id = v_grn;

  select coalesce(sum(x.quantity - x.qty_received), 0) into v_remaining from public.purchase_order_items x where x.purchase_order_id = po.id;
  if v_remaining <= 0 then
    update public.purchase_orders set status = 'fully_received' where id = po.id;
  else
    update public.purchase_orders set status = 'partially_received' where id = po.id;
  end if;
  return jsonb_build_object('ok', true, 'grn_id', v_grn, 'grn_number', v_grn_num, 'value', v_value);
end;
$$;

create or replace function public.po_receive_secure(p_token text, p_po_id uuid, p_lines jsonb, p_notes text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
begin
  select * into c from public.pos_ctx(p_token, 'purchasing');
  return public.pos_po_receive(p_po_id, p_lines, p_notes, c.staff_id, c.company_id, c.branch_id, c.role_name);
end;
$$;

-- 4) posting a receipt to the warehouse ------------------------------------------------------------------
create or replace function public.pos_gr_post(p_grn_id uuid, p_staff uuid, p_company uuid, p_branch uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  g public.goods_receipts%rowtype;
  po public.purchase_orders%rowtype;
  it record;
  v_stock numeric;
  v_old numeric;
  v_new numeric;
  v_value numeric := 0;
  v_wh_branch uuid;
begin
  select x.* into g from public.goods_receipts x where x.id = p_grn_id for update;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'grn_not_found');
  end if;
  select x.* into po from public.purchase_orders x where x.id = g.purchase_order_id and x.company_id = p_company for update;
  if po.id is null then
    return jsonb_build_object('ok', false, 'reason', 'grn_not_found');
  end if;
  if g.status <> 'pending' then
    return jsonb_build_object('ok', false, 'reason', 'grn_not_pending');
  end if;
  select w.branch_id into v_wh_branch from public.warehouses w where w.id = g.warehouse_id;
  for it in select gi.* from public.goods_receipt_items gi where gi.goods_receipt_id = g.id loop
    select coalesce(sum(ws.quantity), 0) into v_stock from public.warehouse_stock ws where ws.ingredient_id = it.ingredient_id;
    select coalesce(i.cost_per_unit, 0) into v_old from public.ingredients i where i.id = it.ingredient_id;
    if greatest(v_stock, 0) + it.received_qty > 0 then
      v_new := round((greatest(v_stock, 0) * v_old + it.received_qty * it.unit_cost) / (greatest(v_stock, 0) + it.received_qty), 4);
    else
      v_new := it.unit_cost;
    end if;
    if v_new <> v_old then
      update public.ingredients set cost_per_unit = v_new where id = it.ingredient_id;
      insert into public.ingredient_cost_history (ingredient_id, old_cost, new_cost, change_reason, reference_id)
      values (it.ingredient_id, v_old, v_new, 'purchase', g.id);
    end if;
    perform public.pos_stock_move(p_company, v_wh_branch, g.warehouse_id, it.ingredient_id, 'purchase', it.received_qty, it.unit_cost,
                                  'purchase_order', po.id, 'ترحيل ' || g.grn_number || ' - ' || coalesce(po.po_number, ''), p_staff);
    insert into public.supplier_prices (supplier_id, ingredient_id, unit_price)
    values (po.supplier_id, it.ingredient_id, it.unit_cost)
    on conflict (supplier_id, ingredient_id) do update set unit_price = excluded.unit_price;
    v_value := v_value + it.total_cost;
  end loop;
  update public.purchase_orders set received_value = received_value + v_value where id = po.id;
  perform public.pos_post_je(p_company, coalesce(v_wh_branch, p_branch), 'purchase', 'goods_receipt', g.id,
    'استلام بضاعة ' || g.grn_number || ' - ' || coalesce(po.po_number, ''),
    jsonb_build_array(public.pos_je_line('1200', v_value, 0, 'بضاعة مستلمة'),
                      public.pos_je_line('2150', 0, v_value, 'بضاعة لم تصل فاتورتها')), p_staff);
  update public.goods_receipts set status = 'posted', posted_by = p_staff, posted_at = now(), value = v_value where id = g.id;
  return jsonb_build_object('ok', true, 'grn_number', g.grn_number, 'value', v_value);
end;
$$;

create or replace function public.pos_gr_void(p_grn_id uuid, p_company uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  g public.goods_receipts%rowtype;
  it record;
  v_got numeric;
  v_remaining numeric;
begin
  select x.* into g from public.goods_receipts x where x.id = p_grn_id for update;
  if not found or not exists (select 1 from public.purchase_orders po where po.id = g.purchase_order_id and po.company_id = p_company) then
    return jsonb_build_object('ok', false, 'reason', 'grn_not_found');
  end if;
  if g.status <> 'pending' then
    return jsonb_build_object('ok', false, 'reason', 'grn_not_pending');
  end if;
  for it in select gi.* from public.goods_receipt_items gi where gi.goods_receipt_id = g.id loop
    update public.purchase_order_items x set qty_received = greatest(x.qty_received - it.received_qty, 0)
     where x.purchase_order_id = g.purchase_order_id and x.ingredient_id = it.ingredient_id;
  end loop;
  update public.goods_receipts set status = 'voided' where id = g.id;
  select coalesce(sum(x.qty_received), 0), coalesce(sum(x.quantity - x.qty_received), 0) into v_got, v_remaining
    from public.purchase_order_items x where x.purchase_order_id = g.purchase_order_id;
  if v_got <= 0 then
    update public.purchase_orders set status = 'approved' where id = g.purchase_order_id and status in ('partially_received', 'fully_received');
  elsif v_remaining > 0 then
    update public.purchase_orders set status = 'partially_received' where id = g.purchase_order_id and status in ('partially_received', 'fully_received');
  end if;
  return jsonb_build_object('ok', true);
end;
$$;

create or replace function public.gr_action_secure(p_token text, p_grn_id uuid, p_action text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
begin
  select * into c from public.pos_ctx(p_token, 'inventory_approve');
  if p_action = 'post' then
    return public.pos_gr_post(p_grn_id, c.staff_id, c.company_id, c.branch_id);
  elsif p_action = 'void' then
    return public.pos_gr_void(p_grn_id, c.company_id);
  end if;
  return jsonb_build_object('ok', false, 'reason', 'unknown_action');
end;
$$;

create or replace function public.gr_list_secure(p_token text, p_status text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
begin
  select * into c from public.pos_ctx(p_token, null);
  if c.role_name <> 'owner' and not exists (select 1 from public.role_permissions rp where rp.role_name = c.role_name and rp.perm in ('purchasing', 'inventory_approve')) then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  return jsonb_build_object('ok', true,
    'can_post', c.role_name = 'owner' or exists (select 1 from public.role_permissions rp where rp.role_name = c.role_name and rp.perm = 'inventory_approve'),
    'receipts', coalesce((
    select jsonb_agg(jsonb_build_object('id', g.id, 'grn_number', g.grn_number, 'status', g.status, 'received_at', g.received_at,
             'posted_at', g.posted_at, 'po_number', po.po_number, 'supplier', s.name, 'warehouse', w.name, 'notes', g.notes,
             'received_by', rb.name, 'posted_by', pb.name,
             'value', coalesce((select sum(gi.total_cost) from public.goods_receipt_items gi where gi.goods_receipt_id = g.id), 0),
             'lines', coalesce((select jsonb_agg(jsonb_build_object('ingredient', i.name, 'unit', i.unit, 'ordered', gi.ordered_qty,
                                       'qty', gi.received_qty, 'unit_cost', gi.unit_cost, 'total', gi.total_cost) order by i.name)
                                  from public.goods_receipt_items gi join public.ingredients i on i.id = gi.ingredient_id
                                 where gi.goods_receipt_id = g.id), '[]'::jsonb))
           order by g.received_at desc)
      from public.goods_receipts g
      join public.purchase_orders po on po.id = g.purchase_order_id
      join public.suppliers s on s.id = po.supplier_id
      left join public.warehouses w on w.id = g.warehouse_id
      left join public.staff rb on rb.id = g.received_by
      left join public.staff pb on pb.id = g.posted_by
     where po.company_id = c.company_id
       and (coalesce(p_status, 'pending') = 'all' or g.status = coalesce(p_status, 'pending'))
       and g.received_at > now() - interval '120 days'), '[]'::jsonb));
end;
$$;

-- 5) custom roles (owner only) -----------------------------------------------------------------------------
create or replace function public.role_admin_secure(p_token text, p_action text, p_name text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
  v_name text := btrim(coalesce(p_name, ''));
begin
  select * into c from public.pos_ctx(p_token, null);
  if c.role_name <> 'owner' then
    return jsonb_build_object('ok', false, 'reason', 'owner_only');
  end if;
  if length(v_name) < 2 or length(v_name) > 40 or v_name ~ '[<>"''`]' then
    return jsonb_build_object('ok', false, 'reason', 'invalid_name');
  end if;
  if p_action = 'add' then
    if exists (select 1 from public.roles r where lower(r.name) = lower(v_name)) then
      return jsonb_build_object('ok', false, 'reason', 'role_exists');
    end if;
    insert into public.roles (name) values (v_name);
  elsif p_action = 'delete' then
    if v_name in ('owner', 'branch_manager', 'cashier', 'waiter', 'storekeeper') then
      return jsonb_build_object('ok', false, 'reason', 'role_builtin');
    end if;
    if exists (select 1 from public.staff s join public.roles r on r.id = s.role_id where r.name = v_name) then
      return jsonb_build_object('ok', false, 'reason', 'role_in_use');
    end if;
    delete from public.role_permissions where role_name = v_name;
    delete from public.roles where name = v_name;
  else
    return jsonb_build_object('ok', false, 'reason', 'unknown_action');
  end if;
  insert into public.settings_logs (staff_id, action, details) values (c.staff_id, 'role_' || p_action, jsonb_build_object('role', v_name));
  return jsonb_build_object('ok', true);
end;
$$;

-- 6) version + grants -----------------------------------------------------------------------------------------
create or replace function public.motionpos_version_public()
returns text
language sql
immutable
as $$
  select '020'
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

-- 7) self-test (rolled back): receive -> nothing moves, post -> stock + journal, void, opening balance account ---
do $selftest$
declare
  v_company uuid; v_brand uuid; v_branch uuid; v_wh uuid; v_ing uuid; v_sup uuid; v_po uuid; v_item uuid;
  v_res jsonb; v_grn uuid; v_qty numeric; v_je int;
begin
  begin
    insert into public.companies (name) values ('selftest020') returning id into v_company;
    insert into public.brands (company_id, name) values (v_company, 'selftest020') returning id into v_brand;
    insert into public.branches (name, brand_id) values ('selftest020', v_brand) returning id into v_branch;
    insert into public.warehouses (name, branch_id, is_main) values ('selftest020', v_branch, true) returning id into v_wh;
    insert into public.ingredients (name, unit, cost_per_unit) values ('selftest020', 'kg', 10) returning id into v_ing;
    insert into public.suppliers (name) values ('selftest020') returning id into v_sup;
    insert into public.accounts (company_id, code, name_ar, name_en, account_type, normal_balance, is_system_account)
    values (v_company, '1200', 'مخزون', 'Inventory', 'asset', 'debit', true), (v_company, '2150', 'بضاعة لم تصل فاتورتها', 'GRNI', 'liability', 'credit', true);
    insert into public.purchase_orders (supplier_id, warehouse_id, company_id, branch_id, status, po_number, total_amount)
    values (v_sup, v_wh, v_company, v_branch, 'approved', 'PO-ST020', 100) returning id into v_po;
    insert into public.purchase_order_items (purchase_order_id, ingredient_id, quantity, unit_price, total_price)
    values (v_po, v_ing, 10, 10, 100) returning id into v_item;

    v_res := public.pos_po_receive(v_po, jsonb_build_array(jsonb_build_object('po_item_id', v_item, 'qty', 4, 'unit_cost', 12)), 'st', null, v_company, v_branch, 'owner');
    if (v_res->>'ok')::boolean is not true then raise exception 'SELFTEST receive failed: %', v_res; end if;
    v_grn := (v_res->>'grn_id')::uuid;
    select coalesce(sum(m.quantity), 0) into v_qty from public.stock_movements m where m.ingredient_id = v_ing;
    if v_qty <> 0 or (select status from public.purchase_orders where id = v_po) <> 'partially_received' then
      raise exception 'SELFTEST receive moved stock or wrong status';
    end if;

    v_res := public.pos_gr_void(v_grn, v_company);
    if (select qty_received from public.purchase_order_items where id = v_item) <> 0 or (select status from public.purchase_orders where id = v_po) <> 'approved' then
      raise exception 'SELFTEST void wrong: %', v_res;
    end if;

    v_res := public.pos_po_receive(v_po, jsonb_build_array(jsonb_build_object('po_item_id', v_item, 'qty', 10, 'unit_cost', 12)), 'st', null, v_company, v_branch, 'owner');
    v_grn := (v_res->>'grn_id')::uuid;
    v_res := public.pos_gr_post(v_grn, null, v_company, v_branch);
    if (v_res->>'ok')::boolean is not true then raise exception 'SELFTEST post failed: %', v_res; end if;
    select coalesce(sum(m.quantity), 0) into v_qty from public.stock_movements m where m.ingredient_id = v_ing;
    select count(*) into v_je from public.journal_entries j where j.reference_id = v_grn;
    if v_qty <> 10 or v_je <> 1 or (select received_value from public.purchase_orders where id = v_po) <> 120
       or (select status from public.goods_receipts where id = v_grn) <> 'posted' or (select cost_per_unit from public.ingredients where id = v_ing) <> 12 then
      raise exception 'SELFTEST post results wrong: qty % je %', v_qty, v_je;
    end if;
    v_res := public.pos_gr_post(v_grn, null, v_company, v_branch);
    if coalesce(v_res->>'reason', '') <> 'grn_not_pending' then raise exception 'SELFTEST double post allowed'; end if;

    perform public.pos_ensure_opening_account(v_company);
    if not exists (select 1 from public.accounts where company_id = v_company and code = '3900') then
      raise exception 'SELFTEST opening account missing';
    end if;

    raise notice 'MOTIONPOS-020-SELFTEST-OK';
    raise exception using errcode = 'P0099', message = 'selftest_rollback';
  exception when sqlstate 'P0099' then
    null;
  end;
end;
$selftest$;

commit;
