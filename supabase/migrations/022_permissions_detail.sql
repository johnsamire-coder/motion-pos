-- 022_permissions_detail.sql
-- Detailed permissions inside the screens. The screen permission (purchasing, inventory, ...) opens the tab;
-- each action inside has its own permission, ticked per role in Staff -> Permissions. The owner always has everything.
-- Defaults keep what every role could do before, except: approving purchase orders and posting receipts to the stores
-- are the owner's (he can give them to any role). Custom roles get the same defaults as the branch manager.
-- + supplier invoice photo on the goods receipt (compressed, kept in the database, copied by the sync).
-- Rules: begin/commit, preflight, rolled-back self-test, grants loop. New table attached to the sync.

begin;

do $preflight$
begin
  if length('إكراميات') <> 8 then
    raise exception 'file_encoding_broken: read the file as UTF-8';
  end if;
  if public.motionpos_version_public() not in ('021', '022') then
    raise exception 'schema_preflight_failed: run 021 first';
  end if;
end;
$preflight$;

create or replace function public.pos_all_perms()
returns text[]
language sql
immutable
as $$
  select array['dashboard', 'pos', 'kds', 'shift', 'customers', 'sales', 'feedback', 'purchasing', 'po_create', 'po_approve', 'po_receive', 'po_post', 'po_invoice', 'supplier_pay', 'suppliers_manage', 'inventory', 'inv_waste', 'inv_transfer', 'inv_stocktake', 'inventory_approve', 'treasury', 'treasury_transfer', 'day_close', 'expenses', 'exp_record', 'exp_recurring', 'exp_categories', 'exp_custody', 'staff', 'staff_manage', 'payroll', 'payroll_approve', 'payroll_pay', 'reports', 'accounting', 'acc_manual', 'settings', 'settings_menu']
$$;

-- one place that answers "may this role do this?"
create or replace function public.pos_perm_ok(p_role text, p_perm text)
returns boolean
language sql
stable
security definer
set search_path = public, extensions
as $$
  select coalesce(p_role, '') = 'owner'
      or exists (select 1 from public.role_permissions rp where rp.role_name = p_role and rp.perm = p_perm)
$$;

-- defaults, only the first time (a second run or the other side of the sync never gives back what the owner removed)
do $defaults$
begin
  if not exists (select 1 from public.role_permissions where perm in ('po_create', 'po_approve', 'po_receive', 'po_post', 'po_invoice', 'supplier_pay', 'suppliers_manage', 'inv_waste', 'inv_transfer', 'inv_stocktake', 'treasury_transfer', 'day_close', 'exp_record', 'exp_recurring', 'exp_categories', 'exp_custody', 'staff_manage', 'payroll_approve', 'payroll_pay', 'acc_manual', 'settings_menu')) then
    insert into public.role_permissions (role_name, perm)
    select r.role_name, d.sub
      from (values ('po_create', 'purchasing', true, true), ('po_approve', 'purchasing', false, false), ('po_receive', 'purchasing', true, true), ('po_post', 'purchasing', false, false), ('po_invoice', 'purchasing', true, true), ('supplier_pay', 'purchasing', true, false), ('suppliers_manage', 'purchasing', true, true), ('inv_waste', 'inventory', true, true), ('inv_transfer', 'inventory', true, true), ('inv_stocktake', 'inventory', true, true), ('treasury_transfer', 'treasury', true, false), ('day_close', 'treasury', true, false), ('exp_record', 'expenses', true, false), ('exp_recurring', 'expenses', true, false), ('exp_categories', 'expenses', true, false), ('exp_custody', 'expenses', true, false), ('staff_manage', 'staff', true, false), ('payroll_approve', 'payroll', true, false), ('payroll_pay', 'payroll', true, false), ('acc_manual', 'accounting', true, false), ('settings_menu', 'settings', true, false)) d(sub, parent, mgr, sk)
      join (select distinct role_name from public.role_permissions where role_name <> 'owner') r on true
     where exists (select 1 from public.role_permissions x where x.role_name = r.role_name and x.perm = d.parent)
       and ((r.role_name = 'storekeeper' and d.sk) or (r.role_name <> 'storekeeper' and d.mgr))
    on conflict do nothing;
  end if;
end;
$defaults$;


-- po_create_secure: same as before + its permission check
create or replace function public.po_create_secure(
  p_token text, p_supplier_id uuid, p_warehouse_id uuid, p_lines jsonb, p_notes text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
  v_id uuid;
  v_num text;
  l jsonb;
  v_total numeric := 0;
  v_n int;
  v_d int;
begin
  select * into c from public.pos_ctx(p_token, 'purchasing');
  if not public.pos_perm_ok(c.role_name, 'po_create') then
    return jsonb_build_object('ok', false, 'reason', 'not_allowed', 'perm', 'po_create');
  end if;
  if not exists (select 1 from public.suppliers s where s.id = p_supplier_id and s.company_id = c.company_id and s.is_active is not false) then
    return jsonb_build_object('ok', false, 'reason', 'supplier_not_found');
  end if;
  if not public.pos_warehouse_ok(p_warehouse_id, c.branch_id, c.role_name) then
    return jsonb_build_object('ok', false, 'reason', 'warehouse_not_allowed');
  end if;
  if jsonb_typeof(p_lines) is distinct from 'array' or jsonb_array_length(p_lines) < 1 or jsonb_array_length(p_lines) > 200 then
    return jsonb_build_object('ok', false, 'reason', 'invalid_items');
  end if;
  select count(*), count(distinct e.value->>'ingredient_id') into v_n, v_d from jsonb_array_elements(p_lines) e(value);
  if v_n <> v_d then
    return jsonb_build_object('ok', false, 'reason', 'duplicate_item');
  end if;
  for l in select e.value from jsonb_array_elements(p_lines) e(value) loop
    if not exists (select 1 from public.ingredients i where i.id = public.pos_uuid(l->>'ingredient_id'))
       or coalesce(public.pos_amount(l->>'qty'), 0) <= 0 or public.pos_amount(l->>'unit_price') is null then
      return jsonb_build_object('ok', false, 'reason', 'invalid_items');
    end if;
    v_total := v_total + round((l->>'qty')::numeric * (l->>'unit_price')::numeric, 2);
  end loop;

  v_num := 'PO-' || to_char(now(), 'YYYY') || '-' || lpad(((select count(*) from public.purchase_orders) + 1)::text, 5, '0');
  insert into public.purchase_orders (supplier_id, warehouse_id, total_amount, status, po_number, notes, company_id, branch_id, created_by)
  values (p_supplier_id, p_warehouse_id, v_total, 'draft', v_num, left(coalesce(p_notes, ''), 500), c.company_id, c.branch_id, c.staff_id)
  returning id into v_id;
  insert into public.purchase_order_items (purchase_order_id, ingredient_id, quantity, unit_price, total_price)
  select v_id, (e.value->>'ingredient_id')::uuid, (e.value->>'qty')::numeric, (e.value->>'unit_price')::numeric,
         round((e.value->>'qty')::numeric * (e.value->>'unit_price')::numeric, 2)
    from jsonb_array_elements(p_lines) e(value);
  return jsonb_build_object('ok', true, 'id', v_id, 'po_number', v_num, 'total', v_total);
end;
$$;


-- po_action_secure: same as before + its permission check
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
  if p_action in ('approve', 'reject') and not public.pos_perm_ok(c.role_name, 'po_approve') then
    return jsonb_build_object('ok', false, 'reason', 'not_allowed', 'perm', 'po_approve');
  end if;
  if p_action in ('cancel', 'close') and not public.pos_perm_ok(c.role_name, 'po_create') then
    return jsonb_build_object('ok', false, 'reason', 'not_allowed', 'perm', 'po_create');
  end if;
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


-- po_receive_secure: same as before + its permission check
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
  if not public.pos_perm_ok(c.role_name, 'po_receive') then
    return jsonb_build_object('ok', false, 'reason', 'not_allowed', 'perm', 'po_receive');
  end if;
  return public.pos_po_receive(p_po_id, p_lines, p_notes, c.staff_id, c.company_id, c.branch_id, c.role_name);
end;
$$;


-- supplier_invoice_secure: same as before + its permission check
create or replace function public.supplier_invoice_secure(
  p_token text, p_po_id uuid, p_invoice_number text, p_invoice_date date, p_amount numeric, p_tax_amount numeric)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
  po public.purchase_orders%rowtype;
  v_amount numeric := round(coalesce(p_amount, -1), 2);
  v_tax numeric := round(coalesce(p_tax_amount, 0), 2);
  v_uninv numeric;
  v_diff numeric;
  v_matched boolean;
  v_id uuid;
begin
  select * into c from public.pos_ctx(p_token, 'purchasing');
  if not public.pos_perm_ok(c.role_name, 'po_invoice') then
    return jsonb_build_object('ok', false, 'reason', 'not_allowed', 'perm', 'po_invoice');
  end if;
  select x.* into po from public.purchase_orders x where x.id = p_po_id and x.company_id = c.company_id for update;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'po_not_found');
  end if;
  if po.status not in ('partially_received', 'fully_received', 'closed') then
    return jsonb_build_object('ok', false, 'reason', 'wrong_po_status');
  end if;
  if nullif(btrim(coalesce(p_invoice_number, '')), '') is null then
    return jsonb_build_object('ok', false, 'reason', 'invalid_value');
  end if;
  if v_amount < 0 or v_amount > 100000000 or v_tax < 0 or v_tax > v_amount then
    return jsonb_build_object('ok', false, 'reason', 'invalid_amount');
  end if;
  if exists (select 1 from public.supplier_invoices i where i.supplier_id = po.supplier_id and i.invoice_number = btrim(p_invoice_number)) then
    return jsonb_build_object('ok', false, 'reason', 'invoice_duplicate');
  end if;
  v_uninv := po.received_value - po.invoiced_value;
  if v_uninv <= 0 then
    return jsonb_build_object('ok', false, 'reason', 'nothing_to_invoice');
  end if;
  v_diff := v_amount - v_uninv;
  v_matched := abs(v_diff) <= greatest(1, v_uninv * 0.005);

  insert into public.supplier_invoices (company_id, supplier_id, purchase_order_id, invoice_number, invoice_date, amount,
                                        tax_amount, received_value, difference, matched, created_by)
  values (c.company_id, po.supplier_id, po.id, btrim(p_invoice_number), coalesce(p_invoice_date, current_date), v_amount,
          v_tax, v_uninv, v_diff, v_matched, c.staff_id)
  returning id into v_id;

  perform public.pos_post_je(c.company_id, c.branch_id, 'purchase', 'supplier_invoice', v_id,
    'فاتورة مورد ' || btrim(p_invoice_number) || ' - ' || coalesce(po.po_number, ''),
    jsonb_build_array(public.pos_je_line('2150', v_uninv, 0, 'تسوية بضاعة مستلمة'),
                      public.pos_je_line('1150', v_tax, 0, 'ضريبة مدخلات'),
                      public.pos_je_line('1200', greatest(v_diff, 0), greatest(-v_diff, 0), 'فرق سعر الفاتورة عن الاستلام'),
                      public.pos_je_line('2100', 0, v_amount + v_tax, 'مستحق للمورد')), c.staff_id);

  perform public.pos_supplier_add(c.company_id, po.supplier_id, 'invoice', v_amount + v_tax,
                                  'فاتورة ' || btrim(p_invoice_number), c.staff_id);
  update public.purchase_orders set invoiced_value = received_value where id = po.id;

  return jsonb_build_object('ok', true, 'matched', v_matched, 'difference', v_diff, 'received_value', v_uninv);
end;
$$;


-- supplier_payment_secure: same as before + its permission check
create or replace function public.supplier_payment_secure(
  p_token text, p_supplier_id uuid, p_amount numeric, p_source text, p_reference text, p_notes text, p_owner_pin text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
  v_amount numeric := round(coalesce(p_amount, 0), 2);
  v_src jsonb;
  v_refuse jsonb;
  v_shift uuid;
  v_id uuid;
begin
  select * into c from public.pos_ctx(p_token, 'purchasing');
  if not public.pos_perm_ok(c.role_name, 'supplier_pay') then
    return jsonb_build_object('ok', false, 'reason', 'not_allowed', 'perm', 'supplier_pay');
  end if;
  if not public.pos_perm_ok(c.role_name, 'supplier_pay')
     and not exists (select 1 from public.role_permissions rp where rp.role_name = c.role_name and rp.perm = 'treasury') then
    return jsonb_build_object('ok', false, 'reason', 'not_allowed');
  end if;
  if not exists (select 1 from public.suppliers s where s.id = p_supplier_id and s.company_id = c.company_id) then
    return jsonb_build_object('ok', false, 'reason', 'supplier_not_found');
  end if;
  if v_amount <= 0 or v_amount > 100000000 then
    return jsonb_build_object('ok', false, 'reason', 'invalid_amount');
  end if;
  v_src := public.pos_source_check(c.staff_id, p_source, v_amount);
  if not (v_src->>'ok')::boolean then
    return v_src;
  end if;
  v_shift := public.pos_uuid(v_src->>'shift_id');
  v_refuse := public.pos_spend_check(c.role_name, c.company_id, v_amount, p_owner_pin);
  if v_refuse is not null then
    return v_refuse;
  end if;

  insert into public.supplier_payments (company_id, supplier_id, amount, payment_method, reference_number, paid_by, notes)
  values (c.company_id, p_supplier_id, v_amount, case when p_source = 'bank' then 'bank_transfer' else 'cash' end,
          left(coalesce(p_reference, ''), 100), c.staff_id, left(coalesce(p_notes, ''), 300))
  returning id into v_id;
  if p_source = 'drawer' then
    insert into public.pos_cash_moves (shift_id, company_id, branch_id, move_type, amount, source, destination, reason, staff_id)
    values (v_shift, c.company_id, c.branch_id, 'supplier_payment', v_amount, 'drawer', 'supplier', left(coalesce(p_notes, 'سداد مورد'), 300), c.staff_id);
  end if;
  perform public.pos_post_je(c.company_id, c.branch_id, 'payment', 'supplier_payment', v_id, 'سداد مورد',
    jsonb_build_array(public.pos_je_line('2100', v_amount, 0, 'سداد مورد'),
                      public.pos_je_line(public.pos_box_code(p_source), 0, v_amount, 'سداد مورد')), c.staff_id);
  perform public.pos_supplier_add(c.company_id, p_supplier_id, 'payment', -v_amount, 'سداد ' || coalesce(p_reference, ''), c.staff_id);
  return jsonb_build_object('ok', true);
end;
$$;


-- suppliers_secure: same as before + its permission check
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
  if p_data is not null and not public.pos_perm_ok(c.role_name, 'suppliers_manage') then
    return jsonb_build_object('ok', false, 'reason', 'not_allowed', 'perm', 'suppliers_manage');
  end if;
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


-- inv_waste_secure: same as before + its permission check
create or replace function public.inv_waste_secure(
  p_token text, p_warehouse_id uuid, p_ingredient_id uuid, p_quantity numeric, p_reason text, p_manager_pin text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
  v_manager uuid;
  v_unit numeric;
  v_cost numeric;
  v_waste_id uuid;
  v_wh_branch uuid;
begin
  select * into c from public.pos_ctx(p_token, 'inventory');
  if not public.pos_perm_ok(c.role_name, 'inv_waste') then
    return jsonb_build_object('ok', false, 'reason', 'not_allowed', 'perm', 'inv_waste');
  end if;
  if not public.pos_warehouse_ok(p_warehouse_id, c.branch_id, c.role_name) then
    return jsonb_build_object('ok', false, 'reason', 'warehouse_not_allowed');
  end if;
  if p_quantity is null or p_quantity <= 0 or p_quantity > 999999 then
    return jsonb_build_object('ok', false, 'reason', 'invalid_quantity');
  end if;
  if nullif(btrim(coalesce(p_reason, '')), '') is null then
    return jsonb_build_object('ok', false, 'reason', 'reason_required');
  end if;
  if not exists (select 1 from public.ingredients i where i.id = p_ingredient_id) then
    return jsonb_build_object('ok', false, 'reason', 'ingredient_not_found');
  end if;
  v_manager := public.verify_manager_pin(p_manager_pin, c.branch_id);
  if v_manager is null then
    return jsonb_build_object('ok', false, 'reason', 'manager_pin');
  end if;

  select coalesce(i.cost_per_unit, 0) into v_unit from public.ingredients i where i.id = p_ingredient_id;
  v_cost := round(p_quantity * v_unit, 2);
  select w.branch_id into v_wh_branch from public.warehouses w where w.id = p_warehouse_id;

  insert into public.waste_logs (warehouse_id, ingredient_id, quantity, reason, cost_loss)
  values (p_warehouse_id, p_ingredient_id, p_quantity, left(btrim(p_reason), 200), v_cost)
  returning id into v_waste_id;

  perform public.pos_stock_move(c.company_id, v_wh_branch, p_warehouse_id, p_ingredient_id, 'waste', -p_quantity, v_unit,
                                'waste_log', v_waste_id, 'هالك: ' || left(btrim(p_reason), 200), c.staff_id);

  perform public.pos_post_je(c.company_id, coalesce(v_wh_branch, c.branch_id), 'inventory', 'waste_log', v_waste_id,
    'هالك مخزن: ' || left(btrim(p_reason), 200),
    jsonb_build_array(public.pos_je_line('5100', v_cost, 0, 'تكلفة هالك'),
                      public.pos_je_line('1200', 0, v_cost, 'خصم الهالك من المخزون')), c.staff_id);

  return jsonb_build_object('ok', true, 'cost', v_cost, 'approved_by', v_manager);
end;
$$;


-- inv_transfer_request_secure: same as before + its permission check
create or replace function public.inv_transfer_request_secure(
  p_token text, p_from_warehouse_id uuid, p_to_warehouse_id uuid, p_lines jsonb, p_notes text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
  v_id uuid;
  v_num text;
  l jsonb;
  v_n int;
  v_d int;
begin
  select * into c from public.pos_ctx(p_token, 'inventory');
  if not public.pos_perm_ok(c.role_name, 'inv_transfer') then
    return jsonb_build_object('ok', false, 'reason', 'not_allowed', 'perm', 'inv_transfer');
  end if;
  if p_from_warehouse_id is null or p_to_warehouse_id is null or p_from_warehouse_id = p_to_warehouse_id
     or not exists (select 1 from public.warehouses w where w.id = p_to_warehouse_id)
     or not exists (select 1 from public.warehouses w where w.id = p_from_warehouse_id) then
    return jsonb_build_object('ok', false, 'reason', 'invalid_warehouses');
  end if;
  if not public.pos_warehouse_ok(p_from_warehouse_id, c.branch_id, c.role_name)
     and not public.pos_warehouse_ok(p_to_warehouse_id, c.branch_id, c.role_name) then
    return jsonb_build_object('ok', false, 'reason', 'warehouse_not_allowed');
  end if;
  if jsonb_typeof(p_lines) is distinct from 'array' or jsonb_array_length(p_lines) < 1 or jsonb_array_length(p_lines) > 200 then
    return jsonb_build_object('ok', false, 'reason', 'invalid_items');
  end if;
  select count(*), count(distinct e.value->>'ingredient_id') into v_n, v_d from jsonb_array_elements(p_lines) e(value);
  if v_n <> v_d then
    return jsonb_build_object('ok', false, 'reason', 'duplicate_item');
  end if;
  for l in select e.value from jsonb_array_elements(p_lines) e(value) loop
    if public.pos_uuid(l->>'ingredient_id') is null or coalesce(public.pos_amount(l->>'qty'), 0) <= 0
       or not exists (select 1 from public.ingredients i where i.id = public.pos_uuid(l->>'ingredient_id')) then
      return jsonb_build_object('ok', false, 'reason', 'invalid_items');
    end if;
  end loop;

  v_num := 'TR-' || to_char(now(), 'YYYYMMDD') || '-' || lpad(((select count(*) from public.inv_transfers) + 1)::text, 4, '0');
  insert into public.inv_transfers (company_id, transfer_number, from_warehouse_id, to_warehouse_id, notes, requested_by)
  values (c.company_id, v_num, p_from_warehouse_id, p_to_warehouse_id, left(coalesce(p_notes, ''), 500), c.staff_id)
  returning id into v_id;
  insert into public.inv_transfer_lines (transfer_id, ingredient_id, qty_requested)
  select v_id, (e.value->>'ingredient_id')::uuid, (e.value->>'qty')::numeric from jsonb_array_elements(p_lines) e(value);

  return jsonb_build_object('ok', true, 'id', v_id, 'transfer_number', v_num);
end;
$$;


-- inv_transfer_action_secure: same as before + its permission check
create or replace function public.inv_transfer_action_secure(
  p_token text, p_transfer_id uuid, p_action text, p_lines jsonb, p_manager_pin text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
  t public.inv_transfers%rowtype;
  v_manager uuid;
  v_ln public.inv_transfer_lines%rowtype;
  v_qty numeric;
  v_unit numeric;
  v_from_branch uuid;
  v_to_branch uuid;
  v_missing numeric := 0;
  l jsonb;
begin
  select * into c from public.pos_ctx(p_token, 'inventory');
  if p_action in ('ship', 'receive', 'cancel') and not public.pos_perm_ok(c.role_name, 'inv_transfer') then
    return jsonb_build_object('ok', false, 'reason', 'not_allowed', 'perm', 'inv_transfer');
  end if;
  select x.* into t from public.inv_transfers x where x.id = p_transfer_id for update;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'transfer_not_found');
  end if;
  select w.branch_id into v_from_branch from public.warehouses w where w.id = t.from_warehouse_id;
  select w.branch_id into v_to_branch from public.warehouses w where w.id = t.to_warehouse_id;

  if p_action = 'approve' then
    if t.status <> 'requested' then return jsonb_build_object('ok', false, 'reason', 'wrong_transfer_status'); end if;
    if not public.pos_warehouse_ok(t.from_warehouse_id, c.branch_id, c.role_name) then
      return jsonb_build_object('ok', false, 'reason', 'warehouse_not_allowed');
    end if;
    v_manager := public.verify_manager_pin(p_manager_pin, c.branch_id);
    if v_manager is null then return jsonb_build_object('ok', false, 'reason', 'manager_pin'); end if;
    update public.inv_transfers set status = 'approved', approved_by = v_manager, approved_at = now() where id = t.id;

  elsif p_action = 'ship' then
    if t.status <> 'approved' then return jsonb_build_object('ok', false, 'reason', 'wrong_transfer_status'); end if;
    if not public.pos_warehouse_ok(t.from_warehouse_id, c.branch_id, c.role_name) then
      return jsonb_build_object('ok', false, 'reason', 'warehouse_not_allowed');
    end if;
    for v_ln in select x.* from public.inv_transfer_lines x where x.transfer_id = t.id loop
      select coalesce(public.pos_amount(e.value->>'qty'), -1) into v_qty
        from jsonb_array_elements(coalesce(p_lines, '[]'::jsonb)) e(value)
       where e.value->>'ingredient_id' = v_ln.ingredient_id::text limit 1;
      v_qty := coalesce(v_qty, v_ln.qty_requested);
      if v_qty < 0 then return jsonb_build_object('ok', false, 'reason', 'invalid_items'); end if;
      select coalesce(i.cost_per_unit, 0) into v_unit from public.ingredients i where i.id = v_ln.ingredient_id;
      if v_qty > 0 then
        perform public.pos_stock_move(c.company_id, v_from_branch, t.from_warehouse_id, v_ln.ingredient_id, 'transfer_out', -v_qty,
                                      v_unit, 'stock_transfer', t.id, 'تحويل صادر ' || t.transfer_number, c.staff_id);
      end if;
      update public.inv_transfer_lines set qty_shipped = v_qty, unit_cost = v_unit where id = v_ln.id;
    end loop;
    update public.inv_transfers set status = 'shipped', shipped_by = c.staff_id, shipped_at = now() where id = t.id;

  elsif p_action = 'receive' then
    if t.status <> 'shipped' then return jsonb_build_object('ok', false, 'reason', 'wrong_transfer_status'); end if;
    if not public.pos_warehouse_ok(t.to_warehouse_id, c.branch_id, c.role_name) then
      return jsonb_build_object('ok', false, 'reason', 'warehouse_not_allowed');
    end if;
    for v_ln in select x.* from public.inv_transfer_lines x where x.transfer_id = t.id loop
      select coalesce(public.pos_amount(e.value->>'qty'), -1) into v_qty
        from jsonb_array_elements(coalesce(p_lines, '[]'::jsonb)) e(value)
       where e.value->>'ingredient_id' = v_ln.ingredient_id::text limit 1;
      v_qty := coalesce(v_qty, v_ln.qty_shipped);
      if v_qty < 0 or v_qty > v_ln.qty_shipped then return jsonb_build_object('ok', false, 'reason', 'invalid_items'); end if;
      if v_qty > 0 then
        perform public.pos_stock_move(c.company_id, v_to_branch, t.to_warehouse_id, v_ln.ingredient_id, 'transfer_in', v_qty,
                                      v_ln.unit_cost, 'stock_transfer', t.id, 'تحويل وارد ' || t.transfer_number, c.staff_id);
      end if;
      v_missing := v_missing + round((v_ln.qty_shipped - v_qty) * v_ln.unit_cost, 2);
      update public.inv_transfer_lines set qty_received = v_qty where id = v_ln.id;
    end loop;
    perform public.pos_post_je(c.company_id, coalesce(v_to_branch, c.branch_id), 'inventory', 'stock_transfer', t.id,
      'عجز استلام تحويل ' || t.transfer_number,
      jsonb_build_array(public.pos_je_line('5300', v_missing, 0, 'عجز تحويل'),
                        public.pos_je_line('1200', 0, v_missing, 'عجز تحويل')), c.staff_id);
    update public.inv_transfers set status = 'received', received_by = c.staff_id, received_at = now() where id = t.id;

  elsif p_action = 'cancel' then
    if t.status not in ('requested', 'approved') then return jsonb_build_object('ok', false, 'reason', 'wrong_transfer_status'); end if;
    update public.inv_transfers set status = 'cancelled' where id = t.id;

  else
    return jsonb_build_object('ok', false, 'reason', 'unknown_action');
  end if;

  return jsonb_build_object('ok', true, 'missing_value', v_missing);
end;
$$;


-- inv_stocktake_secure: same as before + its permission check
create or replace function public.inv_stocktake_secure(
  p_token text, p_warehouse_id uuid, p_lines jsonb, p_notes text, p_manager_pin text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
  v_manager uuid;
  v_count_id uuid;
  v_wh_branch uuid;
  l jsonb;
  v_ing uuid;
  v_actual numeric;
  v_current numeric;
  v_var numeric;
  v_unit numeric;
  v_var_cost numeric;
  v_short numeric := 0;
  v_over numeric := 0;
  v_result jsonb := '[]'::jsonb;
  v_n int;
  v_d int;
begin
  select * into c from public.pos_ctx(p_token, 'inventory');
  if not public.pos_perm_ok(c.role_name, 'inv_stocktake') then
    return jsonb_build_object('ok', false, 'reason', 'not_allowed', 'perm', 'inv_stocktake');
  end if;
  if not public.pos_warehouse_ok(p_warehouse_id, c.branch_id, c.role_name) then
    return jsonb_build_object('ok', false, 'reason', 'warehouse_not_allowed');
  end if;
  if jsonb_typeof(p_lines) is distinct from 'array' or jsonb_array_length(p_lines) < 1 or jsonb_array_length(p_lines) > 500 then
    return jsonb_build_object('ok', false, 'reason', 'invalid_items');
  end if;
  select count(*), count(distinct e.value->>'ingredient_id') into v_n, v_d from jsonb_array_elements(p_lines) e(value);
  if v_n <> v_d then
    return jsonb_build_object('ok', false, 'reason', 'duplicate_item');
  end if;
  for l in select e.value from jsonb_array_elements(p_lines) e(value) loop
    if public.pos_uuid(l->>'ingredient_id') is null or public.pos_amount(l->>'actual_qty') is null
       or not exists (select 1 from public.ingredients i where i.id = public.pos_uuid(l->>'ingredient_id')) then
      return jsonb_build_object('ok', false, 'reason', 'invalid_items');
    end if;
  end loop;
  v_manager := public.verify_manager_pin(p_manager_pin, c.branch_id);
  if v_manager is null then
    return jsonb_build_object('ok', false, 'reason', 'manager_pin');
  end if;

  select w.branch_id into v_wh_branch from public.warehouses w where w.id = p_warehouse_id;
  insert into public.inv_counts (company_id, warehouse_id, counted_by, approved_by, notes)
  values (c.company_id, p_warehouse_id, c.staff_id, v_manager, left(coalesce(p_notes, ''), 500))
  returning id into v_count_id;

  for l in select e.value from jsonb_array_elements(p_lines) e(value) loop
    v_ing := (l->>'ingredient_id')::uuid;
    v_actual := (l->>'actual_qty')::numeric;
    insert into public.warehouse_stock (warehouse_id, ingredient_id, quantity)
    values (p_warehouse_id, v_ing, 0) on conflict (warehouse_id, ingredient_id) do nothing;
    select ws.quantity into v_current from public.warehouse_stock ws
     where ws.warehouse_id = p_warehouse_id and ws.ingredient_id = v_ing for update;
    v_var := v_actual - coalesce(v_current, 0);
    select coalesce(i.cost_per_unit, 0) into v_unit from public.ingredients i where i.id = v_ing;
    v_var_cost := round(v_var * v_unit, 2);
    insert into public.stock_takes (warehouse_id, ingredient_id, theoretical_qty, actual_qty, variance_qty, variance_cost, count_id)
    values (p_warehouse_id, v_ing, coalesce(v_current, 0), v_actual, v_var, v_var_cost, v_count_id);
    if v_var <> 0 then
      perform public.pos_stock_move(c.company_id, v_wh_branch, p_warehouse_id, v_ing, 'adjustment', v_var, v_unit,
                                    'stocktake', v_count_id, 'فرق جرد', c.staff_id);
      if v_var_cost < 0 then v_short := v_short - v_var_cost; else v_over := v_over + v_var_cost; end if;
    end if;
    v_result := v_result || jsonb_build_array(jsonb_build_object(
      'ingredient_id', v_ing, 'system_qty', coalesce(v_current, 0), 'actual_qty', v_actual,
      'variance_qty', v_var, 'variance_cost', v_var_cost));
  end loop;

  perform public.pos_post_je(c.company_id, coalesce(v_wh_branch, c.branch_id), 'inventory', 'stocktake', v_count_id,
    'تسوية جرد',
    jsonb_build_array(public.pos_je_line('5300', v_short, 0, 'عجز جرد'),
                      public.pos_je_line('1200', 0, v_short, 'عجز جرد')), c.staff_id);
  perform public.pos_post_je(c.company_id, coalesce(v_wh_branch, c.branch_id), 'inventory', 'stocktake', v_count_id,
    'تسوية جرد',
    jsonb_build_array(public.pos_je_line('1200', v_over, 0, 'زيادة جرد'),
                      public.pos_je_line('5300', 0, v_over, 'زيادة جرد')), c.staff_id);

  update public.inv_counts set total_variance_cost = v_over - v_short where id = v_count_id;

  return jsonb_build_object('ok', true, 'count_id', v_count_id, 'shortage_value', v_short,
                            'overage_value', v_over, 'lines', v_result);
end;
$$;


-- treasury_transfer_secure: same as before + its permission check
create or replace function public.treasury_transfer_secure(
  p_token text, p_from text, p_to text, p_amount numeric, p_reason text, p_manager_pin text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
  v_amount numeric := round(coalesce(p_amount, 0), 2);
  v_manager uuid;
  v_ref uuid := gen_random_uuid();
begin
  select * into c from public.pos_ctx(p_token, 'treasury');
  if not public.pos_perm_ok(c.role_name, 'treasury_transfer') then
    return jsonb_build_object('ok', false, 'reason', 'not_allowed', 'perm', 'treasury_transfer');
  end if;
  if coalesce(p_from, '') not in ('main_cash', 'bank', 'owner') or coalesce(p_to, '') not in ('main_cash', 'bank', 'owner')
     or p_from = p_to then
    return jsonb_build_object('ok', false, 'reason', 'invalid_destination');
  end if;
  if v_amount <= 0 or v_amount > 100000000 then
    return jsonb_build_object('ok', false, 'reason', 'invalid_amount');
  end if;
  if nullif(btrim(coalesce(p_reason, '')), '') is null then
    return jsonb_build_object('ok', false, 'reason', 'reason_required');
  end if;
  v_manager := public.verify_manager_pin(p_manager_pin, c.branch_id);
  if v_manager is null then
    return jsonb_build_object('ok', false, 'reason', 'manager_pin');
  end if;
  insert into public.pos_cash_moves (company_id, branch_id, move_type, amount, source, destination, reason, staff_id, approved_by)
  values (c.company_id, c.branch_id, 'treasury_transfer', v_amount, p_from, p_to, left(btrim(p_reason), 300), c.staff_id, v_manager);
  perform public.pos_post_je(c.company_id, c.branch_id, 'payment', 'treasury', v_ref, 'تحويل خزينة: ' || left(btrim(p_reason), 200),
    jsonb_build_array(public.pos_je_line(public.pos_box_code(p_to), v_amount, 0, 'تحويل وارد'),
                      public.pos_je_line(public.pos_box_code(p_from), 0, v_amount, 'تحويل صادر')), c.staff_id);
  return jsonb_build_object('ok', true);
end;
$$;


-- day_close_secure: same as before + its permission check
create or replace function public.day_close_secure(p_token text, p_date date)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
  v_date date := coalesce(p_date, current_date);
begin
  select * into c from public.pos_ctx(p_token, 'treasury');
  if not public.pos_perm_ok(c.role_name, 'day_close') then
    return jsonb_build_object('ok', false, 'reason', 'not_allowed', 'perm', 'day_close');
  end if;
  if exists (select 1 from public.pos_shifts s where s.branch_id = c.branch_id and s.status = 'open' and s.opened_at::date <= v_date) then
    return jsonb_build_object('ok', false, 'reason', 'open_shifts_exist');
  end if;
  if exists (select 1 from public.pos_days d where d.branch_id = c.branch_id and d.business_date = v_date) then
    return jsonb_build_object('ok', false, 'reason', 'day_already_closed');
  end if;
  insert into public.pos_days (branch_id, business_date, closed_by, report)
  values (c.branch_id, v_date, c.staff_id, public.pos_day_report(c.branch_id, v_date));
  return jsonb_build_object('ok', true, 'report', public.pos_day_report(c.branch_id, v_date));
end;
$$;


-- expense_record_secure: same as before + its permission check
create or replace function public.expense_record_secure(
  p_token text, p_category_id uuid, p_amount numeric, p_source text, p_description text,
  p_reference text, p_vendor text, p_recurring_id uuid, p_owner_pin text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
  v_amount numeric := round(coalesce(p_amount, 0), 2);
  v_cat public.expense_categories%rowtype;
  v_src jsonb;
  v_refuse jsonb;
  v_shift uuid;
  v_id uuid;
  v_desc text := nullif(btrim(coalesce(p_description, '')), '');
  v_rec public.expense_recurring%rowtype;
begin
  select * into c from public.pos_ctx(p_token, 'expenses');
  if not public.pos_perm_ok(c.role_name, 'exp_record') then
    return jsonb_build_object('ok', false, 'reason', 'not_allowed', 'perm', 'exp_record');
  end if;
  select e.* into v_cat from public.expense_categories e
   where e.id = p_category_id and e.company_id = c.company_id and e.is_active is true;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'invalid_category');
  end if;
  if v_amount <= 0 or v_amount > 100000000 then
    return jsonb_build_object('ok', false, 'reason', 'invalid_amount');
  end if;
  if v_desc is null then
    return jsonb_build_object('ok', false, 'reason', 'reason_required');
  end if;
  if p_recurring_id is not null then
    select r.* into v_rec from public.expense_recurring r where r.id = p_recurring_id and r.company_id = c.company_id for update;
    if not found or v_rec.last_period = date_trunc('month', current_date)::date then
      return jsonb_build_object('ok', false, 'reason', 'recurring_already_paid');
    end if;
  end if;
  v_src := public.pos_source_check(c.staff_id, p_source, v_amount);
  if not (v_src->>'ok')::boolean then
    return v_src;
  end if;
  v_shift := public.pos_uuid(v_src->>'shift_id');
  v_refuse := public.pos_spend_check(c.role_name, c.company_id, v_amount, p_owner_pin);
  if v_refuse is not null then
    return v_refuse;
  end if;

  insert into public.expenses (company_id, branch_id, expense_account_id, amount, payment_method, reference_number,
                               vendor_name, description, created_by, category_id, shift_id, source, recurring_id, recurring_period)
  values (c.company_id, c.branch_id, v_cat.account_id, v_amount,
          case when p_source = 'bank' then 'bank_transfer' else 'cash' end,
          left(coalesce(p_reference, ''), 100), left(coalesce(p_vendor, ''), 150), left(v_desc, 500), c.staff_id,
          v_cat.id, v_shift, p_source, p_recurring_id,
          case when p_recurring_id is not null then date_trunc('month', current_date)::date end)
  returning id into v_id;

  if p_source = 'drawer' then
    insert into public.pos_cash_moves (shift_id, company_id, branch_id, move_type, amount, source, destination, reason, staff_id)
    values (v_shift, c.company_id, c.branch_id, 'expense', v_amount, 'drawer', 'expense', left(v_desc, 300), c.staff_id);
  end if;

  perform public.pos_post_je(c.company_id, c.branch_id, 'expense', 'expense', v_id, 'مصروف: ' || left(v_desc, 200),
    jsonb_build_array(jsonb_build_object('account_id', v_cat.account_id, 'debit', v_amount, 'credit', 0, 'description', v_cat.name),
                      public.pos_je_line(public.pos_box_code(p_source), 0, v_amount, 'سداد مصروف')), c.staff_id);

  if p_recurring_id is not null then
    update public.expense_recurring set last_period = date_trunc('month', current_date)::date where id = p_recurring_id;
  end if;
  return jsonb_build_object('ok', true, 'id', v_id);
end;
$$;


-- recurring_secure: same as before + its permission check
create or replace function public.recurring_secure(p_token text, p_data jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
  v_id uuid;
  v_amount numeric;
  v_day int;
  v_desc text;
begin
  select * into c from public.pos_ctx(p_token, 'expenses');
  if p_data is not null then
    if not public.pos_perm_ok(c.role_name, 'exp_recurring') then
      return jsonb_build_object('ok', false, 'reason', 'not_allowed');
    end if;
    v_id := public.pos_uuid(p_data->>'id');
    v_amount := public.pos_amount(p_data->>'amount');
    v_desc := nullif(btrim(coalesce(p_data->>'description', '')), '');
    if coalesce(p_data->>'day_of_month', '') !~ '^[0-9]{1,2}$' then
      return jsonb_build_object('ok', false, 'reason', 'invalid_value');
    end if;
    v_day := (p_data->>'day_of_month')::int;
    if v_amount is null or v_amount <= 0 or v_day < 1 or v_day > 28 or v_desc is null
       or not exists (select 1 from public.expense_categories e where e.id = public.pos_uuid(p_data->>'category_id')
                                                                  and e.company_id = c.company_id) then
      return jsonb_build_object('ok', false, 'reason', 'invalid_value');
    end if;
    if v_id is null then
      insert into public.expense_recurring (company_id, branch_id, category_id, amount, day_of_month, description, created_by)
      values (c.company_id, c.branch_id, (p_data->>'category_id')::uuid, round(v_amount, 2), v_day, left(v_desc, 300), c.staff_id);
    else
      update public.expense_recurring
         set category_id = (p_data->>'category_id')::uuid, amount = round(v_amount, 2), day_of_month = v_day,
             description = left(v_desc, 300), is_active = coalesce(p_data->>'is_active', 'true') = 'true'
       where id = v_id and company_id = c.company_id;
    end if;
  end if;
  return jsonb_build_object('ok', true, 'items', coalesce((
    select jsonb_agg(jsonb_build_object('id', r.id, 'category_id', r.category_id, 'category', e.name, 'amount', r.amount,
                                        'day_of_month', r.day_of_month, 'description', r.description, 'is_active', r.is_active,
                                        'last_period', r.last_period,
                                        'due', r.is_active
                                               and (r.last_period is null or r.last_period < date_trunc('month', current_date)::date)
                                               and extract(day from current_date) >= r.day_of_month) order by r.day_of_month)
      from public.expense_recurring r join public.expense_categories e on e.id = r.category_id
     where r.company_id = c.company_id and (c.role_name = 'owner' or r.branch_id = c.branch_id)), '[]'::jsonb));
end;
$$;


-- expense_categories_secure: same as before + its permission check
create or replace function public.expense_categories_secure(p_token text, p_data jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
  v_id uuid;
  v_name text;
  v_acc uuid;
begin
  select * into c from public.pos_ctx(p_token, 'expenses');
  if p_data is not null then
    if not public.pos_perm_ok(c.role_name, 'exp_categories') then
      return jsonb_build_object('ok', false, 'reason', 'not_allowed');
    end if;
    v_id := public.pos_uuid(p_data->>'id');
    v_name := nullif(btrim(coalesce(p_data->>'name', '')), '');
    v_acc := public.pos_uuid(p_data->>'account_id');
    if v_name is null or length(v_name) > 100 then
      return jsonb_build_object('ok', false, 'reason', 'invalid_name');
    end if;
    if v_acc is null or not exists (select 1 from public.accounts a where a.id = v_acc and a.company_id = c.company_id
                                                                    and a.account_type in ('expense', 'cogs')) then
      return jsonb_build_object('ok', false, 'reason', 'invalid_account');
    end if;
    if v_id is null then
      insert into public.expense_categories (company_id, name, account_id) values (c.company_id, v_name, v_acc);
    else
      update public.expense_categories
         set name = v_name, account_id = v_acc, is_active = coalesce(p_data->>'is_active', 'true') = 'true'
       where id = v_id and company_id = c.company_id;
    end if;
  end if;
  return jsonb_build_object('ok', true,
    'categories', coalesce((select jsonb_agg(jsonb_build_object('id', e.id, 'name', e.name, 'account_id', e.account_id,
                                                                'account', a.code || ' - ' || a.name_ar, 'is_active', e.is_active)
                                             order by e.is_active desc, e.name)
                              from public.expense_categories e join public.accounts a on a.id = e.account_id
                             where e.company_id = c.company_id), '[]'::jsonb),
    'accounts', coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'name', a.code || ' - ' || a.name_ar) order by a.code)
                            from public.accounts a
                           where a.company_id = c.company_id and a.account_type in ('expense', 'cogs')), '[]'::jsonb),
    'limit', public.pos_setting(c.company_id, 'expense_manager_limit', 1000));
end;
$$;


-- custody_give_secure: same as before + its permission check
create or replace function public.custody_give_secure(
  p_token text, p_staff_id uuid, p_amount numeric, p_source text, p_notes text, p_owner_pin text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
  v_amount numeric := round(coalesce(p_amount, 0), 2);
  v_src jsonb;
  v_refuse jsonb;
  v_shift uuid;
  v_ref uuid := gen_random_uuid();
begin
  select * into c from public.pos_ctx(p_token, 'expenses');
  if not public.pos_perm_ok(c.role_name, 'exp_custody') then
    return jsonb_build_object('ok', false, 'reason', 'not_allowed', 'perm', 'exp_custody');
  end if;
  if not exists (select 1 from public.staff s where s.id = p_staff_id and s.company_id = c.company_id and s.is_active is true) then
    return jsonb_build_object('ok', false, 'reason', 'staff_not_found');
  end if;
  if v_amount <= 0 or v_amount > 100000000 then
    return jsonb_build_object('ok', false, 'reason', 'invalid_amount');
  end if;
  v_src := public.pos_source_check(c.staff_id, p_source, v_amount);
  if not (v_src->>'ok')::boolean then
    return v_src;
  end if;
  v_shift := public.pos_uuid(v_src->>'shift_id');
  v_refuse := public.pos_spend_check(c.role_name, c.company_id, v_amount, p_owner_pin);
  if v_refuse is not null then
    return v_refuse;
  end if;

  perform public.pos_custody_add(c.company_id, p_staff_id, 'give', v_amount, left(coalesce(p_notes, 'عهدة'), 300), c.staff_id);
  insert into public.pos_cash_moves (shift_id, company_id, branch_id, move_type, amount, source, destination, reason, staff_id)
  values (v_shift, c.company_id, c.branch_id, 'custody', v_amount, p_source, 'staff', left(coalesce(p_notes, 'عهدة'), 300), c.staff_id);
  perform public.pos_post_je(c.company_id, c.branch_id, 'payment', 'custody', v_ref, 'صرف عهدة',
    jsonb_build_array(public.pos_je_line('1140', v_amount, 0, 'عهدة موظف'),
                      public.pos_je_line(public.pos_box_code(p_source), 0, v_amount, 'صرف عهدة')), c.staff_id);
  return jsonb_build_object('ok', true);
end;
$$;


-- custody_settle_secure: same as before + its permission check
create or replace function public.custody_settle_secure(
  p_token text, p_staff_id uuid, p_lines jsonb, p_returned_cash numeric, p_return_to text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
  v_bal numeric;
  v_ret numeric := round(coalesce(p_returned_cash, 0), 2);
  v_total numeric := 0;
  l jsonb;
  v_cat public.expense_categories%rowtype;
  v_amt numeric;
  v_shift uuid;
  v_lines jsonb := '[]'::jsonb;
  v_ref uuid := gen_random_uuid();
  v_exp uuid;
begin
  select * into c from public.pos_ctx(p_token, 'expenses');
  if not public.pos_perm_ok(c.role_name, 'exp_custody') then
    return jsonb_build_object('ok', false, 'reason', 'not_allowed', 'perm', 'exp_custody');
  end if;
  select coalesce(sum(x.amount), 0) into v_bal from public.custody_ledger x where x.staff_id = p_staff_id;
  if v_bal <= 0 then
    return jsonb_build_object('ok', false, 'reason', 'no_custody');
  end if;
  if jsonb_typeof(coalesce(p_lines, '[]'::jsonb)) <> 'array' or jsonb_array_length(coalesce(p_lines, '[]'::jsonb)) > 100 then
    return jsonb_build_object('ok', false, 'reason', 'invalid_items');
  end if;
  for l in select e.value from jsonb_array_elements(coalesce(p_lines, '[]'::jsonb)) e(value) loop
    v_amt := public.pos_amount(l->>'amount');
    if v_amt is null or v_amt <= 0
       or not exists (select 1 from public.expense_categories e where e.id = public.pos_uuid(l->>'category_id')
                                                                  and e.company_id = c.company_id and e.is_active is true)
       or nullif(btrim(coalesce(l->>'description', '')), '') is null then
      return jsonb_build_object('ok', false, 'reason', 'invalid_items');
    end if;
    v_total := v_total + round(v_amt, 2);
  end loop;
  if v_ret < 0 or v_total + v_ret <= 0 or v_total + v_ret > v_bal then
    return jsonb_build_object('ok', false, 'reason', 'custody_amount_mismatch', 'balance', v_bal);
  end if;
  if v_ret > 0 then
    if coalesce(p_return_to, '') not in ('main_cash', 'drawer') then
      return jsonb_build_object('ok', false, 'reason', 'invalid_destination');
    end if;
    if p_return_to = 'drawer' then
      select s.id into v_shift from public.pos_shifts s where s.staff_id = c.staff_id and s.status = 'open';
      if v_shift is null then
        return jsonb_build_object('ok', false, 'reason', 'no_open_shift');
      end if;
    end if;
  end if;

  for l in select e.value from jsonb_array_elements(coalesce(p_lines, '[]'::jsonb)) e(value) loop
    select e.* into v_cat from public.expense_categories e where e.id = (l->>'category_id')::uuid;
    v_amt := round((l->>'amount')::numeric, 2);
    insert into public.expenses (company_id, branch_id, expense_account_id, amount, payment_method, description,
                                 created_by, category_id, source, custody_staff_id)
    values (c.company_id, c.branch_id, v_cat.account_id, v_amt, 'cash', left(btrim(l->>'description'), 500),
            c.staff_id, v_cat.id, 'custody', p_staff_id)
    returning id into v_exp;
    v_lines := v_lines || jsonb_build_array(jsonb_build_object('account_id', v_cat.account_id, 'debit', v_amt, 'credit', 0,
                                                               'description', left(btrim(l->>'description'), 200)));
    perform public.pos_custody_add(c.company_id, p_staff_id, 'settle_expense', -v_amt, left(btrim(l->>'description'), 300), c.staff_id);
  end loop;
  if v_ret > 0 then
    perform public.pos_custody_add(c.company_id, p_staff_id, 'return', -v_ret, 'رد باقي العهدة', c.staff_id);
    v_lines := v_lines || jsonb_build_array(public.pos_je_line(case when p_return_to = 'drawer' then '1101' else '1100' end,
                                                               v_ret, 0, 'رد باقي العهدة'));
    if p_return_to = 'drawer' then
      insert into public.pos_cash_moves (shift_id, company_id, branch_id, move_type, amount, source, destination, reason, staff_id)
      values (v_shift, c.company_id, c.branch_id, 'cash_in', v_ret, 'custody', 'drawer', 'رد باقي عهدة', c.staff_id);
    end if;
  end if;
  v_lines := v_lines || jsonb_build_array(public.pos_je_line('1140', 0, v_total + v_ret, 'تسوية عهدة'));
  perform public.pos_post_je(c.company_id, c.branch_id, 'expense', 'custody', v_ref, 'تسوية عهدة موظف', v_lines, c.staff_id);

  return jsonb_build_object('ok', true, 'balance', v_bal - v_total - v_ret);
end;
$$;


-- staff_save_secure: same as before + its permission check
create or replace function public.staff_save_secure(p_token text, p_data jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
  v_id uuid := public.pos_uuid(p_data->>'id');
  v_name text := nullif(btrim(coalesce(p_data->>'name', '')), '');
  v_role text := coalesce(p_data->>'role', 'cashier');
  v_role_id uuid;
  v_branch uuid := public.pos_uuid(p_data->>'branch_id');
  v_active boolean := coalesce(p_data->>'is_active', 'true') = 'true';
  v_salary numeric := coalesce(public.pos_amount(p_data->>'monthly_salary'), 0);
  v_phone text := left(coalesce(p_data->>'phone', ''), 30);
  v_old jsonb;
begin
  select * into c from public.pos_ctx(p_token, 'staff');
  if not public.pos_perm_ok(c.role_name, 'staff_manage') then
    return jsonb_build_object('ok', false, 'reason', 'not_allowed', 'perm', 'staff_manage');
  end if;
  if v_name is null or length(v_name) > 100 then
    return jsonb_build_object('ok', false, 'reason', 'invalid_name');
  end if;
  select r.id into v_role_id from public.roles r where r.name = v_role;
  if v_role_id is null then
    return jsonb_build_object('ok', false, 'reason', 'invalid_role');
  end if;
  if c.role_name <> 'owner' then
    if v_role in ('owner', 'branch_manager') then
      return jsonb_build_object('ok', false, 'reason', 'not_allowed');
    end if;
    v_branch := c.branch_id;
  end if;
  if v_branch is null or not exists (
    select 1 from public.branches b join public.brands br on br.id = b.brand_id
     where b.id = v_branch and br.company_id = c.company_id) then
    return jsonb_build_object('ok', false, 'reason', 'invalid_branch');
  end if;

  if v_id is null then
    insert into public.staff (name, role_id, branch_id, company_id, is_active, monthly_salary, phone)
    values (v_name, v_role_id, v_branch, c.company_id, v_active, v_salary, v_phone)
    returning id into v_id;
  else
    if not public.pos_staff_scope_ok(c.role_name, c.branch_id, c.company_id, v_id) then
      return jsonb_build_object('ok', false, 'reason', 'staff_not_found');
    end if;
    if v_id = c.staff_id and not v_active then
      return jsonb_build_object('ok', false, 'reason', 'cannot_disable_self');
    end if;
    select jsonb_build_object('name', s.name, 'role_id', s.role_id, 'branch_id', s.branch_id, 'is_active', s.is_active,
                              'monthly_salary', s.monthly_salary) into v_old
      from public.staff s where s.id = v_id;
    update public.staff
       set name = v_name, role_id = v_role_id, branch_id = v_branch, is_active = v_active,
           monthly_salary = v_salary, phone = v_phone
     where id = v_id;
  end if;

  insert into public.settings_logs (staff_id, action, details)
  values (c.staff_id, 'staff_save', jsonb_build_object('staff_id', v_id, 'data', p_data - 'pin', 'before', v_old));
  return jsonb_build_object('ok', true, 'id', v_id);
end;
$$;


-- staff_set_pin_secure: same as before + its permission check
create or replace function public.staff_set_pin_secure(p_token text, p_staff_id uuid, p_pin text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
begin
  select * into c from public.pos_ctx(p_token, 'staff');
  if not public.pos_perm_ok(c.role_name, 'staff_manage') then
    return jsonb_build_object('ok', false, 'reason', 'not_allowed', 'perm', 'staff_manage');
  end if;
  if not public.pos_staff_scope_ok(c.role_name, c.branch_id, c.company_id, p_staff_id) then
    return jsonb_build_object('ok', false, 'reason', 'staff_not_found');
  end if;
  if p_pin is null or p_pin !~ '^[0-9]{4}$' then
    return jsonb_build_object('ok', false, 'reason', 'invalid_pin');
  end if;
  if exists (select 1 from public.staff s
              where s.id <> p_staff_id and s.is_active is true and s.pin_hash is not null
                and s.pin_hash = extensions.crypt(p_pin, s.pin_hash)) then
    return jsonb_build_object('ok', false, 'reason', 'pin_taken');
  end if;
  update public.staff set pin_hash = extensions.crypt(p_pin, extensions.gen_salt('bf', 8)) where id = p_staff_id;
  insert into public.settings_logs (staff_id, action, details)
  values (c.staff_id, 'staff_set_pin', jsonb_build_object('staff_id', p_staff_id));
  return jsonb_build_object('ok', true);
end;
$$;


-- payroll_approve_secure: same as before + its permission check
create or replace function public.payroll_approve_secure(p_token text, p_run_id uuid, p_manager_pin text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
  r public.payroll_runs%rowtype;
  v_manager uuid;
  v_exp numeric;
  v_net numeric;
  v_led numeric;
  l record;
begin
  select * into c from public.pos_ctx(p_token, 'payroll');
  if not public.pos_perm_ok(c.role_name, 'payroll_approve') then
    return jsonb_build_object('ok', false, 'reason', 'not_allowed', 'perm', 'payroll_approve');
  end if;
  select x.* into r from public.payroll_runs x where x.id = p_run_id for update;
  if not found or r.branch_id is distinct from c.branch_id or r.status <> 'draft' then
    return jsonb_build_object('ok', false, 'reason', 'payroll_not_draft');
  end if;
  v_manager := public.verify_manager_pin(p_manager_pin, c.branch_id);
  if v_manager is null then
    return jsonb_build_object('ok', false, 'reason', 'manager_pin');
  end if;
  select coalesce(sum(x.base_salary - x.absence_deduction - x.other_deduction + x.bonus), 0),
         coalesce(sum(x.net), 0), coalesce(sum(x.ledger_deduction), 0)
    into v_exp, v_net, v_led
    from public.payroll_lines x where x.run_id = r.id;
  -- a line whose net was floored at zero must not unbalance the entry
  v_exp := v_net + v_led;

  for l in select x.staff_id, x.ledger_deduction from public.payroll_lines x where x.run_id = r.id and x.ledger_deduction > 0 loop
    perform public.pos_staff_add_ledger(c.company_id, l.staff_id, 'deduction', -l.ledger_deduction, null, r.id,
                                        'خصم من مرتب ' || to_char(r.period, 'YYYY-MM'), c.staff_id);
  end loop;

  perform public.pos_post_je(c.company_id, c.branch_id, 'expense', 'payroll', r.id, 'مرتبات شهر ' || to_char(r.period, 'YYYY-MM'),
    jsonb_build_array(public.pos_je_line('6000', v_exp, 0, 'مصروف الرواتب'),
                      public.pos_je_line('2500', 0, v_net, 'رواتب مستحقة'),
                      public.pos_je_line('1130', 0, v_led, 'خصم عجز وسلف')), c.staff_id);

  update public.payroll_runs set status = 'approved', approved_by = v_manager, approved_at = now() where id = r.id;
  return jsonb_build_object('ok', true, 'run', public.pos_payroll_json(r.id));
end;
$$;


-- payroll_pay_secure: same as before + its permission check
create or replace function public.payroll_pay_secure(p_token text, p_run_id uuid, p_source text, p_manager_pin text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
  r public.payroll_runs%rowtype;
  v_manager uuid;
  v_net numeric;
begin
  select * into c from public.pos_ctx(p_token, 'payroll');
  if not public.pos_perm_ok(c.role_name, 'payroll_pay') then
    return jsonb_build_object('ok', false, 'reason', 'not_allowed', 'perm', 'payroll_pay');
  end if;
  select x.* into r from public.payroll_runs x where x.id = p_run_id for update;
  if not found or r.branch_id is distinct from c.branch_id or r.status <> 'approved' then
    return jsonb_build_object('ok', false, 'reason', 'payroll_not_approved');
  end if;
  if coalesce(p_source, '') not in ('main_cash', 'bank') then
    return jsonb_build_object('ok', false, 'reason', 'invalid_destination');
  end if;
  v_manager := public.verify_manager_pin(p_manager_pin, c.branch_id);
  if v_manager is null then
    return jsonb_build_object('ok', false, 'reason', 'manager_pin');
  end if;
  select coalesce(sum(x.net), 0) into v_net from public.payroll_lines x where x.run_id = r.id;
  insert into public.pos_cash_moves (company_id, branch_id, move_type, amount, source, destination, reason, staff_id, approved_by)
  values (c.company_id, c.branch_id, 'payroll', v_net, p_source, 'staff', 'صرف مرتبات ' || to_char(r.period, 'YYYY-MM'), c.staff_id, v_manager);
  perform public.pos_post_je(c.company_id, c.branch_id, 'payment', 'payroll', r.id, 'صرف مرتبات ' || to_char(r.period, 'YYYY-MM'),
    jsonb_build_array(public.pos_je_line('2500', v_net, 0, 'سداد رواتب'),
                      public.pos_je_line(public.pos_box_code(p_source), 0, v_net, 'صرف رواتب')), c.staff_id);
  update public.payroll_runs set status = 'paid', paid_by = c.staff_id, paid_at = now() where id = r.id;
  return jsonb_build_object('ok', true, 'run', public.pos_payroll_json(r.id));
end;
$$;


-- staff_advance_secure: same as before + its permission check
create or replace function public.staff_advance_secure(
  p_token text, p_staff_id uuid, p_amount numeric, p_source text, p_reason text, p_manager_pin text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
  v_amount numeric := round(coalesce(p_amount, 0), 2);
  v_manager uuid;
  v_shift uuid;
  v_ref uuid := gen_random_uuid();
begin
  select * into c from public.pos_ctx(p_token, 'payroll');
  if not public.pos_perm_ok(c.role_name, 'payroll_pay') then
    return jsonb_build_object('ok', false, 'reason', 'not_allowed', 'perm', 'payroll_pay');
  end if;
  if not public.pos_staff_scope_ok(c.role_name, c.branch_id, c.company_id, p_staff_id) and p_staff_id <> c.staff_id then
    return jsonb_build_object('ok', false, 'reason', 'staff_not_found');
  end if;
  if v_amount <= 0 or v_amount > 10000000 then
    return jsonb_build_object('ok', false, 'reason', 'invalid_amount');
  end if;
  if coalesce(p_source, '') not in ('main_cash', 'drawer', 'bank') then
    return jsonb_build_object('ok', false, 'reason', 'invalid_destination');
  end if;
  if p_source = 'drawer' then
    select s.id into v_shift from public.pos_shifts s where s.staff_id = c.staff_id and s.status = 'open';
    if v_shift is null then
      return jsonb_build_object('ok', false, 'reason', 'no_open_shift');
    end if;
    if v_amount > public.pos_shift_expected(v_shift) then
      return jsonb_build_object('ok', false, 'reason', 'not_enough_cash');
    end if;
  end if;
  v_manager := public.verify_manager_pin(p_manager_pin, c.branch_id);
  if v_manager is null then
    return jsonb_build_object('ok', false, 'reason', 'manager_pin');
  end if;

  perform public.pos_staff_add_ledger(c.company_id, p_staff_id, 'advance', v_amount, v_shift, null,
                                      left(coalesce(p_reason, 'سلفة'), 300), c.staff_id);
  insert into public.pos_cash_moves (shift_id, company_id, branch_id, move_type, amount, source, destination, reason, staff_id, approved_by)
  values (v_shift, c.company_id, c.branch_id, 'advance', v_amount, p_source, 'staff', left(coalesce(p_reason, 'سلفة'), 300), c.staff_id, v_manager);
  perform public.pos_post_je(c.company_id, c.branch_id, 'payment', 'advance', v_ref, 'سلفة موظف',
    jsonb_build_array(public.pos_je_line('1130', v_amount, 0, 'سلفة'),
                      public.pos_je_line(public.pos_box_code(p_source), 0, v_amount, 'صرف سلفة')), c.staff_id);
  return jsonb_build_object('ok', true);
end;
$$;


-- journal_manual_secure: same as before + its permission check
create or replace function public.journal_manual_secure(p_token text, p_date date, p_description text, p_lines jsonb, p_branch_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
  l jsonb;
  v_d numeric;
  v_cr numeric;
  v_td numeric := 0;
  v_tc numeric := 0;
  v_lines jsonb := '[]'::jsonb;
  v_id uuid;
  v_branch uuid;
begin
  select * into c from public.pos_ctx(p_token, 'accounting');
  if not public.pos_perm_ok(c.role_name, 'acc_manual') then
    return jsonb_build_object('ok', false, 'reason', 'not_allowed');
  end if;
  if nullif(btrim(coalesce(p_description, '')), '') is null then
    return jsonb_build_object('ok', false, 'reason', 'reason_required');
  end if;
  if p_date is null or p_date > current_date + 31 then
    return jsonb_build_object('ok', false, 'reason', 'invalid_value');
  end if;
  v_branch := case when c.role_name = 'owner' then coalesce(p_branch_id, c.branch_id) else c.branch_id end;
  if jsonb_typeof(p_lines) is distinct from 'array' or jsonb_array_length(p_lines) < 2 or jsonb_array_length(p_lines) > 50 then
    return jsonb_build_object('ok', false, 'reason', 'invalid_items');
  end if;
  for l in select e.value from jsonb_array_elements(p_lines) e(value) loop
    v_d := round(coalesce(public.pos_amount(l->>'debit'), 0), 2);
    v_cr := round(coalesce(public.pos_amount(l->>'credit'), 0), 2);
    if (v_d > 0) = (v_cr > 0)
       or not exists (select 1 from public.accounts a where a.id = public.pos_uuid(l->>'account_id') and a.company_id = c.company_id) then
      return jsonb_build_object('ok', false, 'reason', 'invalid_items');
    end if;
    v_td := v_td + v_d;
    v_tc := v_tc + v_cr;
    v_lines := v_lines || jsonb_build_array(jsonb_build_object('account_id', l->>'account_id', 'debit', v_d, 'credit', v_cr,
                                                               'description', left(coalesce(l->>'description', p_description), 300)));
  end loop;
  if v_td <> v_tc then
    return jsonb_build_object('ok', false, 'reason', 'not_balanced', 'debit', v_td, 'credit', v_tc);
  end if;
  v_id := public.create_journal_entry(c.company_id, v_branch, p_date, 'manual', 'manual', gen_random_uuid(),
                                      left(btrim(p_description), 500), v_lines, true, c.staff_id);
  return jsonb_build_object('ok', true, 'id', v_id);
end;
$$;


-- journal_reverse_secure: same as before + its permission check
create or replace function public.journal_reverse_secure(p_token text, p_id uuid, p_reason text, p_manager_pin text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
  je public.journal_entries%rowtype;
  v_manager uuid;
  v_new uuid;
begin
  select * into c from public.pos_ctx(p_token, 'accounting');
  if not public.pos_perm_ok(c.role_name, 'acc_manual') then
    return jsonb_build_object('ok', false, 'reason', 'not_allowed');
  end if;
  select x.* into je from public.journal_entries x where x.id = p_id and x.company_id = c.company_id for update;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'not_found');
  end if;
  if je.status <> 'posted' or je.reference_type <> 'manual' then
    return jsonb_build_object('ok', false, 'reason', 'cannot_reverse');
  end if;
  if nullif(btrim(coalesce(p_reason, '')), '') is null then
    return jsonb_build_object('ok', false, 'reason', 'reason_required');
  end if;
  v_manager := public.verify_manager_pin(p_manager_pin, c.branch_id);
  if v_manager is null then
    return jsonb_build_object('ok', false, 'reason', 'manager_pin');
  end if;
  v_new := public.reverse_journal_entry(c.company_id, je.id, left(btrim(p_reason), 300), c.staff_id);
  return jsonb_build_object('ok', true, 'id', v_new);
end;
$$;


-- menu_admin_secure: same as before + its permission check
create or replace function public.menu_admin_secure(p_token text, p_action text, p_data jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
  v_brand uuid;
  d jsonb := coalesce(p_data, '{}'::jsonb);
  v_id uuid;
  v_cat uuid;
  v_name text;
  v_num numeric;
  v_old record;
  l jsonb;
  r jsonb;
  v_created int := 0;
  v_updated int := 0;
  v_extra jsonb := '{}'::jsonb;
begin
  select * into c from public.pos_ctx(p_token, 'settings');
  if coalesce(p_action, '') not in ('get', 'get_image') and not public.pos_perm_ok(c.role_name, 'settings_menu') then
    return jsonb_build_object('ok', false, 'reason', 'not_allowed', 'perm', 'settings_menu');
  end if;
  if not public.pos_perm_ok(c.role_name, 'settings_menu') then
    return jsonb_build_object('ok', false, 'reason', 'not_allowed');
  end if;
  select b.brand_id into v_brand from public.branches b where b.id = c.branch_id;
  if v_brand is null then
    return jsonb_build_object('ok', false, 'reason', 'branch_brand_not_configured');
  end if;

  case coalesce(p_action, '')
  when 'get' then
    null;

  when 'save_category' then
    v_id := public.pos_uuid(d->>'id');
    v_name := nullif(btrim(coalesce(d->>'name', '')), '');
    if v_name is null or length(v_name) > 100 then
      return jsonb_build_object('ok', false, 'reason', 'invalid_name');
    end if;
    if coalesce(d->>'station', 'kitchen') not in ('kitchen', 'bar', 'shisha') then
      return jsonb_build_object('ok', false, 'reason', 'invalid_value');
    end if;
    if exists (select 1 from public.categories x where x.brand_id = v_brand and btrim(x.name) = v_name and x.id is distinct from v_id) then
      return jsonb_build_object('ok', false, 'reason', 'name_taken');
    end if;
    if v_id is null then
      insert into public.categories (brand_id, name, station, sort_order, show_in_menu)
      values (v_brand, v_name, coalesce(d->>'station', 'kitchen'),
              coalesce((select max(x.sort_order) + 1 from public.categories x where x.brand_id = v_brand), 0),
              coalesce((d->>'show_in_menu')::boolean, true))
      returning id into v_id;
    else
      update public.categories
         set name = v_name, station = coalesce(d->>'station', station),
             sort_order = coalesce(nullif(d->>'sort_order', '')::int, sort_order),
             show_in_menu = coalesce((d->>'show_in_menu')::boolean, show_in_menu)
       where id = v_id and brand_id = v_brand;
      if not found then
        return jsonb_build_object('ok', false, 'reason', 'invalid_category');
      end if;
    end if;
    v_extra := jsonb_build_object('id', v_id);

  when 'delete_category' then
    v_id := public.pos_uuid(d->>'id');
    if exists (select 1 from public.products p where p.category_id = v_id) then
      return jsonb_build_object('ok', false, 'reason', 'category_not_empty');
    end if;
    delete from public.categories where id = v_id and brand_id = v_brand;

  when 'save_product' then
    v_id := public.pos_uuid(d->>'id');
    v_name := nullif(btrim(coalesce(d->>'name', '')), '');
    v_num := public.pos_amount(d->>'price');
    v_cat := public.pos_uuid(d->>'category_id');
    if v_name is null or length(v_name) > 150 then
      return jsonb_build_object('ok', false, 'reason', 'invalid_name');
    end if;
    if v_num is null or v_num > 999999 then
      return jsonb_build_object('ok', false, 'reason', 'invalid_price');
    end if;
    if v_cat is null or not exists (select 1 from public.categories x where x.id = v_cat and x.brand_id = v_brand) then
      return jsonb_build_object('ok', false, 'reason', 'invalid_category');
    end if;
    if length(coalesce(d->>'description', '')) > 500 then
      return jsonb_build_object('ok', false, 'reason', 'value_too_long');
    end if;
    if exists (select 1 from public.products p where p.brand_id = v_brand and btrim(p.name) = v_name and p.id is distinct from v_id) then
      return jsonb_build_object('ok', false, 'reason', 'name_taken');
    end if;
    if jsonb_typeof(d->'recipe') = 'array' then
      if jsonb_array_length(d->'recipe') > 50 then
        return jsonb_build_object('ok', false, 'reason', 'invalid_items');
      end if;
      for l in select e.value from jsonb_array_elements(d->'recipe') e(value) loop
        if not exists (select 1 from public.ingredients i where i.id = public.pos_uuid(l->>'ingredient_id'))
           or coalesce(public.pos_amount(l->>'qty'), 0) <= 0 then
          return jsonb_build_object('ok', false, 'reason', 'invalid_items');
        end if;
      end loop;
    end if;
    if jsonb_typeof(d->'group_ids') = 'array'
       and exists (select 1 from jsonb_array_elements_text(d->'group_ids') g(v)
                    where not exists (select 1 from public.modifier_groups mg where mg.id = public.pos_uuid(g.v) and mg.brand_id = v_brand)) then
      return jsonb_build_object('ok', false, 'reason', 'group_not_found');
    end if;
    if v_id is null then
      insert into public.products (brand_id, category_id, name, price, is_available, description, show_in_menu, sort_order)
      values (v_brand, v_cat, v_name, round(v_num, 2), coalesce((d->>'is_available')::boolean, true),
              nullif(btrim(coalesce(d->>'description', '')), ''), coalesce((d->>'show_in_menu')::boolean, true),
              coalesce(nullif(d->>'sort_order', '')::int, 0))
      returning id into v_id;
      insert into public.settings_logs (staff_id, action, details)
      values (c.staff_id, 'add_product', jsonb_build_object('product_id', v_id, 'name', v_name, 'price', round(v_num, 2)));
    else
      select p.price, p.name, p.is_available into v_old from public.products p where p.id = v_id and p.brand_id = v_brand for update;
      if not found then
        return jsonb_build_object('ok', false, 'reason', 'product_not_found');
      end if;
      update public.products
         set name = v_name, price = round(v_num, 2), category_id = v_cat,
             is_available = coalesce((d->>'is_available')::boolean, is_available),
             description = nullif(btrim(coalesce(d->>'description', '')), ''),
             show_in_menu = coalesce((d->>'show_in_menu')::boolean, show_in_menu),
             sort_order = coalesce(nullif(d->>'sort_order', '')::int, sort_order)
       where id = v_id;
      if v_old.price is distinct from round(v_num, 2) then
        insert into public.settings_logs (staff_id, action, details)
        values (c.staff_id, 'set_product_price', jsonb_build_object('product_id', v_id, 'name', v_name, 'old_price', v_old.price,
                                                                    'new_price', round(v_num, 2)));
      end if;
    end if;
    if jsonb_typeof(d->'recipe') = 'array' then
      delete from public.recipes where product_id = v_id;
      insert into public.recipes (product_id, ingredient_id, quantity_required)
      select v_id, (e.value->>'ingredient_id')::uuid, sum((e.value->>'qty')::numeric)
        from jsonb_array_elements(d->'recipe') e(value) group by 2;
    end if;
    if jsonb_typeof(d->'group_ids') = 'array' then
      delete from public.product_modifier_groups where product_id = v_id
         and group_id not in (select public.pos_uuid(g.v) from jsonb_array_elements_text(d->'group_ids') g(v));
      insert into public.product_modifier_groups (product_id, group_id)
      select v_id, public.pos_uuid(g.v) from jsonb_array_elements_text(d->'group_ids') g(v)
       where not exists (select 1 from public.product_modifier_groups x where x.product_id = v_id and x.group_id = public.pos_uuid(g.v));
    end if;
    v_extra := jsonb_build_object('id', v_id);

  when 'set_image' then
    v_id := public.pos_uuid(d->>'id');
    if coalesce(d->>'image', '') <> ''
       and ((d->>'image') !~ '^data:image/(png|jpeg|jpg|webp);base64,' or length(d->>'image') > 350000) then
      return jsonb_build_object('ok', false, 'reason', 'invalid_image');
    end if;
    update public.products set image = nullif(d->>'image', '') where id = v_id and brand_id = v_brand;
    if not found then
      return jsonb_build_object('ok', false, 'reason', 'product_not_found');
    end if;

  when 'get_image' then
    return jsonb_build_object('ok', true, 'image', (select p.image from public.products p where p.id = public.pos_uuid(d->>'id') and p.brand_id = v_brand));

  when 'delete_product' then
    v_id := public.pos_uuid(d->>'id');
    if not exists (select 1 from public.products p where p.id = v_id and p.brand_id = v_brand) then
      return jsonb_build_object('ok', false, 'reason', 'product_not_found');
    end if;
    if exists (select 1 from public.order_items oi where oi.product_id = v_id) then
      -- sold before: kept for the old bills and reports, but stopped and hidden
      update public.products set is_available = false, show_in_menu = false where id = v_id;
      v_extra := jsonb_build_object('archived', true);
    else
      delete from public.product_modifier_groups where product_id = v_id;
      delete from public.recipes where product_id = v_id;
      delete from public.products where id = v_id;
    end if;
    insert into public.settings_logs (staff_id, action, details)
    values (c.staff_id, 'delete_product', jsonb_build_object('product_id', v_id, 'archived', v_extra ? 'archived'));

  when 'add_ingredient' then
    v_name := nullif(btrim(coalesce(d->>'name', '')), '');
    if v_name is null or length(v_name) > 100 or nullif(btrim(coalesce(d->>'unit', '')), '') is null then
      return jsonb_build_object('ok', false, 'reason', 'invalid_name');
    end if;
    select i.id into v_id from public.ingredients i where btrim(i.name) = v_name and (i.brand_id is null or i.brand_id = v_brand) limit 1;
    if v_id is null then
      insert into public.ingredients (name, unit, cost_per_unit, min_stock_alert, brand_id)
      values (v_name, left(btrim(d->>'unit'), 20), coalesce(public.pos_amount(d->>'cost_per_unit'), 0),
              coalesce(nullif((public.pos_app_settings(c.company_id) -> 'inventory' ->> 'default_min_stock'), '')::numeric, 0), v_brand)
      returning id into v_id;
      v_extra := jsonb_build_object('id', v_id, 'existing', false);
    else
      v_extra := jsonb_build_object('id', v_id, 'existing', true);
    end if;

  when 'import' then
    -- the whole menu at once: [{category, name, price, description, station}]. Same name = price/category updated.
    if jsonb_typeof(d->'rows') is distinct from 'array' or jsonb_array_length(d->'rows') > 1000 then
      return jsonb_build_object('ok', false, 'reason', 'invalid_items');
    end if;
    for r in select e.value from jsonb_array_elements(d->'rows') e(value) loop
      v_name := nullif(btrim(coalesce(r->>'name', '')), '');
      v_num := public.pos_amount(r->>'price');
      if v_name is null or length(v_name) > 150 or v_num is null or nullif(btrim(coalesce(r->>'category', '')), '') is null
         or coalesce(r->>'station', 'kitchen') not in ('kitchen', 'bar', 'shisha') then
        return jsonb_build_object('ok', false, 'reason', 'invalid_items', 'row', r);
      end if;
      select x.id into v_cat from public.categories x where x.brand_id = v_brand and btrim(x.name) = btrim(r->>'category') limit 1;
      if v_cat is null then
        insert into public.categories (brand_id, name, station, sort_order)
        values (v_brand, left(btrim(r->>'category'), 100), coalesce(r->>'station', 'kitchen'),
                coalesce((select max(x.sort_order) + 1 from public.categories x where x.brand_id = v_brand), 0))
        returning id into v_cat;
      end if;
      select p.id into v_id from public.products p where p.brand_id = v_brand and btrim(p.name) = v_name limit 1;
      if v_id is null then
        insert into public.products (brand_id, category_id, name, price, is_available, description, sort_order)
        values (v_brand, v_cat, v_name, round(v_num, 2), true, nullif(btrim(coalesce(r->>'description', '')), ''),
                coalesce((select max(p.sort_order) + 1 from public.products p where p.category_id = v_cat), 0));
        v_created := v_created + 1;
      else
        update public.products set price = round(v_num, 2), category_id = v_cat,
               description = coalesce(nullif(btrim(coalesce(r->>'description', '')), ''), description)
         where id = v_id;
        v_updated := v_updated + 1;
      end if;
    end loop;
    insert into public.settings_logs (staff_id, action, details)
    values (c.staff_id, 'menu_import', jsonb_build_object('created', v_created, 'updated', v_updated));
    v_extra := jsonb_build_object('created', v_created, 'updated', v_updated);

  else
    return jsonb_build_object('ok', false, 'reason', 'unknown_action');
  end case;

  return jsonb_build_object('ok', true) || v_extra || public.pos_menu_admin_data(v_brand);
end;
$$;


-- modifiers_admin_secure: same as before + its permission check
create or replace function public.modifiers_admin_secure(p_token text, p_action text, p_data jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
  v_brand uuid;
  d jsonb := coalesce(p_data, '{}'::jsonb);
  v_id uuid;
  v_name text;
  v_min int;
  v_max int;
  v_count int;
  m jsonb;
  v_mid uuid;
  v_keep uuid[] := '{}'::uuid[];
  v_price numeric;
  v_ing uuid;
  v_qty numeric;
  v_pid text;
begin
  select * into c from public.pos_ctx(p_token, 'settings');
  if coalesce(p_action, '') not in ('get', 'list') and not public.pos_perm_ok(c.role_name, 'settings_menu') then
    return jsonb_build_object('ok', false, 'reason', 'not_allowed', 'perm', 'settings_menu');
  end if;
  select b.brand_id into v_brand from public.branches b where b.id = c.branch_id;

  if coalesce(p_action, '') = 'get' then
    return jsonb_build_object('ok', true,
      'groups', (select coalesce(jsonb_agg(jsonb_build_object(
                   'id', g.id, 'name', g.name, 'min_selection', coalesce(g.min_selection, 0),
                   'max_selection', coalesce(g.max_selection, 1), 'is_required', coalesce(g.is_required, false),
                   'modifiers', (select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'name', x.name, 'price', coalesce(x.price, 0),
                                                   'ingredient_id', x.ingredient_id, 'ingredient_quantity', coalesce(x.ingredient_quantity, 0))
                                                   order by x.created_at, x.name), '[]'::jsonb)
                                   from public.modifiers x where x.group_id = g.id),
                   'product_ids', (select coalesce(jsonb_agg(l.product_id), '[]'::jsonb)
                                     from public.product_modifier_groups l where l.group_id = g.id)) order by g.name), '[]'::jsonb)
                   from public.modifier_groups g where g.brand_id = v_brand),
      'products', (select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'name', p.name, 'price', p.price,
                                                                'category_id', p.category_id, 'category', cat.name)
                                             order by cat.name, p.name), '[]'::jsonb)
                     from public.products p left join public.categories cat on cat.id = p.category_id
                    where p.brand_id = v_brand),
      'ingredients', (select coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'name', i.name, 'unit', i.unit) order by i.name), '[]'::jsonb)
                        from public.ingredients i));
  end if;

  if p_action = 'save_group' then
    v_id := public.pos_uuid(d->>'id');
    if nullif(d->>'id', '') is not null then
      if v_id is null or not exists (select 1 from public.modifier_groups g where g.id = v_id and g.brand_id = v_brand) then
        return jsonb_build_object('ok', false, 'reason', 'group_not_found');
      end if;
    end if;
    v_name := nullif(btrim(coalesce(d->>'name', '')), '');
    if v_name is null or length(v_name) > 100 then
      return jsonb_build_object('ok', false, 'reason', 'invalid_name');
    end if;
    if coalesce(d->>'min_selection', '') !~ '^[0-9]{1,2}$' or coalesce(d->>'max_selection', '') !~ '^[0-9]{1,2}$'
       or jsonb_typeof(d->'modifiers') is distinct from 'array' or jsonb_typeof(d->'product_ids') is distinct from 'array'
       or jsonb_array_length(d->'product_ids') > 500 then
      return jsonb_build_object('ok', false, 'reason', 'invalid_value');
    end if;
    v_min := (d->>'min_selection')::int;
    v_max := (d->>'max_selection')::int;
    v_count := jsonb_array_length(d->'modifiers');
    if v_count < 1 or v_count > 50 or v_max < 1 or v_min > v_max or v_max > v_count then
      return jsonb_build_object('ok', false, 'reason', 'invalid_selection_limits');
    end if;

    -- check everything before changing anything
    for m in select e.value from jsonb_array_elements(d->'modifiers') e(value) loop
      if jsonb_typeof(m) is distinct from 'object' or nullif(btrim(coalesce(m->>'name', '')), '') is null
         or length(btrim(m->>'name')) > 100 then
        return jsonb_build_object('ok', false, 'reason', 'invalid_name');
      end if;
      v_price := public.pos_amount(coalesce(m->>'price', '0'));
      if v_price is null or v_price > 100000 then
        return jsonb_build_object('ok', false, 'reason', 'invalid_price');
      end if;
      if nullif(m->>'ingredient_id', '') is not null then
        v_ing := public.pos_uuid(m->>'ingredient_id');
        if v_ing is null or not exists (select 1 from public.ingredients i where i.id = v_ing) then
          return jsonb_build_object('ok', false, 'reason', 'ingredient_not_found');
        end if;
        v_qty := public.pos_amount(coalesce(m->>'ingredient_quantity', '0'));
        if v_qty is null or v_qty <= 0 or v_qty > 100000 then
          return jsonb_build_object('ok', false, 'reason', 'invalid_quantity');
        end if;
      end if;
      if nullif(m->>'id', '') is not null then
        v_mid := public.pos_uuid(m->>'id');
        if v_mid is null or v_id is null
           or not exists (select 1 from public.modifiers x where x.id = v_mid and x.group_id = v_id) then
          return jsonb_build_object('ok', false, 'reason', 'modifier_not_found');
        end if;
      end if;
    end loop;
    for v_pid in select e.value from jsonb_array_elements_text(d->'product_ids') e(value) loop
      if public.pos_uuid(v_pid) is null
         or not exists (select 1 from public.products p where p.id = public.pos_uuid(v_pid) and p.brand_id = v_brand) then
        return jsonb_build_object('ok', false, 'reason', 'product_not_found');
      end if;
    end loop;

    if v_id is null then
      insert into public.modifier_groups (brand_id, name, min_selection, max_selection, is_required)
      values (v_brand, v_name, v_min, v_max, v_min > 0)
      returning id into v_id;
    else
      update public.modifier_groups
         set name = v_name, min_selection = v_min, max_selection = v_max, is_required = v_min > 0
       where id = v_id;
    end if;

    for m in select e.value from jsonb_array_elements(d->'modifiers') e(value) loop
      v_mid := public.pos_uuid(m->>'id');
      v_ing := public.pos_uuid(m->>'ingredient_id');
      v_qty := 0;
      if v_ing is not null then
        v_qty := public.pos_amount(coalesce(m->>'ingredient_quantity', '0'));
      end if;
      if v_mid is null then
        insert into public.modifiers (group_id, name, price, ingredient_id, ingredient_quantity)
        values (v_id, btrim(m->>'name'), public.pos_amount(coalesce(m->>'price', '0')), v_ing, v_qty)
        returning id into v_mid;
      else
        update public.modifiers
           set name = btrim(m->>'name'), price = public.pos_amount(coalesce(m->>'price', '0')),
               ingredient_id = v_ing, ingredient_quantity = v_qty
         where id = v_mid and group_id = v_id;
      end if;
      v_keep := v_keep || v_mid;
    end loop;

    -- removed from the group: sold before -> taken out of the group only; never sold -> deleted
    update public.modifiers x set group_id = null
     where x.group_id = v_id and not (x.id = any (v_keep))
       and exists (select 1 from public.order_item_modifiers oim where oim.modifier_id = x.id);
    delete from public.modifiers x where x.group_id = v_id and not (x.id = any (v_keep));

    delete from public.product_modifier_groups where group_id = v_id;
    insert into public.product_modifier_groups (product_id, group_id)
    select distinct public.pos_uuid(e.value), v_id from jsonb_array_elements_text(d->'product_ids') e(value);

  elsif p_action = 'delete_group' then
    v_id := public.pos_uuid(d->>'id');
    if v_id is null or not exists (select 1 from public.modifier_groups g where g.id = v_id and g.brand_id = v_brand) then
      return jsonb_build_object('ok', false, 'reason', 'group_not_found');
    end if;
    update public.modifiers x set group_id = null
     where x.group_id = v_id and exists (select 1 from public.order_item_modifiers oim where oim.modifier_id = x.id);
    delete from public.modifier_groups where id = v_id;

  else
    return jsonb_build_object('ok', false, 'reason', 'unknown_action');
  end if;

  insert into public.settings_logs (staff_id, action, details)
  values (c.staff_id, 'modifiers_' || p_action, jsonb_build_object('id', v_id, 'data', d));
  return jsonb_build_object('ok', true, 'id', v_id);
end;
$$;


-- receipt actions: post = po_post, void = po_receive
create or replace function public.gr_action_secure(p_token text, p_grn_id uuid, p_action text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
begin
  select * into c from public.pos_ctx(p_token, 'purchasing');
  if p_action = 'post' and not public.pos_perm_ok(c.role_name, 'po_post') then
    return jsonb_build_object('ok', false, 'reason', 'not_allowed', 'perm', 'po_post');
  end if;
  if p_action = 'void' and not public.pos_perm_ok(c.role_name, 'po_receive') then
    return jsonb_build_object('ok', false, 'reason', 'not_allowed', 'perm', 'po_receive');
  end if;
  if p_action = 'post' then
    return public.pos_gr_post(p_grn_id, c.staff_id, c.company_id, c.branch_id);
  elsif p_action = 'void' then
    return public.pos_gr_void(p_grn_id, c.company_id);
  end if;
  return jsonb_build_object('ok', false, 'reason', 'unknown_action');
end;
$$;


-- receipt list (same as 020) + posting permission + invoice photos count
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
  if c.role_name <> 'owner' and not exists (select 1 from public.role_permissions rp where rp.role_name = c.role_name and rp.perm in ('purchasing', 'po_post', 'po_receive')) then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  return jsonb_build_object('ok', true,
    'can_post', public.pos_perm_ok(c.role_name, 'po_post'), 'can_receive', public.pos_perm_ok(c.role_name, 'po_receive'),
    'receipts', coalesce((
    select jsonb_agg(jsonb_build_object('id', g.id, 'grn_number', g.grn_number, 'status', g.status, 'received_at', g.received_at,
             'posted_at', g.posted_at, 'po_number', po.po_number, 'supplier', s.name, 'warehouse', w.name, 'notes', g.notes,
             'received_by', rb.name, 'posted_by', pb.name,
             'files', (select count(*) from public.goods_receipt_files gf where gf.goods_receipt_id = g.id),
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


-- ===================================================================================
-- Supplier invoice photos on the goods receipt
-- ===================================================================================
create table if not exists public.goods_receipt_files (
  id uuid primary key default gen_random_uuid(),
  goods_receipt_id uuid not null references public.goods_receipts(id) on delete cascade,
  image text not null,
  created_by uuid,
  created_at timestamptz not null default now()
);
alter table public.goods_receipt_files enable row level security;
create index if not exists goods_receipt_files_grn_idx on public.goods_receipt_files (goods_receipt_id);
select public.pos_sync_attach_all();

create or replace function public.gr_files_secure(p_token text, p_action text, p_data jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
  d jsonb := coalesce(p_data, '{}'::jsonb);
  v_grn uuid := public.pos_uuid(d->>'grn_id');
  v_id uuid := public.pos_uuid(d->>'id');
  v_status text;
begin
  select * into c from public.pos_ctx(p_token, 'purchasing');
  if v_grn is null and v_id is not null then
    select f.goods_receipt_id into v_grn from public.goods_receipt_files f where f.id = v_id;
  end if;
  select g.status into v_status
    from public.goods_receipts g join public.warehouses w on w.id = g.warehouse_id
   where g.id = v_grn and (c.role_name = 'owner' or w.branch_id = c.branch_id);
  if v_status is null then
    return jsonb_build_object('ok', false, 'reason', 'grn_not_found');
  end if;
  if p_action = 'get' then
    return jsonb_build_object('ok', true, 'image', (select f.image from public.goods_receipt_files f where f.id = v_id and f.goods_receipt_id = v_grn));
  elsif p_action = 'add' then
    if not public.pos_perm_ok(c.role_name, 'po_receive') and not public.pos_perm_ok(c.role_name, 'po_post') then
      return jsonb_build_object('ok', false, 'reason', 'not_allowed');
    end if;
    if coalesce(d->>'image', '') !~ '^data:image/(png|jpeg|jpg|webp);base64,' or length(d->>'image') > 600000 then
      return jsonb_build_object('ok', false, 'reason', 'invalid_image');
    end if;
    if (select count(*) from public.goods_receipt_files f where f.goods_receipt_id = v_grn) >= 6 then
      return jsonb_build_object('ok', false, 'reason', 'too_many');
    end if;
    insert into public.goods_receipt_files (goods_receipt_id, image, created_by) values (v_grn, d->>'image', c.staff_id);
  elsif p_action = 'delete' then
    if not public.pos_perm_ok(c.role_name, 'po_receive') or v_status <> 'pending' then
      return jsonb_build_object('ok', false, 'reason', 'not_allowed');
    end if;
    delete from public.goods_receipt_files where id = v_id and goods_receipt_id = v_grn;
  elsif coalesce(p_action, '') <> 'list' then
    return jsonb_build_object('ok', false, 'reason', 'unknown_action');
  end if;
  return jsonb_build_object('ok', true, 'files', coalesce((
    select jsonb_agg(jsonb_build_object('id', f.id, 'created_at', f.created_at, 'by', (select s.name from public.staff s where s.id = f.created_by))
                     order by f.created_at)
      from public.goods_receipt_files f where f.goods_receipt_id = v_grn), '[]'::jsonb));
end;
$$;

create or replace function public.motionpos_version_public()
returns text
language sql
immutable
as $$
  select '022'
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

-- ===================================================================================
-- Self-test (rolled back)
-- ===================================================================================
do $selftest$
declare
  v_company uuid; v_brand uuid; v_branch uuid; v_wh uuid; v_sup uuid; v_po uuid; v_grn uuid; v_mgr uuid; v_owner uuid;
  v_tm text := 'mp-t22-m-' || md5(random()::text || clock_timestamp()::text);
  v_to text := 'mp-t22-o-' || md5(random()::text || clock_timestamp()::text);
  v_res jsonb;
begin
  begin
    if not public.pos_perm_ok('owner', 'po_approve') then raise exception 'SELFTEST owner lost a permission'; end if;
    if exists (select 1 from public.role_permissions where role_name = 'branch_manager' and perm in ('purchasing'))
       and (not public.pos_perm_ok('branch_manager', 'po_receive') or public.pos_perm_ok('branch_manager', 'po_approve')) then
      raise exception 'SELFTEST branch manager defaults wrong';
    end if;
    if array_position(public.pos_all_perms(), 'po_post') is null or array_position(public.pos_all_perms(), 'settings_menu') is null then
      raise exception 'SELFTEST permission list incomplete';
    end if;

    insert into public.companies (name) values ('selftest022') returning id into v_company;
    insert into public.brands (company_id, name) values (v_company, 'selftest022') returning id into v_brand;
    insert into public.branches (name, brand_id) values ('selftest022', v_brand) returning id into v_branch;
    insert into public.warehouses (name, branch_id, is_main) values ('selftest022', v_branch, true) returning id into v_wh;
    insert into public.roles (name) values ('selftest022_role') on conflict do nothing;
    insert into public.role_permissions (role_name, perm) values ('selftest022_role', 'purchasing'), ('selftest022_role', 'po_receive');
    insert into public.staff (name, role_id, branch_id, company_id, is_active)
    values ('selftest022 m', (select id from public.roles where name = 'selftest022_role'), v_branch, v_company, true) returning id into v_mgr;
    insert into public.staff (name, role_id, branch_id, company_id, is_active)
    values ('selftest022 o', (select id from public.roles where name = 'owner'), v_branch, v_company, true) returning id into v_owner;
    insert into public.staff_sessions (token_hash, staff_id, expires_at)
    values (encode(extensions.digest(v_tm, 'sha256'), 'hex'), v_mgr, now() + interval '10 minutes'),
           (encode(extensions.digest(v_to, 'sha256'), 'hex'), v_owner, now() + interval '10 minutes');
    insert into public.suppliers (name) values ('selftest022') returning id into v_sup;
    insert into public.purchase_orders (supplier_id, warehouse_id, company_id, branch_id, status, po_number, total_amount)
    values (v_sup, v_wh, v_company, v_branch, 'draft', 'PO-ST022', 100) returning id into v_po;

    -- a role without po_approve cannot approve; without po_post cannot post
    v_res := public.po_action_secure(v_tm, v_po, 'approve', '0000', null);
    if coalesce(v_res->>'reason', '') <> 'not_allowed' then raise exception 'SELFTEST approve allowed without permission: %', v_res; end if;
    insert into public.goods_receipts (purchase_order_id, warehouse_id, grn_number, status) values (v_po, v_wh, 'GRN-ST022', 'pending') returning id into v_grn;
    v_res := public.gr_action_secure(v_tm, v_grn, 'post');
    if coalesce(v_res->>'reason', '') <> 'not_allowed' then raise exception 'SELFTEST post allowed without permission: %', v_res; end if;
    v_res := public.gr_list_secure(v_tm, 'pending');
    if coalesce((v_res->>'can_post')::boolean, true) or not coalesce((v_res->>'can_receive')::boolean, false) then
      raise exception 'SELFTEST receipt list flags wrong: %', v_res->>'can_post';
    end if;

    -- invoice photo: the receiver adds it, the owner sees it
    v_res := public.gr_files_secure(v_tm, 'add', jsonb_build_object('grn_id', v_grn, 'image', 'data:image/jpeg;base64,AAAA'));
    if jsonb_array_length(v_res->'files') <> 1 then raise exception 'SELFTEST photo not added: %', v_res; end if;
    v_res := public.gr_files_secure(v_to, 'get', jsonb_build_object('id', v_res->'files'->0->>'id'));
    if v_res->>'image' <> 'data:image/jpeg;base64,AAAA' then raise exception 'SELFTEST photo not read back'; end if;
    v_res := public.gr_files_secure(v_tm, 'add', jsonb_build_object('grn_id', v_grn, 'image', 'javascript:x'));
    if coalesce(v_res->>'reason', '') <> 'invalid_image' then raise exception 'SELFTEST bad photo accepted'; end if;

    raise notice 'MOTIONPOS-022-SELFTEST-OK';
    raise exception using errcode = 'P0099', message = 'selftest_rollback';
  exception when sqlstate 'P0099' then
    null;
  end;
end;
$selftest$;

notify pgrst, 'reload schema';

commit;
