-- 038_view_period_per_role.sql
-- The owner can limit how far back each role (branch manager, cashier...) may look, per screen:
-- "last N days" up to today (business day, 8 to 8). Screens: dashboard, sales, reports, purchase, expenses, treasury,
-- accounting, inventory, staff, cost. Empty / 0 = no limit. The owner always sees everything.
-- Set in staff > permissions (owner only), kept in app_settings section 'view_days' = {role: {screen: days}}.
-- Checked on the server: a period starting earlier is cut to the allowed start; a period ending before it, or one
-- record / day / month older than it, is refused with reason 'view_limit' (days + first allowed date).
-- New: pos_view_days, pos_view_min, pos_view_refusal, view_days_secure. 26 functions copied from their latest files
-- with only the limit added (see the comment above each). No tables changed.
-- Rules: begin/commit, preflight (needs 037), version bump to 038, grants loop, rolled-back self-test.

begin;

do $preflight$
begin
  if length('إكراميات') <> 8 then
    raise exception 'file_encoding_broken: read the file as UTF-8';
  end if;
  if public.motionpos_version_public() not in ('037', '038') then
    raise exception 'schema_preflight_failed: run 037 first';
  end if;
end;
$preflight$;

create or replace function public.pos_view_areas()
returns text[]
language sql
immutable
as $$
  select array['dashboard', 'sales', 'reports', 'purchase', 'expenses', 'treasury', 'accounting', 'inventory', 'staff', 'cost']
$$;

-- {screen: days} of a role (empty for the owner)
create or replace function public.pos_view_days(p_company_id uuid, p_role text)
returns jsonb
language sql
stable
security definer
set search_path = public, extensions
as $$
  select case when p_role = 'owner' then '{}'::jsonb else coalesce((
    select jsonb_object_agg(e.key, (e.value #>> '{}')::int)
      from public.app_settings s, jsonb_each(coalesce(s.data -> p_role, '{}'::jsonb)) e
     where s.company_id = p_company_id and s.section = 'view_days'
       and e.key = any (public.pos_view_areas()) and (e.value #>> '{}') ~ '^[0-9]{1,4}$' and (e.value #>> '{}')::int > 0), '{}'::jsonb) end
$$;

-- first business day this role may see on this screen (null = no limit). 1 day = today only.
create or replace function public.pos_view_min(p_company_id uuid, p_role text, p_area text)
returns date
language sql
stable
security definer
set search_path = public, extensions
as $$
  select public.pos_local_date(now()) - ((public.pos_view_days(p_company_id, p_role) ->> p_area)::int - 1)
$$;

create or replace function public.pos_view_refusal(p_company_id uuid, p_role text, p_area text)
returns jsonb
language sql
stable
security definer
set search_path = public, extensions
as $$
  select jsonb_build_object('ok', false, 'reason', 'view_limit',
                            'days', (public.pos_view_days(p_company_id, p_role) ->> p_area)::int,
                            'min_date', public.pos_view_min(p_company_id, p_role, p_area))
$$;

-- owner: read all roles' limits, or save one role's {screen: days}
create or replace function public.view_days_secure(p_token text, p_role text, p_days jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
  v_clean jsonb := '{}'::jsonb;
  e record;
begin
  select * into c from public.pos_ctx(p_token, null);
  if c.role_name <> 'owner' then
    return jsonb_build_object('ok', false, 'reason', 'owner_only');
  end if;
  if p_days is not null then
    if p_role is null or p_role = 'owner' or not exists (select 1 from public.roles r where r.name = p_role) then
      return jsonb_build_object('ok', false, 'reason', 'invalid_role');
    end if;
    if jsonb_typeof(p_days) <> 'object' then
      return jsonb_build_object('ok', false, 'reason', 'invalid_value');
    end if;
    for e in select x.key, x.value from jsonb_each(p_days) x loop
      if not (e.key = any (public.pos_view_areas())) then
        return jsonb_build_object('ok', false, 'reason', 'invalid_value', 'key', e.key);
      end if;
      if jsonb_typeof(e.value) = 'null' or (e.value #>> '{}') = '' then
        continue;
      end if;
      if (e.value #>> '{}') !~ '^[0-9]{1,4}$' or (e.value #>> '{}')::int > 3650 then
        return jsonb_build_object('ok', false, 'reason', 'invalid_value', 'key', e.key);
      end if;
      if (e.value #>> '{}')::int > 0 then
        v_clean := v_clean || jsonb_build_object(e.key, (e.value #>> '{}')::int);
      end if;
    end loop;
    insert into public.app_settings (company_id, section, data, updated_by)
    values (c.company_id, 'view_days', jsonb_build_object(p_role, v_clean), c.staff_id)
    on conflict (company_id, section)
    do update set data = public.app_settings.data || excluded.data, updated_at = now(), updated_by = excluded.updated_by;
    insert into public.settings_logs (staff_id, action, details)
    values (c.staff_id, 'view_days', jsonb_build_object('role', p_role, 'days', v_clean));
  end if;
  return jsonb_build_object('ok', true, 'areas', to_jsonb(public.pos_view_areas()),
    'roles', coalesce((select jsonb_object_agg(r.name, public.pos_view_days(c.company_id, r.name))
                         from public.roles r where r.name <> 'owner'), '{}'::jsonb));
end;
$$;

-- dashboard_secure: copied from 021_phase15_owner_features.sql + the period limit
create or replace function public.dashboard_secure(p_token text, p_from date, p_to date, p_branch_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_lim date;
  c record;
  v_branch uuid;
  v_from date := coalesce(p_from, public.pos_local_date(now()));
  v_to date := coalesce(p_to, public.pos_local_date(now()));
  v_len int;
  v_pfrom date;
  v_pto date;
  v_res jsonb;
begin
  select * into c from public.pos_ctx(p_token, 'dashboard');
  -- the period this role may look at (settings > staff > permissions); null = everything
  v_lim := public.pos_view_min(c.company_id, c.role_name, 'dashboard');
  if v_lim is not null then
    if v_to < v_lim then
      return public.pos_view_refusal(c.company_id, c.role_name, 'dashboard');
    end if;
    v_from := greatest(v_from, v_lim);
  end if;
  v_branch := c.branch_id;
  if c.role_name = 'owner' then
    v_branch := p_branch_id;
  end if;
  if v_to < v_from or v_to - v_from > 366 then
    return jsonb_build_object('ok', false, 'reason', 'invalid_period');
  end if;
  v_len := v_to - v_from + 1;
  v_pto := v_from - 1;
  v_pfrom := v_from - v_len;

  with cur as (select * from public.pos_rpt_orders(c.company_id, v_branch, v_from, v_to)),
       prv as (select * from public.pos_rpt_orders(c.company_id, v_branch, v_pfrom, v_pto)),
       items as (select oi.*, o.created_at as order_at from cur o join public.order_items oi on oi.order_id = o.id
                  where coalesce(oi.status, 'active') = 'active'),
       mv as (select sm.movement_type, sm.total_cost, sm.created_at from public.stock_movements sm
               where sm.company_id = c.company_id and (v_branch is null or sm.branch_id = v_branch)
                 and public.pos_local_date(sm.created_at) between v_pfrom and v_to and sm.movement_type in ('sale', 'waste'))
  select jsonb_build_object(
    'kpi', jsonb_build_object(
      'sales', (select coalesce(sum(total_amount), 0) from cur),
      'orders', (select count(*) from cur),
      'avg_ticket', (select round(coalesce(avg(total_amount), 0), 2) from cur),
      'guests', (select coalesce(sum(coalesce(guest_count, 1)), 0) from cur),
      'discounts', (select coalesce(sum(discount_amount), 0) from cur),
      'tax', (select coalesce(sum(tax_amount), 0) from cur),
      'service', (select coalesce(sum(service_charge_amount), 0) from cur),
      'revenue', (select coalesce(sum(total_amount - tax_amount), 0) from cur),
      'cogs', (select coalesce(sum(total_cost), 0) from mv where movement_type = 'sale' and public.pos_local_date(created_at) between v_from and v_to),
      'waste', (select coalesce(sum(total_cost), 0) from mv where movement_type = 'waste' and public.pos_local_date(created_at) between v_from and v_to),
      'tips', (select coalesce(sum(p.tip_amount), 0) from public.payments p join cur o on o.id = p.order_id),
      'cancelled', (select count(*) from public.orders o where o.company_id = c.company_id and o.status = 'cancelled'
                      and (v_branch is null or o.branch_id = v_branch) and public.pos_local_date(o.created_at) between v_from and v_to),
      'qr_orders', (select count(*) from cur where source = 'qr'),
      'new_customers', (select count(*) from public.customers cu where cu.company_id = c.company_id
                          and public.pos_local_date(cu.created_at) between v_from and v_to),
      'repeat_customers', (select count(distinct o.customer_id) from cur o where o.customer_id is not null
                             and exists (select 1 from public.orders x where x.customer_id = o.customer_id and x.status = 'closed'
                                           and x.created_at < o.created_at)),
      'with_customer', (select count(*) from cur where customer_id is not null)),
    'prev', jsonb_build_object(
      'sales', (select coalesce(sum(total_amount), 0) from prv),
      'orders', (select count(*) from prv),
      'avg_ticket', (select round(coalesce(avg(total_amount), 0), 2) from prv),
      'guests', (select coalesce(sum(coalesce(guest_count, 1)), 0) from prv),
      'revenue', (select coalesce(sum(total_amount - tax_amount), 0) from prv),
      'cogs', (select coalesce(sum(total_cost), 0) from mv where movement_type = 'sale' and public.pos_local_date(created_at) between v_pfrom and v_pto),
      'waste', (select coalesce(sum(total_cost), 0) from mv where movement_type = 'waste' and public.pos_local_date(created_at) between v_pfrom and v_pto)),
    'daily', coalesce((select jsonb_agg(jsonb_build_object('day', g.d::date, 'sales', coalesce(x.sales, 0), 'orders', coalesce(x.orders, 0),
                                                         'revenue', coalesce(x.revenue, 0)) order by g.d)
                         from generate_series(v_from, v_to, interval '1 day') g(d)
                         left join (select public.pos_local_date(created_at) as day, sum(total_amount) as sales, count(*) as orders,
                                           sum(total_amount - tax_amount) as revenue from cur group by 1) x on x.day = g.d::date), '[]'::jsonb),
    'hourly', coalesce((select jsonb_agg(jsonb_build_object('hour', h.h, 'sales', coalesce(x.sales, 0), 'orders', coalesce(x.orders, 0)) order by h.h)
                          from generate_series(0, 23) h(h)
                          left join (select extract(hour from created_at at time zone 'Africa/Cairo')::int as hr, sum(total_amount) as sales,
                                            count(*) as orders from cur group by 1) x on x.hr = h.h), '[]'::jsonb),
    'weekday', coalesce((select jsonb_agg(jsonb_build_object('d', w.d, 'sales', coalesce(x.sales, 0), 'orders', coalesce(x.orders, 0)) order by w.d)
                           from generate_series(0, 6) w(d)
                           left join (select extract(dow from created_at at time zone 'Africa/Cairo')::int as dw, sum(total_amount) as sales,
                                             count(*) as orders from cur group by 1) x on x.dw = w.d), '[]'::jsonb),
    'payments', coalesce((select jsonb_agg(jsonb_build_object('method', q.method, 'amount', q.amount) order by q.amount desc)
                            from (select p.payment_method as method, sum(p.amount) as amount from public.payments p join cur o on o.id = p.order_id
                                   group by 1) q), '[]'::jsonb),
    'order_types', coalesce((select jsonb_agg(jsonb_build_object('type', q.order_type, 'amount', q.amount, 'orders', q.orders) order by q.amount desc)
                               from (select order_type, sum(total_amount) as amount, count(*) as orders from cur group by 1) q), '[]'::jsonb),
    'categories', coalesce((select jsonb_agg(jsonb_build_object('name', q.name, 'amount', q.amount, 'qty', q.qty) order by q.amount desc)
                              from (select coalesce(cat.name, '-') as name, sum(i.total_price) as amount, sum(i.quantity) as qty
                                      from items i left join public.products p on p.id = i.product_id
                                      left join public.categories cat on cat.id = p.category_id group by 1) q), '[]'::jsonb),
    'top_products', coalesce((select jsonb_agg(jsonb_build_object('name', q.name, 'qty', q.qty, 'amount', q.amount, 'cost', q.cost,
                                                                 'has_recipe', q.has_recipe) order by q.amount desc)
                                from (select coalesce(p.name, '-') as name, sum(i.quantity) as qty, sum(i.total_price) as amount,
                                             round(sum(i.quantity) * public.pos_product_cost(i.product_id), 2) as cost,
                                             exists (select 1 from public.recipes r where r.product_id = i.product_id) as has_recipe
                                        from items i left join public.products p on p.id = i.product_id
                                       group by p.name, i.product_id order by sum(i.total_price) desc limit 10) q), '[]'::jsonb),
    'slow_products', coalesce((select jsonb_agg(jsonb_build_object('name', q.name, 'qty', q.qty) order by q.qty)
                                 from (select p.name, coalesce((select sum(i.quantity) from items i where i.product_id = p.id), 0) as qty
                                         from public.products p
                                         join public.branches b on b.brand_id = p.brand_id and (v_branch is null or b.id = v_branch)
                                        where p.is_available is true
                                        group by p.id, p.name order by 2, p.name limit 5) q), '[]'::jsonb),
    'waiters', coalesce((select jsonb_agg(jsonb_build_object('name', q.name, 'amount', q.amount, 'orders', q.orders) order by q.amount desc)
                           from (select coalesce(w.name, 'بدون ويتر') as name, sum(o.total_amount) as amount, count(*) as orders
                                   from cur o left join public.staff w on w.id = o.waiter_id group by 1 order by 2 desc limit 8) q), '[]'::jsonb),
    'top_customers', coalesce((select jsonb_agg(jsonb_build_object('name', q.name, 'amount', q.amount, 'orders', q.orders) order by q.amount desc)
                                 from (select cu.name, sum(o.total_amount) as amount, count(*) as orders
                                         from cur o join public.customers cu on cu.id = o.customer_id group by cu.id, cu.name
                                        order by 2 desc limit 5) q), '[]'::jsonb),
    'prep', coalesce((select jsonb_agg(jsonb_build_object('station', q.station, 'items', q.items, 'avg_minutes', q.avg_m, 'late_pct', q.late_pct)
                                       order by q.station)
                        from (select public.pos_item_station(i.product_id) as station, count(*) as items,
                                     round(avg(extract(epoch from (i.ready_at - i.sent_at)) / 60.0)::numeric, 1) as avg_m,
                                     round(100.0 * count(*) filter (where extract(epoch from (i.ready_at - i.sent_at)) / 60.0
                                            > public.pos_station_warn(c.company_id, public.pos_item_station(i.product_id)) + coalesce(i.prep_extra_minutes, 0))
                                           / nullif(count(*), 0), 1) as late_pct
                                from items i where i.ready_at is not null and i.sent_at is not null group by 1) q), '[]'::jsonb),
    'feedback', (select jsonb_build_object('count', count(*), 'complaints', count(*) filter (where f.kind = 'complaint'),
                                           'avg_rating', round(avg(f.rating), 1), 'open', count(*) filter (where f.status <> 'closed'))
                   from public.customer_feedback f where f.company_id = c.company_id and (v_branch is null or f.branch_id = v_branch)
                    and public.pos_local_date(f.created_at) between v_from and v_to),
    'no_recipe', (select count(*) from public.products p
                   where p.is_available is true and not exists (select 1 from public.recipes r where r.product_id = p.id)
                     and exists (select 1 from public.branches b where b.brand_id = p.brand_id and (v_branch is null or b.id = v_branch)))
  ) into v_res;

  -- what is happening right now
  v_res := v_res || jsonb_build_object('live', jsonb_build_object(
    'open_orders', (select count(*) from public.orders o where o.company_id = c.company_id and (v_branch is null or o.branch_id = v_branch)
                      and coalesce(o.status, '') not in ('paid', 'closed', 'cancelled') and o.created_at > now() - interval '24 hours'),
    'open_value', (select coalesce(sum(o.total_amount), 0) from public.orders o where o.company_id = c.company_id
                     and (v_branch is null or o.branch_id = v_branch)
                     and coalesce(o.status, '') not in ('paid', 'closed', 'cancelled') and o.created_at > now() - interval '24 hours'),
    'tables_busy', (select count(*) from public.tables t join public.areas a on a.id = t.area_id
                     where (v_branch is null or a.branch_id = v_branch) and t.status = 'occupied'
                       and a.branch_id in (select b.id from public.branches b join public.brands br on br.id = b.brand_id where br.company_id = c.company_id)),
    'tables_total', (select count(*) from public.tables t join public.areas a on a.id = t.area_id
                      where (v_branch is null or a.branch_id = v_branch)
                        and a.branch_id in (select b.id from public.branches b join public.brands br on br.id = b.brand_id where br.company_id = c.company_id)),
    'open_shifts', (select count(*) from public.pos_shifts s where s.company_id = c.company_id and (v_branch is null or s.branch_id = v_branch)
                      and s.closed_at is null),
    'qr_waiting', (select count(*) from public.qr_orders q where q.company_id = c.company_id and (v_branch is null or q.branch_id = v_branch)
                     and q.status = 'pending' and q.created_at > now() - interval '12 hours'),
    'low_stock', (select count(*) from public.ingredients i
                   where coalesce(i.min_stock_alert, 0) > 0
                     and coalesce((select sum(ws.quantity) from public.warehouse_stock ws join public.warehouses w on w.id = ws.warehouse_id
                                    where ws.ingredient_id = i.id and (v_branch is null or w.branch_id = v_branch)), 0) < i.min_stock_alert
                     and exists (select 1 from public.branches b join public.brands br on br.id = b.brand_id
                                  where br.company_id = c.company_id and b.brand_id = i.brand_id))),
    'month', public.pos_pnl_month(c.company_id, v_branch, v_to),
    'from', v_from, 'to', v_to, 'prev_from', v_pfrom, 'prev_to', v_pto,
    'branch', coalesce((select b.name from public.branches b where b.id = v_branch), 'كل الفروع'),
    'branches', case when c.role_name = 'owner' then (select coalesce(jsonb_agg(jsonb_build_object('id', b.id, 'name', b.name) order by b.name), '[]'::jsonb)
                                                       from public.branches b join public.brands br on br.id = b.brand_id
                                                      where br.company_id = c.company_id) else '[]'::jsonb end,
    'can_pick_branch', c.role_name = 'owner');
  return jsonb_build_object('ok', true) || v_res;
end;
$$;

-- sales_orders_secure: copied from 021_phase15_owner_features.sql + the period limit
create or replace function public.sales_orders_secure(p_token text, p_from date, p_to date, p_branch_id uuid, p_filters jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_lim date;
  c record;
  f jsonb := coalesce(p_filters, '{}'::jsonb);
  v_from date := coalesce(p_from, public.pos_local_date(now()));
  v_to date := coalesce(p_to, public.pos_local_date(now()));
  v_branch uuid;
  v_state text := coalesce(nullif(f->>'status', ''), 'all');
  v_type text := nullif(f->>'order_type', '');
  v_waiter uuid := public.pos_uuid(f->>'waiter_id');
  v_cashier uuid := public.pos_uuid(f->>'cashier_id');
  v_q text := nullif(btrim(coalesce(f->>'search', '')), '');
  v_digits text := public.pos_phone_norm(f->>'search');
  v_late boolean := coalesce(f->>'late_only', '') = 'true';
  v_wk numeric;
  v_wb numeric;
  v_ws numeric;
  v_res jsonb;
begin
  select * into c from public.pos_ctx(p_token, 'sales');
  -- the period this role may look at (settings > staff > permissions); null = everything
  v_lim := public.pos_view_min(c.company_id, c.role_name, 'sales');
  if v_lim is not null then
    if v_to < v_lim then
      return public.pos_view_refusal(c.company_id, c.role_name, 'sales');
    end if;
    v_from := greatest(v_from, v_lim);
  end if;
  v_branch := c.branch_id;
  if c.role_name = 'owner' then
    v_branch := p_branch_id;
  end if;
  if v_to < v_from or v_to - v_from > 366 then
    return jsonb_build_object('ok', false, 'reason', 'invalid_period');
  end if;
  if v_state not in ('all', 'closed', 'open', 'cancelled') then
    return jsonb_build_object('ok', false, 'reason', 'invalid_value');
  end if;
  v_wk := public.pos_station_warn(c.company_id, 'kitchen');
  v_wb := public.pos_station_warn(c.company_id, 'bar');
  v_ws := public.pos_station_warn(c.company_id, 'shisha');

  v_res := (
    with base as (
      select o.id, o.order_number, o.created_at, o.closed_at, o.order_type, o.status, o.total_amount, o.discount_amount,
             o.branch_id, b.name as branch, t.table_number, w.name as waiter, cu.name as customer, cu.phone as customer_phone
        from public.orders o
        left join public.branches b on b.id = o.branch_id
        left join public.tables t on t.id = o.table_id
        left join public.staff w on w.id = o.waiter_id
        left join public.customers cu on cu.id = o.customer_id
       where o.company_id = c.company_id
         and (v_branch is null or o.branch_id = v_branch)
         and public.pos_local_date(o.created_at) between v_from and v_to
         and (v_state = 'all'
              or (v_state = 'closed' and o.status in ('closed', 'paid'))
              or (v_state = 'cancelled' and o.status = 'cancelled')
              or (v_state = 'open' and coalesce(o.status, '') not in ('closed', 'paid', 'cancelled')))
         and (v_type is null or o.order_type = v_type)
         and (v_waiter is null or o.waiter_id = v_waiter)
         and (v_cashier is null or exists (select 1 from public.payments p join public.pos_shifts sh on sh.id = p.shift_id
                                            where p.order_id = o.id and sh.staff_id = v_cashier))
         and (v_q is null or o.order_number ilike '%' || v_q || '%' or cu.name ilike '%' || v_q || '%'
              or t.table_number = v_q
              or (length(v_digits) >= 3 and public.pos_phone_norm(cu.phone) like '%' || v_digits || '%'))
    ), calc as (
      select bs.*, it.items_count, it.first_sent, it.last_ready, it.unready, it.late_items,
             case when it.items_count > 0 and it.unready = 0 and it.first_sent is not null
                  then round((extract(epoch from (it.last_ready - it.first_sent)) / 60.0)::numeric, 1) end as prep_minutes,
             (select string_agg(distinct p.payment_method, ',') from public.payments p where p.order_id = bs.id) as methods,
             (select st.name from public.payments p join public.pos_shifts sh on sh.id = p.shift_id
                join public.staff st on st.id = sh.staff_id where p.order_id = bs.id order by p.created_at limit 1) as cashier,
             (select st.name from public.order_logs l join public.staff st on st.id = l.user_id
               where l.order_id = bs.id and l.action in ('SEND_TO_KITCHEN', 'SPLIT_FROM') order by l.created_at limit 1) as created_by
        from base bs
        left join lateral (
          select coalesce(sum(oi.quantity), 0) as items_count, min(oi.sent_at) as first_sent, max(oi.ready_at) as last_ready,
                 count(*) filter (where oi.ready_at is null) as unready,
                 count(*) filter (where oi.sent_at is not null
                                    and extract(epoch from (coalesce(oi.ready_at,
                                          case when bs.status in ('closed', 'paid', 'cancelled') then null else now() end) - oi.sent_at)) / 60.0
                                        > (case public.pos_item_station(oi.product_id) when 'kitchen' then v_wk when 'bar' then v_wb else v_ws end) + coalesce(oi.prep_extra_minutes, 0)
                                 ) as late_items
            from public.order_items oi
           where oi.order_id = bs.id and coalesce(oi.status, 'active') = 'active'
        ) it on true
    ), fin as (
      select * from calc where (not v_late or late_items > 0)
    )
    select jsonb_build_object(
      'rows', coalesce((select jsonb_agg(jsonb_build_object(
                  'id', r.id, 'order_number', r.order_number, 'created_at', r.created_at, 'closed_at', r.closed_at,
                  'order_type', r.order_type, 'status', r.status, 'total_amount', r.total_amount, 'discount_amount', r.discount_amount,
                  'branch', r.branch, 'table_number', r.table_number, 'waiter', r.waiter, 'customer', r.customer,
                  'customer_phone', r.customer_phone, 'items_count', r.items_count, 'prep_minutes', r.prep_minutes,
                  'late', r.late_items > 0, 'methods', r.methods, 'cashier', r.cashier, 'created_by', r.created_by)
                  order by r.created_at desc)
                 from (select * from fin order by created_at desc limit 1000) r), '[]'::jsonb),
      'summary', (select jsonb_build_object(
                    'count', count(*),
                    'closed_count', count(*) filter (where status in ('closed', 'paid')),
                    'closed_total', coalesce(sum(total_amount) filter (where status in ('closed', 'paid')), 0),
                    'avg_ticket', round(coalesce(avg(total_amount) filter (where status in ('closed', 'paid')), 0), 2),
                    'open_count', count(*) filter (where coalesce(status, '') not in ('closed', 'paid', 'cancelled')),
                    'cancelled_count', count(*) filter (where status = 'cancelled'),
                    'late_count', count(*) filter (where late_items > 0),
                    'avg_prep', round(avg(prep_minutes), 1))
                    from fin))
  );

  return jsonb_build_object('ok', true, 'from', v_from, 'to', v_to,
    'branch', coalesce((select b.name from public.branches b where b.id = v_branch), 'كل الفروع'),
    'warn', jsonb_build_object('kitchen', v_wk, 'bar', v_wb, 'shisha', v_ws),
    'staff', coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name, 'role', r.name) order by s.name)
                         from public.staff s left join public.roles r on r.id = s.role_id
                        where s.company_id = c.company_id and (v_branch is null or s.branch_id = v_branch)
                          and r.name in ('waiter', 'cashier', 'branch_manager', 'owner')), '[]'::jsonb))
    || v_res;
end;
$$;

-- sales_timing_secure: copied from 021_phase15_owner_features.sql + the period limit
create or replace function public.sales_timing_secure(p_token text, p_from date, p_to date, p_branch_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_lim date;
  c record;
  v_from date := coalesce(p_from, public.pos_local_date(now()) - 6);
  v_to date := coalesce(p_to, public.pos_local_date(now()));
  v_branch uuid;
  v_wk numeric;
  v_wb numeric;
  v_ws numeric;
  v_res jsonb;
begin
  select * into c from public.pos_ctx(p_token, 'sales');
  -- the period this role may look at (settings > staff > permissions); null = everything
  v_lim := public.pos_view_min(c.company_id, c.role_name, 'sales');
  if v_lim is not null then
    if v_to < v_lim then
      return public.pos_view_refusal(c.company_id, c.role_name, 'sales');
    end if;
    v_from := greatest(v_from, v_lim);
  end if;
  v_branch := c.branch_id;
  if c.role_name = 'owner' then
    v_branch := p_branch_id;
  end if;
  if v_to < v_from or v_to - v_from > 366 then
    return jsonb_build_object('ok', false, 'reason', 'invalid_period');
  end if;
  v_wk := public.pos_station_warn(c.company_id, 'kitchen');
  v_wb := public.pos_station_warn(c.company_id, 'bar');
  v_ws := public.pos_station_warn(c.company_id, 'shisha');

  v_res := (
    with it as (
      select oi.id, oi.order_id, o.order_number, o.created_at as order_created, t.table_number, w.name as waiter,
             coalesce(p.name, 'صنف') as product, oi.quantity, public.pos_item_station(oi.product_id) as station, oi.sent_at,
             extract(hour from (oi.sent_at at time zone 'Africa/Cairo'))::int as hour,
             extract(epoch from (oi.prep_started_at - oi.sent_at)) / 60.0 as wait_m,
             extract(epoch from (oi.ready_at - oi.prep_started_at)) / 60.0 as prep_m,
             extract(epoch from (oi.ready_at - oi.sent_at)) / 60.0 as total_m,
             coalesce(oi.prep_extra_minutes, 0) as extra_m
        from public.order_items oi
        join public.orders o on o.id = oi.order_id
        left join public.products p on p.id = oi.product_id
        left join public.tables t on t.id = o.table_id
        left join public.staff w on w.id = o.waiter_id
       where o.company_id = c.company_id and (v_branch is null or o.branch_id = v_branch)
         and public.pos_local_date(oi.sent_at) between v_from and v_to
         and coalesce(oi.status, 'active') = 'active' and oi.ready_at is not null and oi.sent_at is not null
    ), lim as (
      select it.*, (case it.station when 'kitchen' then v_wk when 'bar' then v_wb else v_ws end) + it.extra_m as limit_m from it
    )
    select jsonb_build_object(
      'by_station', coalesce((select jsonb_agg(jsonb_build_object(
                       'station', s.station, 'items', s.items, 'avg_wait', s.avg_wait, 'avg_prep', s.avg_prep, 'avg_total', s.avg_total,
                       'max_total', s.max_total, 'late_items', s.late_items, 'late_pct', s.late_pct, 'limit', s.limit_m) order by s.station)
                       from (select station, max(limit_m) as limit_m, count(*) as items,
                                    round(avg(wait_m)::numeric, 1) as avg_wait, round(avg(prep_m)::numeric, 1) as avg_prep,
                                    round(avg(total_m)::numeric, 1) as avg_total, round(max(total_m)::numeric, 1) as max_total,
                                    count(*) filter (where total_m > limit_m) as late_items,
                                    round(100.0 * count(*) filter (where total_m > limit_m) / count(*), 1) as late_pct
                               from lim group by station) s), '[]'::jsonb),
      'by_product', coalesce((select jsonb_agg(jsonb_build_object(
                       'product', s.product, 'station', s.station, 'items', s.items, 'avg_total', s.avg_total,
                       'max_total', s.max_total, 'late_items', s.late_items, 'late_pct', s.late_pct) order by s.avg_total desc)
                       from (select product, station, count(*) as items, round(avg(total_m)::numeric, 1) as avg_total,
                                    round(max(total_m)::numeric, 1) as max_total, count(*) filter (where total_m > limit_m) as late_items,
                                    round(100.0 * count(*) filter (where total_m > limit_m) / count(*), 1) as late_pct
                               from lim group by product, station order by avg(total_m) desc limit 60) s), '[]'::jsonb),
      'by_hour', coalesce((select jsonb_agg(jsonb_build_object('hour', s.hour, 'items', s.items, 'avg_total', s.avg_total,
                                                               'late_items', s.late_items) order by s.hour)
                       from (select hour, count(*) as items, round(avg(total_m)::numeric, 1) as avg_total,
                                    count(*) filter (where total_m > limit_m) as late_items
                               from lim group by hour) s), '[]'::jsonb),
      'late_orders', coalesce((select jsonb_agg(jsonb_build_object(
                       'order_id', s.order_id, 'order_number', s.order_number, 'created_at', s.order_created,
                       'table_number', s.table_number, 'waiter', s.waiter, 'station', s.station, 'products', s.products,
                       'minutes', s.minutes, 'limit', s.limit_m) order by s.minutes desc)
                       from (select order_id, order_number, order_created, table_number, waiter, station, max(limit_m) as limit_m,
                                    string_agg(distinct product, '، ') as products, round(max(total_m)::numeric, 1) as minutes
                               from lim where total_m > limit_m
                              group by order_id, order_number, order_created, table_number, waiter, station
                              order by max(total_m) desc limit 100) s), '[]'::jsonb))
  );
  return jsonb_build_object('ok', true, 'from', v_from, 'to', v_to,
    'branch', coalesce((select b.name from public.branches b where b.id = v_branch), 'كل الفروع'),
    'warn', jsonb_build_object('kitchen', v_wk, 'bar', v_wb, 'shisha', v_ws)) || v_res;
end;
$$;

-- report_secure: copied from 034_business_day_cancel_charge_small_po.sql + the period limit
create or replace function public.report_secure(p_token text, p_key text, p_from date, p_to date, p_branch_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_lim date;
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
  -- the period this role may look at (settings > staff > permissions); null = everything
  v_lim := public.pos_view_min(c.company_id, c.role_name, 'reports');
  if v_lim is not null then
    if v_to < v_lim then
      return public.pos_view_refusal(c.company_id, c.role_name, 'reports');
    end if;
    v_from := greatest(v_from, v_lim);
  end if;
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
             when 'CHANGE_CHARGES' then 'شيل خدمة/ضريبة' when 'REFUND_ORDER' then 'مرتجع' when 'CANCEL_ORDER' then 'إلغاء طلب' when 'HOSPITALITY' then 'ضيافة'
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
                         and sm.movement_type in ('sale', 'waste', 'hospitality') and (v_branch is null or sm.branch_id = v_branch)
                         and public.pos_local_date(sm.created_at) between v_from and v_to), 0) as used,
             coalesce((select sum(ws.quantity) from public.warehouse_stock ws join public.warehouses w on w.id = ws.warehouse_id
                        where ws.ingredient_id = i.id and (v_branch is null or w.branch_id = v_branch)), 0) as current,
             round(coalesce((select sum(ws.quantity) from public.warehouse_stock ws join public.warehouses w on w.id = ws.warehouse_id
                              where ws.ingredient_id = i.id and (v_branch is null or w.branch_id = v_branch)), 0)
                   / nullif(coalesce((select -sum(sm.quantity) from public.stock_movements sm where sm.ingredient_id = i.id
                         and sm.movement_type in ('sale', 'waste', 'hospitality') and (v_branch is null or sm.branch_id = v_branch)
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

  when 'order_cancellations' then
    v_title := 'الطلبات الملغية (تفاصيل كاملة)';
    v_cols := public.pos_cols(array['at','order_number','order_type','table_number','waiter','by_staff','manager','reason','items_voided','voided_value','total','customer','cust_prior','cust_90d'],
      array['الوقت','الطلب','النوع','الطاولة','الويتر','مين ألغاه','المدير الموافق','السبب','عدد الأصناف الملغية','قيمة الأصناف الملغية','إجمالي الطلب','العميل','إلغاءات سابقة للعميل','منها آخر ٩٠ يوم'], 'ttttttttnmmttt');
    select coalesce(jsonb_agg(to_jsonb(q) order by q.at desc), '[]') into v_rows from (
      select to_char(l.created_at at time zone 'Africa/Cairo', 'YYYY-MM-DD HH24:MI') as at, o.order_number,
             case o.order_type when 'dine_in' then 'صالة' when 'takeaway' then 'تيك أواي' when 'delivery' then 'توصيل' when 'pickup' then 'استلام' else o.order_type end as order_type,
             o.table_number, w.name as waiter, s.name as by_staff, m.name as manager, cr.reason,
             coalesce((l.details->>'items_voided')::numeric, 0) as items_voided,
             (select round(sum((vi.details->>'qty_voided')::numeric * coalesce((vi.details->>'unit_price')::numeric, 0)), 2)
                from public.order_logs vi where vi.order_id = l.order_id and vi.action = 'VOID_ITEM_CANCEL_ORDER') as voided_value,
             coalesce((l.details->>'total_before')::numeric, 0) as total,
             coalesce(cu.name, 'زائر') as customer,
             case when o.customer_id is null then null else
               (select count(*) from public.order_logs l2 join public.orders o2 on o2.id = l2.order_id
                 where l2.action = 'CANCEL_ORDER' and o2.company_id = o.company_id and o2.customer_id = o.customer_id
                   and l2.created_at < l.created_at) end as cust_prior,
             case when o.customer_id is null then null else
               (select count(*) from public.order_logs l2 join public.orders o2 on o2.id = l2.order_id
                 where l2.action = 'CANCEL_ORDER' and o2.company_id = o.company_id and o2.customer_id = o.customer_id
                   and l2.created_at >= l.created_at - interval '90 days' and l2.created_at < l.created_at) end as cust_90d
        from public.order_logs l
        join public.orders o on o.id = l.order_id
        left join public.staff w on w.id = o.waiter_id
        left join public.staff s on s.id = l.user_id
        left join public.staff m on m.id = public.pos_uuid(l.details->>'approved_by_manager_id')
        left join public.cancel_reasons cr on cr.id = public.pos_uuid(l.details->>'reason_id')
        left join public.customers cu on cu.id = o.customer_id
       where l.action = 'CANCEL_ORDER' and o.company_id = c.company_id and (v_branch is null or o.branch_id = v_branch)
         and public.pos_local_date(l.created_at) between v_from and v_to) q;

  when 'cancelled_order_items' then
    v_title := 'أصناف الطلبات الملغية';
    v_cols := public.pos_cols(array['at','order_number','product','qty','unit_price','value','reason','by_staff','manager','customer'],
      array['الوقت','الطلب','الصنف','الكمية','السعر','القيمة','السبب','ألغاه','المدير الموافق','العميل'], 'tttnmmtttt');
    select coalesce(jsonb_agg(to_jsonb(q) order by q.at desc), '[]') into v_rows from (
      select to_char(vi.created_at at time zone 'Africa/Cairo', 'YYYY-MM-DD HH24:MI') as at, o.order_number,
             vi.details->>'product' as product, (vi.details->>'qty_voided')::numeric as qty,
             coalesce((vi.details->>'unit_price')::numeric, 0) as unit_price,
             round((vi.details->>'qty_voided')::numeric * coalesce((vi.details->>'unit_price')::numeric, 0), 2) as value,
             cr.reason, s.name as by_staff, m.name as manager, coalesce(cu.name, 'زائر') as customer
        from public.order_logs vi
        join public.orders o on o.id = vi.order_id
        join public.order_logs cl on cl.order_id = vi.order_id and cl.action = 'CANCEL_ORDER'
        left join public.staff s on s.id = vi.user_id
        left join public.staff m on m.id = public.pos_uuid(vi.details->>'approved_by_manager_id')
        left join public.cancel_reasons cr on cr.id = public.pos_uuid(vi.details->>'reason_id')
        left join public.customers cu on cu.id = o.customer_id
       where vi.action = 'VOID_ITEM_CANCEL_ORDER' and o.company_id = c.company_id and (v_branch is null or o.branch_id = v_branch)
         and public.pos_local_date(vi.created_at) between v_from and v_to) q;

  when 'hospitality' then
    v_title := 'الضيافة';
    v_cols := public.pos_cols(array['at','order_number','category','guest','items','value','cost','account','requested_by','approved_by'],
      array['الوقت','الطلب','النوع','الضيف','عدد الأصناف','القيمة بسعر المنيو','التكلفة','الحساب','طلبها','وافق عليها'], 'ttttnmmttt');
    select coalesce(jsonb_agg(to_jsonb(q) order by q.at desc), '[]') into v_rows from (
      select to_char(h.created_at at time zone 'Africa/Cairo', 'YYYY-MM-DD HH24:MI') as at, o.order_number,
             case h.category when 'owner_guest' then 'ضيف المالك' when 'family' then 'أهل' when 'staff' then 'موظفين'
                             when 'marketing' then 'دعاية' else h.category end as category,
             h.guest_name as guest,
             (select coalesce(sum(oi.quantity), 0) from public.order_items oi
               where oi.order_id = o.id and coalesce(oi.status, 'active') = 'active') as items,
             h.menu_value as value, h.cost, h.account_code as account, rq.name as requested_by, ap.name as approved_by
        from public.hospitality_orders h join public.orders o on o.id = h.order_id
        left join public.staff rq on rq.id = h.requested_by left join public.staff ap on ap.id = h.approved_by
       where h.company_id = c.company_id and (v_branch is null or h.branch_id = v_branch)
         and public.pos_local_date(h.created_at) between v_from and v_to) q;
  -- ---------------------------------------------------------------- staff activity
  when 'staff_activity' then
    v_title := 'حركات الموظفين بالتفصيل';
    v_cols := public.pos_cols(array['at','day','staff','action','order_number','details','amount'],
      array['الوقت','يوم الشغل','الموظف','الحركة','الطلب','التفاصيل','المبلغ'], 'tdttttm');
    select coalesce(jsonb_agg(to_jsonb(q) order by q.ts), '[]') into v_rows from (
      select * from (
        select l.created_at as ts, to_char(l.created_at at time zone 'Africa/Cairo', 'YYYY-MM-DD HH24:MI') as at,
               public.pos_local_date(l.created_at) as day, s.name as staff,
               case l.action when 'SEND_TO_KITCHEN' then 'إرسال للمطبخ' when 'CLOSE_ORDER' then 'دفع وتقفيل طلب'
                 when 'VOID_ITEM' then 'إلغاء صنف' when 'VOID_ITEM_CANCEL_ORDER' then 'إلغاء صنف مع الطلب'
                 when 'CANCEL_ORDER' then 'إلغاء طلب' when 'REFUND_ORDER' then 'مرتجع' when 'REFUND' then 'مرتجع'
                 when 'APPLY_DISCOUNT' then 'خصم' when 'REMOVE_DISCOUNT' then 'شيل خصم' when 'CHANGE_CHARGES' then 'تغيير الخدمة أو الضريبة'
                 when 'TRANSFER_TABLE' then 'نقل طاولة' when 'MERGE_ORDERS' then 'دمج طلبات' when 'MERGED_INTO' then 'اتدمج في طلب تاني'
                 when 'SPLIT_ORDER' then 'تقسيم الحساب' when 'SPLIT_FROM' then 'تقسيم الحساب' when 'HOSPITALITY' then 'ضيافة'
                 when 'UPDATE_ORDER_INFO' then 'تعديل بيانات الطلب' when 'QR_ORDER_ACCEPTED' then 'قبول طلب من المنيو'
                 when 'KITCHEN_STATUS' then 'تغيير حالة التحضير' else l.action end as action,
               o.order_number,
               nullif(concat_ws(' | ', l.details->>'product',
                      case when l.details ? 'qty_voided' then 'الكمية ' || (l.details->>'qty_voided') end,
                      case when mg.name is not null then 'بموافقة ' || mg.name end,
                      case when ch.name is not null then 'على حساب ' || ch.name end), '') as details,
               coalesce(case when l.action like 'VOID_ITEM%' then round(public.pos_num(l.details->>'qty_voided') * coalesce(public.pos_num(l.details->>'unit_price'), 0), 2) end,
                        public.pos_num(l.details->>'amount'), public.pos_num(l.details->>'total_before'),
                        case when l.action in ('CLOSE_ORDER', 'HOSPITALITY') then o.total_amount end) as amount
          from public.order_logs l
          join public.staff s on s.id = l.user_id
          left join public.orders o on o.id = l.order_id
          left join public.staff mg on mg.id = public.pos_uuid(l.details->>'approved_by_manager_id')
          left join public.staff ch on ch.id = public.pos_uuid(l.details->>'charged_staff_id')
         where s.company_id = c.company_id and (v_branch is null or coalesce(o.branch_id, s.branch_id) = v_branch)
           and public.pos_local_date(l.created_at) between v_from and v_to
        union all
        select sh.opened_at, to_char(sh.opened_at at time zone 'Africa/Cairo', 'YYYY-MM-DD HH24:MI'), public.pos_local_date(sh.opened_at),
               st.name, 'فتح وردية', null, 'العهدة', sh.opening_float
          from public.pos_shifts sh join public.staff st on st.id = sh.staff_id
         where sh.company_id = c.company_id and (v_branch is null or sh.branch_id = v_branch)
           and public.pos_local_date(sh.opened_at) between v_from and v_to
        union all
        select sh.closed_at, to_char(sh.closed_at at time zone 'Africa/Cairo', 'YYYY-MM-DD HH24:MI'), public.pos_local_date(sh.closed_at),
               st.name, 'قفل وردية', null, case when sh.difference < 0 then 'عجز' when sh.difference > 0 then 'زيادة' else 'مظبوطة' end, sh.difference
          from public.pos_shifts sh join public.staff st on st.id = sh.staff_id
         where sh.closed_at is not null and sh.company_id = c.company_id and (v_branch is null or sh.branch_id = v_branch)
           and public.pos_local_date(sh.closed_at) between v_from and v_to
        union all
        select m.created_at, to_char(m.created_at at time zone 'Africa/Cairo', 'YYYY-MM-DD HH24:MI'), public.pos_local_date(m.created_at),
               st.name,
               case m.move_type when 'cash_in' then 'فكة داخلة للدرج' when 'drop' then 'توريد من الدرج' when 'tips_payout' then 'صرف إكراميات'
                 when 'expense' then 'مصروف' when 'supplier_payment' then 'دفع لمورد' when 'custody' then 'عهدة' when 'advance' then 'سلفة'
                 when 'treasury_transfer' then 'تحويل خزينة' when 'payroll' then 'مرتبات' when 'shortage' then 'عجز' when 'overage' then 'زيادة'
                 when 'close_handover' then 'تسليم الدرج' else m.move_type end,
               null, nullif(btrim(coalesce(m.reason, '')), ''), m.amount
          from public.pos_cash_moves m join public.staff st on st.id = m.staff_id
         where m.move_type <> 'float' and m.company_id = c.company_id and (v_branch is null or m.branch_id = v_branch)
           and public.pos_local_date(m.created_at) between v_from and v_to
        union all
        select a.clock_in, to_char(a.clock_in at time zone 'Africa/Cairo', 'YYYY-MM-DD HH24:MI'), public.pos_local_date(a.clock_in),
               st.name, 'حضور', null, null, null::numeric
          from public.staff_attendance a join public.staff st on st.id = a.staff_id
         where st.company_id = c.company_id and (v_branch is null or a.branch_id = v_branch)
           and public.pos_local_date(a.clock_in) between v_from and v_to
        union all
        select a.clock_out, to_char(a.clock_out at time zone 'Africa/Cairo', 'YYYY-MM-DD HH24:MI'), public.pos_local_date(a.clock_out),
               st.name, 'انصراف', null, 'اشتغل ' || round(coalesce(a.minutes, 0) / 60.0, 1) || ' ساعة', null::numeric
          from public.staff_attendance a join public.staff st on st.id = a.staff_id
         where a.clock_out is not null and st.company_id = c.company_id and (v_branch is null or a.branch_id = v_branch)
           and public.pos_local_date(a.clock_out) between v_from and v_to
      ) x order by x.ts limit 5000) q;

  when 'staff_summary' then
    v_title := 'ملخص كل موظف';
    v_cols := public.pos_cols(array['staff','role','waiter_orders','waiter_sales','collected','voids','voids_value','cancelled','discounts','charged','hours','first_in','last_out'],
      array['الموظف','الوظيفة','طلبات كويتر','مبيعاته كويتر','قبضه ككاشير','إلغاء أصناف','قيمتها','طلبات ألغاها','خصومات','اتحمل عليه','ساعات الشغل','أول حضور','آخر انصراف'], 'ttnmmnmnmmntt');
    select coalesce(jsonb_agg(to_jsonb(q) order by q.waiter_sales + q.collected desc, q.staff), '[]') into v_rows from (
      select s.name as staff,
        coalesce(case r.name when 'owner' then 'المالك' when 'branch_manager' then 'مدير فرع' when 'cashier' then 'كاشير'
                 when 'waiter' then 'ويتر' when 'storekeeper' then 'أمين مخزن' else r.name end, '') as role,
        (select count(*) from public.pos_rpt_orders(c.company_id, v_branch, v_from, v_to) o where o.waiter_id = s.id) as waiter_orders,
        coalesce((select sum(o.total_amount) from public.pos_rpt_orders(c.company_id, v_branch, v_from, v_to) o where o.waiter_id = s.id), 0) as waiter_sales,
        coalesce((select sum(p.amount) from public.payments p join public.pos_shifts sh on sh.id = p.shift_id
                   where sh.staff_id = s.id and public.pos_local_date(p.created_at) between v_from and v_to), 0) as collected,
        count(l.id) filter (where l.action like 'VOID_ITEM%') as voids,
        coalesce(sum(round(public.pos_num(l.details->>'qty_voided') * coalesce(public.pos_num(l.details->>'unit_price'), 0), 2))
                 filter (where l.action like 'VOID_ITEM%'), 0) as voids_value,
        count(l.id) filter (where l.action = 'CANCEL_ORDER') as cancelled,
        coalesce(sum(public.pos_num(l.details->>'amount')) filter (where l.action = 'APPLY_DISCOUNT'), 0) as discounts,
        coalesce((select sum(sl.amount) from public.staff_ledger sl where sl.staff_id = s.id and sl.entry_type = 'shortage'
                   and public.pos_local_date(sl.created_at) between v_from and v_to), 0) as charged,
        round(coalesce((select sum(a.minutes) from public.staff_attendance a where a.staff_id = s.id
                   and public.pos_local_date(a.clock_in) between v_from and v_to), 0) / 60.0, 1) as hours,
        (select to_char(min(a.clock_in) at time zone 'Africa/Cairo', 'YYYY-MM-DD HH24:MI') from public.staff_attendance a
          where a.staff_id = s.id and public.pos_local_date(a.clock_in) between v_from and v_to) as first_in,
        (select to_char(max(a.clock_out) at time zone 'Africa/Cairo', 'YYYY-MM-DD HH24:MI') from public.staff_attendance a
          where a.staff_id = s.id and public.pos_local_date(a.clock_in) between v_from and v_to) as last_out
        from public.staff s
        left join public.roles r on r.id = s.role_id
        left join public.order_logs l on l.user_id = s.id and public.pos_local_date(l.created_at) between v_from and v_to
       where s.company_id = c.company_id and (v_branch is null or s.branch_id = v_branch)
       group by s.id, s.name, r.name) q;

  else
    return jsonb_build_object('ok', false, 'reason', 'unknown_action');
  end case;

  return jsonb_build_object('ok', true, 'key', p_key, 'title', v_title, 'columns', v_cols, 'rows', coalesce(v_rows, '[]'::jsonb),
    'from', v_from, 'to', v_to,
    'branch', coalesce((select b.name from public.branches b where b.id = v_branch), 'كل الفروع'));
end;
$$;

-- expenses_report_secure: copied from 037_business_day_everywhere.sql + the period limit
create or replace function public.expenses_report_secure(p_token text, p_from date, p_to date)
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
  select * into c from public.pos_ctx(p_token, 'expenses');
  -- the period this role may look at (settings > staff > permissions); null = everything
  v_lim := public.pos_view_min(c.company_id, c.role_name, 'expenses');
  if v_lim is not null then
    if v_to < v_lim then
      return public.pos_view_refusal(c.company_id, c.role_name, 'expenses');
    end if;
    v_from := greatest(v_from, v_lim);
  end if;
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

-- staff_performance_secure: copied from 037_business_day_everywhere.sql + the period limit
create or replace function public.staff_performance_secure(p_token text, p_from date, p_to date)
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
  select * into c from public.pos_ctx(p_token, 'staff');
  -- the period this role may look at (settings > staff > permissions); null = everything
  v_lim := public.pos_view_min(c.company_id, c.role_name, 'staff');
  if v_lim is not null then
    if v_to < v_lim then
      return public.pos_view_refusal(c.company_id, c.role_name, 'staff');
    end if;
    v_from := greatest(v_from, v_lim);
  end if;
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

-- attendance_report_secure: copied from 011_phases_3_to_7.sql + the period limit
create or replace function public.attendance_report_secure(p_token text, p_from date, p_to date)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_lim date;
  c record;
  v_from date := coalesce(p_from, date_trunc('month', current_date)::date);
  v_to date := coalesce(p_to, current_date);
begin
  select * into c from public.pos_ctx(p_token, 'staff');
  -- the period this role may look at (settings > staff > permissions); null = everything
  v_lim := public.pos_view_min(c.company_id, c.role_name, 'staff');
  if v_lim is not null then
    if v_to < v_lim then
      return public.pos_view_refusal(c.company_id, c.role_name, 'staff');
    end if;
    v_from := greatest(v_from, v_lim);
  end if;
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

-- pnl_secure: copied from 012_phases_8_to_11.sql + the period limit
create or replace function public.pnl_secure(p_token text, p_from date, p_to date, p_branch_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_lim date;
  c record;
  v_branch uuid;
  v_from date := coalesce(p_from, date_trunc('month', current_date)::date);
  v_to date := coalesce(p_to, current_date);
  v_rows jsonb;
  v_rev numeric;
  v_cogs numeric;
  v_exp numeric;
begin
  select * into c from public.pos_ctx(p_token, 'accounting');
  -- the period this role may look at (settings > staff > permissions); null = everything
  v_lim := public.pos_view_min(c.company_id, c.role_name, 'accounting');
  if v_lim is not null then
    if v_to < v_lim then
      return public.pos_view_refusal(c.company_id, c.role_name, 'accounting');
    end if;
    v_from := greatest(v_from, v_lim);
  end if;
  v_branch := case when c.role_name = 'owner' then p_branch_id else c.branch_id end;
  select coalesce(jsonb_agg(jsonb_build_object('code', b.code, 'name', b.name, 'type', b.account_type, 'amount', b.balance) order by b.code), '[]'),
         coalesce(sum(b.balance) filter (where b.account_type = 'revenue'), 0),
         coalesce(sum(b.balance) filter (where b.account_type = 'cogs'), 0),
         coalesce(sum(b.balance) filter (where b.account_type = 'expense'), 0)
    into v_rows, v_rev, v_cogs, v_exp
    from public.pos_account_balances(c.company_id, v_from, v_to, v_branch) b
   where b.account_type in ('revenue', 'cogs', 'expense') and b.balance <> 0;
  return jsonb_build_object('ok', true, 'from', v_from, 'to', v_to,
    'branch', coalesce((select x.name from public.branches x where x.id = v_branch), 'كل الفروع'),
    'rows', v_rows, 'revenue', v_rev, 'cogs', v_cogs, 'gross_profit', v_rev - v_cogs, 'expenses', v_exp, 'net_profit', v_rev - v_cogs - v_exp);
end;
$$;

-- general_ledger_secure: copied from 012_phases_8_to_11.sql + the period limit
create or replace function public.general_ledger_secure(p_token text, p_account_id uuid, p_from date, p_to date, p_branch_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_lim date;
  c record;
  v_branch uuid;
  v_from date := coalesce(p_from, date_trunc('month', current_date)::date);
  v_to date := coalesce(p_to, current_date);
  a public.accounts%rowtype;
  v_open numeric;
  v_sign int;
begin
  select * into c from public.pos_ctx(p_token, 'accounting');
  -- the period this role may look at (settings > staff > permissions); null = everything
  v_lim := public.pos_view_min(c.company_id, c.role_name, 'accounting');
  if v_lim is not null then
    if v_to < v_lim then
      return public.pos_view_refusal(c.company_id, c.role_name, 'accounting');
    end if;
    v_from := greatest(v_from, v_lim);
  end if;
  v_branch := case when c.role_name = 'owner' then p_branch_id else c.branch_id end;
  select x.* into a from public.accounts x where x.id = p_account_id and x.company_id = c.company_id;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'not_found');
  end if;
  v_sign := case when a.normal_balance = 'debit' then 1 else -1 end;
  select coalesce(sum(l.debit - l.credit), 0) * v_sign into v_open
    from public.journal_entry_lines l join public.journal_entries je on je.id = l.journal_entry_id
   where l.account_id = a.id and je.status in ('posted', 'reversed') and je.entry_date < v_from
     and (v_branch is null or je.branch_id = v_branch);
  return jsonb_build_object('ok', true, 'account', a.code || ' - ' || a.name_ar, 'opening', v_open, 'lines', coalesce((
    select jsonb_agg(jsonb_build_object('date', q.entry_date, 'entry_number', q.entry_number, 'description', q.description,
             'debit', q.debit, 'credit', q.credit, 'balance', v_open + q.running) order by q.entry_date, q.entry_number, q.rn)
      from (select je.entry_date, je.entry_number, coalesce(l.description, je.description) as description, l.debit, l.credit,
                   row_number() over (order by je.entry_date, je.entry_number, l.id) as rn,
                   sum((l.debit - l.credit) * v_sign) over (order by je.entry_date, je.entry_number, l.id) as running
              from public.journal_entry_lines l join public.journal_entries je on je.id = l.journal_entry_id
             where l.account_id = a.id and je.status in ('posted', 'reversed') and je.entry_date between v_from and v_to
               and (v_branch is null or je.branch_id = v_branch)) q), '[]'::jsonb));
end;
$$;

-- journal_list_secure: copied from 012_phases_8_to_11.sql + the period limit
create or replace function public.journal_list_secure(p_token text, p_from date, p_to date, p_branch_id uuid, p_type text, p_search text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_lim date;
  c record;
  v_branch uuid;
begin
  select * into c from public.pos_ctx(p_token, 'accounting');
  -- the period this role may look at (settings > staff > permissions); null = everything
  v_lim := public.pos_view_min(c.company_id, c.role_name, 'accounting');
  if v_lim is not null then
    if coalesce(p_to, public.pos_local_date(now())) < v_lim then
      return public.pos_view_refusal(c.company_id, c.role_name, 'accounting');
    end if;
    p_from := greatest(coalesce(p_from, v_lim), v_lim);
  end if;
  v_branch := case when c.role_name = 'owner' then p_branch_id else c.branch_id end;
  return jsonb_build_object('ok', true, 'entries', coalesce((
    select jsonb_agg(to_jsonb(q) order by q.entry_date desc, q.entry_number desc) from (
      select je.id, je.entry_number, je.entry_date, je.journal_type, je.reference_type, je.description, je.status,
             b.name as branch, st.name as created_by,
             (select sum(l.debit) from public.journal_entry_lines l where l.journal_entry_id = je.id) as total
        from public.journal_entries je
        left join public.branches b on b.id = je.branch_id
        left join public.staff st on st.id = je.created_by
       where je.company_id = c.company_id
         and je.entry_date between coalesce(p_from, current_date - 30) and coalesce(p_to, current_date)
         and (v_branch is null or je.branch_id = v_branch)
         and (p_type is null or p_type = '' or je.journal_type = p_type)
         and (p_search is null or p_search = '' or je.description ilike '%' || p_search || '%' or je.entry_number ilike '%' || p_search || '%')
       order by je.entry_date desc, je.entry_number desc
       limit 500) q), '[]'::jsonb));
end;
$$;

-- trial_balance_secure: copied from 011_phases_3_to_7.sql + the period limit
create or replace function public.trial_balance_secure(p_token text, p_from date, p_to date)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_lim date;
  c record;
begin
  select * into c from public.pos_ctx(p_token, 'accounting');
  -- the period this role may look at (settings > staff > permissions); null = everything
  v_lim := public.pos_view_min(c.company_id, c.role_name, 'accounting');
  if v_lim is not null then
    if coalesce(p_to, public.pos_local_date(now())) < v_lim then
      return public.pos_view_refusal(c.company_id, c.role_name, 'accounting');
    end if;
    p_from := greatest(coalesce(p_from, v_lim), v_lim);
  end if;
  return jsonb_build_object('ok', true, 'rows', coalesce((
    select jsonb_agg(to_jsonb(t) order by t.account_code)
      from public.get_trial_balance(c.company_id, coalesce(p_from, date_trunc('year', current_date)::date),
                                    coalesce(p_to, current_date)) t), '[]'::jsonb));
end;
$$;

-- shifts_list_secure: copied from 037_business_day_everywhere.sql + the period limit
create or replace function public.shifts_list_secure(p_token text, p_from date, p_to date)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_lim date;
  c record;
begin
  select * into c from public.pos_ctx(p_token, 'treasury');
  -- the period this role may look at (settings > staff > permissions); null = everything
  v_lim := public.pos_view_min(c.company_id, c.role_name, 'treasury');
  if v_lim is not null then
    if coalesce(p_to, public.pos_local_date(now())) < v_lim then
      return public.pos_view_refusal(c.company_id, c.role_name, 'treasury');
    end if;
    p_from := greatest(coalesce(p_from, v_lim), v_lim);
  end if;
  return jsonb_build_object('ok', true, 'shifts', coalesce((
    select jsonb_agg(jsonb_build_object('id', s.id, 'staff', st.name, 'status', s.status, 'opened_at', s.opened_at,
                                        'closed_at', s.closed_at, 'expected_cash', s.expected_cash,
                                        'counted_cash', s.counted_cash, 'difference', s.difference) order by s.opened_at desc)
      from public.pos_shifts s join public.staff st on st.id = s.staff_id
     where (c.role_name = 'owner' or s.branch_id = c.branch_id)
       and public.pos_local_date(s.opened_at) between coalesce(p_from, public.pos_local_date(now()) - 7) and coalesce(p_to, public.pos_local_date(now()))), '[]'::jsonb));
end;
$$;

-- inv_ledger_secure: copied from 037_business_day_everywhere.sql + the period limit
create or replace function public.inv_ledger_secure(
  p_token text, p_warehouse_id uuid, p_ingredient_id uuid, p_from date, p_to date)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_lim date;
  c record;
begin
  select * into c from public.pos_ctx(p_token, 'inventory');
  -- the period this role may look at (settings > staff > permissions); null = everything
  v_lim := public.pos_view_min(c.company_id, c.role_name, 'inventory');
  if v_lim is not null then
    if coalesce(p_to, public.pos_local_date(now())) < v_lim then
      return public.pos_view_refusal(c.company_id, c.role_name, 'inventory');
    end if;
    p_from := greatest(coalesce(p_from, v_lim), v_lim);
  end if;
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

-- inv_variance_secure: copied from 037_business_day_everywhere.sql + the period limit
create or replace function public.inv_variance_secure(p_token text, p_warehouse_id uuid, p_from date, p_to date)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_lim date;
  c record;
begin
  select * into c from public.pos_ctx(p_token, 'inventory');
  -- the period this role may look at (settings > staff > permissions); null = everything
  v_lim := public.pos_view_min(c.company_id, c.role_name, 'inventory');
  if v_lim is not null then
    if coalesce(p_to, public.pos_local_date(now())) < v_lim then
      return public.pos_view_refusal(c.company_id, c.role_name, 'inventory');
    end if;
    p_from := greatest(coalesce(p_from, v_lim), v_lim);
  end if;
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

-- po_list_secure: copied from 011_phases_3_to_7.sql + the period limit
create or replace function public.po_list_secure(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_lim date;
  c record;
begin
  select * into c from public.pos_ctx(p_token, 'purchasing');
  -- the period this role may look at (settings > staff > permissions); null = everything
  v_lim := public.pos_view_min(c.company_id, c.role_name, 'purchase');
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
     where po.company_id = c.company_id and po.created_at > now() - interval '180 days'
       and (v_lim is null or public.pos_local_date(po.created_at) >= v_lim)), '[]'::jsonb));
end;
$$;

-- gr_list_secure: copied from 034_business_day_cancel_charge_small_po.sql + the period limit
create or replace function public.gr_list_secure(p_token text, p_status text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_lim date;
  c record;
begin
  select * into c from public.pos_ctx(p_token, null);
  -- the period this role may look at (settings > staff > permissions); null = everything
  v_lim := public.pos_view_min(c.company_id, c.role_name, 'purchase');
  if c.role_name <> 'owner' and not exists (select 1 from public.role_permissions rp where rp.role_name = c.role_name and rp.perm in ('purchasing', 'po_post', 'po_receive')) then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  return jsonb_build_object('ok', true,
    'can_post', public.pos_perm_ok(c.role_name, 'po_post'), 'can_receive', public.pos_perm_ok(c.role_name, 'po_receive'),
    'receipts', coalesce((
    select jsonb_agg(jsonb_build_object('id', g.id, 'grn_number', g.grn_number, 'status', g.status, 'received_at', g.received_at,
             'posted_at', g.posted_at, 'po_number', po.po_number, 'supplier', s.name, 'warehouse', w.name, 'notes', g.notes,
             'received_by', rb.name, 'posted_by', pb.name,
             'small_post', c.role_name = 'branch_manager' and public.pos_gr_small(g.id, c.company_id),
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
       and g.received_at > now() - interval '120 days'
       and (v_lim is null or public.pos_local_date(g.received_at) >= v_lim)), '[]'::jsonb));
end;
$$;

-- price_history_secure: copied from 011_phases_3_to_7.sql + the period limit
create or replace function public.price_history_secure(p_token text, p_ingredient_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_lim date;
  c record;
begin
  select * into c from public.pos_ctx(p_token, 'purchasing');
  -- the period this role may look at (settings > staff > permissions); null = everything
  v_lim := public.pos_view_min(c.company_id, c.role_name, 'purchase');
  return jsonb_build_object('ok', true, 'history', coalesce((
    select jsonb_agg(jsonb_build_object('at', g.received_at, 'supplier', s.name, 'unit_cost', gi.unit_cost,
                                        'qty', gi.received_qty, 'grn', g.grn_number) order by g.received_at desc)
      from public.goods_receipt_items gi
      join public.goods_receipts g on g.id = gi.goods_receipt_id
      join public.purchase_orders po on po.id = g.purchase_order_id
      join public.suppliers s on s.id = po.supplier_id
     where gi.ingredient_id = p_ingredient_id and po.company_id = c.company_id
       and (v_lim is null or public.pos_local_date(g.received_at) >= v_lim)), '[]'::jsonb),
    'current', coalesce((
    select jsonb_agg(jsonb_build_object('supplier', s.name, 'unit_price', sp.unit_price) order by sp.unit_price)
      from public.supplier_prices sp join public.suppliers s on s.id = sp.supplier_id
     where sp.ingredient_id = p_ingredient_id and s.company_id = c.company_id), '[]'::jsonb));
end;
$$;

-- supplier_statement_secure: copied from 011_phases_3_to_7.sql + the period limit
create or replace function public.supplier_statement_secure(p_token text, p_supplier_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_lim date;
  c record;
begin
  select * into c from public.pos_ctx(p_token, 'purchasing');
  -- the period this role may look at (settings > staff > permissions); null = everything
  v_lim := public.pos_view_min(c.company_id, c.role_name, 'purchase');
  return jsonb_build_object('ok', true, 'entries', coalesce((
    select jsonb_agg(jsonb_build_object('at', l.created_at, 'type', l.entry_type, 'amount', l.amount,
                                        'balance_after', l.balance_after, 'reference', l.reference) order by l.created_at)
      from public.supplier_ledger l
     where l.supplier_id = p_supplier_id and l.company_id = c.company_id
       and (v_lim is null or public.pos_local_date(l.created_at) >= v_lim)), '[]'::jsonb));
end;
$$;

-- customer_statement_secure: copied from 012_phases_8_to_11.sql + the period limit
create or replace function public.customer_statement_secure(p_token text, p_customer_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_lim date;
  c record;
begin
  select * into c from public.pos_ctx(p_token, null);
  -- the period this role may look at (settings > staff > permissions); null = everything
  v_lim := public.pos_view_min(c.company_id, c.role_name, 'accounting');
  return jsonb_build_object('ok', true, 'entries', coalesce((
    select jsonb_agg(jsonb_build_object('at', l.created_at, 'type', l.transaction_type, 'amount', l.amount, 'balance_after', l.balance_after,
                                        'reference', l.reference_number, 'notes', l.notes) order by l.created_at)
      from public.customer_ledger l join public.customers cu on cu.id = l.customer_id
     where l.customer_id = p_customer_id and cu.company_id = c.company_id
       and (v_lim is null or public.pos_local_date(l.created_at) >= v_lim)), '[]'::jsonb));
end;
$$;

-- waste_report_secure: copied from 011_phases_3_to_7.sql + the period limit
create or replace function public.waste_report_secure(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_lim date;
  c record;
begin
  select * into c from public.pos_ctx(p_token, 'reports');
  -- the period this role may look at (settings > staff > permissions); null = everything
  v_lim := public.pos_view_min(c.company_id, c.role_name, 'cost');
  return jsonb_build_object('ok', true, 'rows', coalesce((
    select jsonb_agg(jsonb_build_object('created_at', w.created_at, 'ingredient', i.name, 'unit', i.unit,
                                        'quantity', w.quantity, 'reason', w.reason, 'cost_loss', w.cost_loss) order by w.created_at desc)
      from public.waste_logs w left join public.ingredients i on i.id = w.ingredient_id
     where w.created_at > now() - interval '90 days'
       and (v_lim is null or public.pos_local_date(w.created_at) >= v_lim)), '[]'::jsonb));
end;
$$;

-- sales_order_detail_secure: copied from 013_phase12_customer_requests.sql + the period limit
create or replace function public.sales_order_detail_secure(p_token text, p_order_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_lim date;
  c record;
  v_o public.orders%rowtype;
  v_wk numeric;
  v_wb numeric;
  v_ws numeric;
begin
  select * into c from public.pos_ctx(p_token, 'sales');
  -- the period this role may look at (settings > staff > permissions); null = everything
  v_lim := public.pos_view_min(c.company_id, c.role_name, 'sales');
  select o.* into v_o from public.orders o
   where o.id = p_order_id and o.company_id = c.company_id and (c.role_name = 'owner' or o.branch_id = c.branch_id);
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'order_not_found');
  end if;
  if v_lim is not null and public.pos_local_date(v_o.created_at) < v_lim then
    return public.pos_view_refusal(c.company_id, c.role_name, 'sales');
  end if;
  v_wk := public.pos_station_warn(c.company_id, 'kitchen');
  v_wb := public.pos_station_warn(c.company_id, 'bar');
  v_ws := public.pos_station_warn(c.company_id, 'shisha');
  return jsonb_build_object('ok', true,
    'warn', jsonb_build_object('kitchen', v_wk, 'bar', v_wb, 'shisha', v_ws),
    'order', jsonb_build_object(
      'id', v_o.id, 'order_number', v_o.order_number, 'status', v_o.status, 'order_type', v_o.order_type,
      'created_at', v_o.created_at, 'closed_at', v_o.closed_at, 'guest_count', v_o.guest_count, 'notes', v_o.notes,
      'sub_total', v_o.sub_total, 'discount_amount', v_o.discount_amount, 'service_charge_amount', v_o.service_charge_amount,
      'tax_amount', v_o.tax_amount, 'total_amount', v_o.total_amount, 'vat_enabled', v_o.vat_enabled,
      'service_enabled', v_o.service_enabled, 'discount_percent', v_o.discount_percent,
      'order_discount_amount', v_o.order_discount_amount,
      'discount_name', (select d.name from public.discounts d where d.id = v_o.discount_id),
      'branch', (select b.name from public.branches b where b.id = v_o.branch_id),
      'table_number', (select t.table_number from public.tables t where t.id = v_o.table_id),
      'waiter', (select s.name from public.staff s where s.id = v_o.waiter_id),
      'customer', (select jsonb_build_object('id', cu.id, 'name', cu.name, 'phone', cu.phone)
                     from public.customers cu where cu.id = v_o.customer_id),
      'created_by', (select st.name from public.order_logs l join public.staff st on st.id = l.user_id
                      where l.order_id = v_o.id and l.action in ('SEND_TO_KITCHEN', 'SPLIT_FROM') order by l.created_at limit 1)),
    'items', coalesce((select jsonb_agg(jsonb_build_object(
                'id', oi.id, 'name', coalesce(p.name, 'صنف'), 'quantity', oi.quantity, 'unit_price', oi.unit_price,
                'total_price', oi.total_price, 'discount_amount', coalesce(oi.discount_amount, 0),
                'status', coalesce(oi.status, 'active'), 'void_reason', cr.reason, 'notes', oi.item_notes,
                'station', public.pos_item_station(oi.product_id),
                'sent_at', oi.sent_at, 'prep_started_at', oi.prep_started_at, 'ready_at', oi.ready_at, 'served_at', oi.served_at,
                'wait_minutes', round((extract(epoch from (oi.prep_started_at - oi.sent_at)) / 60.0)::numeric, 1),
                'prep_minutes', round((extract(epoch from (oi.ready_at - oi.prep_started_at)) / 60.0)::numeric, 1),
                'total_minutes', round((extract(epoch from (oi.ready_at - oi.sent_at)) / 60.0)::numeric, 1),
                'modifiers', coalesce((select jsonb_agg(jsonb_build_object('name', m.modifier_name, 'price', m.unit_price))
                                         from public.order_item_modifiers m where m.order_item_id = oi.id), '[]'::jsonb))
                order by oi.sent_at, p.name)
                from public.order_items oi
                left join public.products p on p.id = oi.product_id
                left join public.cancel_reasons cr on cr.id = oi.void_reason_id
               where oi.order_id = v_o.id), '[]'::jsonb),
    'payments', coalesce((select jsonb_agg(jsonb_build_object('method', p.payment_method, 'amount', p.amount, 'tip', p.tip_amount,
                                                              'at', p.created_at, 'reference', p.reference_number, 'cashier', st.name)
                                           order by p.created_at)
                            from public.payments p
                            left join public.pos_shifts sh on sh.id = p.shift_id
                            left join public.staff st on st.id = sh.staff_id
                           where p.order_id = v_o.id), '[]'::jsonb),
    'logs', coalesce((select jsonb_agg(jsonb_build_object('at', l.created_at, 'action', l.action, 'by', s.name, 'details', l.details)
                                       order by l.created_at)
                        from public.order_logs l left join public.staff s on s.id = l.user_id
                       where l.order_id = v_o.id), '[]'::jsonb));
end;
$$;

-- journal_get_secure: copied from 012_phases_8_to_11.sql + the period limit
create or replace function public.journal_get_secure(p_token text, p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_lim date;
  c record;
  v jsonb;
begin
  select * into c from public.pos_ctx(p_token, 'accounting');
  -- the period this role may look at (settings > staff > permissions); null = everything
  v_lim := public.pos_view_min(c.company_id, c.role_name, 'accounting');
  select jsonb_build_object('id', je.id, 'entry_number', je.entry_number, 'entry_date', je.entry_date, 'journal_type', je.journal_type,
           'reference_type', je.reference_type, 'description', je.description, 'status', je.status, 'branch', b.name,
           'created_by', st.name, 'created_at', je.created_at,
           'lines', (select jsonb_agg(jsonb_build_object('code', a.code, 'account', a.name_ar, 'debit', l.debit, 'credit', l.credit,
                                                         'description', l.description) order by l.debit desc, a.code)
                       from public.journal_entry_lines l join public.accounts a on a.id = l.account_id where l.journal_entry_id = je.id))
    into v
    from public.journal_entries je left join public.branches b on b.id = je.branch_id left join public.staff st on st.id = je.created_by
   where je.id = p_id and je.company_id = c.company_id
     and (v_lim is null or je.entry_date >= v_lim);
  if v is null then
    return jsonb_build_object('ok', false, 'reason', 'not_found');
  end if;
  return jsonb_build_object('ok', true, 'entry', v);
end;
$$;

-- shift_report_secure: copied from 011_phases_3_to_7.sql + the period limit
create or replace function public.shift_report_secure(p_token text, p_shift_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_lim date;
  c record;
  s public.pos_shifts%rowtype;
begin
  select * into c from public.pos_ctx(p_token, null);
  -- the period this role may look at (settings > staff > permissions); null = everything
  v_lim := public.pos_view_min(c.company_id, c.role_name, 'treasury');
  select x.* into s from public.pos_shifts x where x.id = p_shift_id;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'shift_not_found');
  end if;
  if not (s.staff_id = c.staff_id and s.status = 'closed') then
    perform public.pos_ctx(p_token, 'treasury');
    if c.role_name <> 'owner' and s.branch_id is distinct from c.branch_id then
      return jsonb_build_object('ok', false, 'reason', 'shift_not_found');
    end if;
    if v_lim is not null and public.pos_local_date(s.opened_at) < v_lim then
      return public.pos_view_refusal(c.company_id, c.role_name, 'treasury');
    end if;
  end if;
  return jsonb_build_object('ok', true, 'report', public.pos_shift_report(s.id));
end;
$$;

-- day_report_secure: copied from 037_business_day_everywhere.sql + the period limit
create or replace function public.day_report_secure(p_token text, p_date date)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_lim date;
  c record;
begin
  select * into c from public.pos_ctx(p_token, 'treasury');
  -- the period this role may look at (settings > staff > permissions); null = everything
  v_lim := public.pos_view_min(c.company_id, c.role_name, 'treasury');
  if v_lim is not null and coalesce(p_date, public.pos_local_date(now())) < v_lim then
    return public.pos_view_refusal(c.company_id, c.role_name, 'treasury');
  end if;
  return jsonb_build_object('ok', true, 'report', public.pos_day_report(c.branch_id, coalesce(p_date, public.pos_local_date(now()))),
    'closed', exists (select 1 from public.pos_days d where d.branch_id = c.branch_id and d.business_date = coalesce(p_date, public.pos_local_date(now()))));
end;
$$;

-- pnl_daily_secure: copied from 021_phase15_owner_features.sql + the period limit
create or replace function public.pnl_daily_secure(p_token text, p_month date, p_branch_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_lim date;
  c record;
  v_branch uuid;
begin
  select * into c from public.pos_ctx(p_token, 'reports');
  -- the period this role may look at (settings > staff > permissions); null = everything
  v_lim := public.pos_view_min(c.company_id, c.role_name, 'dashboard');
  if v_lim is not null and date_trunc('month', coalesce(p_month, public.pos_local_date(now())))::date < v_lim then
    return public.pos_view_refusal(c.company_id, c.role_name, 'dashboard');
  end if;
  v_branch := c.branch_id;
  if c.role_name = 'owner' then
    v_branch := p_branch_id;
  end if;
  return jsonb_build_object('ok', true, 'branch', coalesce((select b.name from public.branches b where b.id = v_branch), 'كل الفروع'))
         || public.pos_pnl_month(c.company_id, v_branch, p_month);
end;
$$;

-- pos_settings_list_secure: copied from 013_phase12_customer_requests.sql + the period limit
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
    'view_days', public.pos_view_days(c.company_id, c.role_name),
    'perms', case when c.role_name = 'owner' then to_jsonb(public.pos_all_perms())
             else coalesce((select jsonb_agg(rp.perm) from public.role_permissions rp where rp.role_name = c.role_name), '[]'::jsonb) end);
end;
$$;

create or replace function public.motionpos_version_public()
returns text
language sql
immutable
as $$
  select '038'
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
  v_src text;
  f text;
begin
  begin
    perform set_config('motionpos.sync_apply', 'on', true);
    insert into public.companies (name) values ('selftest038') returning id into v_co;
    insert into public.app_settings (company_id, section, data)
    values (v_co, 'view_days', '{"branch_manager": {"sales": 3, "purchase": 0, "bogus": 5, "reports": "x"}}'::jsonb);
    if public.pos_view_days(v_co, 'branch_manager') <> '{"sales": 3}'::jsonb then raise exception 'SELFTEST days %', public.pos_view_days(v_co, 'branch_manager'); end if;
    if public.pos_view_min(v_co, 'branch_manager', 'sales') <> public.pos_local_date(now()) - 2 then raise exception 'SELFTEST min'; end if;
    if public.pos_view_min(v_co, 'branch_manager', 'purchase') is not null then raise exception 'SELFTEST no limit'; end if;
    if public.pos_view_min(v_co, 'owner', 'sales') is not null then raise exception 'SELFTEST owner'; end if;
    if public.pos_view_refusal(v_co, 'branch_manager', 'sales')->>'reason' <> 'view_limit' then raise exception 'SELFTEST refusal'; end if;
    foreach f in array array['dashboard_secure', 'sales_orders_secure', 'sales_timing_secure', 'report_secure', 'expenses_report_secure',
        'staff_performance_secure', 'attendance_report_secure', 'pnl_secure', 'general_ledger_secure', 'journal_list_secure',
        'trial_balance_secure', 'shifts_list_secure', 'inv_ledger_secure', 'inv_variance_secure', 'po_list_secure', 'gr_list_secure',
        'price_history_secure', 'supplier_statement_secure', 'customer_statement_secure', 'waste_report_secure',
        'sales_order_detail_secure', 'journal_get_secure', 'shift_report_secure', 'day_report_secure', 'pnl_daily_secure'] loop
      select pg_get_functiondef(p.oid) into v_src from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = f;
      if position('pos_view_min' in v_src) = 0 then raise exception 'SELFTEST % has no limit', f; end if;
    end loop;
    if public.motionpos_version_public() <> '038' then raise exception 'SELFTEST version'; end if;
    raise notice 'MOTIONPOS-038-SELFTEST-OK';
    raise exception using errcode = 'P0099', message = 'selftest_rollback';
  exception when sqlstate 'P0099' then
    null;
  end;
end;
$selftest$;

notify pgrst, 'reload schema';

commit;
