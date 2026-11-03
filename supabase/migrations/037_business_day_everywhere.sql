-- 037_business_day_everywhere.sql
-- 034 made the reports count a "day" as the business day (settings > الشركة > day_start_hour: 8 = from 8 in the morning
-- to 8 the next morning). Some screens still cut the day at midnight UTC (02:00 Cairo) or used the server's date for
-- "today": the day report / day close (Z report), expenses report, staff performance, shifts list, stock ledger and
-- expected-vs-actual. They now use pos_local_date like the sales reports, and "today" is the current business day.
-- Attendance keeps the Cairo calendar day on purpose (clocking in at 07:30 belongs to that day).
-- Functions copied from their latest files (011, 022, 031) with only the date expressions changed. No tables changed.
-- Rules: begin/commit, preflight (needs 036), version bump to 037, grants loop, rolled-back self-test.

begin;

do $preflight$
begin
  if length('إكراميات') <> 8 then
    raise exception 'file_encoding_broken: read the file as UTF-8';
  end if;
  if public.motionpos_version_public() not in ('036', '037') then
    raise exception 'schema_preflight_failed: run 036 first';
  end if;
end;
$preflight$;

-- copied from 011_phases_3_to_7.sql
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
                        and exists (select 1 from public.payments p where p.order_id = o.id and public.pos_local_date(p.created_at) = p_date)),
    'sales_total', coalesce((select sum(p.amount) from public.payments p join public.orders o on o.id = p.order_id
                               where o.branch_id = p_branch_id and public.pos_local_date(p.created_at) = p_date), 0),
    'payments_by_method', coalesce((select jsonb_object_agg(q.m, q.t) from (
        select p.payment_method as m, sum(p.amount) as t from public.payments p join public.orders o on o.id = p.order_id
         where o.branch_id = p_branch_id and public.pos_local_date(p.created_at) = p_date group by p.payment_method) q), '{}'::jsonb),
    'tips', coalesce((select sum(p.tip_amount) from public.payments p join public.orders o on o.id = p.order_id
                        where o.branch_id = p_branch_id and public.pos_local_date(p.created_at) = p_date), 0),
    'voided_items', (select count(*) from public.order_logs l join public.orders o on o.id = l.order_id
                      where o.branch_id = p_branch_id and l.action like 'VOID_ITEM%' and public.pos_local_date(l.created_at) = p_date),
    'discounts', (select count(*) from public.order_logs l join public.orders o on o.id = l.order_id
                   where o.branch_id = p_branch_id and l.action = 'APPLY_DISCOUNT' and public.pos_local_date(l.created_at) = p_date),
    'refunds', (select count(*) from public.order_logs l join public.orders o on o.id = l.order_id
                 where o.branch_id = p_branch_id and l.action = 'REFUND_ORDER' and public.pos_local_date(l.created_at) = p_date),
    'shifts', coalesce((select jsonb_agg(jsonb_build_object('staff', st.name, 'status', s.status,
                                                            'difference', s.difference, 'counted_cash', s.counted_cash))
                          from public.pos_shifts s join public.staff st on st.id = s.staff_id
                         where s.branch_id = p_branch_id and public.pos_local_date(s.opened_at) = p_date), '[]'::jsonb),
    'drops', coalesce((select jsonb_object_agg(q.d, q.t) from (
        select m.destination as d, sum(m.amount) as t from public.pos_cash_moves m
         where m.branch_id = p_branch_id and m.move_type = 'drop' and public.pos_local_date(m.created_at) = p_date group by m.destination) q), '{}'::jsonb))
$$;

-- copied from 011_phases_3_to_7.sql
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
  return jsonb_build_object('ok', true, 'report', public.pos_day_report(c.branch_id, coalesce(p_date, public.pos_local_date(now()))),
    'closed', exists (select 1 from public.pos_days d where d.branch_id = c.branch_id and d.business_date = coalesce(p_date, public.pos_local_date(now()))));
end;
$$;

-- copied from 022_permissions_detail.sql
create or replace function public.day_close_secure(p_token text, p_date date)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
  v_date date := coalesce(p_date, public.pos_local_date(now()));
begin
  select * into c from public.pos_ctx(p_token, 'treasury');
  if not public.pos_perm_ok(c.role_name, 'day_close') then
    return jsonb_build_object('ok', false, 'reason', 'not_allowed', 'perm', 'day_close');
  end if;
  if exists (select 1 from public.pos_shifts s where s.branch_id = c.branch_id and s.status = 'open' and public.pos_local_date(s.opened_at) <= v_date) then
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

-- copied from 011_phases_3_to_7.sql
create or replace function public.expenses_report_secure(p_token text, p_from date, p_to date)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
  v_from date := coalesce(p_from, date_trunc('month', public.pos_local_date(now()))::date);
  v_to date := coalesce(p_to, public.pos_local_date(now()));
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
                 and public.pos_local_date(x.created_at) between v_from and v_to
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
         and public.pos_local_date(x.created_at) between v_from and v_to), '[]'::jsonb));
end;
$$;

-- copied from 011_phases_3_to_7.sql
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
         and public.pos_local_date(sm.created_at) between coalesce(p_from, public.pos_local_date(now()) - 30) and coalesce(p_to, public.pos_local_date(now()))
       order by sm.created_at desc
       limit 500) q), '[]'::jsonb));
end;
$$;

-- copied from 031_hospitality.sql
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
               coalesce(sum(case when sm.movement_type in ('sale', 'hospitality') then -sm.quantity end), 0) as sales_qty,
               coalesce(sum(case when sm.movement_type = 'waste' then -sm.quantity end), 0) as waste_qty,
               coalesce(sum(case when sm.movement_type = 'adjustment' and sm.reference_type = 'stocktake' then sm.quantity end), 0) as count_qty
          from public.stock_movements sm
          join public.ingredients i on i.id = sm.ingredient_id
         where sm.warehouse_id = p_warehouse_id
           and public.pos_local_date(sm.created_at) between coalesce(p_from, public.pos_local_date(now()) - 30) and coalesce(p_to, public.pos_local_date(now()))
         group by i.name, i.unit, i.cost_per_unit) q), '[]'::jsonb));
end;
$$;

-- copied from 011_phases_3_to_7.sql
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
       and public.pos_local_date(s.opened_at) between coalesce(p_from, public.pos_local_date(now()) - 7) and coalesce(p_to, public.pos_local_date(now()))), '[]'::jsonb));
end;
$$;

-- copied from 011_phases_3_to_7.sql
create or replace function public.staff_performance_secure(p_token text, p_from date, p_to date)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
  v_from date := coalesce(p_from, date_trunc('month', public.pos_local_date(now()))::date);
  v_to date := coalesce(p_to, public.pos_local_date(now()));
begin
  select * into c from public.pos_ctx(p_token, 'staff');
  return jsonb_build_object('ok', true, 'rows', coalesce((
    select jsonb_agg(jsonb_build_object(
      'staff', s.name,
      'sales', coalesce((select sum(p.amount) from public.payments p join public.pos_shifts sh on sh.id = p.shift_id
                          where sh.staff_id = s.id and public.pos_local_date(p.created_at) between v_from and v_to), 0),
      'waiter_sales', coalesce((select sum(o.total_amount) from public.orders o
                                 where o.waiter_id = s.id and o.status = 'closed' and public.pos_local_date(o.created_at) between v_from and v_to), 0),
      'voids', (select count(*) from public.order_logs l where l.user_id = s.id and l.action like 'VOID_ITEM%'
                  and public.pos_local_date(l.created_at) between v_from and v_to),
      'discounts', (select count(*) from public.order_logs l where l.user_id = s.id and l.action = 'APPLY_DISCOUNT'
                      and public.pos_local_date(l.created_at) between v_from and v_to),
      'refunds', (select count(*) from public.order_logs l where l.user_id = s.id and l.action = 'REFUND_ORDER'
                    and public.pos_local_date(l.created_at) between v_from and v_to),
      'shift_difference', coalesce((select sum(sh.difference) from public.pos_shifts sh
                                     where sh.staff_id = s.id and sh.status = 'closed' and public.pos_local_date(sh.opened_at) between v_from and v_to), 0),
      'tips', coalesce((select sum(p.tip_amount) from public.payments p
                         where p.tip_staff_id = s.id and public.pos_local_date(p.created_at) between v_from and v_to), 0)) order by s.name)
      from public.staff s
     where s.company_id = c.company_id and (c.role_name = 'owner' or s.branch_id = c.branch_id)), '[]'::jsonb));
end;
$$;

create or replace function public.motionpos_version_public()
returns text
language sql
immutable
as $$
  select '037'
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
  v_src text;
  f text;
begin
  begin
    foreach f in array array['pos_day_report', 'day_report_secure', 'day_close_secure', 'expenses_report_secure', 'inv_ledger_secure',
                             'inv_variance_secure', 'shifts_list_secure', 'staff_performance_secure'] loop
      select pg_get_functiondef(p.oid) into v_src from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = f;
      if position('pos_local_date' in v_src) = 0 or v_src ~ '(created_at|opened_at)::date' or v_src ~ '\mcurrent_date\M' then
        raise exception 'SELFTEST % still uses the calendar date', f;
      end if;
    end loop;
    if public.motionpos_version_public() <> '037' then raise exception 'SELFTEST version'; end if;
    raise notice 'MOTIONPOS-037-SELFTEST-OK';
    raise exception using errcode = 'P0099', message = 'selftest_rollback';
  exception when sqlstate 'P0099' then
    null;
  end;
end;
$selftest$;

notify pgrst, 'reload schema';

commit;
