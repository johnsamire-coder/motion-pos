-- 040_po_cancel_lines.sql
-- Purchase order: refuse / cancel one or more lines and keep the rest (e.g. the owner approves the order without
-- one item). New po_lines_cancel_secure(token, po, line ids, reason, manager PIN):
--   * draft or approved: the chosen lines are removed;
--   * partially received: a line keeps only what was already received (nothing received = removed);
--   * the order total is worked out again; the reason and the removed items are written in the order notes;
--   * no line left = the order is cancelled; everything left fully received = fully received.
-- Who: the order approver (po_approve, or the branch manager for his small orders as in 034), or whoever can
-- create orders (po_create) once it is approved. Always with a manager PIN and a reason. No tables changed.
-- Rules: begin/commit, preflight (needs 039), version bump to 040, grants loop, rolled-back self-test.

begin;

do $preflight$
begin
  if length('إكراميات') <> 8 then
    raise exception 'file_encoding_broken: read the file as UTF-8';
  end if;
  if public.motionpos_version_public() not in ('039', '040') then
    raise exception 'schema_preflight_failed: run 039 first';
  end if;
end;
$preflight$;

create or replace function public.po_lines_cancel_secure(p_token text, p_po_id uuid, p_line_ids jsonb, p_reason text, p_manager_pin text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
  po public.purchase_orders%rowtype;
  v_manager uuid;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_ids uuid[];
  v_removed text;
  v_left int;
  v_status text;
  v_total numeric;
begin
  select * into c from public.pos_ctx(p_token, 'purchasing');
  select x.* into po from public.purchase_orders x where x.id = p_po_id and x.company_id = c.company_id for update;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'po_not_found');
  end if;
  if po.status not in ('draft', 'approved', 'partially_received') then
    return jsonb_build_object('ok', false, 'reason', 'wrong_po_status');
  end if;
  if not (public.pos_perm_ok(c.role_name, 'po_approve')
          or (po.status <> 'draft' and public.pos_perm_ok(c.role_name, 'po_create'))
          or (c.role_name = 'branch_manager' and public.pos_po_small_ok(c.company_id, c.branch_id, po.total_amount, po.id))) then
    return jsonb_build_object('ok', false, 'reason', 'not_allowed', 'perm', 'po_approve');
  end if;
  if v_reason is null then
    return jsonb_build_object('ok', false, 'reason', 'reason_required');
  end if;
  if jsonb_typeof(p_line_ids) is distinct from 'array' or jsonb_array_length(p_line_ids) = 0
     or exists (select 1 from jsonb_array_elements_text(p_line_ids) e(v) where public.pos_uuid(e.v) is null) then
    return jsonb_build_object('ok', false, 'reason', 'invalid_value');
  end if;
  select array_agg(distinct public.pos_uuid(e.v)) into v_ids from jsonb_array_elements_text(p_line_ids) e(v);
  if exists (select 1 from unnest(v_ids) u(id)
              where not exists (select 1 from public.purchase_order_items x where x.id = u.id and x.purchase_order_id = po.id)) then
    return jsonb_build_object('ok', false, 'reason', 'invalid_value');
  end if;
  if exists (select 1 from public.purchase_order_items x where x.id = any (v_ids) and x.qty_received >= x.quantity) then
    return jsonb_build_object('ok', false, 'reason', 'line_already_received');
  end if;
  v_manager := public.verify_manager_pin(p_manager_pin, c.branch_id);
  if v_manager is null then
    return jsonb_build_object('ok', false, 'reason', 'manager_pin');
  end if;

  select string_agg(i.name || ' ' || trim(to_char(x.quantity - x.qty_received, 'FM999999990.###')), '، ' order by i.name) into v_removed
    from public.purchase_order_items x join public.ingredients i on i.id = x.ingredient_id
   where x.id = any (v_ids);
  -- nothing received: the line goes; part received: it keeps only what came
  delete from public.purchase_order_items x where x.id = any (v_ids) and coalesce(x.qty_received, 0) = 0;
  update public.purchase_order_items x
     set quantity = x.qty_received, total_price = round(x.qty_received * x.unit_price, 2)
   where x.id = any (v_ids) and x.qty_received > 0;

  select count(*), coalesce(sum(x.total_price), 0) into v_left, v_total
    from public.purchase_order_items x where x.purchase_order_id = po.id;
  v_status := case when v_left = 0 then 'cancelled'
                   when po.status = 'partially_received'
                        and not exists (select 1 from public.purchase_order_items x
                                         where x.purchase_order_id = po.id and x.qty_received < x.quantity) then 'fully_received'
                   else po.status end;
  update public.purchase_orders
     set total_amount = round(v_total, 2), status = v_status,
         notes = left('أصناف ملغاة: ' || coalesce(v_removed, '') || ' - السبب: ' || v_reason || coalesce(' | ' || nullif(notes, ''), ''), 500)
   where id = po.id;
  insert into public.settings_logs (staff_id, action, details)
  values (c.staff_id, 'po_lines_cancel', jsonb_build_object('po', po.id, 'po_number', po.po_number, 'lines', to_jsonb(v_ids),
          'removed', v_removed, 'reason', v_reason, 'manager', v_manager));
  return jsonb_build_object('ok', true, 'status', v_status, 'total', round(v_total, 2), 'lines_left', v_left);
end;
$$;

create or replace function public.motionpos_version_public()
returns text
language sql
immutable
as $$
  select '040'
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
  v_br uuid;
  v_sup uuid;
  v_po uuid;
  v_a uuid;
  v_b uuid;
  v_i1 uuid;
  v_i2 uuid;
  v_tok text;
  v_res jsonb;
begin
  begin
    perform set_config('motionpos.sync_apply', 'on', true);
    insert into public.companies (name) values ('selftest040') returning id into v_co;
    insert into public.branches (name) values ('selftest040') returning id into v_br;
    insert into public.staff (name, company_id, branch_id, is_active, pin_hash, role_id)
    values ('selftest040', v_co, v_br, true, extensions.crypt('4740', extensions.gen_salt('bf')), (select id from public.roles where name = 'owner' limit 1));
    v_tok := public.staff_login('4740')->>'session_token';
    insert into public.suppliers (name, company_id) values ('selftest040', v_co) returning id into v_sup;
    insert into public.ingredients (name, unit) values ('selftest040 a', 'kg') returning id into v_i1;
    insert into public.ingredients (name, unit) values ('selftest040 b', 'kg') returning id into v_i2;
    insert into public.purchase_orders (supplier_id, total_amount, status, company_id) values (v_sup, 150, 'draft', v_co) returning id into v_po;
    insert into public.purchase_order_items (purchase_order_id, ingredient_id, quantity, unit_price, total_price, qty_received)
    values (v_po, v_i1, 1, 100, 100, 0) returning id into v_a;
    insert into public.purchase_order_items (purchase_order_id, ingredient_id, quantity, unit_price, total_price, qty_received)
    values (v_po, v_i2, 1, 50, 50, 0) returning id into v_b;
    if public.po_lines_cancel_secure(v_tok, v_po, jsonb_build_array(v_a), '', '4740')->>'reason' <> 'reason_required' then raise exception 'SELFTEST reason'; end if;
    v_res := public.po_lines_cancel_secure(v_tok, v_po, jsonb_build_array(v_a), 'not needed', '4740');
    if not (v_res->>'ok')::boolean or (v_res->>'total')::numeric <> 50 or v_res->>'status' <> 'draft' then raise exception 'SELFTEST one line %', v_res; end if;
    if exists (select 1 from public.purchase_order_items where id = v_a) then raise exception 'SELFTEST line still there'; end if;
    v_res := public.po_lines_cancel_secure(v_tok, v_po, jsonb_build_array(v_b), 'none left', '4740');
    if v_res->>'status' <> 'cancelled' then raise exception 'SELFTEST last line %', v_res; end if;
    if public.motionpos_version_public() <> '040' then raise exception 'SELFTEST version'; end if;
    raise notice 'MOTIONPOS-040-SELFTEST-OK';
    raise exception using errcode = 'P0099', message = 'selftest_rollback';
  exception when sqlstate 'P0099' then
    null;
  end;
end;
$selftest$;

notify pgrst, 'reload schema';

commit;
