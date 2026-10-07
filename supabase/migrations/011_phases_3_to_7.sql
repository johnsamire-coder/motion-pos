-- 011_phases_3_to_7.sql
-- Phases 3 to 7 in one file: stores, treasury and shifts, staff (attendance and payroll), expenses, purchasing.
-- Same rules as 008-010: every function needs a shift ticket, money and quantities are calculated here,
-- every money movement makes a journal entry, nothing financial is deleted.
-- If anything fails (including the self-test at the end) the WHOLE file is rolled back.

begin;

-- ===================================================================================
-- PART A: shared foundation + phase 3 (stores)
-- ===================================================================================

do $preflight$
begin
  if length('إكراميات') <> 8 then
    raise exception 'file_encoding_broken: read the file as UTF-8';
  end if;
  if to_regprocedure('public.close_order_secure(text,uuid,jsonb,numeric,uuid)') is null
     or to_regprocedure('public.pos_gl_account(uuid,text)') is null
     or to_regprocedure('public.record_stock_movement(uuid,uuid,uuid,uuid,uuid,text,numeric,numeric,text,uuid,text,uuid)') is null then
    raise exception 'schema_preflight_failed: run 001 to 010 first';
  end if;
end;
$preflight$;

-- New accounts (only where missing)
do $accounts$
declare
  c uuid;
  a record;
begin
  for c in select distinct x.company_id from public.accounts x where x.company_id is not null loop
    for a in
      select * from (values
        ('1130', 'ذمم الموظفين (عجز وسلف)', 'Staff receivables', 'asset', 'debit'),
        ('1140', 'عهد الموظفين', 'Staff custody', 'asset', 'debit'),
        ('1150', 'ضريبة القيمة المضافة - مدخلات', 'Input VAT', 'asset', 'debit'),
        ('2150', 'بضاعة مستلمة لم تصل فاتورتها', 'Goods received not invoiced', 'liability', 'credit'),
        ('2500', 'رواتب مستحقة', 'Salaries payable', 'liability', 'credit'),
        ('3300', 'جاري صاحب المحل', 'Owner current account', 'equity', 'debit'),
        ('5300', 'فروقات الجرد', 'Stock count differences', 'cogs', 'debit')
      ) as v(code, name_ar, name_en, account_type, normal_balance)
    loop
      if not exists (select 1 from public.accounts x where x.company_id = c and x.code = a.code) then
        insert into public.accounts (company_id, code, name_ar, name_en, account_type, normal_balance, is_system_account)
        values (c, a.code, a.name_ar, a.name_en, a.account_type, a.normal_balance, true);
      end if;
    end loop;
  end loop;
end;
$accounts$;

-- Journal entry reference types used by the new sections
alter table public.journal_entries drop constraint if exists journal_entries_reference_type_check;
alter table public.journal_entries add constraint journal_entries_reference_type_check check (reference_type = any (array[
  'order', 'purchase_order', 'goods_receipt', 'waste_log', 'stock_transfer', 'expense', 'payment', 'supplier_payment',
  'adjustment', 'manual', 'shift', 'payroll', 'custody', 'stocktake', 'supplier_invoice', 'treasury', 'advance']));

-- Permissions per role (owner always has everything)
create table if not exists public.role_permissions (
  role_name text not null,
  perm text not null,
  primary key (role_name, perm)
);
alter table public.role_permissions enable row level security;

insert into public.role_permissions (role_name, perm)
select r, p
  from (values
    ('branch_manager', array['pos','kds','shift','inventory','inventory_approve','purchasing','treasury','expenses','staff','payroll','reports','settings','accounting']),
    ('cashier', array['pos','kds','shift']),
    ('waiter', array['pos','kds']),
    ('storekeeper', array['inventory','purchasing'])
  ) as v(r, perms)
  cross join lateral unnest(v.perms) as p
on conflict do nothing;

-- Session + permission check. Every new function starts with this.
create or replace function public.pos_ctx(p_token text, p_perm text)
returns table (staff_id uuid, company_id uuid, branch_id uuid, role_name text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  r record;
begin
  select s.staff_id as sid, s.company_id as cid, s.branch_id as bid, s.role_name as rname
    into r
    from public.require_session(p_token) s;
  if p_perm is not null and r.rname <> 'owner'
     and not exists (select 1 from public.role_permissions rp where rp.role_name = r.rname and rp.perm = p_perm) then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  return query select r.sid, r.cid, r.bid, r.rname;
end;
$$;

-- Owner PIN check (for amounts above the manager limit). Same attempt limit as the manager PIN.
create or replace function public.pos_verify_owner_pin(p_pin text, p_company_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_ip text := public.request_client_ip();
  v_ip_failures int;
  v_all_failures int;
  v_id uuid;
begin
  select count(*) into v_ip_failures from public.manager_pin_attempts
   where client_ip = v_ip and not success and attempted_at > now() - interval '10 minutes';
  select count(*) into v_all_failures from public.manager_pin_attempts
   where not success and attempted_at > now() - interval '10 minutes';
  if v_ip_failures >= 10 or v_all_failures >= 100 then
    return null;
  end if;
  if p_pin is not null and p_pin ~ '^[0-9]{4}$' then
    select s.id into v_id
      from public.staff s join public.roles r on r.id = s.role_id
     where s.company_id = p_company_id and s.is_active is true and r.name = 'owner'
       and s.pin_hash is not null and s.pin_hash = extensions.crypt(p_pin, s.pin_hash)
     limit 1;
  end if;
  insert into public.manager_pin_attempts (client_ip, success) values (v_ip, v_id is not null);
  return v_id;
end;
$$;

-- Journal entry from lines given by account code: {code, debit, credit, description}. Zero lines are skipped.
create or replace function public.pos_post_je(
  p_company_id uuid, p_branch_id uuid, p_journal_type text, p_ref_type text, p_ref_id uuid,
  p_description text, p_lines jsonb, p_staff_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_lines jsonb := '[]'::jsonb;
  l jsonb;
  v_debit numeric;
  v_credit numeric;
begin
  for l in select e.value from jsonb_array_elements(p_lines) as e(value) loop
    v_debit := round(coalesce((l->>'debit')::numeric, 0), 2);
    v_credit := round(coalesce((l->>'credit')::numeric, 0), 2);
    if v_debit > 0 or v_credit > 0 then
      v_lines := v_lines || jsonb_build_array(jsonb_build_object(
        'account_id', coalesce(public.pos_uuid(l->>'account_id'), public.pos_gl_account(p_company_id, l->>'code')),
        'debit', v_debit, 'credit', v_credit, 'description', coalesce(l->>'description', p_description)));
    end if;
  end loop;
  if jsonb_array_length(v_lines) = 0 then
    return null;
  end if;
  return public.create_journal_entry(p_company_id, p_branch_id, current_date, p_journal_type, p_ref_type, p_ref_id,
                                     p_description, v_lines, true, p_staff_id);
end;
$$;

create or replace function public.pos_je_line(p_code text, p_debit numeric, p_credit numeric, p_desc text)
returns jsonb
language sql
immutable
as $$
  select jsonb_build_object('code', p_code, 'debit', coalesce(p_debit, 0), 'credit', coalesce(p_credit, 0), 'description', p_desc)
$$;

-- Can this session use this warehouse? (owner: all; others: own branch + shared main warehouses)
create or replace function public.pos_warehouse_ok(p_warehouse_id uuid, p_branch_id uuid, p_role text)
returns boolean
language sql
stable
security definer
set search_path = public, extensions
as $$
  select exists (
    select 1 from public.warehouses w
     where w.id = p_warehouse_id
       and (p_role = 'owner' or w.branch_id = p_branch_id or w.branch_id is null))
$$;

-- Stock out / in through the one stock function, returns the value moved
create or replace function public.pos_stock_move(
  p_company_id uuid, p_branch_id uuid, p_warehouse_id uuid, p_ingredient_id uuid, p_type text,
  p_qty numeric, p_unit_cost numeric, p_ref_type text, p_ref_id uuid, p_note text, p_staff_id uuid)
returns numeric
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_cost numeric;
  v_brand uuid;
begin
  if p_unit_cost is null then
    select coalesce(i.cost_per_unit, 0) into v_cost from public.ingredients i where i.id = p_ingredient_id;
  else
    v_cost := p_unit_cost;
  end if;
  select b.brand_id into v_brand from public.branches b where b.id = p_branch_id;
  perform public.record_stock_movement(p_company_id, v_brand, p_branch_id, p_warehouse_id, p_ingredient_id,
                                       p_type, p_qty, coalesce(v_cost, 0), p_ref_type, p_ref_id, p_note, p_staff_id);
  return round(abs(p_qty) * coalesce(v_cost, 0), 2);
end;
$$;

-- -------------------------------------------------------------------------------
-- Phase 3: stores
-- -------------------------------------------------------------------------------
alter table public.stock_takes add column if not exists count_id uuid;
alter table public.stock_takes alter column theoretical_qty type numeric(15,4);
alter table public.stock_takes alter column actual_qty type numeric(15,4);
alter table public.stock_takes alter column variance_qty type numeric(15,4);

create table if not exists public.inv_counts (
  id uuid primary key default gen_random_uuid(),
  company_id uuid,
  warehouse_id uuid not null references public.warehouses(id),
  counted_by uuid,
  approved_by uuid,
  notes text,
  total_variance_cost numeric(15,2) not null default 0,
  created_at timestamptz not null default now()
);
alter table public.inv_counts enable row level security;

create table if not exists public.inv_transfers (
  id uuid primary key default gen_random_uuid(),
  company_id uuid,
  transfer_number text,
  from_warehouse_id uuid not null references public.warehouses(id),
  to_warehouse_id uuid not null references public.warehouses(id),
  status text not null default 'requested' check (status in ('requested', 'approved', 'shipped', 'received', 'cancelled')),
  notes text,
  requested_by uuid, approved_by uuid, shipped_by uuid, received_by uuid,
  created_at timestamptz not null default now(),
  approved_at timestamptz, shipped_at timestamptz, received_at timestamptz
);
alter table public.inv_transfers enable row level security;

create table if not exists public.inv_transfer_lines (
  id uuid primary key default gen_random_uuid(),
  transfer_id uuid not null references public.inv_transfers(id) on delete cascade,
  ingredient_id uuid not null references public.ingredients(id),
  qty_requested numeric(15,4) not null,
  qty_shipped numeric(15,4) not null default 0,
  qty_received numeric(15,4) not null default 0,
  unit_cost numeric(15,4) not null default 0
);
alter table public.inv_transfer_lines enable row level security;

create or replace function public.inv_warehouses_secure(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
begin
  select * into c from public.pos_ctx(p_token, null);
  return jsonb_build_object('ok', true, 'warehouses', coalesce((
    select jsonb_agg(jsonb_build_object('id', w.id, 'name', w.name, 'branch_id', w.branch_id,
                                        'branch_name', b.name, 'is_main', w.is_main,
                                        'mine', (c.role_name = 'owner' or w.branch_id = c.branch_id or w.branch_id is null))
                     order by w.is_main desc, w.name)
      from public.warehouses w left join public.branches b on b.id = w.branch_id), '[]'::jsonb));
end;
$$;

create or replace function public.inv_stock_secure(p_token text, p_warehouse_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
begin
  select * into c from public.pos_ctx(p_token, 'inventory');
  if not public.pos_warehouse_ok(p_warehouse_id, c.branch_id, c.role_name) then
    return jsonb_build_object('ok', false, 'reason', 'warehouse_not_allowed');
  end if;
  return jsonb_build_object('ok', true, 'items', coalesce((
    select jsonb_agg(jsonb_build_object(
             'ingredient_id', i.id, 'name', i.name, 'unit', i.unit,
             'quantity', coalesce(ws.quantity, 0), 'min_stock_alert', coalesce(i.min_stock_alert, 0),
             'cost_per_unit', coalesce(i.cost_per_unit, 0),
             'value', round(coalesce(ws.quantity, 0) * coalesce(i.cost_per_unit, 0), 2),
             'low', coalesce(ws.quantity, 0) <= coalesce(i.min_stock_alert, 0)) order by i.name)
      from public.ingredients i
      left join public.warehouse_stock ws on ws.ingredient_id = i.id and ws.warehouse_id = p_warehouse_id), '[]'::jsonb));
end;
$$;

create or replace function public.inv_ledger_secure(
  p_token text, p_warehouse_id uuid, p_ingredient_id uuid, p_from date, p_to date)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
begin
  select * into c from public.pos_ctx(p_token, 'inventory');
  if not public.pos_warehouse_ok(p_warehouse_id, c.branch_id, c.role_name) then
    return jsonb_build_object('ok', false, 'reason', 'warehouse_not_allowed');
  end if;
  return jsonb_build_object('ok', true, 'moves', coalesce((
    select jsonb_agg(x order by (x->>'created_at') desc) from (
      select jsonb_build_object(
               'created_at', sm.created_at, 'ingredient', i.name, 'unit', i.unit, 'type', sm.movement_type,
               'quantity', sm.quantity, 'unit_cost', sm.unit_cost, 'total_cost', sm.total_cost,
               'balance_after', sm.balance_after, 'notes', sm.notes, 'by', st.name) as x
        from public.stock_movements sm
        left join public.ingredients i on i.id = sm.ingredient_id
        left join public.staff st on st.id = sm.created_by
       where sm.warehouse_id = p_warehouse_id
         and (p_ingredient_id is null or sm.ingredient_id = p_ingredient_id)
         and sm.created_at::date between coalesce(p_from, current_date - 30) and coalesce(p_to, current_date)
       order by sm.created_at desc
       limit 500) q), '[]'::jsonb));
end;
$$;

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

-- Blind count: the counter sends what he counted, the difference is calculated here
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

-- Expected vs actual for a period: expected use = sales by recipe + recorded waste; actual adds the count differences
create or replace function public.inv_variance_secure(p_token text, p_warehouse_id uuid, p_from date, p_to date)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
begin
  select * into c from public.pos_ctx(p_token, 'inventory');
  if not public.pos_warehouse_ok(p_warehouse_id, c.branch_id, c.role_name) then
    return jsonb_build_object('ok', false, 'reason', 'warehouse_not_allowed');
  end if;
  return jsonb_build_object('ok', true, 'rows', coalesce((
    select jsonb_agg(jsonb_build_object(
             'ingredient', q.name, 'unit', q.unit, 'sales_qty', q.sales_qty, 'waste_qty', q.waste_qty,
             'expected_qty', q.sales_qty + q.waste_qty,
             'actual_qty', q.sales_qty + q.waste_qty - q.count_qty,
             'difference_qty', -q.count_qty,
             'difference_value', round(-q.count_qty * q.cost, 2)) order by round(q.count_qty * q.cost, 2))
      from (
        select i.name, i.unit, coalesce(i.cost_per_unit, 0) as cost,
               coalesce(sum(case when sm.movement_type = 'sale' then -sm.quantity end), 0) as sales_qty,
               coalesce(sum(case when sm.movement_type = 'waste' then -sm.quantity end), 0) as waste_qty,
               coalesce(sum(case when sm.movement_type = 'adjustment' and sm.reference_type = 'stocktake' then sm.quantity end), 0) as count_qty
          from public.stock_movements sm
          join public.ingredients i on i.id = sm.ingredient_id
         where sm.warehouse_id = p_warehouse_id
           and sm.created_at::date between coalesce(p_from, current_date - 30) and coalesce(p_to, current_date)
         group by i.name, i.unit, i.cost_per_unit) q), '[]'::jsonb));
end;
$$;

-- Transfers between warehouses / branches: request -> approve -> ship (in transit) -> receive
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

create or replace function public.inv_transfers_list_secure(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
begin
  select * into c from public.pos_ctx(p_token, 'inventory');
  return jsonb_build_object('ok', true, 'transfers', coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', t.id, 'transfer_number', t.transfer_number, 'status', t.status, 'created_at', t.created_at,
             'from_warehouse', wf.name, 'to_warehouse', wt.name, 'from_warehouse_id', t.from_warehouse_id,
             'to_warehouse_id', t.to_warehouse_id, 'notes', t.notes,
             'lines', (select jsonb_agg(jsonb_build_object('ingredient_id', l.ingredient_id, 'ingredient', i.name, 'unit', i.unit,
                                                           'qty_requested', l.qty_requested, 'qty_shipped', l.qty_shipped,
                                                           'qty_received', l.qty_received))
                         from public.inv_transfer_lines l join public.ingredients i on i.id = l.ingredient_id
                        where l.transfer_id = t.id)) order by t.created_at desc)
      from public.inv_transfers t
      join public.warehouses wf on wf.id = t.from_warehouse_id
      join public.warehouses wt on wt.id = t.to_warehouse_id
     where t.created_at > now() - interval '90 days'
       and (c.role_name = 'owner'
            or public.pos_warehouse_ok(t.from_warehouse_id, c.branch_id, c.role_name)
            or public.pos_warehouse_ok(t.to_warehouse_id, c.branch_id, c.role_name))), '[]'::jsonb));
end;
$$;

-- ===================================================================================
-- PART B: phase 4 (treasury and shifts)
-- Boxes: main_cash = 1100 (main safe), drawer = 1101 (cashier drawers), bank = 1110, owner = 3300.
-- ===================================================================================

create table if not exists public.pos_shifts (
  id uuid primary key default gen_random_uuid(),
  company_id uuid,
  branch_id uuid,
  staff_id uuid not null references public.staff(id),
  status text not null default 'open' check (status in ('open', 'closed')),
  opened_at timestamptz not null default now(),
  opening_float numeric(15,2) not null default 0,
  closed_at timestamptz,
  expected_cash numeric(15,2),
  counted_cash numeric(15,2),
  difference numeric(15,2),
  tips_paid numeric(15,2) not null default 0,
  notes text
);
create unique index if not exists pos_shifts_one_open_per_staff on public.pos_shifts (staff_id) where status = 'open';
alter table public.pos_shifts enable row level security;

create table if not exists public.pos_cash_moves (
  id uuid primary key default gen_random_uuid(),
  shift_id uuid references public.pos_shifts(id),
  company_id uuid,
  branch_id uuid,
  move_type text not null check (move_type in ('float', 'cash_in', 'drop', 'tips_payout', 'expense', 'close_handover',
                                               'shortage', 'overage', 'supplier_payment', 'custody', 'advance',
                                               'treasury_transfer', 'payroll')),
  amount numeric(15,2) not null,
  source text,
  destination text,
  reason text,
  staff_id uuid,
  approved_by uuid,
  created_at timestamptz not null default now()
);
alter table public.pos_cash_moves enable row level security;

alter table public.payments add column if not exists shift_id uuid references public.pos_shifts(id);

create table if not exists public.staff_ledger (
  id uuid primary key default gen_random_uuid(),
  company_id uuid,
  staff_id uuid not null references public.staff(id),
  entry_type text not null check (entry_type in ('shortage', 'advance', 'deduction', 'repayment', 'adjustment')),
  amount numeric(15,2) not null,
  balance_after numeric(15,2) not null default 0,
  shift_id uuid,
  payroll_run_id uuid,
  notes text,
  created_by uuid,
  created_at timestamptz not null default now()
);
alter table public.staff_ledger enable row level security;

create table if not exists public.pos_days (
  branch_id uuid not null,
  business_date date not null,
  closed_by uuid,
  closed_at timestamptz not null default now(),
  report jsonb,
  primary key (branch_id, business_date)
);
alter table public.pos_days enable row level security;

-- Box name -> account code
create or replace function public.pos_box_code(p_box text)
returns text
language sql
immutable
as $$
  select case p_box when 'main_cash' then '1100' when 'drawer' then '1101' when 'bank' then '1110' when 'owner' then '3300' end
$$;

-- What should be in the drawer right now (never shown to the cashier before closing)
create or replace function public.pos_shift_expected(p_shift_id uuid)
returns numeric
language sql
stable
security definer
set search_path = public, extensions
as $$
  select coalesce((select s.opening_float from public.pos_shifts s where s.id = p_shift_id), 0)
       + coalesce((select sum(p.amount + coalesce(p.tip_amount, 0)) from public.payments p
                    where p.shift_id = p_shift_id and p.payment_method = 'cash'), 0)
       + coalesce((select sum(case when m.move_type in ('cash_in', 'overage') then m.amount
                                   when m.move_type in ('drop', 'tips_payout', 'expense', 'supplier_payment', 'custody',
                                                        'advance', 'payroll', 'close_handover', 'shortage') then -m.amount
                                   else 0 end)
                    from public.pos_cash_moves m where m.shift_id = p_shift_id and m.move_type <> 'float'), 0)
$$;

-- Staff balance (what the staff member owes: shortages + advances - deductions/repayments)
create or replace function public.pos_staff_add_ledger(
  p_company_id uuid, p_staff_id uuid, p_type text, p_amount numeric, p_shift_id uuid, p_run_id uuid, p_notes text, p_by uuid)
returns numeric
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_bal numeric;
begin
  perform 1 from public.staff s where s.id = p_staff_id for update;
  select coalesce(sum(l.amount), 0) + p_amount into v_bal from public.staff_ledger l where l.staff_id = p_staff_id;
  insert into public.staff_ledger (company_id, staff_id, entry_type, amount, balance_after, shift_id, payroll_run_id, notes, created_by)
  values (p_company_id, p_staff_id, p_type, p_amount, v_bal, p_shift_id, p_run_id, p_notes, p_by);
  return v_bal;
end;
$$;

-- Sales must now be inside an open shift: close and refund are redefined with the shift
create or replace function public.close_order_secure(
  p_token text, p_order_id uuid, p_payments jsonb, p_tip_amount numeric, p_tip_staff_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_staff uuid;
  v_branch uuid;
  v_order public.orders%rowtype;
  v_payments jsonb := coalesce(p_payments, '[]'::jsonb);
  v_totals jsonb;
  v_total numeric;
  v_tax numeric;
  v_service numeric;
  v_revenue numeric;
  v_tip numeric := round(coalesce(p_tip_amount, 0), 2);
  v_p jsonb;
  v_method text;
  v_amount numeric;
  v_paid numeric := 0;
  v_oa numeric := 0;
  v_idx int := 0;
  v_tip_line int := 0;
  v_cust public.customers%rowtype;
  v_balance numeric := 0;
  v_wh uuid;
  v_c record;
  v_unit numeric;
  v_cogs numeric := 0;
  v_lines jsonb := '[]'::jsonb;
  v_pm record;
  v_method_count int;
  v_first_method text;
  v_shift uuid;
begin
  select rs.staff_id, rs.branch_id into v_staff, v_branch from public.require_session(p_token) rs;

  select s.id into v_shift from public.pos_shifts s where s.staff_id = v_staff and s.status = 'open';
  if v_shift is null then
    return jsonb_build_object('ok', false, 'reason', 'no_open_shift');
  end if;

  select o.* into v_order from public.orders o where o.id = p_order_id and o.branch_id = v_branch for update;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'order_not_found');
  end if;
  if coalesce(v_order.status, '') in ('paid', 'closed', 'cancelled') then
    return jsonb_build_object('ok', false, 'reason', 'order_not_open');
  end if;
  if not exists (select 1 from public.order_items oi
                  where oi.order_id = p_order_id and coalesce(oi.status, 'active') = 'active') then
    return jsonb_build_object('ok', false, 'reason', 'empty_order');
  end if;
  if exists (select 1 from public.payments p where p.order_id = p_order_id) then
    return jsonb_build_object('ok', false, 'reason', 'order_has_old_payments');
  end if;

  v_totals := public.recalc_order_totals(p_order_id);
  v_total := (v_totals->>'total_amount')::numeric;
  v_tax := (v_totals->>'tax_amount')::numeric;
  v_service := (v_totals->>'service_charge_amount')::numeric;
  v_revenue := v_total - v_tax - v_service;

  if v_tip < 0 or v_tip > 99999999 then
    return jsonb_build_object('ok', false, 'reason', 'invalid_tip');
  end if;
  if jsonb_typeof(v_payments) is distinct from 'array' or jsonb_array_length(v_payments) > 10 then
    return jsonb_build_object('ok', false, 'reason', 'invalid_payments');
  end if;

  for v_p in select e.value from jsonb_array_elements(v_payments) as e(value)
  loop
    v_idx := v_idx + 1;
    if jsonb_typeof(v_p) is distinct from 'object' then
      return jsonb_build_object('ok', false, 'reason', 'invalid_payments');
    end if;
    v_method := v_p->>'method';
    if v_method is null or v_method not in ('cash', 'card', 'instapay', 'wallet', 'on_account') then
      return jsonb_build_object('ok', false, 'reason', 'invalid_payment_method');
    end if;
    if coalesce(v_p->>'amount', '') !~ '^[0-9]{1,9}(\.[0-9]{1,2})?$' then
      return jsonb_build_object('ok', false, 'reason', 'invalid_payment_amount');
    end if;
    v_amount := (v_p->>'amount')::numeric;
    if v_amount <= 0 then
      return jsonb_build_object('ok', false, 'reason', 'invalid_payment_amount');
    end if;
    v_paid := v_paid + v_amount;
    if v_method = 'on_account' then
      v_oa := v_oa + v_amount;
    elsif v_tip_line = 0 then
      v_tip_line := v_idx;
    end if;
  end loop;

  if abs(v_paid - v_total) > 0.004 then
    return jsonb_build_object('ok', false, 'reason', 'payment_mismatch', 'due', v_total, 'paid', v_paid);
  end if;

  if v_tip > 0 then
    if v_tip_line = 0 then
      return jsonb_build_object('ok', false, 'reason', 'tip_needs_cash_or_card');
    end if;
    if p_tip_staff_id is null or not exists (
      select 1 from public.staff s where s.id = p_tip_staff_id and s.branch_id = v_branch and s.is_active is true) then
      return jsonb_build_object('ok', false, 'reason', 'invalid_tip_staff');
    end if;
  end if;

  if v_oa > 0 then
    if v_order.customer_id is null then
      return jsonb_build_object('ok', false, 'reason', 'credit_needs_customer');
    end if;
    select c.* into v_cust
      from public.customers c
     where c.id = v_order.customer_id and c.company_id = v_order.company_id
     for update;
    if not found or coalesce(v_cust.customer_type, 'cash') = 'cash' then
      return jsonb_build_object('ok', false, 'reason', 'customer_not_allowed_credit');
    end if;
    select coalesce(sum(l.amount), 0) into v_balance from public.customer_ledger l where l.customer_id = v_cust.id;
    if coalesce(v_cust.credit_limit, 0) > 0 and v_balance + v_oa > v_cust.credit_limit then
      return jsonb_build_object('ok', false, 'reason', 'credit_limit_exceeded',
                                'balance', v_balance, 'limit', v_cust.credit_limit);
    end if;
  end if;

  -- Payments
  v_idx := 0;
  for v_p in select e.value from jsonb_array_elements(v_payments) as e(value)
  loop
    v_idx := v_idx + 1;
    insert into public.payments (order_id, payment_method, amount, tip_amount, tip_staff_id, reference_number, shift_id)
    values (p_order_id, v_p->>'method', (v_p->>'amount')::numeric,
            case when v_idx = v_tip_line then v_tip else 0 end,
            case when v_idx = v_tip_line and v_tip > 0 then p_tip_staff_id else null end,
            nullif(left(btrim(coalesce(v_p->>'reference', '')), 100), ''), v_shift);
  end loop;

  -- Credit sale on the customer's account
  if v_oa > 0 then
    v_balance := v_balance + v_oa;
    insert into public.customer_ledger (company_id, customer_id, order_id, transaction_type, amount,
                                        reference_number, balance_after, notes, created_by)
    values (v_order.company_id, v_cust.id, p_order_id, 'credit_sale', v_oa,
            v_order.order_number, v_balance, 'بيع آجل', v_staff);
    update public.customers set current_balance = v_balance where id = v_cust.id;
  end if;

  -- Stock: recipe + modifier ingredients of every active item
  v_wh := public.pos_branch_warehouse(v_order.branch_id);
  for v_c in
    select c.ingredient_id, sum(c.qty) as qty
      from public.order_items oi
      cross join lateral public.pos_item_consumption(oi.id, oi.quantity) c
     where oi.order_id = p_order_id
       and coalesce(oi.status, 'active') = 'active'
     group by c.ingredient_id
  loop
    if v_c.qty > 0 then
      if v_wh is null then
        raise exception 'no_branch_warehouse';
      end if;
      select coalesce(i.cost_per_unit, 0) into v_unit from public.ingredients i where i.id = v_c.ingredient_id;
      perform public.record_stock_movement(
        v_order.company_id, v_order.brand_id, v_order.branch_id, v_wh, v_c.ingredient_id,
        'sale', -v_c.qty, coalesce(v_unit, 0), 'order', p_order_id,
        'بيع - طلب ' || coalesce(v_order.order_number, ''), v_staff);
      v_cogs := v_cogs + round(v_c.qty * coalesce(v_unit, 0), 2);
    end if;
  end loop;

  -- Sales journal entry
  for v_pm in
    select p.payment_method, sum(p.amount + coalesce(p.tip_amount, 0)) as amt
      from public.payments p
     where p.order_id = p_order_id
     group by p.payment_method
  loop
    if v_pm.amt > 0 then
      v_lines := v_lines || jsonb_build_array(jsonb_build_object(
        'account_id', public.pos_payment_account(v_order.company_id, v_pm.payment_method),
        'debit', v_pm.amt, 'credit', 0, 'description', 'تحصيل ' || v_pm.payment_method));
    end if;
  end loop;
  if v_revenue > 0 then
    v_lines := v_lines || jsonb_build_array(jsonb_build_object(
      'account_id', public.pos_gl_account(v_order.company_id, '4000'),
      'debit', 0, 'credit', v_revenue, 'description', 'إيراد مبيعات'));
  end if;
  if v_service > 0 then
    v_lines := v_lines || jsonb_build_array(jsonb_build_object(
      'account_id', public.pos_gl_account(v_order.company_id, '4100'),
      'debit', 0, 'credit', v_service, 'description', 'إيراد خدمة'));
  end if;
  if v_tax > 0 then
    v_lines := v_lines || jsonb_build_array(jsonb_build_object(
      'account_id', public.pos_gl_account(v_order.company_id, '2200'),
      'debit', 0, 'credit', v_tax, 'description', 'ضريبة قيمة مضافة'));
  end if;
  if v_tip > 0 then
    v_lines := v_lines || jsonb_build_array(jsonb_build_object(
      'account_id', public.pos_gl_account(v_order.company_id, '2400'),
      'debit', 0, 'credit', v_tip, 'description', 'إكرامية مستحقة'));
  end if;
  if v_total + v_tip > 0 then
    perform public.create_journal_entry(
      v_order.company_id, v_order.branch_id, current_date, 'sales', 'order', p_order_id,
      'قيد مبيعات - طلب ' || coalesce(v_order.order_number, ''), v_lines, true, v_staff);
  end if;

  -- Cost of sales journal entry
  if v_cogs > 0 then
    perform public.create_journal_entry(
      v_order.company_id, v_order.branch_id, current_date, 'inventory', 'order', p_order_id,
      'قيد تكلفة مبيعات - طلب ' || coalesce(v_order.order_number, ''),
      jsonb_build_array(
        jsonb_build_object('account_id', public.pos_gl_account(v_order.company_id, '5000'),
                           'debit', v_cogs, 'credit', 0, 'description', 'تكلفة المبيعات'),
        jsonb_build_object('account_id', public.pos_gl_account(v_order.company_id, '1200'),
                           'debit', 0, 'credit', v_cogs, 'description', 'خصم المخزون')),
      true, v_staff);
  end if;

  select count(distinct p.payment_method), min(p.payment_method)
    into v_method_count, v_first_method
    from public.payments p
   where p.order_id = p_order_id;

  update public.orders
     set status = 'closed',
         is_posted_to_gl = true,
         payment_method = case when v_method_count = 1 then v_first_method
                               when v_method_count > 1 then 'split' else 'none' end
   where id = p_order_id;

  perform public.pos_free_table_if_empty(v_order.table_id);

  insert into public.order_logs (order_id, user_id, action, details)
  values (p_order_id, v_staff, 'CLOSE_ORDER', jsonb_build_object(
    'total', v_total, 'paid', v_paid, 'tip', v_tip, 'tip_staff_id', p_tip_staff_id,
    'on_account', v_oa, 'cogs', v_cogs, 'payments', v_payments));

  return jsonb_build_object('ok', true, 'order_number', v_order.order_number,
                            'total', v_total, 'tip', v_tip, 'cogs', v_cogs);
end;
$$;

create or replace function public.refund_order_secure(
  p_token text, p_order_number text, p_reason_id uuid, p_manager_pin text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_staff uuid;
  v_branch uuid;
  v_order public.orders%rowtype;
  v_manager uuid;
  v_je record;
  v_pm record;
  v_cl record;
  v_balance numeric;
  v_reversed int := 0;
  v_shift uuid;
begin
  select rs.staff_id, rs.branch_id into v_staff, v_branch from public.require_session(p_token) rs;

  select s.id into v_shift from public.pos_shifts s where s.staff_id = v_staff and s.status = 'open';
  if v_shift is null then
    return jsonb_build_object('ok', false, 'reason', 'no_open_shift');
  end if;

  select o.* into v_order
    from public.orders o
   where o.branch_id = v_branch
     and o.order_number = btrim(coalesce(p_order_number, ''))
     and o.status in ('closed', 'paid')
   order by o.created_at desc
   limit 1
   for update;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'order_not_found');
  end if;

  if p_reason_id is null or not exists (select 1 from public.cancel_reasons c where c.id = p_reason_id) then
    return jsonb_build_object('ok', false, 'reason', 'bad_reason');
  end if;

  v_manager := public.verify_manager_pin(p_manager_pin, v_branch);
  if v_manager is null then
    return jsonb_build_object('ok', false, 'reason', 'manager_pin');
  end if;

  for v_je in
    select je.id
      from public.journal_entries je
     where je.reference_type = 'order'
       and je.reference_id = v_order.id
       and je.journal_type = 'sales'
       and je.status = 'posted'
  loop
    perform public.reverse_journal_entry(v_order.company_id, v_je.id,
                                         'مرتجع طلب ' || coalesce(v_order.order_number, ''), v_staff);
    v_reversed := v_reversed + 1;
  end loop;

  for v_pm in
    select p.payment_method, sum(p.amount) as amt, sum(coalesce(p.tip_amount, 0)) as tip
      from public.payments p
     where p.order_id = v_order.id
     group by p.payment_method
  loop
    if v_pm.amt <> 0 or v_pm.tip <> 0 then
      insert into public.payments (order_id, payment_method, amount, tip_amount, reference_number, shift_id)
      values (v_order.id, v_pm.payment_method, -v_pm.amt, -v_pm.tip, 'REFUND', v_shift);
    end if;
  end loop;

  for v_cl in
    select l.customer_id, sum(l.amount) as amt
      from public.customer_ledger l
     where l.order_id = v_order.id
     group by l.customer_id
  loop
    if v_cl.amt <> 0 then
      select coalesce(sum(x.amount), 0) - v_cl.amt into v_balance
        from public.customer_ledger x where x.customer_id = v_cl.customer_id;
      insert into public.customer_ledger (company_id, customer_id, order_id, transaction_type, amount,
                                          reference_number, balance_after, notes, created_by)
      values (v_order.company_id, v_cl.customer_id, v_order.id, 'refund', -v_cl.amt,
              v_order.order_number, v_balance, 'مرتجع', v_staff);
      update public.customers set current_balance = v_balance where id = v_cl.customer_id;
    end if;
  end loop;

  update public.orders
     set status = 'cancelled',
         notes = left(coalesce(v_order.notes || ' | ', '') || 'مرتجع', 500)
   where id = v_order.id;

  insert into public.order_logs (order_id, user_id, action, details)
  values (v_order.id, v_staff, 'REFUND_ORDER', jsonb_build_object(
    'reason_id', p_reason_id, 'approved_by_manager_id', v_manager, 'total', v_order.total_amount,
    'entries_reversed', v_reversed, 'stock_returned', false));

  return jsonb_build_object('ok', true, 'order_number', v_order.order_number, 'total', v_order.total_amount);
end;
$$;

create or replace function public.shift_open_secure(p_token text, p_opening_float numeric)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
  v_id uuid;
  v_float numeric := round(coalesce(p_opening_float, 0), 2);
begin
  select * into c from public.pos_ctx(p_token, 'shift');
  if exists (select 1 from public.pos_shifts s where s.staff_id = c.staff_id and s.status = 'open') then
    return jsonb_build_object('ok', false, 'reason', 'shift_already_open');
  end if;
  if v_float < 0 or v_float > 1000000 then
    return jsonb_build_object('ok', false, 'reason', 'invalid_amount');
  end if;
  insert into public.pos_shifts (company_id, branch_id, staff_id, opening_float)
  values (c.company_id, c.branch_id, c.staff_id, v_float) returning id into v_id;
  if v_float > 0 then
    insert into public.pos_cash_moves (shift_id, company_id, branch_id, move_type, amount, source, destination, reason, staff_id)
    values (v_id, c.company_id, c.branch_id, 'float', v_float, 'main_cash', 'drawer', 'عهدة أول الوردية', c.staff_id);
    perform public.pos_post_je(c.company_id, c.branch_id, 'payment', 'shift', v_id, 'عهدة أول الوردية',
      jsonb_build_array(public.pos_je_line('1101', v_float, 0, 'درج الكاشير'),
                        public.pos_je_line('1100', 0, v_float, 'من الخزينة الرئيسية')), c.staff_id);
  end if;
  return jsonb_build_object('ok', true, 'shift_id', v_id);
end;
$$;

-- The cashier sees his shift without the expected cash (blind)
create or replace function public.shift_current_secure(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
  s public.pos_shifts%rowtype;
begin
  select * into c from public.pos_ctx(p_token, null);
  select x.* into s from public.pos_shifts x where x.staff_id = c.staff_id and x.status = 'open';
  if not found then
    return jsonb_build_object('ok', true, 'open', false);
  end if;
  return jsonb_build_object('ok', true, 'open', true, 'shift_id', s.id, 'opened_at', s.opened_at,
    'opening_float', s.opening_float,
    'orders_paid', (select count(distinct p.order_id) from public.payments p where p.shift_id = s.id and p.amount > 0));
end;
$$;

-- Cash during the shift: cash_in (more change from the main safe) or drop (to main safe, bank or owner)
create or replace function public.shift_cash_move_secure(
  p_token text, p_move_type text, p_amount numeric, p_destination text, p_reason text, p_manager_pin text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
  v_shift uuid;
  v_amount numeric := round(coalesce(p_amount, 0), 2);
  v_manager uuid;
begin
  select * into c from public.pos_ctx(p_token, 'shift');
  select s.id into v_shift from public.pos_shifts s where s.staff_id = c.staff_id and s.status = 'open' for update;
  if v_shift is null then
    return jsonb_build_object('ok', false, 'reason', 'no_open_shift');
  end if;
  if p_move_type not in ('cash_in', 'drop') then
    return jsonb_build_object('ok', false, 'reason', 'invalid_input');
  end if;
  if p_move_type = 'drop' and coalesce(p_destination, '') not in ('main_cash', 'bank', 'owner') then
    return jsonb_build_object('ok', false, 'reason', 'invalid_destination');
  end if;
  if v_amount <= 0 or v_amount > 10000000 then
    return jsonb_build_object('ok', false, 'reason', 'invalid_amount');
  end if;
  if nullif(btrim(coalesce(p_reason, '')), '') is null then
    return jsonb_build_object('ok', false, 'reason', 'reason_required');
  end if;
  if p_move_type = 'drop' and v_amount > public.pos_shift_expected(v_shift) then
    return jsonb_build_object('ok', false, 'reason', 'not_enough_cash');
  end if;
  v_manager := public.verify_manager_pin(p_manager_pin, c.branch_id);
  if v_manager is null then
    return jsonb_build_object('ok', false, 'reason', 'manager_pin');
  end if;

  insert into public.pos_cash_moves (shift_id, company_id, branch_id, move_type, amount, source, destination, reason, staff_id, approved_by)
  values (v_shift, c.company_id, c.branch_id, p_move_type, v_amount,
          case when p_move_type = 'drop' then 'drawer' else 'main_cash' end,
          case when p_move_type = 'drop' then p_destination else 'drawer' end,
          left(btrim(p_reason), 300), c.staff_id, v_manager);

  if p_move_type = 'drop' then
    perform public.pos_post_je(c.company_id, c.branch_id, 'payment', 'shift', v_shift, 'توريد من الدرج: ' || left(btrim(p_reason), 200),
      jsonb_build_array(public.pos_je_line(public.pos_box_code(p_destination), v_amount, 0, 'توريد'),
                        public.pos_je_line('1101', 0, v_amount, 'من درج الكاشير')), c.staff_id);
  else
    perform public.pos_post_je(c.company_id, c.branch_id, 'payment', 'shift', v_shift, 'فكة إضافية للدرج: ' || left(btrim(p_reason), 200),
      jsonb_build_array(public.pos_je_line('1101', v_amount, 0, 'درج الكاشير'),
                        public.pos_je_line('1100', 0, v_amount, 'من الخزينة الرئيسية')), c.staff_id);
  end if;
  return jsonb_build_object('ok', true);
end;
$$;

-- Shift report (used after closing, and by managers)
create or replace function public.pos_shift_report(p_shift_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public, extensions
as $$
  select jsonb_build_object(
    'shift_id', s.id, 'staff', st.name, 'status', s.status, 'opened_at', s.opened_at, 'closed_at', s.closed_at,
    'opening_float', s.opening_float, 'expected_cash', s.expected_cash, 'counted_cash', s.counted_cash,
    'difference', s.difference, 'tips_paid', s.tips_paid,
    'payments_by_method', coalesce((select jsonb_object_agg(q.payment_method, q.total) from (
        select p.payment_method, sum(p.amount) as total from public.payments p where p.shift_id = s.id group by p.payment_method) q), '{}'::jsonb),
    'orders_paid', (select count(distinct p.order_id) from public.payments p where p.shift_id = s.id and p.amount > 0),
    'cash_moves', coalesce((select jsonb_agg(jsonb_build_object('type', m.move_type, 'amount', m.amount, 'destination', m.destination,
                                                               'reason', m.reason, 'at', m.created_at) order by m.created_at)
                              from public.pos_cash_moves m where m.shift_id = s.id), '[]'::jsonb))
  from public.pos_shifts s join public.staff st on st.id = s.staff_id
  where s.id = p_shift_id
$$;

-- Blind close: the cashier sends what he counted. Tips are paid out, the difference is recorded,
-- and the counted cash goes to the main safe.
create or replace function public.shift_close_secure(p_token text, p_counted_cash numeric, p_notes text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
  s public.pos_shifts%rowtype;
  v_counted numeric := round(coalesce(p_counted_cash, -1), 2);
  v_tips numeric;
  v_expected numeric;
  v_diff numeric;
begin
  select * into c from public.pos_ctx(p_token, 'shift');
  select x.* into s from public.pos_shifts x where x.staff_id = c.staff_id and x.status = 'open' for update;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'no_open_shift');
  end if;
  if v_counted < 0 or v_counted > 100000000 then
    return jsonb_build_object('ok', false, 'reason', 'invalid_amount');
  end if;

  -- 1) tips collected in this shift are paid to the staff in cash from the drawer
  select coalesce(sum(p.tip_amount), 0) into v_tips from public.payments p where p.shift_id = s.id;
  if v_tips > 0 then
    insert into public.pos_cash_moves (shift_id, company_id, branch_id, move_type, amount, source, destination, reason, staff_id)
    values (s.id, c.company_id, c.branch_id, 'tips_payout', v_tips, 'drawer', 'staff', 'صرف الإكراميات', c.staff_id);
    perform public.pos_post_je(c.company_id, c.branch_id, 'payment', 'shift', s.id, 'صرف إكراميات الوردية',
      jsonb_build_array(public.pos_je_line('2400', v_tips, 0, 'إكراميات مستحقة'),
                        public.pos_je_line('1101', 0, v_tips, 'من درج الكاشير')), c.staff_id);
  end if;

  -- 2) difference
  v_expected := public.pos_shift_expected(s.id);
  v_diff := v_counted - v_expected;
  if v_diff < 0 then
    insert into public.pos_cash_moves (shift_id, company_id, branch_id, move_type, amount, reason, staff_id)
    values (s.id, c.company_id, c.branch_id, 'shortage', -v_diff, 'عجز قفل الوردية', c.staff_id);
    perform public.pos_staff_add_ledger(c.company_id, c.staff_id, 'shortage', -v_diff, s.id, null, 'عجز وردية', c.staff_id);
    perform public.pos_post_je(c.company_id, c.branch_id, 'adjustment', 'shift', s.id, 'عجز وردية',
      jsonb_build_array(public.pos_je_line('1130', -v_diff, 0, 'عجز على الكاشير'),
                        public.pos_je_line('1101', 0, -v_diff, 'عجز الدرج')), c.staff_id);
  elsif v_diff > 0 then
    insert into public.pos_cash_moves (shift_id, company_id, branch_id, move_type, amount, reason, staff_id)
    values (s.id, c.company_id, c.branch_id, 'overage', v_diff, 'زيادة قفل الوردية', c.staff_id);
    perform public.pos_post_je(c.company_id, c.branch_id, 'adjustment', 'shift', s.id, 'زيادة وردية',
      jsonb_build_array(public.pos_je_line('1101', v_diff, 0, 'زيادة الدرج'),
                        public.pos_je_line('4200', 0, v_diff, 'زيادة نقدية')), c.staff_id);
  end if;

  -- 3) the counted cash goes to the main safe
  if v_counted > 0 then
    insert into public.pos_cash_moves (shift_id, company_id, branch_id, move_type, amount, source, destination, reason, staff_id)
    values (s.id, c.company_id, c.branch_id, 'close_handover', v_counted, 'drawer', 'main_cash', 'تسليم نقدية آخر الوردية', c.staff_id);
    perform public.pos_post_je(c.company_id, c.branch_id, 'payment', 'shift', s.id, 'تسليم نقدية آخر الوردية',
      jsonb_build_array(public.pos_je_line('1100', v_counted, 0, 'الخزينة الرئيسية'),
                        public.pos_je_line('1101', 0, v_counted, 'من درج الكاشير')), c.staff_id);
  end if;

  update public.pos_shifts
     set status = 'closed', closed_at = now(), expected_cash = v_expected, counted_cash = v_counted,
         difference = v_diff, tips_paid = v_tips, notes = left(coalesce(p_notes, ''), 500)
   where id = s.id;

  return jsonb_build_object('ok', true, 'report', public.pos_shift_report(s.id));
end;
$$;

create or replace function public.shift_report_secure(p_token text, p_shift_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
  s public.pos_shifts%rowtype;
begin
  select * into c from public.pos_ctx(p_token, null);
  select x.* into s from public.pos_shifts x where x.id = p_shift_id;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'shift_not_found');
  end if;
  if not (s.staff_id = c.staff_id and s.status = 'closed') then
    perform public.pos_ctx(p_token, 'treasury');
    if c.role_name <> 'owner' and s.branch_id is distinct from c.branch_id then
      return jsonb_build_object('ok', false, 'reason', 'shift_not_found');
    end if;
  end if;
  return jsonb_build_object('ok', true, 'report', public.pos_shift_report(s.id));
end;
$$;

create or replace function public.shifts_list_secure(p_token text, p_from date, p_to date)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
begin
  select * into c from public.pos_ctx(p_token, 'treasury');
  return jsonb_build_object('ok', true, 'shifts', coalesce((
    select jsonb_agg(jsonb_build_object('id', s.id, 'staff', st.name, 'status', s.status, 'opened_at', s.opened_at,
                                        'closed_at', s.closed_at, 'expected_cash', s.expected_cash,
                                        'counted_cash', s.counted_cash, 'difference', s.difference) order by s.opened_at desc)
      from public.pos_shifts s join public.staff st on st.id = s.staff_id
     where (c.role_name = 'owner' or s.branch_id = c.branch_id)
       and s.opened_at::date between coalesce(p_from, current_date - 7) and coalesce(p_to, current_date)), '[]'::jsonb));
end;
$$;

-- End of day report (Z) and day closing
create or replace function public.pos_day_report(p_branch_id uuid, p_date date)
returns jsonb
language sql
stable
security definer
set search_path = public, extensions
as $$
  select jsonb_build_object(
    'date', p_date,
    'orders_closed', (select count(*) from public.orders o where o.branch_id = p_branch_id and o.status = 'closed'
                        and exists (select 1 from public.payments p where p.order_id = o.id and p.created_at::date = p_date)),
    'sales_total', coalesce((select sum(p.amount) from public.payments p join public.orders o on o.id = p.order_id
                               where o.branch_id = p_branch_id and p.created_at::date = p_date), 0),
    'payments_by_method', coalesce((select jsonb_object_agg(q.m, q.t) from (
        select p.payment_method as m, sum(p.amount) as t from public.payments p join public.orders o on o.id = p.order_id
         where o.branch_id = p_branch_id and p.created_at::date = p_date group by p.payment_method) q), '{}'::jsonb),
    'tips', coalesce((select sum(p.tip_amount) from public.payments p join public.orders o on o.id = p.order_id
                        where o.branch_id = p_branch_id and p.created_at::date = p_date), 0),
    'voided_items', (select count(*) from public.order_logs l join public.orders o on o.id = l.order_id
                      where o.branch_id = p_branch_id and l.action like 'VOID_ITEM%' and l.created_at::date = p_date),
    'discounts', (select count(*) from public.order_logs l join public.orders o on o.id = l.order_id
                   where o.branch_id = p_branch_id and l.action = 'APPLY_DISCOUNT' and l.created_at::date = p_date),
    'refunds', (select count(*) from public.order_logs l join public.orders o on o.id = l.order_id
                 where o.branch_id = p_branch_id and l.action = 'REFUND_ORDER' and l.created_at::date = p_date),
    'shifts', coalesce((select jsonb_agg(jsonb_build_object('staff', st.name, 'status', s.status,
                                                            'difference', s.difference, 'counted_cash', s.counted_cash))
                          from public.pos_shifts s join public.staff st on st.id = s.staff_id
                         where s.branch_id = p_branch_id and s.opened_at::date = p_date), '[]'::jsonb),
    'drops', coalesce((select jsonb_object_agg(q.d, q.t) from (
        select m.destination as d, sum(m.amount) as t from public.pos_cash_moves m
         where m.branch_id = p_branch_id and m.move_type = 'drop' and m.created_at::date = p_date group by m.destination) q), '{}'::jsonb))
$$;

create or replace function public.day_report_secure(p_token text, p_date date)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
begin
  select * into c from public.pos_ctx(p_token, 'treasury');
  return jsonb_build_object('ok', true, 'report', public.pos_day_report(c.branch_id, coalesce(p_date, current_date)),
    'closed', exists (select 1 from public.pos_days d where d.branch_id = c.branch_id and d.business_date = coalesce(p_date, current_date)));
end;
$$;

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

-- Balances of the money boxes (from the journal)
create or replace function public.treasury_balances_secure(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
begin
  select * into c from public.pos_ctx(p_token, 'treasury');
  return jsonb_build_object('ok', true, 'balances', coalesce((
    select jsonb_agg(jsonb_build_object('code', a.code, 'name', a.name_ar,
             'balance', coalesce((select sum(l.debit - l.credit) from public.journal_entry_lines l
                                    join public.journal_entries je on je.id = l.journal_entry_id
                                   where l.account_id = a.id and je.status in ('posted', 'reversed')), 0)) order by a.code)
      from public.accounts a
     where a.company_id = c.company_id and a.code in ('1100', '1101', '1110', '1130', '1140', '3300')), '[]'::jsonb));
end;
$$;

-- Moving money between main safe, bank and owner
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

-- ===================================================================================
-- PART C: phase 5 (staff, permissions, attendance, advances, payroll)
-- ===================================================================================

alter table public.staff add column if not exists monthly_salary numeric(15,2) not null default 0;
alter table public.staff add column if not exists phone text;

create table if not exists public.pos_settings (
  company_id uuid not null,
  key text not null,
  value text not null,
  primary key (company_id, key)
);
alter table public.pos_settings enable row level security;

insert into public.pos_settings (company_id, key, value)
select c.id, v.key, v.value
  from public.companies c
  cross join (values ('working_days_per_month', '26'), ('expense_manager_limit', '1000')) as v(key, value)
on conflict do nothing;

create or replace function public.pos_setting(p_company_id uuid, p_key text, p_default numeric)
returns numeric
language sql
stable
security definer
set search_path = public, extensions
as $$
  select coalesce((select public.pos_amount(s.value) from public.pos_settings s
                    where s.company_id = p_company_id and s.key = p_key), p_default)
$$;

create or replace function public.pos_setting_save_secure(p_token text, p_key text, p_value text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
  v numeric := public.pos_amount(p_value);
begin
  select * into c from public.pos_ctx(p_token, 'settings');
  if c.role_name <> 'owner' then
    return jsonb_build_object('ok', false, 'reason', 'not_allowed');
  end if;
  if p_key = 'working_days_per_month' and (v is null or v < 1 or v > 31) then
    return jsonb_build_object('ok', false, 'reason', 'invalid_value');
  elsif p_key = 'expense_manager_limit' and (v is null or v > 100000000) then
    return jsonb_build_object('ok', false, 'reason', 'invalid_value');
  elsif p_key not in ('working_days_per_month', 'expense_manager_limit') then
    return jsonb_build_object('ok', false, 'reason', 'unknown_action');
  end if;
  insert into public.pos_settings (company_id, key, value) values (c.company_id, p_key, v::text)
  on conflict (company_id, key) do update set value = excluded.value;
  insert into public.settings_logs (staff_id, action, details)
  values (c.staff_id, 'setting', jsonb_build_object('key', p_key, 'value', v));
  return jsonb_build_object('ok', true);
end;
$$;

create or replace function public.pos_settings_list_secure(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
begin
  select * into c from public.pos_ctx(p_token, null);
  return jsonb_build_object('ok', true,
    'working_days_per_month', public.pos_setting(c.company_id, 'working_days_per_month', 26),
    'expense_manager_limit', public.pos_setting(c.company_id, 'expense_manager_limit', 1000),
    'role', c.role_name,
    'perms', case when c.role_name = 'owner' then
               to_jsonb(array['pos','kds','shift','inventory','inventory_approve','purchasing','treasury','expenses','staff','payroll','reports','settings','accounting'])
             else coalesce((select jsonb_agg(rp.perm) from public.role_permissions rp where rp.role_name = c.role_name), '[]'::jsonb) end);
end;
$$;

-- Can this session manage this staff member?
create or replace function public.pos_staff_scope_ok(p_ctx_role text, p_ctx_branch uuid, p_ctx_company uuid, p_staff_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, extensions
as $$
  select exists (
    select 1 from public.staff s left join public.roles r on r.id = s.role_id
     where s.id = p_staff_id and s.company_id = p_ctx_company
       and (p_ctx_role = 'owner'
            or (s.branch_id = p_ctx_branch and coalesce(r.name, 'cashier') not in ('owner', 'branch_manager'))))
$$;

create or replace function public.staff_list_secure(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
begin
  select * into c from public.pos_ctx(p_token, 'staff');
  return jsonb_build_object('ok', true, 'staff', coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', s.id, 'name', s.name, 'role', coalesce(r.name, ''), 'branch_id', s.branch_id, 'branch', b.name,
             'is_active', s.is_active, 'monthly_salary', s.monthly_salary, 'phone', s.phone,
             'has_pin', s.pin_hash is not null,
             'balance', coalesce((select sum(l.amount) from public.staff_ledger l where l.staff_id = s.id), 0)) order by s.is_active desc, s.name)
      from public.staff s
      left join public.roles r on r.id = s.role_id
      left join public.branches b on b.id = s.branch_id
     where s.company_id = c.company_id and (c.role_name = 'owner' or s.branch_id = c.branch_id)), '[]'::jsonb),
    'roles', (select jsonb_agg(r.name order by r.name) from public.roles r));
end;
$$;

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

create or replace function public.role_permissions_secure(p_token text, p_role text, p_perms jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
  v_all text[] := array['pos','kds','shift','inventory','inventory_approve','purchasing','treasury','expenses','staff','payroll','reports','settings','accounting'];
begin
  select * into c from public.pos_ctx(p_token, null);
  if p_perms is not null then
    if c.role_name <> 'owner' then
      return jsonb_build_object('ok', false, 'reason', 'not_allowed');
    end if;
    if p_role is null or p_role = 'owner' or not exists (select 1 from public.roles r where r.name = p_role) then
      return jsonb_build_object('ok', false, 'reason', 'invalid_role');
    end if;
    if jsonb_typeof(p_perms) <> 'array' then
      return jsonb_build_object('ok', false, 'reason', 'invalid_value');
    end if;
    if exists (select 1 from jsonb_array_elements_text(p_perms) e(v) where not (e.v = any (v_all))) then
      return jsonb_build_object('ok', false, 'reason', 'invalid_value');
    end if;
    delete from public.role_permissions where role_name = p_role;
    insert into public.role_permissions (role_name, perm)
    select p_role, e.v from jsonb_array_elements_text(p_perms) e(v) on conflict do nothing;
    insert into public.settings_logs (staff_id, action, details)
    values (c.staff_id, 'role_permissions', jsonb_build_object('role', p_role, 'perms', p_perms));
  end if;
  return jsonb_build_object('ok', true, 'all_perms', to_jsonb(v_all),
    'roles', (select jsonb_object_agg(r.name, coalesce((select jsonb_agg(rp.perm) from public.role_permissions rp
                                                         where rp.role_name = r.name), '[]'::jsonb))
                from public.roles r where r.name <> 'owner'));
end;
$$;

-- Attendance: any logged-in device in the branch; the staff member types his own PIN
create table if not exists public.staff_attendance (
  id uuid primary key default gen_random_uuid(),
  company_id uuid,
  branch_id uuid,
  staff_id uuid not null references public.staff(id),
  clock_in timestamptz not null default now(),
  clock_out timestamptz,
  minutes int,
  device_staff_id uuid
);
create index if not exists staff_attendance_staff_idx on public.staff_attendance (staff_id, clock_in);
alter table public.staff_attendance enable row level security;

create or replace function public.attendance_punch_secure(p_token text, p_pin text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
  v_ip text := public.request_client_ip();
  v_fail int;
  v_sid uuid;
  v_sname text;
  v_open uuid;
begin
  select * into c from public.pos_ctx(p_token, null);
  select count(*) into v_fail from public.manager_pin_attempts
   where client_ip = v_ip and not success and attempted_at > now() - interval '10 minutes';
  if v_fail >= 10 then
    return jsonb_build_object('ok', false, 'reason', 'locked');
  end if;
  if p_pin is not null and p_pin ~ '^[0-9]{4}$' then
    select s.id, s.name into v_sid, v_sname
      from public.staff s
     where s.branch_id = c.branch_id and s.is_active is true and s.pin_hash is not null
       and s.pin_hash = extensions.crypt(p_pin, s.pin_hash)
     limit 1;
  end if;
  if v_sid is null then
    insert into public.manager_pin_attempts (client_ip, success) values (v_ip, false);
    return jsonb_build_object('ok', false, 'reason', 'wrong_pin');
  end if;

  select a.id into v_open from public.staff_attendance a
   where a.staff_id = v_sid and a.clock_out is null and a.clock_in > now() - interval '20 hours'
   order by a.clock_in desc limit 1 for update;
  if v_open is null then
    insert into public.staff_attendance (company_id, branch_id, staff_id, device_staff_id)
    values (c.company_id, c.branch_id, v_sid, c.staff_id);
    return jsonb_build_object('ok', true, 'action', 'in', 'name', v_sname, 'at', now());
  end if;
  update public.staff_attendance
     set clock_out = now(), minutes = greatest(0, round(extract(epoch from (now() - clock_in)) / 60))::int
   where id = v_open;
  return jsonb_build_object('ok', true, 'action', 'out', 'name', v_sname, 'at', now());
end;
$$;

create or replace function public.attendance_report_secure(p_token text, p_from date, p_to date)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
  v_from date := coalesce(p_from, date_trunc('month', current_date)::date);
  v_to date := coalesce(p_to, current_date);
begin
  select * into c from public.pos_ctx(p_token, 'staff');
  return jsonb_build_object('ok', true,
    'summary', coalesce((
      select jsonb_agg(jsonb_build_object('staff', s.name, 'days', q.days, 'hours', round(q.minutes / 60.0, 1),
                                          'open_now', q.open_now) order by s.name)
        from (select a.staff_id, count(distinct (a.clock_in at time zone 'Africa/Cairo')::date) as days,
                     coalesce(sum(a.minutes), 0) as minutes, bool_or(a.clock_out is null) as open_now
                from public.staff_attendance a
               where (c.role_name = 'owner' or a.branch_id = c.branch_id)
                 and (a.clock_in at time zone 'Africa/Cairo')::date between v_from and v_to
               group by a.staff_id) q
        join public.staff s on s.id = q.staff_id), '[]'::jsonb),
    'records', coalesce((
      select jsonb_agg(jsonb_build_object('staff', s.name, 'clock_in', a.clock_in, 'clock_out', a.clock_out,
                                          'minutes', a.minutes) order by a.clock_in desc)
        from public.staff_attendance a join public.staff s on s.id = a.staff_id
       where (c.role_name = 'owner' or a.branch_id = c.branch_id)
         and (a.clock_in at time zone 'Africa/Cairo')::date between v_from and v_to), '[]'::jsonb));
end;
$$;

-- Advances (salary loans): paid from the main safe or from the cashier's open shift
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

create or replace function public.staff_ledger_secure(p_token text, p_staff_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
begin
  select * into c from public.pos_ctx(p_token, 'staff');
  if not public.pos_staff_scope_ok(c.role_name, c.branch_id, c.company_id, p_staff_id) then
    return jsonb_build_object('ok', false, 'reason', 'staff_not_found');
  end if;
  return jsonb_build_object('ok', true, 'entries', coalesce((
    select jsonb_agg(jsonb_build_object('at', l.created_at, 'type', l.entry_type, 'amount', l.amount,
                                        'balance_after', l.balance_after, 'notes', l.notes) order by l.created_at desc)
      from public.staff_ledger l where l.staff_id = p_staff_id), '[]'::jsonb));
end;
$$;

-- Payroll
create table if not exists public.payroll_runs (
  id uuid primary key default gen_random_uuid(),
  company_id uuid,
  branch_id uuid,
  period date not null,
  status text not null default 'draft' check (status in ('draft', 'approved', 'paid')),
  working_days numeric not null default 26,
  created_by uuid, approved_by uuid, paid_by uuid,
  created_at timestamptz not null default now(), approved_at timestamptz, paid_at timestamptz,
  unique (branch_id, period)
);
alter table public.payroll_runs enable row level security;

create table if not exists public.payroll_lines (
  id uuid primary key default gen_random_uuid(),
  run_id uuid not null references public.payroll_runs(id) on delete cascade,
  staff_id uuid not null references public.staff(id),
  base_salary numeric(15,2) not null default 0,
  days_worked int not null default 0,
  absent_days numeric(6,2) not null default 0,
  absence_deduction numeric(15,2) not null default 0,
  ledger_deduction numeric(15,2) not null default 0,
  other_deduction numeric(15,2) not null default 0,
  bonus numeric(15,2) not null default 0,
  net numeric(15,2) not null default 0,
  notes text,
  unique (run_id, staff_id)
);
alter table public.payroll_lines enable row level security;

create or replace function public.pos_payroll_line_calc(p_line_id uuid)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  l public.payroll_lines%rowtype;
  v_days numeric;
begin
  select x.* into l from public.payroll_lines x where x.id = p_line_id;
  select r.working_days into v_days from public.payroll_runs r where r.id = l.run_id;
  update public.payroll_lines
     set absence_deduction = least(base_salary, round(base_salary / greatest(v_days, 1) * absent_days, 2)),
         net = greatest(0, base_salary - least(base_salary, round(base_salary / greatest(v_days, 1) * absent_days, 2))
                           - ledger_deduction - other_deduction + bonus)
   where id = p_line_id;
end;
$$;

create or replace function public.pos_payroll_json(p_run_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public, extensions
as $$
  select jsonb_build_object('id', r.id, 'period', r.period, 'status', r.status, 'working_days', r.working_days,
    'total_net', coalesce((select sum(x.net) from public.payroll_lines x where x.run_id = r.id), 0),
    'lines', coalesce((select jsonb_agg(jsonb_build_object(
               'id', l.id, 'staff_id', l.staff_id, 'staff', s.name, 'base_salary', l.base_salary, 'days_worked', l.days_worked,
               'absent_days', l.absent_days, 'absence_deduction', l.absence_deduction, 'ledger_deduction', l.ledger_deduction,
               'other_deduction', l.other_deduction, 'bonus', l.bonus, 'net', l.net, 'notes', l.notes,
               'staff_balance', coalesce((select sum(sl.amount) from public.staff_ledger sl where sl.staff_id = l.staff_id), 0))
               order by s.name)
               from public.payroll_lines l join public.staff s on s.id = l.staff_id where l.run_id = r.id), '[]'::jsonb))
  from public.payroll_runs r where r.id = p_run_id
$$;

create or replace function public.payroll_prepare_secure(p_token text, p_period date)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
  v_period date := date_trunc('month', coalesce(p_period, current_date))::date;
  v_run public.payroll_runs%rowtype;
  v_days numeric;
  st record;
  v_worked int;
  v_owed numeric;
  v_line uuid;
  v_exists boolean;
begin
  select * into c from public.pos_ctx(p_token, 'payroll');
  select r.* into v_run from public.payroll_runs r where r.branch_id = c.branch_id and r.period = v_period for update;
  v_exists := found;
  if v_exists and v_run.status <> 'draft' then
    return jsonb_build_object('ok', true, 'run', public.pos_payroll_json(v_run.id));
  end if;
  v_days := public.pos_setting(c.company_id, 'working_days_per_month', 26);
  if not v_exists then
    insert into public.payroll_runs (company_id, branch_id, period, working_days, created_by)
    values (c.company_id, c.branch_id, v_period, v_days, c.staff_id) returning * into v_run;
  else
    update public.payroll_runs set working_days = v_days where id = v_run.id;
    delete from public.payroll_lines where run_id = v_run.id;
  end if;

  for st in
    select s.id, s.monthly_salary from public.staff s
     where s.branch_id = c.branch_id and s.is_active is true and s.monthly_salary > 0
  loop
    select count(distinct (a.clock_in at time zone 'Africa/Cairo')::date) into v_worked
      from public.staff_attendance a
     where a.staff_id = st.id
       and (a.clock_in at time zone 'Africa/Cairo')::date >= v_period
       and (a.clock_in at time zone 'Africa/Cairo')::date < (v_period + interval '1 month')::date;
    select greatest(0, coalesce(sum(l.amount), 0)) into v_owed from public.staff_ledger l where l.staff_id = st.id;
    insert into public.payroll_lines (run_id, staff_id, base_salary, days_worked, absent_days, ledger_deduction)
    values (v_run.id, st.id, st.monthly_salary, v_worked, greatest(0, v_days - v_worked), least(v_owed, st.monthly_salary))
    returning id into v_line;
    perform public.pos_payroll_line_calc(v_line);
  end loop;

  return jsonb_build_object('ok', true, 'run', public.pos_payroll_json(v_run.id));
end;
$$;

create or replace function public.payroll_get_secure(p_token text, p_period date)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
  v_id uuid;
begin
  select * into c from public.pos_ctx(p_token, 'payroll');
  select r.id into v_id from public.payroll_runs r
   where r.branch_id = c.branch_id and r.period = date_trunc('month', coalesce(p_period, current_date))::date;
  if v_id is null then
    return jsonb_build_object('ok', true, 'run', null);
  end if;
  return jsonb_build_object('ok', true, 'run', public.pos_payroll_json(v_id));
end;
$$;

create or replace function public.payroll_line_update_secure(
  p_token text, p_line_id uuid, p_absent_days numeric, p_ledger_deduction numeric,
  p_other_deduction numeric, p_bonus numeric, p_notes text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
  l public.payroll_lines%rowtype;
  r public.payroll_runs%rowtype;
  v_owed numeric;
begin
  select * into c from public.pos_ctx(p_token, 'payroll');
  select x.* into l from public.payroll_lines x where x.id = p_line_id for update;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'not_found');
  end if;
  select x.* into r from public.payroll_runs x where x.id = l.run_id;
  if r.branch_id is distinct from c.branch_id or r.status <> 'draft' then
    return jsonb_build_object('ok', false, 'reason', 'payroll_not_draft');
  end if;
  select greatest(0, coalesce(sum(x.amount), 0)) into v_owed from public.staff_ledger x where x.staff_id = l.staff_id;
  if coalesce(p_absent_days, 0) < 0 or coalesce(p_absent_days, 0) > 31
     or coalesce(p_ledger_deduction, 0) < 0 or coalesce(p_ledger_deduction, 0) > v_owed
     or coalesce(p_other_deduction, 0) < 0 or coalesce(p_bonus, 0) < 0 or coalesce(p_bonus, 0) > 10000000 then
    return jsonb_build_object('ok', false, 'reason', 'invalid_value', 'max_ledger_deduction', v_owed);
  end if;
  update public.payroll_lines
     set absent_days = round(coalesce(p_absent_days, 0), 2), ledger_deduction = round(coalesce(p_ledger_deduction, 0), 2),
         other_deduction = round(coalesce(p_other_deduction, 0), 2), bonus = round(coalesce(p_bonus, 0), 2),
         notes = left(coalesce(p_notes, ''), 300)
   where id = l.id;
  perform public.pos_payroll_line_calc(l.id);
  return jsonb_build_object('ok', true, 'run', public.pos_payroll_json(r.id));
end;
$$;

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

-- Staff performance (sales, voids, discounts, shift differences)
create or replace function public.staff_performance_secure(p_token text, p_from date, p_to date)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
  v_from date := coalesce(p_from, date_trunc('month', current_date)::date);
  v_to date := coalesce(p_to, current_date);
begin
  select * into c from public.pos_ctx(p_token, 'staff');
  return jsonb_build_object('ok', true, 'rows', coalesce((
    select jsonb_agg(jsonb_build_object(
      'staff', s.name,
      'sales', coalesce((select sum(p.amount) from public.payments p join public.pos_shifts sh on sh.id = p.shift_id
                          where sh.staff_id = s.id and p.created_at::date between v_from and v_to), 0),
      'waiter_sales', coalesce((select sum(o.total_amount) from public.orders o
                                 where o.waiter_id = s.id and o.status = 'closed' and o.created_at::date between v_from and v_to), 0),
      'voids', (select count(*) from public.order_logs l where l.user_id = s.id and l.action like 'VOID_ITEM%'
                  and l.created_at::date between v_from and v_to),
      'discounts', (select count(*) from public.order_logs l where l.user_id = s.id and l.action = 'APPLY_DISCOUNT'
                      and l.created_at::date between v_from and v_to),
      'refunds', (select count(*) from public.order_logs l where l.user_id = s.id and l.action = 'REFUND_ORDER'
                    and l.created_at::date between v_from and v_to),
      'shift_difference', coalesce((select sum(sh.difference) from public.pos_shifts sh
                                     where sh.staff_id = s.id and sh.status = 'closed' and sh.opened_at::date between v_from and v_to), 0),
      'tips', coalesce((select sum(p.tip_amount) from public.payments p
                         where p.tip_staff_id = s.id and p.created_at::date between v_from and v_to), 0)) order by s.name)
      from public.staff s
     where s.company_id = c.company_id and (c.role_name = 'owner' or s.branch_id = c.branch_id)), '[]'::jsonb));
end;
$$;

-- ===================================================================================
-- PART D: phase 6 (expenses, custody, recurring expenses)
-- Rule: up to the manager limit (setting, default 1000) the manager's own session is enough;
-- above it the owner's PIN is needed. Roles without the 'expenses' permission cannot spend.
-- ===================================================================================

create table if not exists public.expense_categories (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null,
  name text not null,
  account_id uuid not null references public.accounts(id),
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);
alter table public.expense_categories enable row level security;

insert into public.expense_categories (company_id, name, account_id)
select a.company_id, a.name_ar, a.id
  from public.accounts a
 where a.account_type = 'expense' and a.company_id is not null and a.code <> '6000'
   and not exists (select 1 from public.expense_categories e where e.account_id = a.id);

alter table public.expenses add column if not exists category_id uuid references public.expense_categories(id);
alter table public.expenses add column if not exists shift_id uuid references public.pos_shifts(id);
alter table public.expenses add column if not exists source text;
alter table public.expenses add column if not exists approved_by uuid;
alter table public.expenses add column if not exists recurring_id uuid;
alter table public.expenses add column if not exists recurring_period date;
alter table public.expenses add column if not exists custody_staff_id uuid;

create table if not exists public.custody_ledger (
  id uuid primary key default gen_random_uuid(),
  company_id uuid,
  staff_id uuid not null references public.staff(id),
  entry_type text not null check (entry_type in ('give', 'settle_expense', 'return')),
  amount numeric(15,2) not null,
  balance_after numeric(15,2) not null default 0,
  notes text,
  created_by uuid,
  created_at timestamptz not null default now()
);
alter table public.custody_ledger enable row level security;

create table if not exists public.expense_recurring (
  id uuid primary key default gen_random_uuid(),
  company_id uuid,
  branch_id uuid,
  category_id uuid not null references public.expense_categories(id),
  amount numeric(15,2) not null,
  day_of_month int not null default 1 check (day_of_month between 1 and 28),
  description text not null,
  is_active boolean not null default true,
  last_period date,
  created_by uuid,
  created_at timestamptz not null default now()
);
alter table public.expense_recurring enable row level security;

-- Spending limit check. Returns null when allowed, else a refusal object.
create or replace function public.pos_spend_check(p_role text, p_company_id uuid, p_amount numeric, p_owner_pin text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_limit numeric := public.pos_setting(p_company_id, 'expense_manager_limit', 1000);
begin
  if p_role = 'owner' or p_amount <= v_limit then
    return null;
  end if;
  if public.pos_verify_owner_pin(p_owner_pin, p_company_id) is null then
    return jsonb_build_object('ok', false, 'reason', 'owner_pin_required', 'limit', v_limit);
  end if;
  return null;
end;
$$;

-- Where the money comes from: drawer (own open shift), main_cash or bank. Returns the shift id for the drawer.
create or replace function public.pos_source_check(p_staff_id uuid, p_source text, p_amount numeric)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_shift uuid;
begin
  if coalesce(p_source, '') not in ('drawer', 'main_cash', 'bank') then
    return jsonb_build_object('ok', false, 'reason', 'invalid_destination');
  end if;
  if p_source = 'drawer' then
    select s.id into v_shift from public.pos_shifts s where s.staff_id = p_staff_id and s.status = 'open';
    if v_shift is null then
      return jsonb_build_object('ok', false, 'reason', 'no_open_shift');
    end if;
    if p_amount > public.pos_shift_expected(v_shift) then
      return jsonb_build_object('ok', false, 'reason', 'not_enough_cash');
    end if;
  end if;
  return jsonb_build_object('ok', true, 'shift_id', v_shift);
end;
$$;

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
    if c.role_name not in ('owner', 'branch_manager') then
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

-- Custody: give money to a staff member, later he settles with receipts and returns the rest
create or replace function public.pos_custody_add(
  p_company_id uuid, p_staff_id uuid, p_type text, p_amount numeric, p_notes text, p_by uuid)
returns numeric
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_bal numeric;
begin
  perform 1 from public.staff s where s.id = p_staff_id for update;
  select coalesce(sum(l.amount), 0) + p_amount into v_bal from public.custody_ledger l where l.staff_id = p_staff_id;
  insert into public.custody_ledger (company_id, staff_id, entry_type, amount, balance_after, notes, created_by)
  values (p_company_id, p_staff_id, p_type, p_amount, v_bal, p_notes, p_by);
  return v_bal;
end;
$$;

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

create or replace function public.custody_list_secure(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
begin
  select * into c from public.pos_ctx(p_token, 'expenses');
  return jsonb_build_object('ok', true, 'balances', coalesce((
    select jsonb_agg(jsonb_build_object('staff_id', s.id, 'staff', s.name, 'balance', q.bal) order by s.name)
      from (select l.staff_id, sum(l.amount) as bal from public.custody_ledger l
             where l.company_id = c.company_id group by l.staff_id having sum(l.amount) <> 0) q
      join public.staff s on s.id = q.staff_id), '[]'::jsonb),
    'entries', coalesce((
    select jsonb_agg(jsonb_build_object('at', l.created_at, 'staff', s.name, 'type', l.entry_type, 'amount', l.amount,
                                        'balance_after', l.balance_after, 'notes', l.notes) order by l.created_at desc)
      from public.custody_ledger l join public.staff s on s.id = l.staff_id
     where l.company_id = c.company_id and l.created_at > now() - interval '90 days'), '[]'::jsonb));
end;
$$;

-- Recurring expenses: templates; each month they show as due until the manager pays them
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
    if c.role_name not in ('owner', 'branch_manager') then
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

create or replace function public.expenses_report_secure(p_token text, p_from date, p_to date)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
  v_from date := coalesce(p_from, date_trunc('month', current_date)::date);
  v_to date := coalesce(p_to, current_date);
begin
  select * into c from public.pos_ctx(p_token, 'expenses');
  return jsonb_build_object('ok', true,
    'by_category', coalesce((
      select jsonb_agg(jsonb_build_object('category', q.name, 'branch', q.branch, 'total', q.total) order by q.total desc)
        from (select coalesce(ec.name, a.name_ar) as name, b.name as branch, sum(x.amount) as total
                from public.expenses x
                left join public.expense_categories ec on ec.id = x.category_id
                left join public.accounts a on a.id = x.expense_account_id
                left join public.branches b on b.id = x.branch_id
               where x.company_id = c.company_id and (c.role_name = 'owner' or x.branch_id = c.branch_id)
                 and x.created_at::date between v_from and v_to
               group by 1, 2) q), '[]'::jsonb),
    'items', coalesce((
      select jsonb_agg(jsonb_build_object('at', x.created_at, 'category', coalesce(ec.name, a.name_ar), 'amount', x.amount,
                                          'source', x.source, 'description', x.description, 'by', st.name,
                                          'vendor', x.vendor_name, 'reference', x.reference_number) order by x.created_at desc)
        from public.expenses x
        left join public.expense_categories ec on ec.id = x.category_id
        left join public.accounts a on a.id = x.expense_account_id
        left join public.staff st on st.id = x.created_by
       where x.company_id = c.company_id and (c.role_name = 'owner' or x.branch_id = c.branch_id)
         and x.created_at::date between v_from and v_to), '[]'::jsonb));
end;
$$;

-- Trial balance for the accounting screen (the old function read journal lines the public key cannot see)
create or replace function public.trial_balance_secure(p_token text, p_from date, p_to date)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
begin
  select * into c from public.pos_ctx(p_token, 'accounting');
  return jsonb_build_object('ok', true, 'rows', coalesce((
    select jsonb_agg(to_jsonb(t) order by t.account_code)
      from public.get_trial_balance(c.company_id, coalesce(p_from, date_trunc('year', current_date)::date),
                                    coalesce(p_to, current_date)) t), '[]'::jsonb));
end;
$$;

-- ===================================================================================
-- PART E: phase 7 (purchasing and suppliers) + locks + self-test
-- Receiving:  Dr 1200 inventory / Cr 2150 goods received not invoiced
-- Invoice:    Dr 2150 (received value) + Dr 1150 input VAT +/- 1200 price difference / Cr 2100 suppliers
-- Payment:    Dr 2100 / Cr box
-- ===================================================================================

alter table public.suppliers add column if not exists company_id uuid;
update public.suppliers set company_id = (select c.id from public.companies c order by c.created_at limit 1) where company_id is null;

alter table public.purchase_orders alter column status set default 'draft';
alter table public.purchase_orders add column if not exists company_id uuid;
alter table public.purchase_orders add column if not exists branch_id uuid;
alter table public.purchase_orders add column if not exists created_by uuid;
alter table public.purchase_orders add column if not exists received_value numeric(15,2) not null default 0;
alter table public.purchase_orders add column if not exists invoiced_value numeric(15,2) not null default 0;
alter table public.purchase_order_items alter column quantity type numeric(15,4);
alter table public.purchase_order_items add column if not exists qty_received numeric(15,4) not null default 0;
alter table public.goods_receipt_items alter column total_cost type numeric(15,2);

create table if not exists public.supplier_ledger (
  id uuid primary key default gen_random_uuid(),
  company_id uuid,
  supplier_id uuid not null references public.suppliers(id),
  entry_type text not null check (entry_type in ('invoice', 'payment', 'adjustment')),
  amount numeric(15,2) not null,
  balance_after numeric(15,2) not null default 0,
  reference text,
  created_by uuid,
  created_at timestamptz not null default now()
);
alter table public.supplier_ledger enable row level security;

create table if not exists public.supplier_invoices (
  id uuid primary key default gen_random_uuid(),
  company_id uuid,
  supplier_id uuid not null references public.suppliers(id),
  purchase_order_id uuid references public.purchase_orders(id),
  invoice_number text not null,
  invoice_date date not null default current_date,
  amount numeric(15,2) not null,
  tax_amount numeric(15,2) not null default 0,
  received_value numeric(15,2) not null default 0,
  difference numeric(15,2) not null default 0,
  matched boolean not null default true,
  created_by uuid,
  created_at timestamptz not null default now()
);
alter table public.supplier_invoices enable row level security;

create or replace function public.pos_supplier_add(
  p_company_id uuid, p_supplier_id uuid, p_type text, p_amount numeric, p_ref text, p_by uuid)
returns numeric
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_bal numeric;
begin
  perform 1 from public.suppliers s where s.id = p_supplier_id for update;
  select coalesce(sum(l.amount), 0) + p_amount into v_bal from public.supplier_ledger l where l.supplier_id = p_supplier_id;
  insert into public.supplier_ledger (company_id, supplier_id, entry_type, amount, balance_after, reference, created_by)
  values (p_company_id, p_supplier_id, p_type, p_amount, v_bal, p_ref, p_by);
  update public.suppliers set current_balance = v_bal where id = p_supplier_id;
  return v_bal;
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

create or replace function public.po_action_secure(p_token text, p_po_id uuid, p_action text, p_manager_pin text)
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

create or replace function public.po_receive_secure(p_token text, p_po_id uuid, p_lines jsonb, p_notes text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
  po public.purchase_orders%rowtype;
  v_item public.purchase_order_items%rowtype;
  l jsonb;
  v_qty numeric;
  v_cost numeric;
  v_grn uuid;
  v_grn_num text;
  v_value numeric := 0;
  v_line_value numeric;
  v_stock numeric;
  v_old_cost numeric;
  v_new_cost numeric;
  v_wh_branch uuid;
  v_remaining numeric;
begin
  select * into c from public.pos_ctx(p_token, 'purchasing');
  select x.* into po from public.purchase_orders x where x.id = p_po_id and x.company_id = c.company_id for update;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'po_not_found');
  end if;
  if po.status not in ('approved', 'partially_received') then
    return jsonb_build_object('ok', false, 'reason', 'wrong_po_status');
  end if;
  if not public.pos_warehouse_ok(po.warehouse_id, c.branch_id, c.role_name) then
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

  select w.branch_id into v_wh_branch from public.warehouses w where w.id = po.warehouse_id;
  v_grn_num := 'GRN-' || to_char(now(), 'YYYYMMDD') || '-' || lpad(((select count(*) from public.goods_receipts) + 1)::text, 4, '0');
  insert into public.goods_receipts (purchase_order_id, warehouse_id, grn_number, received_by, notes)
  values (po.id, po.warehouse_id, v_grn_num, c.staff_id, left(coalesce(p_notes, ''), 500))
  returning id into v_grn;

  for l in select e.value from jsonb_array_elements(p_lines) e(value) loop
    select x.* into v_item from public.purchase_order_items x where x.id = (l->>'po_item_id')::uuid for update;
    v_qty := (l->>'qty')::numeric;
    continue when v_qty <= 0;
    v_cost := coalesce(public.pos_amount(l->>'unit_cost'), v_item.unit_price);
    v_line_value := round(v_qty * v_cost, 2);

    -- weighted average cost across all warehouses
    select coalesce(sum(ws.quantity), 0) into v_stock from public.warehouse_stock ws where ws.ingredient_id = v_item.ingredient_id;
    select coalesce(i.cost_per_unit, 0) into v_old_cost from public.ingredients i where i.id = v_item.ingredient_id;
    if greatest(v_stock, 0) + v_qty > 0 then
      v_new_cost := round((greatest(v_stock, 0) * v_old_cost + v_qty * v_cost) / (greatest(v_stock, 0) + v_qty), 4);
    else
      v_new_cost := v_cost;
    end if;
    if v_new_cost <> v_old_cost then
      update public.ingredients set cost_per_unit = v_new_cost where id = v_item.ingredient_id;
      insert into public.ingredient_cost_history (ingredient_id, old_cost, new_cost, change_reason, reference_id)
      values (v_item.ingredient_id, v_old_cost, v_new_cost, 'purchase', v_grn);
    end if;

    perform public.pos_stock_move(c.company_id, v_wh_branch, po.warehouse_id, v_item.ingredient_id, 'purchase', v_qty, v_cost,
                                  'purchase_order', po.id, 'استلام ' || v_grn_num || ' - ' || coalesce(po.po_number, ''), c.staff_id);
    insert into public.goods_receipt_items (goods_receipt_id, ingredient_id, ordered_qty, received_qty, unit_cost, total_cost)
    values (v_grn, v_item.ingredient_id, v_item.quantity, v_qty, v_cost, v_line_value);
    insert into public.supplier_prices (supplier_id, ingredient_id, unit_price)
    values (po.supplier_id, v_item.ingredient_id, v_cost)
    on conflict (supplier_id, ingredient_id) do update set unit_price = excluded.unit_price;
    update public.purchase_order_items set qty_received = qty_received + v_qty where id = v_item.id;
    v_value := v_value + v_line_value;
  end loop;

  select coalesce(sum(x.quantity - x.qty_received), 0) into v_remaining
    from public.purchase_order_items x where x.purchase_order_id = po.id;
  update public.purchase_orders
     set received_value = received_value + v_value,
         status = case when v_remaining <= 0 then 'fully_received' else 'partially_received' end
   where id = po.id;

  perform public.pos_post_je(c.company_id, coalesce(v_wh_branch, c.branch_id), 'purchase', 'goods_receipt', v_grn,
    'استلام بضاعة ' || v_grn_num || ' - ' || coalesce(po.po_number, ''),
    jsonb_build_array(public.pos_je_line('1200', v_value, 0, 'بضاعة مستلمة'),
                      public.pos_je_line('2150', 0, v_value, 'بضاعة لم تصل فاتورتها')), c.staff_id);

  return jsonb_build_object('ok', true, 'grn_number', v_grn_num, 'value', v_value);
end;
$$;

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
  if c.role_name not in ('owner', 'branch_manager')
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

create or replace function public.supplier_statement_secure(p_token text, p_supplier_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
begin
  select * into c from public.pos_ctx(p_token, 'purchasing');
  return jsonb_build_object('ok', true, 'entries', coalesce((
    select jsonb_agg(jsonb_build_object('at', l.created_at, 'type', l.entry_type, 'amount', l.amount,
                                        'balance_after', l.balance_after, 'reference', l.reference) order by l.created_at)
      from public.supplier_ledger l
     where l.supplier_id = p_supplier_id and l.company_id = c.company_id), '[]'::jsonb));
end;
$$;

create or replace function public.po_list_secure(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
begin
  select * into c from public.pos_ctx(p_token, 'purchasing');
  return jsonb_build_object('ok', true, 'orders', coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', po.id, 'po_number', po.po_number, 'status', po.status, 'created_at', po.created_at,
             'supplier_id', po.supplier_id, 'supplier', s.name, 'warehouse', w.name, 'total', po.total_amount,
             'received_value', po.received_value, 'invoiced_value', po.invoiced_value, 'notes', po.notes,
             'lines', (select jsonb_agg(jsonb_build_object('id', x.id, 'ingredient', i.name, 'unit', i.unit,
                                                           'quantity', x.quantity, 'qty_received', x.qty_received,
                                                           'unit_price', x.unit_price))
                         from public.purchase_order_items x join public.ingredients i on i.id = x.ingredient_id
                        where x.purchase_order_id = po.id)) order by po.created_at desc)
      from public.purchase_orders po
      join public.suppliers s on s.id = po.supplier_id
      left join public.warehouses w on w.id = po.warehouse_id
     where po.company_id = c.company_id and po.created_at > now() - interval '180 days'), '[]'::jsonb));
end;
$$;

create or replace function public.price_history_secure(p_token text, p_ingredient_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
begin
  select * into c from public.pos_ctx(p_token, 'purchasing');
  return jsonb_build_object('ok', true, 'history', coalesce((
    select jsonb_agg(jsonb_build_object('at', g.received_at, 'supplier', s.name, 'unit_cost', gi.unit_cost,
                                        'qty', gi.received_qty, 'grn', g.grn_number) order by g.received_at desc)
      from public.goods_receipt_items gi
      join public.goods_receipts g on g.id = gi.goods_receipt_id
      join public.purchase_orders po on po.id = g.purchase_order_id
      join public.suppliers s on s.id = po.supplier_id
     where gi.ingredient_id = p_ingredient_id and po.company_id = c.company_id), '[]'::jsonb),
    'current', coalesce((
    select jsonb_agg(jsonb_build_object('supplier', s.name, 'unit_price', sp.unit_price) order by sp.unit_price)
      from public.supplier_prices sp join public.suppliers s on s.id = sp.supplier_id
     where sp.ingredient_id = p_ingredient_id and s.company_id = c.company_id), '[]'::jsonb));
end;
$$;

-- Waste report for the cost-control screen (waste_logs is locked below)
create or replace function public.waste_report_secure(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
begin
  select * into c from public.pos_ctx(p_token, 'reports');
  return jsonb_build_object('ok', true, 'rows', coalesce((
    select jsonb_agg(jsonb_build_object('created_at', w.created_at, 'ingredient', i.name, 'unit', i.unit,
                                        'quantity', w.quantity, 'reason', w.reason, 'cost_loss', w.cost_loss) order by w.created_at desc)
      from public.waste_logs w left join public.ingredients i on i.id = w.ingredient_id
     where w.created_at > now() - interval '90 days'), '[]'::jsonb));
end;
$$;

-- ===================================================================================
-- Locks and permissions
-- ===================================================================================
do $locks$
declare
  t text;
  f record;
begin
  foreach t in array array['warehouse_stock', 'stock_movements', 'waste_logs', 'stock_takes', 'stock_transfers',
                           'purchase_orders', 'purchase_order_items', 'goods_receipts', 'goods_receipt_items',
                           'supplier_payments', 'suppliers', 'expenses', 'ingredient_cost_history',
                           'stock_adjustments', 'fiscal_periods', 'accounting_audit_logs', 'payment_method_account_mappings'] loop
    if to_regclass('public.' || t) is not null then
      execute format('alter table public.%I enable row level security', t);
    end if;
  end loop;
  foreach t in array array['ingredients', 'recipes'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists pos_read_only on public.%I', t);
    execute format('create policy pos_read_only on public.%I for select to anon, authenticated using (true)', t);
  end loop;

  -- accounts: read only (the old policy also allowed writing); journal entries: no direct access at all
  drop policy if exists company_accounts_isolation on public.accounts;
  drop policy if exists pos_read_only on public.accounts;
  create policy pos_read_only on public.accounts for select to anon, authenticated using (true);
  drop policy if exists company_journals_isolation on public.journal_entries;

  -- old functions the screens no longer use
  for f in
    select p.oid::regprocedure as sig
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in ('log_waste', 'record_stock_take', 'process_purchase_item', 'record_stock_movement', 'record_expense',
                         'get_trial_balance', 'create_journal_entry', 'generate_journal_entry_number',
                         'get_account_for_payment_method', 'get_balance_sheet', 'get_general_ledger',
                         'get_profit_and_loss_from_gl', 'get_low_stock_alerts', 'convert_quantity')
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
  end loop;

  -- internal helpers: never callable with the public key
  for f in
    select p.oid::regprocedure as sig
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname like 'pos\_%'
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
  end loop;

  -- screen functions: callable, each one checks the shift ticket inside
  for f in
    select p.oid::regprocedure as sig
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname like '%\_secure'
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to anon, authenticated, service_role', f.sig);
  end loop;
end;
$locks$;

-- ===================================================================================
-- Self-test: a full day is run with the real functions, checked, then undone.
-- Steps that need a manager or owner PIN are done by setting the status directly (the PINs are not known here).
-- ===================================================================================
do $selftest$
declare
  v_cashier uuid;
  v_manager uuid;
  v_branch uuid;
  v_tok_c text := 'mp-test-c-' || md5(random()::text || clock_timestamp()::text);
  v_tok_m text := 'mp-test-m-' || md5(random()::text || clock_timestamp()::text);
  v_start timestamptz := now();
  v_res jsonb;
  v_product uuid;
  v_order uuid;
  v_total numeric;
  v_shift uuid;
  v_expected numeric;
  v_cat uuid;
  v_ing uuid;
  v_wh uuid;
  v_wh2 uuid;
  v_sup uuid;
  v_po uuid;
  v_item uuid;
  v_tr uuid;
  v_qty_before numeric;
  v_qty_after numeric;
  v_run uuid;
begin
  begin
    select s.id, s.branch_id into v_cashier, v_branch from public.staff s join public.roles r on r.id = s.role_id
     where s.is_active is true and r.name = 'cashier' and s.branch_id is not null limit 1;
    select s.id into v_manager from public.staff s join public.roles r on r.id = s.role_id
     where s.is_active is true and r.name = 'branch_manager' and s.branch_id = v_branch limit 1;
    if v_cashier is null or v_manager is null then
      raise notice 'selftest skipped: needs an active cashier and branch manager in the same branch';
      raise exception using errcode = 'P0099', message = 'selftest_skip';
    end if;
    insert into public.staff_sessions (token_hash, staff_id, expires_at) values
      (encode(extensions.digest(v_tok_c, 'sha256'), 'hex'), v_cashier, now() + interval '10 minutes'),
      (encode(extensions.digest(v_tok_m, 'sha256'), 'hex'), v_manager, now() + interval '10 minutes');

    -- 1) a sale without an open shift is refused
    select p.id into v_product from public.products p join public.branches b on b.brand_id = p.brand_id
     where b.id = v_branch and p.is_available is true and p.price > 1
       and not exists (select 1 from public.product_modifier_groups g join public.modifier_groups mg on mg.id = g.group_id
                        where g.product_id = p.id and (coalesce(mg.min_selection, 0) > 0 or coalesce(mg.is_required, false)))
     order by p.id limit 1;
    if v_product is null then
      raise notice 'selftest skipped: no product';
      raise exception using errcode = 'P0099', message = 'selftest_skip';
    end if;
    v_res := public.submit_order_items_secure(v_tok_c, null::uuid, 'takeaway', null::uuid, null::uuid, null::uuid, null::uuid, 1,
               jsonb_build_array(jsonb_build_object('product_id', v_product, 'quantity', 1, 'modifier_ids', '[]'::jsonb)));
    if not coalesce((v_res->>'ok')::boolean, false) then raise exception 'SELFTEST submit failed: %', v_res; end if;
    v_order := (v_res->>'order_id')::uuid;
    select o.total_amount into v_total from public.orders o where o.id = v_order;
    v_res := public.close_order_secure(v_tok_c, v_order,
               jsonb_build_array(jsonb_build_object('method', 'cash', 'amount', v_total)), 0, null::uuid);
    if coalesce(v_res->>'reason', '') <> 'no_open_shift' then
      raise exception 'SELFTEST sale without shift not refused: %', v_res;
    end if;

    -- 2) shift: open with 100, sell with a 10 tip, blind close 5 short
    v_res := public.shift_open_secure(v_tok_c, 100);
    if not coalesce((v_res->>'ok')::boolean, false) then raise exception 'SELFTEST shift open failed: %', v_res; end if;
    v_shift := (v_res->>'shift_id')::uuid;
    v_res := public.close_order_secure(v_tok_c, v_order,
               jsonb_build_array(jsonb_build_object('method', 'cash', 'amount', v_total)), 10, v_cashier);
    if not coalesce((v_res->>'ok')::boolean, false) then raise exception 'SELFTEST sale in shift failed: %', v_res; end if;
    v_res := public.shift_current_secure(v_tok_c);
    if v_res ? 'expected_cash' then raise exception 'SELFTEST the cashier can see the expected cash'; end if;
    v_expected := public.pos_shift_expected(v_shift);
    if v_expected <> 100 + v_total + 10 then raise exception 'SELFTEST expected cash wrong: %', v_expected; end if;
    -- after the 10 tip is paid out the drawer should hold 100 + total; he counts 5 less
    v_res := public.shift_close_secure(v_tok_c, 100 + v_total - 5, 'selftest');
    if not coalesce((v_res->>'ok')::boolean, false) then raise exception 'SELFTEST shift close failed: %', v_res; end if;
    if (v_res->'report'->>'difference')::numeric <> -5 then raise exception 'SELFTEST shift difference wrong: %', v_res; end if;
    if (select coalesce(sum(l.amount), 0) from public.staff_ledger l where l.staff_id = v_cashier and l.created_at >= v_start) <> 5 then
      raise exception 'SELFTEST shortage was not put on the cashier';
    end if;

    -- 3) the cashier cannot spend
    begin
      perform public.expense_record_secure(v_tok_c, null::uuid, 10, 'main_cash', 'x', null, null, null::uuid, null);
      raise exception 'SELFTEST the cashier was allowed to spend';
    exception when sqlstate '42501' then
      null;
    end;

    -- 4) manager: expense under the limit, custody give 100 and settle 60 + 40 back
    select e.id into v_cat from public.expense_categories e where e.is_active is true order by e.name limit 1;
    v_res := public.expense_record_secure(v_tok_m, v_cat, 50, 'main_cash', 'selftest expense', 'R1', 'v', null::uuid, null);
    if not coalesce((v_res->>'ok')::boolean, false) then raise exception 'SELFTEST expense failed: %', v_res; end if;
    v_res := public.custody_give_secure(v_tok_m, v_cashier, 100, 'main_cash', 'selftest', null);
    if not coalesce((v_res->>'ok')::boolean, false) then raise exception 'SELFTEST custody give failed: %', v_res; end if;
    v_res := public.custody_settle_secure(v_tok_m, v_cashier,
               jsonb_build_array(jsonb_build_object('category_id', v_cat, 'amount', 60, 'description', 'receipt')), 40, 'main_cash');
    if not coalesce((v_res->>'ok')::boolean, false) or (v_res->>'balance')::numeric <> 0 then
      raise exception 'SELFTEST custody settle failed: %', v_res;
    end if;

    -- 5) payroll draft: the cashier's shortage is proposed as a deduction
    update public.staff set monthly_salary = 2600 where id = v_cashier;
    v_res := public.payroll_prepare_secure(v_tok_m, current_date);
    if not coalesce((v_res->>'ok')::boolean, false) then raise exception 'SELFTEST payroll failed: %', v_res; end if;
    if not exists (select 1 from jsonb_array_elements(v_res->'run'->'lines') e(value)
                    where (e.value->>'staff_id')::uuid = v_cashier and (e.value->>'ledger_deduction')::numeric = 5) then
      raise exception 'SELFTEST payroll did not deduct the shortage: %', v_res;
    end if;

    -- 6) purchasing: supplier, order, receive 2 of 3, invoice with a price difference, pay
    select i.id into v_ing from public.ingredients i order by i.name limit 1;
    select w.id into v_wh from public.warehouses w where w.branch_id = v_branch limit 1;
    if v_ing is not null and v_wh is not null then
      v_res := public.suppliers_secure(v_tok_m, jsonb_build_object('name', 'selftest supplier'));
      v_sup := (v_res->>'id')::uuid;
      v_res := public.po_create_secure(v_tok_m, v_sup, v_wh,
                 jsonb_build_array(jsonb_build_object('ingredient_id', v_ing, 'qty', 3, 'unit_price', 10)), 'selftest');
      if not coalesce((v_res->>'ok')::boolean, false) then raise exception 'SELFTEST po create failed: %', v_res; end if;
      v_po := (v_res->>'id')::uuid;
      update public.purchase_orders set status = 'approved' where id = v_po;
      select x.id into v_item from public.purchase_order_items x where x.purchase_order_id = v_po;
      select coalesce(ws.quantity, 0) into v_qty_before from public.warehouse_stock ws where ws.warehouse_id = v_wh and ws.ingredient_id = v_ing;
      v_res := public.po_receive_secure(v_tok_m, v_po, jsonb_build_array(jsonb_build_object('po_item_id', v_item, 'qty', 2)), 'selftest');
      if not coalesce((v_res->>'ok')::boolean, false) then raise exception 'SELFTEST receive failed: %', v_res; end if;
      select coalesce(ws.quantity, 0) into v_qty_after from public.warehouse_stock ws where ws.warehouse_id = v_wh and ws.ingredient_id = v_ing;
      if coalesce(v_qty_after, 0) - coalesce(v_qty_before, 0) <> 2 then raise exception 'SELFTEST stock not increased'; end if;
      if (select po.status from public.purchase_orders po where po.id = v_po) <> 'partially_received' then
        raise exception 'SELFTEST po status not partial';
      end if;
      v_res := public.supplier_invoice_secure(v_tok_m, v_po, 'SELFTEST-INV', current_date, 21, 2.94);
      if not coalesce((v_res->>'ok')::boolean, false) then raise exception 'SELFTEST invoice failed: %', v_res; end if;
      v_res := public.supplier_payment_secure(v_tok_m, v_sup, 23.94, 'main_cash', 'R2', 'selftest', null);
      if not coalesce((v_res->>'ok')::boolean, false) then raise exception 'SELFTEST supplier payment failed: %', v_res; end if;
      if (select coalesce(sum(l.amount), 0) from public.supplier_ledger l where l.supplier_id = v_sup) <> 0 then
        raise exception 'SELFTEST supplier balance not zero';
      end if;

      -- 7) transfer 1 unit to another warehouse and receive it
      select w.id into v_wh2 from public.warehouses w where w.id <> v_wh order by w.is_main desc limit 1;
      if v_wh2 is not null then
        v_res := public.inv_transfer_request_secure(v_tok_m, v_wh, v_wh2,
                   jsonb_build_array(jsonb_build_object('ingredient_id', v_ing, 'qty', 1)), 'selftest');
        if not coalesce((v_res->>'ok')::boolean, false) then raise exception 'SELFTEST transfer request failed: %', v_res; end if;
        v_tr := (v_res->>'id')::uuid;
        update public.inv_transfers set status = 'approved' where id = v_tr;
        v_res := public.inv_transfer_action_secure(v_tok_m, v_tr, 'ship', null, null);
        if not coalesce((v_res->>'ok')::boolean, false) then raise exception 'SELFTEST transfer ship failed: %', v_res; end if;
        v_res := public.inv_transfer_action_secure(v_tok_m, v_tr, 'receive', null, null);
        if not coalesce((v_res->>'ok')::boolean, false) then raise exception 'SELFTEST transfer receive failed: %', v_res; end if;
      end if;
    end if;

    -- 8) every journal entry made in this test is balanced
    if exists (select 1 from public.journal_entries je join public.journal_entry_lines l on l.journal_entry_id = je.id
                where je.created_at >= v_start group by je.id having abs(sum(l.debit) - sum(l.credit)) > 0.001) then
      raise exception 'SELFTEST a journal entry is not balanced';
    end if;
    if (select count(*) from public.journal_entries je where je.created_at >= v_start) < 8 then
      raise exception 'SELFTEST too few journal entries were made';
    end if;

    raise notice 'MOTIONPOS-PH3-7-SELFTEST-OK';
    raise exception using errcode = 'P0099', message = 'selftest_rollback';
  exception when sqlstate 'P0099' then
    null;  -- everything the test did is undone here
  end;
end;
$selftest$;

commit;
