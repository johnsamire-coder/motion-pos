-- 024_tips_pool_payinfo_recipes.sql
-- 1) Tips: one pot per branch (no person picked at payment). Shift shortage covered from the pot first.
--    The manager shares the pot equally (permission "tips_distribute" under the treasury).
-- 2) Shift close statement: cash / card / instapay / wallet / credit + tips by method + shortage covered from tips.
-- 3) InstaPay and wallet numbers in the settings, printed on the bill and shown on the QR menu.
-- 4) Recipes for many products at once (menu screen), the owner can still edit every recipe.
-- Rules: begin/commit, preflight, rolled-back self-test, grants loop. New table attached to the sync.

begin;

do $preflight$
begin
  if length('إكراميات') <> 8 then
    raise exception 'file_encoding_broken: read the file as UTF-8';
  end if;
  if public.motionpos_version_public() not in ('023', '024') then
    raise exception 'schema_preflight_failed: run 023 first';
  end if;
end;
$preflight$;

create or replace function public.pos_all_perms()
returns text[]
language sql
immutable
as $$
  select array['dashboard', 'pos', 'kds', 'shift', 'customers', 'sales', 'feedback', 'purchasing', 'po_create', 'po_approve', 'po_receive', 'po_post', 'po_invoice', 'supplier_pay', 'suppliers_manage', 'inventory', 'inv_waste', 'inv_transfer', 'inv_stocktake', 'inventory_approve', 'treasury', 'treasury_transfer', 'day_close', 'tips_distribute', 'expenses', 'exp_record', 'exp_recurring', 'exp_categories', 'exp_custody', 'staff', 'staff_manage', 'payroll', 'payroll_approve', 'payroll_pay', 'reports', 'accounting', 'acc_manual', 'settings', 'settings_menu']
$$;

do $defaults$
begin
  if not exists (select 1 from public.role_permissions where perm = 'tips_distribute') then
    insert into public.role_permissions (role_name, perm)
    select distinct rp.role_name, 'tips_distribute' from public.role_permissions rp
     where rp.perm = 'treasury' and rp.role_name not in ('owner', 'storekeeper')
    on conflict do nothing;
  end if;
end;
$defaults$;


-- close order (same as 011): the tip person is optional, tips go to the pot
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
    if p_tip_staff_id is not null and not exists (
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


-- ===================================================================================
-- Tips go to one pot (the tips account 2400 of the branch). The cashier no longer picks a person.
-- A shift shortage is first covered from the pot, the rest stays on the cashier as before.
-- The manager shares the pot equally between the staff he ticks (by default: who clocked in today).
-- ===================================================================================
alter table public.pos_shifts add column if not exists tips_total numeric not null default 0;
alter table public.pos_shifts add column if not exists shortage_from_tips numeric not null default 0;

create table if not exists public.tip_payouts (
  id uuid primary key default gen_random_uuid(),
  company_id uuid,
  branch_id uuid,
  batch_id uuid not null,
  staff_id uuid not null references public.staff(id),
  amount numeric not null check (amount > 0),
  source text not null check (source in ('main_cash', 'drawer')),
  shift_id uuid,
  created_by uuid,
  created_at timestamptz not null default now()
);
alter table public.tip_payouts enable row level security;
create index if not exists tip_payouts_branch_idx on public.tip_payouts (branch_id, created_at);
select public.pos_sync_attach_all();

-- what is in the pot now (credit balance of 2400 for the branch)
create or replace function public.pos_tips_pool(p_company_id uuid, p_branch_id uuid)
returns numeric
language sql
stable
security definer
set search_path = public, extensions
as $$
  select coalesce((select b.balance from public.pos_account_balances(p_company_id, date '1900-01-01', date '2999-12-31', p_branch_id) b
                    where b.code = '2400' limit 1), 0)
$$;

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
    'difference', s.difference, 'tips_paid', s.tips_paid, 'tips_total', s.tips_total, 'shortage_from_tips', s.shortage_from_tips,
    'shortage_on_cashier', case when coalesce(s.difference, 0) < 0 then -s.difference - s.shortage_from_tips else 0 end,
    'payments_by_method', coalesce((select jsonb_object_agg(q.payment_method, q.total) from (
        select p.payment_method, sum(p.amount) as total from public.payments p where p.shift_id = s.id group by p.payment_method) q), '{}'::jsonb),
    'tips_by_method', coalesce((select jsonb_object_agg(q.payment_method, q.total) from (
        select p.payment_method, sum(p.tip_amount) as total from public.payments p where p.shift_id = s.id and p.tip_amount > 0
         group by p.payment_method) q), '{}'::jsonb),
    'sales_total', coalesce((select sum(p.amount) from public.payments p where p.shift_id = s.id), 0),
    'orders_paid', (select count(distinct p.order_id) from public.payments p where p.shift_id = s.id and p.amount > 0),
    'tips_pool', public.pos_tips_pool(s.company_id, s.branch_id),
    'cash_moves', coalesce((select jsonb_agg(jsonb_build_object('type', m.move_type, 'amount', m.amount, 'destination', m.destination,
                                                               'reason', m.reason, 'at', m.created_at) order by m.created_at)
                              from public.pos_cash_moves m where m.shift_id = s.id), '[]'::jsonb))
  from public.pos_shifts s join public.staff st on st.id = s.staff_id
  where s.id = p_shift_id
$$;

-- Blind close (same as before) but: tips are NOT paid out here (they stay in the pot), and a shortage is
-- covered first from the pot. The counted cash (tips included) goes to the main safe.
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
  v_pool numeric;
  v_from_tips numeric := 0;
  v_rest numeric;
begin
  select * into c from public.pos_ctx(p_token, 'shift');
  select x.* into s from public.pos_shifts x where x.staff_id = c.staff_id and x.status = 'open' for update;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'no_open_shift');
  end if;
  if v_counted < 0 or v_counted > 100000000 then
    return jsonb_build_object('ok', false, 'reason', 'invalid_amount');
  end if;

  select coalesce(sum(p.tip_amount), 0) into v_tips from public.payments p where p.shift_id = s.id;

  v_expected := public.pos_shift_expected(s.id);
  v_diff := v_counted - v_expected;
  if v_diff < 0 then
    insert into public.pos_cash_moves (shift_id, company_id, branch_id, move_type, amount, reason, staff_id)
    values (s.id, c.company_id, c.branch_id, 'shortage', -v_diff, 'عجز قفل الوردية', c.staff_id);
    -- 1) from the tips pot
    v_pool := greatest(0, public.pos_tips_pool(c.company_id, c.branch_id));
    v_from_tips := least(-v_diff, v_pool);
    if v_from_tips > 0 then
      perform public.pos_post_je(c.company_id, c.branch_id, 'adjustment', 'shift', s.id, 'عجز وردية اتغطّى من الإكراميات',
        jsonb_build_array(public.pos_je_line('2400', v_from_tips, 0, 'من صندوق الإكراميات'),
                          public.pos_je_line('1101', 0, v_from_tips, 'عجز الدرج')), c.staff_id);
    end if;
    -- 2) the rest on the cashier (as before)
    v_rest := -v_diff - v_from_tips;
    if v_rest > 0 then
      perform public.pos_staff_add_ledger(c.company_id, c.staff_id, 'shortage', v_rest, s.id, null, 'عجز وردية', c.staff_id);
      perform public.pos_post_je(c.company_id, c.branch_id, 'adjustment', 'shift', s.id, 'عجز وردية',
        jsonb_build_array(public.pos_je_line('1130', v_rest, 0, 'عجز على الكاشير'),
                          public.pos_je_line('1101', 0, v_rest, 'عجز الدرج')), c.staff_id);
    end if;
  elsif v_diff > 0 then
    insert into public.pos_cash_moves (shift_id, company_id, branch_id, move_type, amount, reason, staff_id)
    values (s.id, c.company_id, c.branch_id, 'overage', v_diff, 'زيادة قفل الوردية', c.staff_id);
    perform public.pos_post_je(c.company_id, c.branch_id, 'adjustment', 'shift', s.id, 'زيادة وردية',
      jsonb_build_array(public.pos_je_line('1101', v_diff, 0, 'زيادة الدرج'),
                        public.pos_je_line('4200', 0, v_diff, 'زيادة نقدية')), c.staff_id);
  end if;

  if v_counted > 0 then
    insert into public.pos_cash_moves (shift_id, company_id, branch_id, move_type, amount, source, destination, reason, staff_id)
    values (s.id, c.company_id, c.branch_id, 'close_handover', v_counted, 'drawer', 'main_cash', 'تسليم نقدية آخر الوردية', c.staff_id);
    perform public.pos_post_je(c.company_id, c.branch_id, 'payment', 'shift', s.id, 'تسليم نقدية آخر الوردية',
      jsonb_build_array(public.pos_je_line('1100', v_counted, 0, 'الخزينة الرئيسية'),
                        public.pos_je_line('1101', 0, v_counted, 'من درج الكاشير')), c.staff_id);
  end if;

  update public.pos_shifts
     set status = 'closed', closed_at = now(), expected_cash = v_expected, counted_cash = v_counted,
         difference = v_diff, tips_paid = 0, tips_total = v_tips, shortage_from_tips = v_from_tips,
         notes = left(coalesce(p_notes, ''), 500)
   where id = s.id;

  return jsonb_build_object('ok', true, 'report', public.pos_shift_report(s.id));
end;
$$;

-- The tips pot: see it, share it equally
create or replace function public.tips_secure(p_token text, p_action text, p_data jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
  d jsonb := coalesce(p_data, '{}'::jsonb);
  v_pool numeric;
  v_amount numeric;
  v_ids uuid[];
  v_n int;
  v_each numeric;
  v_total numeric;
  v_batch uuid := gen_random_uuid();
  v_shift uuid;
  v_src text := coalesce(d->>'source', 'main_cash');
begin
  select * into c from public.pos_ctx(p_token, 'treasury');
  if not public.pos_perm_ok(c.role_name, 'tips_distribute') then
    return jsonb_build_object('ok', false, 'reason', 'not_allowed', 'perm', 'tips_distribute');
  end if;
  v_pool := round(greatest(0, public.pos_tips_pool(c.company_id, c.branch_id)), 2);

  if coalesce(p_action, '') = 'distribute' then
    if jsonb_typeof(d->'staff_ids') is distinct from 'array' then
      return jsonb_build_object('ok', false, 'reason', 'invalid_value');
    end if;
    select coalesce(array_agg(distinct s.id), '{}'::uuid[]) into v_ids
      from jsonb_array_elements_text(d->'staff_ids') x(v) join public.staff s on s.id = public.pos_uuid(x.v)
     where s.branch_id = c.branch_id and s.is_active is true;
    v_n := coalesce(array_length(v_ids, 1), 0);
    if v_n = 0 then
      return jsonb_build_object('ok', false, 'reason', 'invalid_value');
    end if;
    v_amount := coalesce(public.pos_amount(d->>'amount'), v_pool);
    if v_amount <= 0 or v_amount > v_pool then
      return jsonb_build_object('ok', false, 'reason', 'invalid_amount', 'pool', v_pool);
    end if;
    v_each := floor(v_amount * 100 / v_n) / 100;          -- what does not divide stays in the pot
    if v_each <= 0 then
      return jsonb_build_object('ok', false, 'reason', 'invalid_amount', 'pool', v_pool);
    end if;
    v_total := v_each * v_n;
    if v_src not in ('main_cash', 'drawer') then
      return jsonb_build_object('ok', false, 'reason', 'invalid_value');
    end if;
    if v_src = 'drawer' then
      select x.id into v_shift from public.pos_shifts x where x.staff_id = c.staff_id and x.status = 'open';
      if v_shift is null then
        return jsonb_build_object('ok', false, 'reason', 'no_open_shift');
      end if;
      insert into public.pos_cash_moves (shift_id, company_id, branch_id, move_type, amount, source, destination, reason, staff_id)
      values (v_shift, c.company_id, c.branch_id, 'tips_payout', v_total, 'drawer', 'staff', 'توزيع الإكراميات', c.staff_id);
    end if;
    insert into public.tip_payouts (company_id, branch_id, batch_id, staff_id, amount, source, shift_id, created_by)
    select c.company_id, c.branch_id, v_batch, u.id, v_each, v_src, v_shift, c.staff_id from unnest(v_ids) u(id);
    perform public.pos_post_je(c.company_id, c.branch_id, 'payment', 'adjustment', v_batch, 'توزيع الإكراميات على ' || v_n || ' موظف',
      jsonb_build_array(public.pos_je_line('2400', v_total, 0, 'صندوق الإكراميات'),
                        public.pos_je_line(case when v_src = 'drawer' then '1101' else '1100' end, 0, v_total, 'صرف الإكراميات')), c.staff_id);
    v_pool := round(greatest(0, public.pos_tips_pool(c.company_id, c.branch_id)), 2);
  elsif coalesce(p_action, '') <> 'status' then
    return jsonb_build_object('ok', false, 'reason', 'unknown_action');
  end if;

  return jsonb_build_object('ok', true, 'pool', v_pool, 'each', v_each, 'paid', v_total,
    'collected_today', coalesce((select sum(p.tip_amount) from public.payments p join public.pos_shifts sh on sh.id = p.shift_id
                                  where sh.branch_id = c.branch_id and public.pos_local_date(p.created_at) = public.pos_local_date(now())), 0),
    'covered_shortages_today', coalesce((select sum(sh.shortage_from_tips) from public.pos_shifts sh
                                          where sh.branch_id = c.branch_id and public.pos_local_date(sh.closed_at) = public.pos_local_date(now())), 0),
    'staff', coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name,
                         'came_today', exists (select 1 from public.staff_attendance a where a.staff_id = s.id
                                                 and public.pos_local_date(a.clock_in) = public.pos_local_date(now()))) order by s.name)
                         from public.staff s join public.roles r on r.id = s.role_id
                        where s.branch_id = c.branch_id and s.is_active is true and r.name <> 'owner'), '[]'::jsonb),
    'history', coalesce((select jsonb_agg(jsonb_build_object('at', q.at, 'by', q.by, 'total', q.total, 'each', q.each, 'count', q.cnt,
                                                            'names', q.names, 'source', q.source) order by q.at desc)
                           from (select min(t.created_at) as at, (select s.name from public.staff s where s.id = min(t.created_by::text)::uuid) as by,
                                        sum(t.amount) as total, max(t.amount) as each, count(*) as cnt, string_agg(st.name, '، ' order by st.name) as names,
                                        max(t.source) as source
                                   from public.tip_payouts t join public.staff st on st.id = t.staff_id
                                  where t.branch_id = c.branch_id and t.created_at > now() - interval '60 days'
                                  group by t.batch_id order by min(t.created_at) desc limit 30) q), '[]'::jsonb));
end;
$$;


-- settings defaults (same as 021) + payment numbers
create or replace function public.pos_settings_defaults()
returns jsonb
language sql
immutable
as $$
  select jsonb_build_object(
    'general', jsonb_build_object('company_name', 'Motion POS', 'logo', '', 'address', '', 'phone', '', 'tax_number', '',
                                  'commercial_register', '', 'currency', 'ج.م'),
    'receipt', jsonb_build_object('header', '', 'footer', 'شكراً لزيارتكم', 'show_logo', true, 'paper_mm', 80, 'copies', 1,
                                  'auto_print_after_pay', false, 'auto_kitchen_ticket', false, 'show_tax_number', true,
                                  'show_feedback_qr', true),
    'pos', jsonb_build_object('order_types', jsonb_build_array('dine_in', 'takeaway', 'delivery', 'pickup'),
                              'payment_methods', jsonb_build_array('cash', 'card', 'instapay', 'wallet', 'on_account'),
                              'require_waiter', false, 'round_total', false,
                              'quick_notes', jsonb_build_array('بدون بصل', 'بدون طماطم', 'بدون مايونيز', 'حار', 'سكر زيادة',
                                                               'سكر خفيف', 'سكر بره', 'من غير سكر', 'من غير تلج', 'تلج زيادة')),
    'kds', jsonb_build_object('stations', jsonb_build_array('kitchen', 'bar', 'shisha'), 'warn_minutes', 15, 'sound', true,
                              'refresh_seconds', 10, 'warn_kitchen_minutes', 20, 'warn_bar_minutes', 10, 'warn_shisha_minutes', 10,
                              'rush_kitchen_orders', 0, 'rush_kitchen_minutes', 10, 'rush_bar_orders', 0, 'rush_bar_minutes', 5,
                              'rush_shisha_orders', 0, 'rush_shisha_minutes', 5),
    'waiter_qr', jsonb_build_object('qr_enabled', true, 'qr_call_waiter', true, 'qr_request_bill', true, 'qr_show_prices', true,
                                    'qr_ordering', true,
                                    'qr_welcome', 'أهلاً بيك 👋 اختار اللي نفسك فيه، وإحنا نجهّزهولك',
                                    'qr_privacy_note', 'بنسأل عن اسمك ورقمك عشان الويتر يعرفك ويأكد طلبك، وعشان نفتكرك المرة الجاية ونبعتلك عروضنا وهدية عيد ميلادك 🎁 بياناتك أمانة عندنا ومش بنشاركها مع أي حد.'),
    'loyalty', jsonb_build_object('enabled', false, 'min_spent', 1000, 'period_days', 365, 'percent', 5, 'label', 'خصم انتماء'),
    'social', jsonb_build_object('facebook_url', '', 'instagram_url', '', 'feedback_enabled', true, 'links_in_thanks', true,
                                 'feedback_intro', 'رأيك يهمنا جداً 🙏 قولنا إيه اللي عجبك وإيه اللي محتاج يتحسن'),
    'payinfo', jsonb_build_object('instapay', '', 'instapay_link', '', 'wallet', '', 'wallet_name', 'فودافون كاش',
                                  'show_on_receipt', true, 'show_on_menu', true),
    'shift', jsonb_build_object('default_float', 0, 'drawer_alert_limit', 5000),
    'inventory', jsonb_build_object('allow_negative_stock', true, 'default_min_stock', 5, 'units', '[]'::jsonb),
    'staff', jsonb_build_object('work_start_time', '09:00', 'late_grace_minutes', 15),
    'offline', jsonb_build_object('mode', 'none', 'local_server_url', ''),
    'whatsapp', jsonb_build_object(
      'customer_message', 'أهلاً يا {الاسم} 👋',
      'thanks_enabled', true,
      'thanks_message', 'شكراً يا {الاسم} إنك شرفتنا ونورتنا النهارده 🙏 بنحب نشوفك دايماً في {المحل} ❤️')
  )
$$;


-- settings save (same as 021) + link check for InstaPay
create or replace function public.app_settings_save_secure(p_token text, p_section text, p_data jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
  v_def jsonb := public.pos_settings_defaults() -> p_section;
  v_clean jsonb := '{}'::jsonb;
  k text;
  v jsonb;
  v_max int;
  v_num numeric;
begin
  select * into c from public.pos_ctx(p_token, 'settings');
  if v_def is null then
    return jsonb_build_object('ok', false, 'reason', 'unknown_action');
  end if;
  if p_section in ('general', 'offline') and c.role_name <> 'owner' then
    return jsonb_build_object('ok', false, 'reason', 'owner_only');
  end if;
  if jsonb_typeof(p_data) is distinct from 'object' then
    return jsonb_build_object('ok', false, 'reason', 'invalid_value');
  end if;
  for k, v in select e.key, e.value from jsonb_each(p_data) e loop
    if v_def ? k then
      if jsonb_typeof(v) <> jsonb_typeof(v_def -> k) then
        return jsonb_build_object('ok', false, 'reason', 'invalid_value', 'key', k);
      end if;
      v_max := 1000;
      if k = 'logo' then
        v_max := 400000;
      end if;
      if jsonb_typeof(v) = 'string' and length(v #>> '{}') > v_max then
        return jsonb_build_object('ok', false, 'reason', 'value_too_long', 'key', k);
      end if;
      if k = 'logo' and (v #>> '{}') <> '' and (v #>> '{}') !~ '^data:image/(png|jpeg|jpg|webp|svg\+xml);base64,' then
        return jsonb_build_object('ok', false, 'reason', 'invalid_logo');
      end if;
      if jsonb_typeof(v) = 'array' then
        if jsonb_array_length(v) > 50
           or exists (select 1 from jsonb_array_elements(v) x(e)
                       where jsonb_typeof(x.e) <> 'string' or length(x.e #>> '{}') > 60 or btrim(x.e #>> '{}') = '') then
          return jsonb_build_object('ok', false, 'reason', 'invalid_value', 'key', k);
        end if;
      end if;
      if k like 'warn\_%' and jsonb_typeof(v) = 'number' then
        v_num := (v #>> '{}')::numeric;
        if v_num < 1 or v_num > 240 then
          return jsonb_build_object('ok', false, 'reason', 'invalid_value', 'key', k);
        end if;
      end if;
      v_clean := v_clean || jsonb_build_object(k, v);
    end if;
  end loop;
  if p_section = 'offline' and coalesce(v_clean->>'mode', 'none') not in ('none', 'cashier', 'branch') then
    return jsonb_build_object('ok', false, 'reason', 'invalid_value', 'key', 'mode');
  end if;
  if p_section = 'receipt' and coalesce((v_clean->>'paper_mm')::int, 80) not in (58, 80) then
    return jsonb_build_object('ok', false, 'reason', 'invalid_value', 'key', 'paper_mm');
  end if;

  if p_section = 'loyalty' and (coalesce((v_clean->>'percent')::numeric, 0) < 0 or coalesce((v_clean->>'percent')::numeric, 0) > 100
                                 or coalesce((v_clean->>'period_days')::numeric, 365) < 1 or coalesce((v_clean->>'period_days')::numeric, 365) > 3650
                                 or coalesce((v_clean->>'min_spent')::numeric, 0) < 0) then
    return jsonb_build_object('ok', false, 'reason', 'invalid_value', 'key', 'loyalty');
  end if;
  if p_section = 'kds' and exists (select 1 from jsonb_each(v_clean) e
                                    where e.key like 'rush\_%' and ((e.value #>> '{}')::numeric < 0 or (e.value #>> '{}')::numeric > 240)) then
    return jsonb_build_object('ok', false, 'reason', 'invalid_value', 'key', 'rush');
  end if;
  if p_section = 'payinfo' and coalesce(v_clean->>'instapay_link', '') !~ '^(https?://[^ <>"]+)?$' then
    return jsonb_build_object('ok', false, 'reason', 'invalid_url');
  end if;
  if p_section = 'social' and (coalesce(v_clean->>'facebook_url', '') !~ '^(https?://[^ <>"]+)?$'
                               or coalesce(v_clean->>'instagram_url', '') !~ '^(https?://[^ <>"]+)?$') then
    return jsonb_build_object('ok', false, 'reason', 'invalid_url');
  end if;

  insert into public.app_settings (company_id, section, data, updated_by)
  values (c.company_id, p_section, v_clean, c.staff_id)
  on conflict (company_id, section)
  do update set data = public.app_settings.data || excluded.data, updated_at = now(), updated_by = excluded.updated_by;

  insert into public.settings_logs (staff_id, action, details)
  values (c.staff_id, 'app_settings', jsonb_build_object('section', p_section, 'keys',
          (select jsonb_agg(x) from jsonb_object_keys(v_clean) x)));
  return jsonb_build_object('ok', true, 'settings', public.pos_app_settings(c.company_id));
end;
$$;


-- QR menu (same as 021) + InstaPay / wallet numbers
create or replace function public.qr_menu_public(p_qr text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
declare
  t record;
  s jsonb;
  tx record;
begin
  select * into t from public.pos_qr_table(p_qr);
  if t.table_id is null then
    return jsonb_build_object('ok', false, 'reason', 'not_found');
  end if;
  s := public.pos_app_settings(t.company_id);
  if not coalesce((s->'waiter_qr'->>'qr_enabled')::boolean, true) then
    return jsonb_build_object('ok', false, 'reason', 'qr_disabled');
  end if;
  select x.vat_percentage, x.service_charge_percentage, x.is_vat_inclusive into tx
    from public.branch_tax_settings x where x.branch_id = t.branch_id limit 1;
  return jsonb_build_object('ok', true,
    'company_name', s->'general'->>'company_name', 'logo', s->'general'->>'logo', 'currency', s->'general'->>'currency',
    'phone', s->'general'->>'phone', 'address', s->'general'->>'address',
    'branch', t.branch_name, 'table_number', t.table_number,
    'call_waiter', coalesce((s->'waiter_qr'->>'qr_call_waiter')::boolean, true),
    'request_bill', coalesce((s->'waiter_qr'->>'qr_request_bill')::boolean, true),
    'show_prices', coalesce((s->'waiter_qr'->>'qr_show_prices')::boolean, true),
    'ordering', coalesce((s->'waiter_qr'->>'qr_ordering')::boolean, true),
    'welcome', s->'waiter_qr'->>'qr_welcome', 'privacy_note', s->'waiter_qr'->>'qr_privacy_note',
    'facebook_url', s->'social'->>'facebook_url', 'instagram_url', s->'social'->>'instagram_url',
    'feedback_token', case when coalesce((s->'social'->>'feedback_enabled')::boolean, true)
                           then (select b.public_token from public.branches b where b.id = t.branch_id) end,
    'store_offline', public.pos_qr_store_offline(t.branch_id),
    'payinfo', case when coalesce((s->'payinfo'->>'show_on_menu')::boolean, true) then s->'payinfo' end,
    'vat_percentage', coalesce(tx.vat_percentage, 0), 'service_percentage', coalesce(tx.service_charge_percentage, 0),
    'vat_inclusive', coalesce(tx.is_vat_inclusive, false),
    'categories', coalesce((
      select jsonb_agg(jsonb_build_object('id', cat.id, 'name', cat.name,
               'products', (select jsonb_agg(jsonb_build_object(
                                 'id', p.id, 'name', p.name, 'price', p.price, 'description', p.description,
                                 'has_image', coalesce(p.image, '') <> '',
                                 'groups', coalesce((
                                   select jsonb_agg(jsonb_build_object('id', g.id, 'name', g.name,
                                            'min', greatest(coalesce(g.min_selection, 0), case when coalesce(g.is_required, false) then 1 else 0 end),
                                            'max', coalesce(g.max_selection, 0),
                                            'modifiers', coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'name', m.name, 'price', m.price)
                                                                                    order by m.price, m.name)
                                                                     from public.modifiers m where m.group_id = g.id), '[]'::jsonb)) order by g.name)
                                     from public.product_modifier_groups pg join public.modifier_groups g on g.id = pg.group_id
                                    where pg.product_id = p.id
                                      and exists (select 1 from public.modifiers m where m.group_id = g.id)), '[]'::jsonb))
                               order by p.sort_order, p.name)
                              from public.products p
                             where p.category_id = cat.id and p.is_available is true and p.show_in_menu is true))
             order by cat.sort_order, cat.name)
        from public.categories cat
       where cat.brand_id = t.brand_id and cat.show_in_menu is true
         and exists (select 1 from public.products p where p.category_id = cat.id and p.is_available is true and p.show_in_menu is true)),
      '[]'::jsonb));
end;
$$;


-- reports (same as 012): tips per person = old named tips + shares from the pot
create or replace function public.report_secure(p_token text, p_key text, p_from date, p_to date, p_branch_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
  v_from date := coalesce(p_from, current_date - 30);
  v_to date := coalesce(p_to, current_date);
  v_branch uuid;
  v_title text;
  v_cols jsonb;
  v_rows jsonb;
  v_days int;
  v_set jsonb;
  v_start time;
  v_grace int;
begin
  select * into c from public.pos_ctx(p_token, 'reports');
  v_branch := case when c.role_name = 'owner' then p_branch_id else c.branch_id end;
  if v_to < v_from or v_to - v_from > 731 then
    return jsonb_build_object('ok', false, 'reason', 'invalid_period');
  end if;
  v_days := v_to - v_from + 1;

  case p_key
  -- ---------------------------------------------------------------- sales
  when 'sales_daily' then
    v_title := 'المبيعات اليومية';
    v_cols := public.pos_cols(array['day','orders','guests','gross','discount','service','tax','total','avg_ticket','per_guest'],
      array['اليوم','الطلبات','الضيوف','قبل الخصم','الخصم','الخدمة','الضريبة','الإجمالي','متوسط الفاتورة','متوسط الفرد'], 'dnnmmmmmmm');
    select coalesce(jsonb_agg(to_jsonb(q) order by q.day), '[]') into v_rows from (
      select public.pos_local_date(o.created_at) as day, count(*) as orders, sum(coalesce(o.guest_count, 1)) as guests,
             sum(o.sub_total) as gross, sum(o.discount_amount) as discount, sum(o.service_charge_amount) as service,
             sum(o.tax_amount) as tax, sum(o.total_amount) as total, round(avg(o.total_amount), 2) as avg_ticket,
             round(sum(o.total_amount) / nullif(sum(coalesce(o.guest_count, 1)), 0), 2) as per_guest
        from public.pos_rpt_orders(c.company_id, v_branch, v_from, v_to) o group by 1) q;

  when 'sales_monthly' then
    v_title := 'المبيعات الشهرية';
    v_cols := public.pos_cols(array['month','orders','gross','discount','service','tax','total','avg_ticket'],
      array['الشهر','الطلبات','قبل الخصم','الخصم','الخدمة','الضريبة','الإجمالي','متوسط الفاتورة'], 'tnmmmmmm');
    select coalesce(jsonb_agg(to_jsonb(q) order by q.month), '[]') into v_rows from (
      select to_char(public.pos_local_date(o.created_at), 'YYYY-MM') as month, count(*) as orders, sum(o.sub_total) as gross,
             sum(o.discount_amount) as discount, sum(o.service_charge_amount) as service, sum(o.tax_amount) as tax,
             sum(o.total_amount) as total, round(avg(o.total_amount), 2) as avg_ticket
        from public.pos_rpt_orders(c.company_id, v_branch, v_from, v_to) o group by 1) q;

  when 'sales_hourly' then
    v_title := 'أوقات الذروة (بالساعة)';
    v_cols := public.pos_cols(array['hour','orders','total','avg_per_day'], array['الساعة','الطلبات','الإجمالي','متوسط اليوم'], 'tnmm');
    select coalesce(jsonb_agg(to_jsonb(q) order by q.hour), '[]') into v_rows from (
      select lpad(extract(hour from o.created_at at time zone 'Africa/Cairo')::text, 2, '0') || ':00' as hour,
             count(*) as orders, sum(o.total_amount) as total, round(sum(o.total_amount) / v_days, 2) as avg_per_day
        from public.pos_rpt_orders(c.company_id, v_branch, v_from, v_to) o group by 1) q;

  when 'sales_weekday' then
    v_title := 'المبيعات بأيام الأسبوع';
    v_cols := public.pos_cols(array['weekday','orders','total'], array['اليوم','الطلبات','الإجمالي'], 'tnm');
    select coalesce(jsonb_agg(jsonb_build_object('weekday', (array['الأحد','الاثنين','الثلاثاء','الأربعاء','الخميس','الجمعة','السبت'])[q.d + 1],
                                                 'orders', q.orders, 'total', q.total) order by q.d), '[]') into v_rows from (
      select extract(dow from o.created_at at time zone 'Africa/Cairo')::int as d, count(*) as orders, sum(o.total_amount) as total
        from public.pos_rpt_orders(c.company_id, v_branch, v_from, v_to) o group by 1) q;

  when 'sales_payment_method' then
    v_title := 'المبيعات بطريقة الدفع';
    v_cols := public.pos_cols(array['method','count','amount','tips'], array['طريقة الدفع','العدد','المبلغ','الإكراميات'], 'tnmm');
    select coalesce(jsonb_agg(to_jsonb(q) order by q.amount desc), '[]') into v_rows from (
      select p.payment_method as method, count(*) as count, sum(p.amount) as amount, sum(coalesce(p.tip_amount, 0)) as tips
        from public.payments p join public.orders o on o.id = p.order_id
       where o.company_id = c.company_id and (v_branch is null or o.branch_id = v_branch)
         and public.pos_local_date(p.created_at) between v_from and v_to group by 1) q;

  when 'sales_order_type' then
    v_title := 'المبيعات بنوع الطلب';
    v_cols := public.pos_cols(array['order_type','orders','total','avg_ticket'], array['النوع','الطلبات','الإجمالي','متوسط الفاتورة'], 'tnmm');
    select coalesce(jsonb_agg(to_jsonb(q) order by q.total desc), '[]') into v_rows from (
      select o.order_type, count(*) as orders, sum(o.total_amount) as total, round(avg(o.total_amount), 2) as avg_ticket
        from public.pos_rpt_orders(c.company_id, v_branch, v_from, v_to) o group by 1) q;

  when 'sales_category' then
    v_title := 'المبيعات بالقسم';
    v_cols := public.pos_cols(array['category','qty','amount','share'], array['القسم','الكمية','المبلغ','النسبة'], 'tnmp');
    select coalesce(jsonb_agg(to_jsonb(q) order by q.amount desc), '[]') into v_rows from (
      select coalesce(cat.name, '-') as category, sum(oi.quantity) as qty, sum(oi.total_price) as amount,
             round(100 * sum(oi.total_price) / nullif(sum(sum(oi.total_price)) over (), 0), 1) as share
        from public.pos_rpt_orders(c.company_id, v_branch, v_from, v_to) o
        join public.order_items oi on oi.order_id = o.id and coalesce(oi.status, 'active') = 'active'
        left join public.products p on p.id = oi.product_id left join public.categories cat on cat.id = p.category_id
       group by 1) q;

  when 'sales_item' then
    v_title := 'المبيعات بالصنف';
    v_cols := public.pos_cols(array['product','category','qty','amount','avg_price','share'],
      array['الصنف','القسم','الكمية','المبلغ','متوسط السعر','النسبة'], 'ttnmmp');
    select coalesce(jsonb_agg(to_jsonb(q) order by q.amount desc), '[]') into v_rows from (
      select coalesce(p.name, '-') as product, coalesce(cat.name, '-') as category, sum(oi.quantity) as qty,
             sum(oi.total_price) as amount, round(sum(oi.total_price) / nullif(sum(oi.quantity), 0), 2) as avg_price,
             round(100 * sum(oi.total_price) / nullif(sum(sum(oi.total_price)) over (), 0), 1) as share
        from public.pos_rpt_orders(c.company_id, v_branch, v_from, v_to) o
        join public.order_items oi on oi.order_id = o.id and coalesce(oi.status, 'active') = 'active'
        left join public.products p on p.id = oi.product_id left join public.categories cat on cat.id = p.category_id
       group by 1, 2) q;

  when 'sales_modifiers' then
    v_title := 'أكتر الإضافات طلباً';
    v_cols := public.pos_cols(array['modifier','count','amount'], array['الإضافة','العدد','المبلغ'], 'tnm');
    select coalesce(jsonb_agg(to_jsonb(q) order by q.count desc), '[]') into v_rows from (
      select m.modifier_name as modifier, sum(oi.quantity) as count, sum(coalesce(m.unit_price, 0) * oi.quantity) as amount
        from public.pos_rpt_orders(c.company_id, v_branch, v_from, v_to) o
        join public.order_items oi on oi.order_id = o.id and coalesce(oi.status, 'active') = 'active'
        join public.order_item_modifiers m on m.order_item_id = oi.id group by 1) q;

  when 'sales_waiter' then
    v_title := 'المبيعات بالويتر';
    v_cols := public.pos_cols(array['waiter','orders','total','avg_ticket','guests'], array['الويتر','الطلبات','الإجمالي','متوسط الفاتورة','الضيوف'], 'tnmmn');
    select coalesce(jsonb_agg(to_jsonb(q) order by q.total desc), '[]') into v_rows from (
      select coalesce(w.name, 'بدون ويتر') as waiter, count(*) as orders, sum(o.total_amount) as total,
             round(avg(o.total_amount), 2) as avg_ticket, sum(coalesce(o.guest_count, 1)) as guests
        from public.pos_rpt_orders(c.company_id, v_branch, v_from, v_to) o left join public.staff w on w.id = o.waiter_id group by 1) q;

  when 'sales_cashier' then
    v_title := 'المقبوض بالكاشير';
    v_cols := public.pos_cols(array['cashier','orders','cash','other','total'], array['الكاشير','الطلبات','كاش','طرق تانية','الإجمالي'], 'tnmmm');
    select coalesce(jsonb_agg(to_jsonb(q) order by q.total desc), '[]') into v_rows from (
      select st.name as cashier, count(distinct p.order_id) as orders,
             sum(case when p.payment_method = 'cash' then p.amount else 0 end) as cash,
             sum(case when p.payment_method <> 'cash' then p.amount else 0 end) as other, sum(p.amount) as total
        from public.payments p join public.pos_shifts sh on sh.id = p.shift_id join public.staff st on st.id = sh.staff_id
       where sh.company_id = c.company_id and (v_branch is null or sh.branch_id = v_branch)
         and public.pos_local_date(p.created_at) between v_from and v_to group by 1) q;

  when 'sales_compare' then
    v_title := 'مقارنة الفترة بالفترة اللي قبلها';
    v_cols := public.pos_cols(array['metric','current','previous','change'], array['البند','الفترة دي','الفترة اللي قبلها','التغيير %'], 'tmmp');
    with cur as (select count(*) n, coalesce(sum(total_amount), 0) t, coalesce(avg(total_amount), 0) a, coalesce(sum(discount_amount), 0) d
                   from public.pos_rpt_orders(c.company_id, v_branch, v_from, v_to)),
         prv as (select count(*) n, coalesce(sum(total_amount), 0) t, coalesce(avg(total_amount), 0) a, coalesce(sum(discount_amount), 0) d
                   from public.pos_rpt_orders(c.company_id, v_branch, v_from - v_days, v_from - 1))
    select jsonb_build_array(
      jsonb_build_object('metric', 'عدد الطلبات', 'current', cur.n, 'previous', prv.n, 'change', round(100.0 * (cur.n - prv.n) / nullif(prv.n, 0), 1)),
      jsonb_build_object('metric', 'إجمالي المبيعات', 'current', cur.t, 'previous', prv.t, 'change', round(100 * (cur.t - prv.t) / nullif(prv.t, 0), 1)),
      jsonb_build_object('metric', 'متوسط الفاتورة', 'current', round(cur.a, 2), 'previous', round(prv.a, 2), 'change', round(100 * (cur.a - prv.a) / nullif(prv.a, 0), 1)),
      jsonb_build_object('metric', 'الخصومات', 'current', cur.d, 'previous', prv.d, 'change', round(100 * (cur.d - prv.d) / nullif(prv.d, 0), 1)))
      into v_rows from cur, prv;

  -- ---------------------------------------------------------------- profit
  when 'item_profit' then
    v_title := 'ربحية الأصناف وتصنيف المنيو';
    v_cols := public.pos_cols(array['product','qty','revenue','unit_cost','cost','profit','cost_pct','class'],
      array['الصنف','الكمية','الإيراد','تكلفة الوحدة','التكلفة','الربح','نسبة التكلفة','التصنيف'], 'tnmmmmpt');
    select coalesce(jsonb_agg(jsonb_build_object('product', q.product, 'qty', q.qty, 'revenue', q.revenue, 'unit_cost', q.unit_cost,
             'cost', q.cost, 'profit', q.revenue - q.cost, 'cost_pct', round(100 * q.cost / nullif(q.revenue, 0), 1),
             'class', case when q.qty >= 0.7 * q.avg_qty and q.margin >= q.avg_margin then 'نجم (مربح ومطلوب)'
                           when q.qty >= 0.7 * q.avg_qty then 'حصان (مطلوب وربحه قليل)'
                           when q.margin >= q.avg_margin then 'لغز (مربح ومش مطلوب)'
                           else 'ضعيف (لا ده ولا ده)' end) order by q.revenue - q.cost desc), '[]') into v_rows from (
      select x.*, avg(x.qty) over () as avg_qty, avg(x.margin) over () as avg_margin from (
        select coalesce(p.name, '-') as product, sum(oi.quantity) as qty, sum(oi.total_price) as revenue,
               round(public.pos_product_cost(oi.product_id), 2) as unit_cost,
               round(public.pos_product_cost(oi.product_id) * sum(oi.quantity), 2) as cost,
               sum(oi.total_price) / nullif(sum(oi.quantity), 0) - public.pos_product_cost(oi.product_id) as margin
          from public.pos_rpt_orders(c.company_id, v_branch, v_from, v_to) o
          join public.order_items oi on oi.order_id = o.id and coalesce(oi.status, 'active') = 'active'
          left join public.products p on p.id = oi.product_id
         group by p.name, oi.product_id) x) q;

  when 'category_profit' then
    v_title := 'ربحية الأقسام';
    v_cols := public.pos_cols(array['category','revenue','cost','profit','cost_pct'], array['القسم','الإيراد','التكلفة','الربح','نسبة التكلفة'], 'tmmmp');
    select coalesce(jsonb_agg(jsonb_build_object('category', q.category, 'revenue', q.revenue, 'cost', q.cost, 'profit', q.revenue - q.cost,
             'cost_pct', round(100 * q.cost / nullif(q.revenue, 0), 1)) order by q.revenue - q.cost desc), '[]') into v_rows from (
      select coalesce(cat.name, '-') as category, sum(oi.total_price) as revenue,
             round(sum(public.pos_product_cost(oi.product_id) * oi.quantity), 2) as cost
        from public.pos_rpt_orders(c.company_id, v_branch, v_from, v_to) o
        join public.order_items oi on oi.order_id = o.id and coalesce(oi.status, 'active') = 'active'
        left join public.products p on p.id = oi.product_id left join public.categories cat on cat.id = p.category_id
       group by 1) q;

  when 'daily_profit' then
    v_title := 'الربح اليومي (قبل المصروفات)';
    v_cols := public.pos_cols(array['day','revenue','cogs','waste','gross_profit','margin'],
      array['اليوم','الإيراد بدون ضريبة','تكلفة المبيعات','الهالك','مجمل الربح','نسبة الربح'], 'dmmmmp');
    select coalesce(jsonb_agg(jsonb_build_object('day', d.day, 'revenue', d.revenue, 'cogs', d.cogs, 'waste', d.waste,
             'gross_profit', d.revenue - d.cogs - d.waste, 'margin', round(100 * (d.revenue - d.cogs - d.waste) / nullif(d.revenue, 0), 1))
             order by d.day), '[]') into v_rows from (
      select g.day::date as day,
             coalesce((select sum(o.total_amount - o.tax_amount) from public.pos_rpt_orders(c.company_id, v_branch, g.day::date, g.day::date) o), 0) as revenue,
             coalesce((select sum(sm.total_cost) from public.stock_movements sm where sm.company_id = c.company_id and sm.movement_type = 'sale'
                         and (v_branch is null or sm.branch_id = v_branch) and public.pos_local_date(sm.created_at) = g.day::date), 0) as cogs,
             coalesce((select sum(sm.total_cost) from public.stock_movements sm where sm.company_id = c.company_id and sm.movement_type = 'waste'
                         and (v_branch is null or sm.branch_id = v_branch) and public.pos_local_date(sm.created_at) = g.day::date), 0) as waste
        from generate_series(v_from, v_to, interval '1 day') g(day)) d;

  -- ---------------------------------------------------------------- discounts / voids / refunds
  when 'discounts_detail' then
    v_title := 'الخصومات بالتفصيل';
    v_cols := public.pos_cols(array['at','order_number','kind','percent','amount','total_before','cashier','manager'],
      array['الوقت','الطلب','النوع','النسبة','المبلغ','الإجمالي قبلها','الكاشير','المدير الموافق'], 'ttnnmmtt');
    select coalesce(jsonb_agg(to_jsonb(q) order by q.at desc), '[]') into v_rows from (
      select to_char(l.created_at at time zone 'Africa/Cairo', 'YYYY-MM-DD HH24:MI') as at, o.order_number,
             case l.details->>'kind' when 'manual' then 'يدوي' when 'list' then 'من القايمة' else l.details->>'kind' end as kind,
             (l.details->>'percent')::numeric as percent, (l.details->>'amount')::numeric as amount,
             (l.details->>'total_before')::numeric as total_before, s.name as cashier, m.name as manager
        from public.order_logs l join public.orders o on o.id = l.order_id
        left join public.staff s on s.id = l.user_id left join public.staff m on m.id = public.pos_uuid(l.details->>'approved_by_manager_id')
       where l.action = 'APPLY_DISCOUNT' and o.company_id = c.company_id and (v_branch is null or o.branch_id = v_branch)
         and public.pos_local_date(l.created_at) between v_from and v_to) q;

  when 'voids_detail' then
    v_title := 'الإلغاءات بالتفصيل';
    v_cols := public.pos_cols(array['at','order_number','product','qty','value','reason','after_prep','waste_cost','cashier','manager'],
      array['الوقت','الطلب','الصنف','الكمية','القيمة','السبب','بعد التحضير','تكلفة الهالك','الكاشير','المدير الموافق'], 'tttnmttmtt');
    select coalesce(jsonb_agg(to_jsonb(q) order by q.at desc), '[]') into v_rows from (
      select to_char(l.created_at at time zone 'Africa/Cairo', 'YYYY-MM-DD HH24:MI') as at, o.order_number, l.details->>'product' as product,
             (l.details->>'qty_voided')::numeric as qty,
             round((l.details->>'qty_voided')::numeric * coalesce((l.details->>'unit_price')::numeric, 0), 2) as value,
             cr.reason, case when (l.details->>'recorded_as_waste')::boolean then 'نعم' else 'لا' end as after_prep,
             coalesce((l.details->>'waste_cost')::numeric, 0) as waste_cost, s.name as cashier, m.name as manager
        from public.order_logs l join public.orders o on o.id = l.order_id
        left join public.staff s on s.id = l.user_id left join public.staff m on m.id = public.pos_uuid(l.details->>'approved_by_manager_id')
        left join public.cancel_reasons cr on cr.id = public.pos_uuid(l.details->>'reason_id')
       where l.action like 'VOID_ITEM%' and o.company_id = c.company_id and (v_branch is null or o.branch_id = v_branch)
         and public.pos_local_date(l.created_at) between v_from and v_to) q;

  when 'refunds_detail' then
    v_title := 'المرتجعات والطلبات الملغية';
    v_cols := public.pos_cols(array['at','order_number','action','total','reason','by_staff','manager'],
      array['الوقت','الطلب','العملية','الإجمالي','السبب','بواسطة','المدير الموافق'], 'tttmttt');
    select coalesce(jsonb_agg(to_jsonb(q) order by q.at desc), '[]') into v_rows from (
      select to_char(l.created_at at time zone 'Africa/Cairo', 'YYYY-MM-DD HH24:MI') as at, o.order_number,
             case l.action when 'REFUND_ORDER' then 'مرتجع بعد الدفع' else 'إلغاء طلب' end as action,
             coalesce((l.details->>'total')::numeric, (l.details->>'total_before')::numeric) as total, cr.reason, s.name as by_staff, m.name as manager
        from public.order_logs l join public.orders o on o.id = l.order_id
        left join public.staff s on s.id = l.user_id left join public.staff m on m.id = public.pos_uuid(l.details->>'approved_by_manager_id')
        left join public.cancel_reasons cr on cr.id = public.pos_uuid(l.details->>'reason_id')
       where l.action in ('REFUND_ORDER', 'CANCEL_ORDER') and o.company_id = c.company_id and (v_branch is null or o.branch_id = v_branch)
         and public.pos_local_date(l.created_at) between v_from and v_to) q;

  -- ---------------------------------------------------------------- theft indicators
  when 'theft_indicators' then
    v_title := 'مؤشرات السرقة لكل موظف';
    v_cols := public.pos_cols(array['staff','voids','voids_value','voids_after_prep','manual_discounts','discounts_value','charges_removed',
                                    'refunds','cancelled_orders','shortage_count','shortage_total','night_actions','approvals_given'],
      array['الموظف','إلغاءات','قيمتها','بعد التحضير','خصم يدوي','قيمة الخصومات','شيل خدمة/ضريبة','مرتجعات','طلبات ملغية',
            'مرات العجز','إجمالي العجز','عمليات بعد ١٢ بالليل','موافقات أعطاها كمدير'], 'tnmnnmnnnnmnn');
    select coalesce(jsonb_agg(to_jsonb(q) order by q.voids_value + q.discounts_value + q.shortage_total desc), '[]') into v_rows from (
      select s.name as staff,
        count(*) filter (where l.action like 'VOID_ITEM%') as voids,
        coalesce(sum(round((l.details->>'qty_voided')::numeric * coalesce((l.details->>'unit_price')::numeric, 0), 2))
                   filter (where l.action like 'VOID_ITEM%'), 0) as voids_value,
        count(*) filter (where l.action like 'VOID_ITEM%' and (l.details->>'recorded_as_waste')::boolean) as voids_after_prep,
        count(*) filter (where l.action = 'APPLY_DISCOUNT' and l.details->>'kind' = 'manual') as manual_discounts,
        coalesce(sum((l.details->>'amount')::numeric) filter (where l.action = 'APPLY_DISCOUNT'), 0) as discounts_value,
        count(*) filter (where l.action = 'CHANGE_CHARGES' and ((l.details->>'vat_after')::boolean is false or (l.details->>'service_after')::boolean is false)) as charges_removed,
        count(*) filter (where l.action = 'REFUND_ORDER') as refunds,
        count(*) filter (where l.action = 'CANCEL_ORDER') as cancelled_orders,
        (select count(*) from public.pos_shifts sh where sh.staff_id = s.id and sh.difference < 0
            and public.pos_local_date(sh.opened_at) between v_from and v_to) as shortage_count,
        coalesce((select -sum(sh.difference) from public.pos_shifts sh where sh.staff_id = s.id and sh.difference < 0
            and public.pos_local_date(sh.opened_at) between v_from and v_to), 0) as shortage_total,
        count(*) filter (where extract(hour from l.created_at at time zone 'Africa/Cairo') between 0 and 5
                           and l.action in ('VOID_ITEM', 'APPLY_DISCOUNT', 'REFUND_ORDER', 'CANCEL_ORDER', 'CHANGE_CHARGES')) as night_actions,
        (select count(*) from public.order_logs l2 where public.pos_uuid(l2.details->>'approved_by_manager_id') = s.id
            and public.pos_local_date(l2.created_at) between v_from and v_to) as approvals_given
        from public.staff s
        left join public.order_logs l on l.user_id = s.id and public.pos_local_date(l.created_at) between v_from and v_to
       where s.company_id = c.company_id and (v_branch is null or s.branch_id = v_branch)
       group by s.id, s.name) q;

  when 'long_open_orders' then
    v_title := 'طلبات مفتوحة من وقت طويل (أكتر من ساعتين)';
    v_cols := public.pos_cols(array['order_number','opened','hours','table_number','waiter','total'],
      array['الطلب','اتفتح','ساعات','الطاولة','الويتر','الإجمالي'], 'ttnttm');
    select coalesce(jsonb_agg(to_jsonb(q) order by q.hours desc), '[]') into v_rows from (
      select o.order_number, to_char(o.created_at at time zone 'Africa/Cairo', 'YYYY-MM-DD HH24:MI') as opened,
             round(extract(epoch from now() - o.created_at) / 3600, 1) as hours, t.table_number, w.name as waiter, o.total_amount as total
        from public.orders o left join public.tables t on t.id = o.table_id left join public.staff w on w.id = o.waiter_id
       where o.company_id = c.company_id and (v_branch is null or o.branch_id = v_branch)
         and coalesce(o.status, '') not in ('paid', 'closed', 'cancelled') and o.created_at < now() - interval '2 hours') q;

  when 'manager_approvals' then
    v_title := 'موافقات المديرين';
    v_cols := public.pos_cols(array['manager','action','count'], array['المدير','العملية','العدد'], 'ttn');
    select coalesce(jsonb_agg(to_jsonb(q) order by q.count desc), '[]') into v_rows from (
      select m.name as manager, case l.action when 'VOID_ITEM' then 'إلغاء صنف' when 'APPLY_DISCOUNT' then 'خصم'
             when 'CHANGE_CHARGES' then 'شيل خدمة/ضريبة' when 'REFUND_ORDER' then 'مرتجع' when 'CANCEL_ORDER' then 'إلغاء طلب'
             else l.action end as action, count(*) as count
        from public.order_logs l join public.staff m on m.id = public.pos_uuid(l.details->>'approved_by_manager_id')
       where m.company_id = c.company_id and (v_branch is null or m.branch_id = v_branch)
         and public.pos_local_date(l.created_at) between v_from and v_to group by 1, 2) q;

  -- ---------------------------------------------------------------- inventory
  when 'stock_valuation' then
    v_title := 'تقييم المخزون (دلوقتي)';
    v_cols := public.pos_cols(array['warehouse','ingredient','unit','qty','unit_cost','value'],
      array['المخزن','الخامة','الوحدة','الكمية','تكلفة الوحدة','القيمة'], 'tttnmm');
    select coalesce(jsonb_agg(to_jsonb(q) order by q.warehouse, q.value desc), '[]') into v_rows from (
      select w.name as warehouse, i.name as ingredient, i.unit, ws.quantity as qty, i.cost_per_unit as unit_cost,
             round(ws.quantity * i.cost_per_unit, 2) as value
        from public.warehouse_stock ws join public.warehouses w on w.id = ws.warehouse_id join public.ingredients i on i.id = ws.ingredient_id
       where (v_branch is null or w.branch_id = v_branch or w.branch_id is null) and ws.quantity <> 0) q;

  when 'waste_by_reason' then
    v_title := 'الهالك بالسبب';
    v_cols := public.pos_cols(array['reason','ingredient','qty','cost'], array['السبب','الخامة','الكمية','التكلفة'], 'ttnm');
    select coalesce(jsonb_agg(to_jsonb(q) order by q.cost desc), '[]') into v_rows from (
      select split_part(wl.reason, ':', 1) as reason, i.name as ingredient, sum(wl.quantity) as qty, sum(wl.cost_loss) as cost
        from public.waste_logs wl join public.warehouses w on w.id = wl.warehouse_id join public.ingredients i on i.id = wl.ingredient_id
       where (v_branch is null or w.branch_id = v_branch or w.branch_id is null)
         and public.pos_local_date(wl.created_at) between v_from and v_to group by 1, 2) q;

  when 'count_variances' then
    v_title := 'فروقات الجرد';
    v_cols := public.pos_cols(array['at','warehouse','ingredient','system_qty','actual_qty','variance','value'],
      array['التاريخ','المخزن','الخامة','على السيستم','المعدود','الفرق','قيمة الفرق'], 'tttnnnm');
    select coalesce(jsonb_agg(to_jsonb(q) order by q.at desc), '[]') into v_rows from (
      select to_char(st.created_at at time zone 'Africa/Cairo', 'YYYY-MM-DD') as at, w.name as warehouse, i.name as ingredient,
             st.theoretical_qty as system_qty, st.actual_qty, st.variance_qty as variance, st.variance_cost as value
        from public.stock_takes st join public.warehouses w on w.id = st.warehouse_id join public.ingredients i on i.id = st.ingredient_id
       where (v_branch is null or w.branch_id = v_branch or w.branch_id is null) and st.variance_qty <> 0
         and public.pos_local_date(st.created_at) between v_from and v_to) q;

  when 'low_stock' then
    v_title := 'خامات تحت الحد الأدنى';
    v_cols := public.pos_cols(array['warehouse','ingredient','unit','qty','min'], array['المخزن','الخامة','الوحدة','الرصيد','الحد الأدنى'], 'tttnn');
    select coalesce(jsonb_agg(to_jsonb(q) order by q.warehouse, q.ingredient), '[]') into v_rows from (
      select w.name as warehouse, i.name as ingredient, i.unit, coalesce(ws.quantity, 0) as qty, i.min_stock_alert as min
        from public.warehouses w cross join public.ingredients i
        left join public.warehouse_stock ws on ws.warehouse_id = w.id and ws.ingredient_id = i.id
       where (v_branch is null or w.branch_id = v_branch) and coalesce(ws.quantity, 0) <= coalesce(i.min_stock_alert, 0)) q;

  when 'stock_turnover' then
    v_title := 'دوران المخزون';
    v_cols := public.pos_cols(array['ingredient','unit','used','current','days_left'], array['الخامة','الوحدة','المستهلك في الفترة','الرصيد الحالي','يكفي كام يوم'], 'ttnnn');
    select coalesce(jsonb_agg(to_jsonb(q) order by q.days_left nulls last), '[]') into v_rows from (
      select i.name as ingredient, i.unit,
             coalesce((select -sum(sm.quantity) from public.stock_movements sm where sm.ingredient_id = i.id
                         and sm.movement_type in ('sale', 'waste') and (v_branch is null or sm.branch_id = v_branch)
                         and public.pos_local_date(sm.created_at) between v_from and v_to), 0) as used,
             coalesce((select sum(ws.quantity) from public.warehouse_stock ws join public.warehouses w on w.id = ws.warehouse_id
                        where ws.ingredient_id = i.id and (v_branch is null or w.branch_id = v_branch)), 0) as current,
             round(coalesce((select sum(ws.quantity) from public.warehouse_stock ws join public.warehouses w on w.id = ws.warehouse_id
                              where ws.ingredient_id = i.id and (v_branch is null or w.branch_id = v_branch)), 0)
                   / nullif(coalesce((select -sum(sm.quantity) from public.stock_movements sm where sm.ingredient_id = i.id
                         and sm.movement_type in ('sale', 'waste') and (v_branch is null or sm.branch_id = v_branch)
                         and public.pos_local_date(sm.created_at) between v_from and v_to), 0) / v_days, 0), 1) as days_left
        from public.ingredients i) q;

  when 'transfers' then
    v_title := 'التحويلات بين المخازن';
    v_cols := public.pos_cols(array['at','number','from_wh','to_wh','status','ingredient','requested','shipped','received'],
      array['التاريخ','الرقم','من','إلى','الحالة','الخامة','المطلوب','المشحون','المستلم'], 'tttttnnnn');
    select coalesce(jsonb_agg(to_jsonb(q) order by q.at desc), '[]') into v_rows from (
      select to_char(t.created_at at time zone 'Africa/Cairo', 'YYYY-MM-DD') as at, t.transfer_number as number, wf.name as from_wh,
             wt.name as to_wh, t.status, i.name as ingredient, l.qty_requested as requested, l.qty_shipped as shipped, l.qty_received as received
        from public.inv_transfers t join public.inv_transfer_lines l on l.transfer_id = t.id join public.ingredients i on i.id = l.ingredient_id
        join public.warehouses wf on wf.id = t.from_warehouse_id join public.warehouses wt on wt.id = t.to_warehouse_id
       where t.company_id = c.company_id and public.pos_local_date(t.created_at) between v_from and v_to
         and (v_branch is null or wf.branch_id = v_branch or wt.branch_id = v_branch)) q;

  -- ---------------------------------------------------------------- purchasing
  when 'purchases_by_supplier' then
    v_title := 'المشتريات بالمورد';
    v_cols := public.pos_cols(array['supplier','received','invoiced','paid','balance'], array['المورد','المستلم','الفواتير','المدفوع','الرصيد الحالي'], 'tmmmm');
    select coalesce(jsonb_agg(to_jsonb(q) order by q.received desc), '[]') into v_rows from (
      select s.name as supplier,
             coalesce((select sum(gi.total_cost) from public.goods_receipt_items gi join public.goods_receipts g on g.id = gi.goods_receipt_id
                        join public.purchase_orders po on po.id = g.purchase_order_id
                       where po.supplier_id = s.id and public.pos_local_date(g.received_at) between v_from and v_to), 0) as received,
             coalesce((select sum(i.amount + i.tax_amount) from public.supplier_invoices i where i.supplier_id = s.id
                         and i.invoice_date between v_from and v_to), 0) as invoiced,
             coalesce((select sum(p.amount) from public.supplier_payments p where p.supplier_id = s.id
                         and public.pos_local_date(p.created_at) between v_from and v_to), 0) as paid,
             coalesce((select sum(l.amount) from public.supplier_ledger l where l.supplier_id = s.id), 0) as balance
        from public.suppliers s where s.company_id = c.company_id) q;

  when 'purchases_by_ingredient' then
    v_title := 'المشتريات بالخامة';
    v_cols := public.pos_cols(array['ingredient','unit','qty','value','avg_cost','min_cost','max_cost'],
      array['الخامة','الوحدة','الكمية','القيمة','متوسط السعر','أقل سعر','أعلى سعر'], 'ttnmmmm');
    select coalesce(jsonb_agg(to_jsonb(q) order by q.value desc), '[]') into v_rows from (
      select i.name as ingredient, i.unit, sum(gi.received_qty) as qty, sum(gi.total_cost) as value,
             round(sum(gi.total_cost) / nullif(sum(gi.received_qty), 0), 4) as avg_cost, min(gi.unit_cost) as min_cost, max(gi.unit_cost) as max_cost
        from public.goods_receipt_items gi join public.goods_receipts g on g.id = gi.goods_receipt_id
        join public.purchase_orders po on po.id = g.purchase_order_id join public.ingredients i on i.id = gi.ingredient_id
       where po.company_id = c.company_id and public.pos_local_date(g.received_at) between v_from and v_to group by 1, 2) q;

  when 'price_changes' then
    v_title := 'تغيّر أسعار الخامات';
    v_cols := public.pos_cols(array['at','ingredient','old_cost','new_cost','change'], array['التاريخ','الخامة','السعر القديم','السعر الجديد','التغيير %'], 'ttmmp');
    select coalesce(jsonb_agg(to_jsonb(q) order by q.at desc), '[]') into v_rows from (
      select to_char(h.created_at at time zone 'Africa/Cairo', 'YYYY-MM-DD') as at, i.name as ingredient, h.old_cost, h.new_cost,
             round(100 * (h.new_cost - h.old_cost) / nullif(h.old_cost, 0), 1) as change
        from public.ingredient_cost_history h join public.ingredients i on i.id = h.ingredient_id
       where public.pos_local_date(h.created_at) between v_from and v_to) q;

  when 'unmatched_invoices' then
    v_title := 'فواتير موردين مش مطابقة للاستلام';
    v_cols := public.pos_cols(array['date','supplier','invoice','received','amount','difference'],
      array['التاريخ','المورد','رقم الفاتورة','قيمة المستلم','قيمة الفاتورة','الفرق'], 'tttmmm');
    select coalesce(jsonb_agg(to_jsonb(q) order by q.date desc), '[]') into v_rows from (
      select i.invoice_date::text as date, s.name as supplier, i.invoice_number as invoice, i.received_value as received,
             i.amount, i.difference
        from public.supplier_invoices i join public.suppliers s on s.id = i.supplier_id
       where i.company_id = c.company_id and not i.matched and i.invoice_date between v_from and v_to) q;

  when 'supplier_aging' then
    v_title := 'أعمار ديون الموردين';
    v_cols := public.pos_cols(array['supplier','balance','last_invoice','last_payment','days_since_payment'],
      array['المورد','الرصيد','آخر فاتورة','آخر سداد','أيام من آخر سداد'], 'tmttn');
    select coalesce(jsonb_agg(to_jsonb(q) order by q.balance desc), '[]') into v_rows from (
      select s.name as supplier, coalesce(sum(l.amount), 0) as balance,
             max(l.created_at) filter (where l.entry_type = 'invoice')::date::text as last_invoice,
             max(l.created_at) filter (where l.entry_type = 'payment')::date::text as last_payment,
             current_date - max(l.created_at) filter (where l.entry_type = 'payment')::date as days_since_payment
        from public.suppliers s left join public.supplier_ledger l on l.supplier_id = s.id
       where s.company_id = c.company_id group by s.id, s.name having coalesce(sum(l.amount), 0) <> 0) q;

  -- ---------------------------------------------------------------- treasury
  when 'cash_movements' then
    v_title := 'حركة النقدية';
    v_cols := public.pos_cols(array['at','type','amount','source','destination','reason','staff'],
      array['الوقت','النوع','المبلغ','من','إلى','السبب','الموظف'], 'ttmtttt');
    select coalesce(jsonb_agg(to_jsonb(q) order by q.at desc), '[]') into v_rows from (
      select to_char(m.created_at at time zone 'Africa/Cairo', 'YYYY-MM-DD HH24:MI') as at, m.move_type as type, m.amount,
             m.source, m.destination, m.reason, s.name as staff
        from public.pos_cash_moves m left join public.staff s on s.id = m.staff_id
       where m.company_id = c.company_id and (v_branch is null or m.branch_id = v_branch)
         and public.pos_local_date(m.created_at) between v_from and v_to) q;

  when 'shifts' then
    v_title := 'الورديات وفروقها';
    v_cols := public.pos_cols(array['opened','closed','staff','float','expected','counted','difference','tips'],
      array['فتح','قفل','الموظف','العهدة','المفروض','المعدود','الفرق','الإكراميات'], 'tttmmmmm');
    select coalesce(jsonb_agg(to_jsonb(q) order by q.opened desc), '[]') into v_rows from (
      select to_char(sh.opened_at at time zone 'Africa/Cairo', 'YYYY-MM-DD HH24:MI') as opened,
             to_char(sh.closed_at at time zone 'Africa/Cairo', 'YYYY-MM-DD HH24:MI') as closed, s.name as staff,
             sh.opening_float as float, sh.expected_cash as expected, sh.counted_cash as counted, sh.difference, sh.tips_paid as tips
        from public.pos_shifts sh join public.staff s on s.id = sh.staff_id
       where sh.company_id = c.company_id and (v_branch is null or sh.branch_id = v_branch)
         and public.pos_local_date(sh.opened_at) between v_from and v_to) q;

  when 'expenses_by_category' then
    v_title := 'المصروفات بالبند';
    v_cols := public.pos_cols(array['category','count','total','share'], array['البند','العدد','الإجمالي','النسبة'], 'tnmp');
    select coalesce(jsonb_agg(to_jsonb(q) order by q.total desc), '[]') into v_rows from (
      select coalesce(ec.name, a.name_ar) as category, count(*) as count, sum(x.amount) as total,
             round(100 * sum(x.amount) / nullif(sum(sum(x.amount)) over (), 0), 1) as share
        from public.expenses x left join public.expense_categories ec on ec.id = x.category_id left join public.accounts a on a.id = x.expense_account_id
       where x.company_id = c.company_id and (v_branch is null or x.branch_id = v_branch)
         and public.pos_local_date(x.created_at) between v_from and v_to group by 1) q;

  -- ---------------------------------------------------------------- customers
  when 'customer_balances' then
    v_title := 'أرصدة العملاء الآجل';
    v_cols := public.pos_cols(array['customer','phone','balance','credit_limit','last_sale','last_payment','days_since_payment'],
      array['العميل','التليفون','الرصيد','الحد','آخر بيع','آخر تحصيل','أيام من آخر تحصيل'], 'ttmmttn');
    select coalesce(jsonb_agg(to_jsonb(q) order by q.balance desc), '[]') into v_rows from (
      select cu.name as customer, cu.phone, coalesce(sum(l.amount), 0) as balance, cu.credit_limit,
             max(l.created_at) filter (where l.transaction_type = 'credit_sale')::date::text as last_sale,
             max(l.created_at) filter (where l.transaction_type = 'payment_received')::date::text as last_payment,
             current_date - coalesce(max(l.created_at) filter (where l.transaction_type = 'payment_received'),
                                     min(l.created_at))::date as days_since_payment
        from public.customers cu left join public.customer_ledger l on l.customer_id = cu.id
       where cu.company_id = c.company_id group by cu.id, cu.name, cu.phone, cu.credit_limit
      having coalesce(sum(l.amount), 0) <> 0) q;

  when 'top_customers' then
    v_title := 'أكتر العملاء شراء';
    v_cols := public.pos_cols(array['customer','orders','total','avg_ticket'], array['العميل','الطلبات','الإجمالي','متوسط الفاتورة'], 'tnmm');
    select coalesce(jsonb_agg(to_jsonb(q) order by q.total desc), '[]') into v_rows from (
      select cu.name as customer, count(*) as orders, sum(o.total_amount) as total, round(avg(o.total_amount), 2) as avg_ticket
        from public.pos_rpt_orders(c.company_id, v_branch, v_from, v_to) o join public.customers cu on cu.id = o.customer_id group by 1) q;

  -- ---------------------------------------------------------------- staff
  when 'attendance' then
    v_set := public.pos_app_settings(c.company_id) -> 'staff';
    v_start := coalesce(nullif(v_set->>'work_start_time', ''), '09:00')::time;
    v_grace := coalesce((v_set->>'late_grace_minutes')::int, 15);
    v_title := 'الحضور والتأخير';
    v_cols := public.pos_cols(array['staff','days','hours','late_days','late_minutes'], array['الموظف','أيام الحضور','الساعات','أيام التأخير','دقايق التأخير'], 'tnnnn');
    select coalesce(jsonb_agg(to_jsonb(q) order by q.staff), '[]') into v_rows from (
      select s.name as staff, count(*) as days, round(sum(d.minutes) / 60.0, 1) as hours,
             count(*) filter (where d.first_in > v_start + make_interval(mins => v_grace)) as late_days,
             coalesce(sum(greatest(0, extract(epoch from (d.first_in - v_start)) / 60)::int)
                        filter (where d.first_in > v_start + make_interval(mins => v_grace)), 0) as late_minutes
        from (select a.staff_id, public.pos_local_date(a.clock_in) as day, min((a.clock_in at time zone 'Africa/Cairo')::time) as first_in,
                     coalesce(sum(a.minutes), 0) as minutes
                from public.staff_attendance a
               where a.company_id = c.company_id and (v_branch is null or a.branch_id = v_branch)
                 and public.pos_local_date(a.clock_in) between v_from and v_to group by 1, 2) d
        join public.staff s on s.id = d.staff_id group by s.name) q;

  when 'tips_by_staff' then
    v_title := 'الإكراميات لكل موظف';
    v_cols := public.pos_cols(array['staff','count','tips'], array['الموظف','العدد','الإجمالي'], 'tnm');
    select coalesce(jsonb_agg(to_jsonb(q) order by q.tips desc), '[]') into v_rows from (
      select s.name as staff, count(*) as count, sum(x.amount) as tips
        from (select p.tip_staff_id as staff_id, p.tip_amount as amount, p.created_at from public.payments p
               where p.tip_staff_id is not null and p.tip_amount > 0
              union all
              select t.staff_id, t.amount, t.created_at from public.tip_payouts t) x
        join public.staff s on s.id = x.staff_id
       where s.company_id = c.company_id and (v_branch is null or s.branch_id = v_branch)
         and public.pos_local_date(x.created_at) between v_from and v_to group by 1) q;

  when 'staff_balances' then
    v_title := 'أرصدة الموظفين (عجز وسلف)';
    v_cols := public.pos_cols(array['staff','shortages','advances','deducted','balance'], array['الموظف','العجز','السلف','اتخصم','الرصيد عليه'], 'tmmmm');
    select coalesce(jsonb_agg(to_jsonb(q) order by q.balance desc), '[]') into v_rows from (
      select s.name as staff,
             coalesce(sum(l.amount) filter (where l.entry_type = 'shortage'), 0) as shortages,
             coalesce(sum(l.amount) filter (where l.entry_type = 'advance'), 0) as advances,
             coalesce(-sum(l.amount) filter (where l.entry_type in ('deduction', 'repayment')), 0) as deducted,
             coalesce(sum(l.amount), 0) as balance
        from public.staff s join public.staff_ledger l on l.staff_id = s.id
       where s.company_id = c.company_id and (v_branch is null or s.branch_id = v_branch) group by s.name) q;

  -- ---------------------------------------------------------------- tax
  when 'vat_monthly' then
    v_title := 'ضريبة القيمة المضافة الشهرية';
    v_cols := public.pos_cols(array['month','sales_base','output_vat','purchases_base','input_vat','net_vat'],
      array['الشهر','المبيعات الخاضعة','ضريبة المبيعات','المشتريات الخاضعة','ضريبة المدخلات','الصافي المستحق'], 'tmmmmm');
    select coalesce(jsonb_agg(jsonb_build_object('month', m.month, 'sales_base', m.sales_base, 'output_vat', m.output_vat,
             'purchases_base', m.purchases_base, 'input_vat', m.input_vat, 'net_vat', m.output_vat - m.input_vat) order by m.month), '[]')
      into v_rows from (
      select g.month,
             coalesce((select sum(o.total_amount - o.tax_amount) from public.pos_rpt_orders(c.company_id, v_branch, v_from, v_to) o
                        where to_char(public.pos_local_date(o.created_at), 'YYYY-MM') = g.month), 0) as sales_base,
             coalesce((select sum(o.tax_amount) from public.pos_rpt_orders(c.company_id, v_branch, v_from, v_to) o
                        where to_char(public.pos_local_date(o.created_at), 'YYYY-MM') = g.month), 0) as output_vat,
             coalesce((select sum(i.amount) from public.supplier_invoices i where i.company_id = c.company_id
                         and to_char(i.invoice_date, 'YYYY-MM') = g.month), 0) as purchases_base,
             coalesce((select sum(i.tax_amount) from public.supplier_invoices i where i.company_id = c.company_id
                         and to_char(i.invoice_date, 'YYYY-MM') = g.month), 0) as input_vat
        from (select distinct to_char(d::date, 'YYYY-MM') as month from generate_series(v_from, v_to, interval '1 day') d) g) m;

  else
    return jsonb_build_object('ok', false, 'reason', 'unknown_action');
  end case;

  return jsonb_build_object('ok', true, 'key', p_key, 'title', v_title, 'columns', v_cols, 'rows', coalesce(v_rows, '[]'::jsonb),
    'from', v_from, 'to', v_to,
    'branch', coalesce((select b.name from public.branches b where b.id = v_branch), 'كل الفروع'));
end;
$$;


-- menu screen (same as 022) + recipes for many products at once
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

  when 'import_recipes' then
    -- [{product, ingredient, unit, qty}] grouped by product. A product that already has a recipe is kept
    -- (unless overwrite = true). Missing ingredients are created with cost 0 (purchases set the cost later).
    if jsonb_typeof(d->'rows') is distinct from 'array' or jsonb_array_length(d->'rows') > 3000 then
      return jsonb_build_object('ok', false, 'reason', 'invalid_items');
    end if;
    for r in select e.value from jsonb_array_elements(d->'rows') e(value) loop
      v_name := nullif(btrim(coalesce(r->>'ingredient', '')), '');
      v_num := public.pos_amount(r->>'qty');
      if v_name is null or length(v_name) > 100 or coalesce(v_num, 0) <= 0 or nullif(btrim(coalesce(r->>'unit', '')), '') is null
         or nullif(btrim(coalesce(r->>'product', '')), '') is null then
        return jsonb_build_object('ok', false, 'reason', 'invalid_items', 'row', r);
      end if;
    end loop;
    create temporary table if not exists pg_temp.mp_rec (product_id uuid, ingredient_id uuid, qty numeric) on commit drop;
    delete from pg_temp.mp_rec;
    for r in select e.value from jsonb_array_elements(d->'rows') e(value) loop
      select p.id into v_id from public.products p where p.brand_id = v_brand and btrim(p.name) = btrim(r->>'product') limit 1;
      if v_id is null then
        v_extra := jsonb_set(v_extra, '{missing}', coalesce(v_extra->'missing', '[]'::jsonb) || to_jsonb(btrim(r->>'product')));
        continue;
      end if;
      select i.id into v_cat from public.ingredients i where btrim(i.name) = btrim(r->>'ingredient') and (i.brand_id is null or i.brand_id = v_brand) limit 1;
      if v_cat is null then
        insert into public.ingredients (name, unit, cost_per_unit, min_stock_alert, brand_id)
        values (left(btrim(r->>'ingredient'), 100), left(btrim(r->>'unit'), 20), 0, 0, v_brand) returning id into v_cat;
        v_created := v_created + 1;
      end if;
      insert into pg_temp.mp_rec values (v_id, v_cat, public.pos_amount(r->>'qty'));
    end loop;
    select count(distinct x.product_id) into v_updated from pg_temp.mp_rec x
     where coalesce((d->>'overwrite')::boolean, false) or not exists (select 1 from public.recipes rr where rr.product_id = x.product_id);
    v_extra := v_extra || jsonb_build_object('skipped', (select count(distinct x.product_id) from pg_temp.mp_rec x
       where not coalesce((d->>'overwrite')::boolean, false) and exists (select 1 from public.recipes rr where rr.product_id = x.product_id)));
    delete from public.recipes rr using (select distinct product_id from pg_temp.mp_rec) x
     where rr.product_id = x.product_id and coalesce((d->>'overwrite')::boolean, false);
    insert into public.recipes (product_id, ingredient_id, quantity_required)
    select x.product_id, x.ingredient_id, sum(x.qty) from pg_temp.mp_rec x
     where not exists (select 1 from public.recipes rr where rr.product_id = x.product_id)
     group by 1, 2;
    insert into public.settings_logs (staff_id, action, details)
    values (c.staff_id, 'recipes_import', jsonb_build_object('products', v_updated, 'new_ingredients', v_created));
    v_extra := v_extra || jsonb_build_object('imported', v_updated, 'new_ingredients', v_created);

  else
    return jsonb_build_object('ok', false, 'reason', 'unknown_action');
  end case;

  return jsonb_build_object('ok', true) || v_extra || public.pos_menu_admin_data(v_brand);
end;
$$;


create or replace function public.motionpos_version_public()
returns text
language sql
immutable
as $$
  select '024'
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
  v_company uuid; v_brand uuid; v_branch uuid; v_owner uuid; v_a uuid; v_b uuid; v_c uuid; v_shift uuid; v_prod uuid;
  v_to text := 'mp-t24-o-' || md5(random()::text || clock_timestamp()::text);
  v_res jsonb;
begin
  begin
    if array_position(public.pos_all_perms(), 'tips_distribute') is null then
      raise exception 'SELFTEST tips_distribute missing from the list';
    end if;
    if (select p.prosrc from pg_proc p where p.proname = 'close_order_secure' limit 1) not like '%p_tip_staff_id is not null and not exists%' then
      raise exception 'SELFTEST payment still needs a tip person';
    end if;
    if public.pos_settings_defaults()->'payinfo'->>'wallet_name' is null then
      raise exception 'SELFTEST payinfo defaults missing';
    end if;

    insert into public.companies (name) values ('selftest024') returning id into v_company;
    insert into public.brands (company_id, name) values (v_company, 'selftest024') returning id into v_brand;
    insert into public.branches (name, brand_id) values ('selftest024', v_brand) returning id into v_branch;
    insert into public.accounts (company_id, code, name_ar, name_en, account_type, normal_balance, is_system_account)
    values (v_company, '1100', 'خزينة', 'Cash', 'asset', 'debit', true),
           (v_company, '1101', 'درج', 'Drawer', 'asset', 'debit', true),
           (v_company, '1130', 'عهد', 'Staff', 'asset', 'debit', true),
           (v_company, '2400', 'إكراميات', 'Tips', 'liability', 'credit', true),
           (v_company, '4200', 'إيرادات أخرى', 'Other', 'revenue', 'credit', true);
    insert into public.staff (name, role_id, branch_id, company_id, is_active)
    values ('selftest024 o', (select id from public.roles where name = 'owner'), v_branch, v_company, true) returning id into v_owner;
    insert into public.staff (name, role_id, branch_id, company_id, is_active)
    values ('selftest024 a', (select id from public.roles where name <> 'owner' order by name limit 1), v_branch, v_company, true) returning id into v_a;
    insert into public.staff (name, role_id, branch_id, company_id, is_active)
    values ('selftest024 b', (select id from public.roles where name <> 'owner' order by name limit 1), v_branch, v_company, true) returning id into v_b;
    insert into public.staff (name, role_id, branch_id, company_id, is_active)
    values ('selftest024 c', (select id from public.roles where name <> 'owner' order by name limit 1), v_branch, v_company, true) returning id into v_c;
    insert into public.staff_sessions (token_hash, staff_id, expires_at)
    values (encode(extensions.digest(v_to, 'sha256'), 'hex'), v_owner, now() + interval '10 minutes');

    -- 50 in the tips pot
    perform public.pos_post_je(v_company, v_branch, 'adjustment', 'shift', null, 'selftest tips',
      jsonb_build_array(public.pos_je_line('1101', 50, 0, 'x'), public.pos_je_line('2400', 0, 50, 'x')), v_owner);
    if public.pos_tips_pool(v_company, v_branch) <> 50 then
      raise exception 'SELFTEST pot is %, expected 50', public.pos_tips_pool(v_company, v_branch);
    end if;

    -- shift with 100, counted 70: 30 short, all covered from the pot
    insert into public.pos_shifts (company_id, branch_id, staff_id, opening_float) values (v_company, v_branch, v_owner, 100) returning id into v_shift;
    v_res := public.shift_close_secure(v_to, 70, null);
    if not coalesce((v_res->>'ok')::boolean, false) then raise exception 'SELFTEST close failed: %', v_res; end if;
    if (v_res->'report'->>'shortage_from_tips')::numeric <> 30 or (v_res->'report'->>'shortage_on_cashier')::numeric <> 0 then
      raise exception 'SELFTEST shortage not covered from the pot: %', v_res->'report';
    end if;
    if public.pos_tips_pool(v_company, v_branch) <> 20 then
      raise exception 'SELFTEST pot after shortage is %, expected 20', public.pos_tips_pool(v_company, v_branch);
    end if;
    if exists (select 1 from public.staff_ledger l where l.staff_id = v_owner) then
      raise exception 'SELFTEST covered shortage still charged on the cashier';
    end if;

    -- share 20 between 3: 6.66 each, 0.02 stays
    v_res := public.tips_secure(v_to, 'distribute', jsonb_build_object('staff_ids', jsonb_build_array(v_a, v_b, v_c), 'source', 'main_cash'));
    if not coalesce((v_res->>'ok')::boolean, false) or (v_res->>'each')::numeric <> 6.66 or (v_res->>'pool')::numeric <> 0.02 then
      raise exception 'SELFTEST share wrong: %', v_res;
    end if;
    if (select count(*) from public.tip_payouts t where t.branch_id = v_branch) <> 3 then
      raise exception 'SELFTEST payouts not written';
    end if;
    v_res := public.tips_secure(v_to, 'distribute', jsonb_build_object('staff_ids', jsonb_build_array(v_a), 'amount', 5));
    if coalesce(v_res->>'reason', '') <> 'invalid_amount' then raise exception 'SELFTEST shared more than the pot: %', v_res; end if;

    -- recipes for many products at once
    insert into public.products (brand_id, name, price, is_available) values (v_brand, 'selftest024 لاتيه', 50, true) returning id into v_prod;
    v_res := public.menu_admin_secure(v_to, 'import_recipes', jsonb_build_object('rows', jsonb_build_array(
      jsonb_build_object('product', 'selftest024 لاتيه', 'ingredient', 'selftest024 بن', 'unit', 'كيلو', 'qty', '0.018'),
      jsonb_build_object('product', 'selftest024 لاتيه', 'ingredient', 'selftest024 لبن', 'unit', 'لتر', 'qty', '0.2'),
      jsonb_build_object('product', 'selftest024 مش موجود', 'ingredient', 'selftest024 لبن', 'unit', 'لتر', 'qty', '0.2'))));
    if not coalesce((v_res->>'ok')::boolean, false) or (v_res->>'imported')::int <> 1 or (v_res->>'new_ingredients')::int <> 2
       or jsonb_array_length(v_res->'missing') <> 1 then
      raise exception 'SELFTEST recipes import wrong: %', v_res - 'categories' - 'products_list';
    end if;
    if (select count(*) from public.recipes r where r.product_id = v_prod) <> 2 then raise exception 'SELFTEST recipe rows missing'; end if;
    -- second time without overwrite keeps the old recipe
    v_res := public.menu_admin_secure(v_to, 'import_recipes', jsonb_build_object('rows', jsonb_build_array(
      jsonb_build_object('product', 'selftest024 لاتيه', 'ingredient', 'selftest024 بن', 'unit', 'كيلو', 'qty', '1'))));
    if (v_res->>'skipped')::int <> 1 or (select sum(quantity_required) from public.recipes r where r.product_id = v_prod) <> 0.218 then
      raise exception 'SELFTEST existing recipe was changed';
    end if;

    raise notice 'MOTIONPOS-024-SELFTEST-OK';
    raise exception using errcode = 'P0099', message = 'selftest_rollback';
  exception when sqlstate 'P0099' then
    null;
  end;
end;
$selftest$;

notify pgrst, 'reload schema';

commit;
