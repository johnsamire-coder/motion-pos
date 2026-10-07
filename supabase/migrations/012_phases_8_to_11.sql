-- 012_phases_8_to_11.sql
-- Phases 8 to 11 in one file: waiter / kitchen stations / QR menu / printing, reports, accounting, settings.
-- Same rules as before. If anything fails (including the self-test) the WHOLE file is rolled back.

begin;

-- ===================================================================================
-- PART A: settings store, kitchen stations, waiter feed, QR menu, print data
-- ===================================================================================

do $preflight$
begin
  if length('إكراميات') <> 8 then
    raise exception 'file_encoding_broken: read the file as UTF-8';
  end if;
  if to_regprocedure('public.pos_ctx(text,text)') is null or to_regprocedure('public.shift_open_secure(text,numeric)') is null then
    raise exception 'schema_preflight_failed: run 001 to 011 first';
  end if;
end;
$preflight$;

-- -----------------------------------------------------------------------------------
-- Settings: one json document per section per company. Defaults live in one function.
-- -----------------------------------------------------------------------------------
create table if not exists public.app_settings (
  company_id uuid not null,
  section text not null,
  data jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now(),
  updated_by uuid,
  primary key (company_id, section)
);
alter table public.app_settings enable row level security;

create or replace function public.pos_settings_defaults()
returns jsonb
language sql
immutable
as $$
  select jsonb_build_object(
    'general', jsonb_build_object('company_name', 'Motion POS', 'logo', '', 'address', '', 'phone', '', 'tax_number', '',
                                  'commercial_register', '', 'currency', 'ج.م'),
    'receipt', jsonb_build_object('header', '', 'footer', 'شكراً لزيارتكم', 'show_logo', true, 'paper_mm', 80, 'copies', 1,
                                  'auto_print_after_pay', false, 'auto_kitchen_ticket', false, 'show_tax_number', true),
    'pos', jsonb_build_object('order_types', jsonb_build_array('dine_in', 'takeaway', 'delivery', 'pickup'),
                              'payment_methods', jsonb_build_array('cash', 'card', 'instapay', 'wallet', 'on_account'),
                              'require_waiter', false, 'round_total', false),
    'kds', jsonb_build_object('stations', jsonb_build_array('kitchen', 'bar', 'shisha'), 'warn_minutes', 15, 'sound', true,
                              'refresh_seconds', 10),
    'waiter_qr', jsonb_build_object('qr_enabled', true, 'qr_call_waiter', true, 'qr_request_bill', true, 'qr_show_prices', true),
    'shift', jsonb_build_object('default_float', 0, 'drawer_alert_limit', 5000),
    'inventory', jsonb_build_object('allow_negative_stock', true, 'default_min_stock', 5),
    'staff', jsonb_build_object('work_start_time', '09:00', 'late_grace_minutes', 15),
    'offline', jsonb_build_object('mode', 'none', 'local_server_url', '')
  )
$$;

create or replace function public.pos_app_settings(p_company_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public, extensions
as $$
  select jsonb_object_agg(d.key, d.value || coalesce((select s.data from public.app_settings s
                                                       where s.company_id = p_company_id and s.section = d.key), '{}'::jsonb))
    from jsonb_each(public.pos_settings_defaults()) d
$$;

create or replace function public.app_settings_get_secure(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
begin
  select * into c from public.pos_ctx(p_token, null);
  return jsonb_build_object('ok', true, 'settings', public.pos_app_settings(c.company_id),
    'numbers', jsonb_build_object('working_days_per_month', public.pos_setting(c.company_id, 'working_days_per_month', 26),
                                  'expense_manager_limit', public.pos_setting(c.company_id, 'expense_manager_limit', 1000)));
end;
$$;

-- Only keys that exist in the defaults are kept, and each keeps the type of its default.
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
begin
  select * into c from public.pos_ctx(p_token, 'settings');
  if v_def is null then
    return jsonb_build_object('ok', false, 'reason', 'unknown_action');
  end if;
  if p_section in ('general', 'offline') and c.role_name <> 'owner' then
    return jsonb_build_object('ok', false, 'reason', 'not_allowed');
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
      v_clean := v_clean || jsonb_build_object(k, v);
    end if;
  end loop;
  if p_section = 'offline' and coalesce(v_clean->>'mode', 'none') not in ('none', 'cashier', 'branch') then
    return jsonb_build_object('ok', false, 'reason', 'invalid_value', 'key', 'mode');
  end if;
  if p_section = 'receipt' and coalesce((v_clean->>'paper_mm')::int, 80) not in (58, 80) then
    return jsonb_build_object('ok', false, 'reason', 'invalid_value', 'key', 'paper_mm');
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

-- -----------------------------------------------------------------------------------
-- Kitchen stations (kitchen / bar / shisha) per category, status per order per station
-- -----------------------------------------------------------------------------------
alter table public.categories add column if not exists station text not null default 'kitchen';
alter table public.categories drop constraint if exists categories_station_check;
alter table public.categories add constraint categories_station_check check (station in ('kitchen', 'bar', 'shisha'));

create table if not exists public.order_station_status (
  order_id uuid not null references public.orders(id) on delete cascade,
  station text not null check (station in ('kitchen', 'bar', 'shisha')),
  status text not null default 'pending' check (status in ('pending', 'preparing', 'ready', 'served')),
  updated_at timestamptz not null default now(),
  ready_at timestamptz,
  primary key (order_id, station)
);
alter table public.order_station_status enable row level security;

create or replace function public.pos_item_station(p_product_id uuid)
returns text
language sql
stable
security definer
set search_path = public, extensions
as $$
  select coalesce((select c.station from public.products p join public.categories c on c.id = p.category_id
                    where p.id = p_product_id), 'kitchen')
$$;

-- order.kitchen_status follows its stations: all ready -> ready, any started -> preparing, else pending
create or replace function public.pos_order_kitchen_sync(p_order_id uuid)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_total int;
  v_ready int;
  v_started int;
begin
  select count(*), count(*) filter (where s.status in ('ready', 'served')),
         count(*) filter (where s.status in ('preparing', 'ready', 'served'))
    into v_total, v_ready, v_started
    from public.order_station_status s
   where s.order_id = p_order_id
     and exists (select 1 from public.order_items oi
                  where oi.order_id = s.order_id and coalesce(oi.status, 'active') = 'active'
                    and public.pos_item_station(oi.product_id) = s.station);
  update public.orders
     set kitchen_status = case when v_total > 0 and v_ready = v_total then 'ready'
                               when v_started > 0 then 'preparing' else 'pending' end
   where id = p_order_id;
end;
$$;

create or replace function public.trg_order_items_station()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  insert into public.order_station_status (order_id, station, status)
  values (new.order_id, public.pos_item_station(new.product_id), 'pending')
  on conflict (order_id, station)
  do update set status = 'pending', updated_at = now(), ready_at = null
          where public.order_station_status.status in ('ready', 'served');
  perform public.pos_order_kitchen_sync(new.order_id);
  return null;
end;
$$;

drop trigger if exists trg_order_items_station on public.order_items;
create trigger trg_order_items_station
after insert or update of order_id on public.order_items
for each row execute function public.trg_order_items_station();

-- Existing open orders get their station rows
insert into public.order_station_status (order_id, station, status)
select distinct o.id, public.pos_item_station(oi.product_id),
       case when o.kitchen_status in ('ready', 'served') then 'ready'
            when o.kitchen_status = 'preparing' then 'preparing' else 'pending' end
  from public.orders o join public.order_items oi on oi.order_id = o.id
 where coalesce(o.status, '') <> 'cancelled' and coalesce(oi.status, 'active') = 'active'
on conflict do nothing;

create or replace function public.kds_station_list_secure(p_token text, p_station text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
begin
  select * into c from public.pos_ctx(p_token, 'kds');
  if coalesce(p_station, '') not in ('kitchen', 'bar', 'shisha') then
    return jsonb_build_object('ok', false, 'reason', 'invalid_value');
  end if;
  return jsonb_build_object('ok', true, 'orders', coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', o.id, 'order_number', o.order_number, 'order_type', o.order_type, 'status', s.status,
             'created_at', o.created_at, 'station_since', s.updated_at, 'table_number', t.table_number, 'waiter', w.name,
             'items', (select jsonb_agg(jsonb_build_object(
                         'name', coalesce(p.name, 'صنف'), 'quantity', oi.quantity, 'item_notes', oi.item_notes,
                         'modifiers', coalesce((select jsonb_agg(m.modifier_name) from public.order_item_modifiers m
                                                 where m.order_item_id = oi.id), '[]'::jsonb)))
                         from public.order_items oi left join public.products p on p.id = oi.product_id
                        where oi.order_id = o.id and coalesce(oi.status, 'active') = 'active'
                          and public.pos_item_station(oi.product_id) = p_station)) order by o.created_at)
      from public.order_station_status s
      join public.orders o on o.id = s.order_id
      left join public.tables t on t.id = o.table_id
      left join public.staff w on w.id = o.waiter_id
     where o.branch_id = c.branch_id and s.station = p_station and s.status in ('pending', 'preparing')
       and coalesce(o.status, '') <> 'cancelled' and o.created_at > now() - interval '24 hours'
       and exists (select 1 from public.order_items x where x.order_id = o.id and coalesce(x.status, 'active') = 'active'
                     and public.pos_item_station(x.product_id) = p_station)), '[]'::jsonb));
end;
$$;

create or replace function public.kds_station_set_secure(p_token text, p_order_id uuid, p_station text, p_status text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
begin
  select * into c from public.pos_ctx(p_token, 'kds');
  if coalesce(p_status, '') not in ('preparing', 'ready') then
    return jsonb_build_object('ok', false, 'reason', 'invalid_status');
  end if;
  if not exists (select 1 from public.orders o where o.id = p_order_id and o.branch_id = c.branch_id) then
    return jsonb_build_object('ok', false, 'reason', 'order_not_found');
  end if;
  update public.order_station_status
     set status = p_status, updated_at = now(), ready_at = case when p_status = 'ready' then now() else ready_at end
   where order_id = p_order_id and station = p_station;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'order_not_found');
  end if;
  perform public.pos_order_kitchen_sync(p_order_id);
  insert into public.order_logs (order_id, user_id, action, details)
  values (p_order_id, c.staff_id, 'KITCHEN_STATUS', jsonb_build_object('station', p_station, 'to', p_status));
  return jsonb_build_object('ok', true);
end;
$$;

-- -----------------------------------------------------------------------------------
-- QR menu and table calls
-- -----------------------------------------------------------------------------------
alter table public.tables add column if not exists qr_token text;
update public.tables set qr_token = encode(extensions.gen_random_bytes(12), 'hex') where qr_token is null;
alter table public.tables alter column qr_token set default encode(extensions.gen_random_bytes(12), 'hex');
create unique index if not exists tables_qr_token_key on public.tables (qr_token);

create table if not exists public.service_requests (
  id uuid primary key default gen_random_uuid(),
  branch_id uuid,
  table_id uuid references public.tables(id) on delete cascade,
  request_type text not null check (request_type in ('waiter', 'bill')),
  status text not null default 'open' check (status in ('open', 'done')),
  created_at timestamptz not null default now(),
  done_at timestamptz,
  done_by uuid
);
alter table public.service_requests enable row level security;

create or replace function public.pos_qr_table(p_qr text)
returns table (table_id uuid, table_number text, branch_id uuid, branch_name text, company_id uuid, brand_id uuid)
language sql
stable
security definer
set search_path = public, extensions
as $$
  select t.id, t.table_number, b.id, b.name, br.company_id, b.brand_id
    from public.tables t
    join public.areas a on a.id = t.area_id
    join public.branches b on b.id = a.branch_id
    join public.brands br on br.id = b.brand_id
   where t.qr_token = p_qr and coalesce(p_qr, '') ~ '^[0-9a-f]{24}$'
$$;

-- Public (no login): the customer's phone reads the menu of the table it scanned
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
begin
  select * into t from public.pos_qr_table(p_qr);
  if t.table_id is null then
    return jsonb_build_object('ok', false, 'reason', 'not_found');
  end if;
  s := public.pos_app_settings(t.company_id);
  if not coalesce((s->'waiter_qr'->>'qr_enabled')::boolean, true) then
    return jsonb_build_object('ok', false, 'reason', 'qr_disabled');
  end if;
  return jsonb_build_object('ok', true,
    'company_name', s->'general'->>'company_name', 'logo', s->'general'->>'logo', 'currency', s->'general'->>'currency',
    'branch', t.branch_name, 'table_number', t.table_number,
    'call_waiter', coalesce((s->'waiter_qr'->>'qr_call_waiter')::boolean, true),
    'request_bill', coalesce((s->'waiter_qr'->>'qr_request_bill')::boolean, true),
    'show_prices', coalesce((s->'waiter_qr'->>'qr_show_prices')::boolean, true),
    'categories', coalesce((
      select jsonb_agg(jsonb_build_object('name', cat.name,
               'products', (select jsonb_agg(jsonb_build_object('name', p.name, 'price', p.price) order by p.name)
                              from public.products p where p.category_id = cat.id and p.is_available is true)) order by cat.name)
        from public.categories cat
       where cat.brand_id = t.brand_id
         and exists (select 1 from public.products p where p.category_id = cat.id and p.is_available is true)), '[]'::jsonb));
end;
$$;

create or replace function public.qr_request_public(p_qr text, p_type text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  t record;
  s jsonb;
begin
  select * into t from public.pos_qr_table(p_qr);
  if t.table_id is null or coalesce(p_type, '') not in ('waiter', 'bill') then
    return jsonb_build_object('ok', false, 'reason', 'not_found');
  end if;
  s := public.pos_app_settings(t.company_id);
  if not coalesce((s->'waiter_qr'->>'qr_enabled')::boolean, true)
     or (p_type = 'waiter' and not coalesce((s->'waiter_qr'->>'qr_call_waiter')::boolean, true))
     or (p_type = 'bill' and not coalesce((s->'waiter_qr'->>'qr_request_bill')::boolean, true)) then
    return jsonb_build_object('ok', false, 'reason', 'qr_disabled');
  end if;
  if exists (select 1 from public.service_requests r where r.table_id = t.table_id and r.request_type = p_type and r.status = 'open') then
    return jsonb_build_object('ok', true, 'already', true);
  end if;
  if (select count(*) from public.service_requests r where r.table_id = t.table_id and r.created_at > now() - interval '1 hour') >= 20 then
    return jsonb_build_object('ok', false, 'reason', 'too_many');
  end if;
  insert into public.service_requests (branch_id, table_id, request_type) values (t.branch_id, t.table_id, p_type);
  return jsonb_build_object('ok', true);
end;
$$;

-- Waiter feed: ready stations of his orders + open table calls of the branch
create or replace function public.waiter_feed_secure(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
begin
  select * into c from public.pos_ctx(p_token, 'pos');
  return jsonb_build_object('ok', true,
    'ready', coalesce((
      select jsonb_agg(jsonb_build_object('order_id', o.id, 'order_number', o.order_number, 'table_number', t.table_number,
                                          'station', s.station, 'ready_at', s.ready_at) order by s.ready_at)
        from public.order_station_status s
        join public.orders o on o.id = s.order_id
        left join public.tables t on t.id = o.table_id
       where o.branch_id = c.branch_id and s.status = 'ready' and coalesce(o.status, '') <> 'cancelled'
         and (c.role_name <> 'waiter' or o.waiter_id = c.staff_id)
         and s.ready_at > now() - interval '12 hours'), '[]'::jsonb),
    'calls', coalesce((
      select jsonb_agg(jsonb_build_object('id', r.id, 'type', r.request_type, 'table_number', t.table_number,
                                          'created_at', r.created_at) order by r.created_at)
        from public.service_requests r join public.tables t on t.id = r.table_id
       where r.branch_id = c.branch_id and r.status = 'open'), '[]'::jsonb));
end;
$$;

create or replace function public.waiter_ack_secure(p_token text, p_kind text, p_id uuid, p_station text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
begin
  select * into c from public.pos_ctx(p_token, 'pos');
  if p_kind = 'call' then
    update public.service_requests set status = 'done', done_at = now(), done_by = c.staff_id
     where id = p_id and branch_id = c.branch_id and status = 'open';
  elsif p_kind = 'ready' then
    update public.order_station_status s set status = 'served', updated_at = now()
      from public.orders o
     where s.order_id = p_id and s.station = p_station and o.id = s.order_id and o.branch_id = c.branch_id and s.status = 'ready';
  else
    return jsonb_build_object('ok', false, 'reason', 'unknown_action');
  end if;
  return jsonb_build_object('ok', true);
end;
$$;

create or replace function public.tables_qr_secure(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
begin
  select * into c from public.pos_ctx(p_token, 'settings');
  return jsonb_build_object('ok', true, 'tables', coalesce((
    select jsonb_agg(jsonb_build_object('table_number', t.table_number, 'area', a.name, 'qr_token', t.qr_token)
                     order by a.name, t.table_number)
      from public.tables t join public.areas a on a.id = t.area_id
     where a.branch_id = c.branch_id), '[]'::jsonb));
end;
$$;

-- Everything a printed bill or kitchen ticket needs, in one call
create or replace function public.order_print_data_secure(p_token text, p_order_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
  v jsonb;
begin
  select * into c from public.pos_ctx(p_token, null);
  select jsonb_build_object(
    'order_number', o.order_number, 'order_type', o.order_type, 'status', o.status, 'created_at', o.created_at,
    'table_number', t.table_number, 'waiter', w.name, 'customer', cu.name, 'guest_count', o.guest_count,
    'sub_total', o.sub_total, 'discount_amount', o.discount_amount, 'service_charge_amount', o.service_charge_amount,
    'tax_amount', o.tax_amount, 'total_amount', o.total_amount, 'branch', b.name, 'branch_address', b.address,
    'items', coalesce((select jsonb_agg(jsonb_build_object('name', coalesce(p.name, 'صنف'), 'quantity', oi.quantity,
                                                           'unit_price', oi.unit_price, 'total_price', oi.total_price,
                                                           'notes', oi.item_notes, 'station', public.pos_item_station(oi.product_id),
                                                           'modifiers', coalesce((select jsonb_agg(m.modifier_name)
                                                                                    from public.order_item_modifiers m
                                                                                   where m.order_item_id = oi.id), '[]'::jsonb))
                                        order by p.name)
                         from public.order_items oi left join public.products p on p.id = oi.product_id
                        where oi.order_id = o.id and coalesce(oi.status, 'active') = 'active'), '[]'::jsonb),
    'payments', coalesce((select jsonb_agg(jsonb_build_object('method', p.payment_method, 'amount', p.amount, 'tip', p.tip_amount))
                            from public.payments p where p.order_id = o.id), '[]'::jsonb),
    'cashier', (select st.name from public.payments p join public.pos_shifts sh on sh.id = p.shift_id
                  join public.staff st on st.id = sh.staff_id where p.order_id = o.id limit 1))
    into v
    from public.orders o
    left join public.tables t on t.id = o.table_id
    left join public.staff w on w.id = o.waiter_id
    left join public.customers cu on cu.id = o.customer_id
    left join public.branches b on b.id = o.branch_id
   where o.id = p_order_id and o.branch_id = c.branch_id;
  if v is null then
    return jsonb_build_object('ok', false, 'reason', 'order_not_found');
  end if;
  return jsonb_build_object('ok', true, 'order', v, 'settings', public.pos_app_settings(c.company_id));
end;
$$;

-- ===================================================================================
-- PART B: phase 9 (reports). One function, one report key each. Result:
-- {ok, title, columns:[{key,label,type}], rows:[...]}  type: t text, n number, m money, d date, p percent
-- ===================================================================================

create or replace function public.pos_cols(p_keys text[], p_labels text[], p_types text)
returns jsonb
language sql
immutable
as $$
  select coalesce(jsonb_agg(jsonb_build_object('key', p_keys[i], 'label', p_labels[i], 'type', substr(p_types, i, 1)) order by i), '[]'::jsonb)
    from generate_subscripts(p_keys, 1) i
$$;

-- Closed orders of the company in the period (optionally one branch)
create or replace function public.pos_rpt_orders(p_company_id uuid, p_branch_id uuid, p_from date, p_to date)
returns setof public.orders
language sql
stable
security definer
set search_path = public, extensions
as $$
  select o.* from public.orders o
   where o.company_id = p_company_id and o.status = 'closed'
     and (p_branch_id is null or o.branch_id = p_branch_id)
     and (o.created_at at time zone 'Africa/Cairo')::date between p_from and p_to
$$;

-- Cost of one unit of a product from its recipe at today's ingredient costs
create or replace function public.pos_product_cost(p_product_id uuid)
returns numeric
language sql
stable
security definer
set search_path = public, extensions
as $$
  select coalesce(sum(r.quantity_required * coalesce(i.cost_per_unit, 0)), 0)
    from public.recipes r join public.ingredients i on i.id = r.ingredient_id
   where r.product_id = p_product_id
$$;

create or replace function public.pos_local_date(ts timestamptz)
returns date
language sql
immutable
as $$ select (ts at time zone 'Africa/Cairo')::date $$;

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
      select s.name as staff, count(*) as count, sum(p.tip_amount) as tips
        from public.payments p join public.staff s on s.id = p.tip_staff_id
       where s.company_id = c.company_id and (v_branch is null or s.branch_id = v_branch) and p.tip_amount > 0
         and public.pos_local_date(p.created_at) between v_from and v_to group by 1) q;

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

-- ===================================================================================
-- PART C: phase 10 (accounting, customers) + phase 11 (remaining settings)
-- Account balance sign: positive = normal side of the account.
-- ===================================================================================

-- Fiscal months for this year and next year (only missing ones)
insert into public.fiscal_periods (company_id, period_name, start_date, end_date, status)
select c.id, to_char(m, 'YYYY-MM'), m::date, (m + interval '1 month - 1 day')::date, 'open'
  from public.companies c
  cross join generate_series(date_trunc('year', current_date), date_trunc('year', current_date) + interval '23 months', interval '1 month') m
 where not exists (select 1 from public.fiscal_periods f where f.company_id = c.id and f.start_date = m::date);

create or replace function public.pos_is_manager(p_role text)
returns boolean
language sql
immutable
as $$ select p_role in ('owner', 'branch_manager') $$;

create or replace function public.journal_list_secure(p_token text, p_from date, p_to date, p_branch_id uuid, p_type text, p_search text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
  v_branch uuid;
begin
  select * into c from public.pos_ctx(p_token, 'accounting');
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

create or replace function public.journal_get_secure(p_token text, p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
  v jsonb;
begin
  select * into c from public.pos_ctx(p_token, 'accounting');
  select jsonb_build_object('id', je.id, 'entry_number', je.entry_number, 'entry_date', je.entry_date, 'journal_type', je.journal_type,
           'reference_type', je.reference_type, 'description', je.description, 'status', je.status, 'branch', b.name,
           'created_by', st.name, 'created_at', je.created_at,
           'lines', (select jsonb_agg(jsonb_build_object('code', a.code, 'account', a.name_ar, 'debit', l.debit, 'credit', l.credit,
                                                         'description', l.description) order by l.debit desc, a.code)
                       from public.journal_entry_lines l join public.accounts a on a.id = l.account_id where l.journal_entry_id = je.id))
    into v
    from public.journal_entries je left join public.branches b on b.id = je.branch_id left join public.staff st on st.id = je.created_by
   where je.id = p_id and je.company_id = c.company_id;
  if v is null then
    return jsonb_build_object('ok', false, 'reason', 'not_found');
  end if;
  return jsonb_build_object('ok', true, 'entry', v);
end;
$$;

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
  if not public.pos_is_manager(c.role_name) then
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

-- Only manual entries are reversed here; system entries are reversed by their own screens (refund, etc.)
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
  if not public.pos_is_manager(c.role_name) then
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

create or replace function public.pos_account_balances(p_company_id uuid, p_from date, p_to date, p_branch_id uuid)
returns table (account_id uuid, code text, name text, account_type text, normal_balance text, debit numeric, credit numeric, balance numeric)
language sql
stable
security definer
set search_path = public, extensions
as $$
  select a.id, a.code, a.name_ar, a.account_type, a.normal_balance,
         coalesce(sum(l.debit), 0), coalesce(sum(l.credit), 0),
         case when a.normal_balance = 'debit' then coalesce(sum(l.debit - l.credit), 0) else coalesce(sum(l.credit - l.debit), 0) end
    from public.accounts a
    left join public.journal_entry_lines l on l.account_id = a.id
     and exists (select 1 from public.journal_entries je where je.id = l.journal_entry_id
                   and je.status in ('posted', 'reversed') and je.entry_date between p_from and p_to
                   and (p_branch_id is null or je.branch_id = p_branch_id))
   where a.company_id = p_company_id
   group by a.id, a.code, a.name_ar, a.account_type, a.normal_balance
$$;

create or replace function public.pnl_secure(p_token text, p_from date, p_to date, p_branch_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
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

create or replace function public.balance_sheet_secure(p_token text, p_as_of date)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
  v_to date := coalesce(p_as_of, current_date);
  v_rows jsonb;
  v_assets numeric;
  v_liab numeric;
  v_equity numeric;
  v_profit numeric;
begin
  select * into c from public.pos_ctx(p_token, 'accounting');
  select coalesce(jsonb_agg(jsonb_build_object('code', b.code, 'name', b.name, 'type', b.account_type,
                    'amount', b.balance) order by b.code) filter (where b.account_type in ('asset', 'liability', 'equity') and b.balance <> 0), '[]'),
         coalesce(sum(b.balance) filter (where b.account_type = 'asset'), 0),
         coalesce(sum(b.balance) filter (where b.account_type = 'liability'), 0),
         coalesce(sum(b.balance) filter (where b.account_type = 'equity'), 0),
         coalesce(sum(b.balance) filter (where b.account_type = 'revenue'), 0)
           - coalesce(sum(b.balance) filter (where b.account_type in ('cogs', 'expense')), 0)
    into v_rows, v_assets, v_liab, v_equity, v_profit
    from public.pos_account_balances(c.company_id, '1900-01-01', v_to, null) b;
  return jsonb_build_object('ok', true, 'as_of', v_to, 'rows', v_rows, 'assets', v_assets, 'liabilities', v_liab,
    'equity', v_equity, 'profit_not_closed', v_profit, 'liabilities_and_equity', v_liab + v_equity + v_profit,
    'balanced', abs(v_assets - (v_liab + v_equity + v_profit)) < 0.01);
end;
$$;

create or replace function public.general_ledger_secure(p_token text, p_account_id uuid, p_from date, p_to date, p_branch_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
  v_branch uuid;
  v_from date := coalesce(p_from, date_trunc('month', current_date)::date);
  v_to date := coalesce(p_to, current_date);
  a public.accounts%rowtype;
  v_open numeric;
  v_sign int;
begin
  select * into c from public.pos_ctx(p_token, 'accounting');
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

create or replace function public.accounts_list_secure(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
begin
  select * into c from public.pos_ctx(p_token, null);
  return jsonb_build_object('ok', true, 'accounts', coalesce((
    select jsonb_agg(jsonb_build_object('id', a.id, 'code', a.code, 'name', a.name_ar, 'type', a.account_type) order by a.code)
      from public.accounts a where a.company_id = c.company_id and coalesce(a.is_active, true)), '[]'::jsonb));
end;
$$;

create or replace function public.fiscal_periods_secure(p_token text, p_period_id uuid, p_action text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
begin
  select * into c from public.pos_ctx(p_token, 'accounting');
  if p_period_id is not null then
    if c.role_name <> 'owner' then
      return jsonb_build_object('ok', false, 'reason', 'not_allowed');
    end if;
    if p_action = 'close' then
      update public.fiscal_periods set status = 'closed', closed_by = c.staff_id, closed_at = now()
       where id = p_period_id and company_id = c.company_id and status = 'open';
    elsif p_action = 'reopen' then
      update public.fiscal_periods set status = 'open'
       where id = p_period_id and company_id = c.company_id and status = 'closed';
    else
      return jsonb_build_object('ok', false, 'reason', 'unknown_action');
    end if;
    insert into public.settings_logs (staff_id, action, details)
    values (c.staff_id, 'fiscal_period_' || p_action, jsonb_build_object('period_id', p_period_id));
  end if;
  return jsonb_build_object('ok', true, 'periods', coalesce((
    select jsonb_agg(jsonb_build_object('id', f.id, 'name', f.period_name, 'start', f.start_date, 'end', f.end_date,
                                        'status', f.status, 'closed_at', f.closed_at) order by f.start_date)
      from public.fiscal_periods f where f.company_id = c.company_id), '[]'::jsonb));
end;
$$;

-- -----------------------------------------------------------------------------------
-- Customers: list / save, statement, receive payment
-- -----------------------------------------------------------------------------------
create or replace function public.customers_secure(p_token text, p_data jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
  v_id uuid;
  v_name text;
  v_type text;
  v_limit numeric;
begin
  select * into c from public.pos_ctx(p_token, null);
  if p_data is not null then
    if not public.pos_is_manager(c.role_name)
       and not exists (select 1 from public.role_permissions rp where rp.role_name = c.role_name and rp.perm = 'accounting') then
      return jsonb_build_object('ok', false, 'reason', 'not_allowed');
    end if;
    v_id := public.pos_uuid(p_data->>'id');
    v_name := nullif(btrim(coalesce(p_data->>'name', '')), '');
    v_type := coalesce(p_data->>'customer_type', 'registered');
    v_limit := coalesce(public.pos_amount(p_data->>'credit_limit'), 0);
    if v_name is null or length(v_name) > 150 or v_type not in ('cash', 'registered', 'on_account') then
      return jsonb_build_object('ok', false, 'reason', 'invalid_value');
    end if;
    if v_id is null then
      insert into public.customers (company_id, name, phone, address, customer_type, credit_limit)
      values (c.company_id, v_name, left(coalesce(p_data->>'phone', ''), 30), left(coalesce(p_data->>'address', ''), 300), v_type, v_limit)
      returning id into v_id;
    else
      update public.customers
         set name = v_name, phone = left(coalesce(p_data->>'phone', ''), 30), address = left(coalesce(p_data->>'address', ''), 300),
             customer_type = v_type, credit_limit = v_limit
       where id = v_id and company_id = c.company_id;
    end if;
    insert into public.settings_logs (staff_id, action, details) values (c.staff_id, 'customer_save', jsonb_build_object('id', v_id, 'data', p_data));
  end if;
  return jsonb_build_object('ok', true, 'id', v_id, 'customers', coalesce((
    select jsonb_agg(jsonb_build_object('id', cu.id, 'name', cu.name, 'phone', cu.phone, 'address', cu.address,
                                        'customer_type', cu.customer_type, 'credit_limit', cu.credit_limit,
                                        'balance', coalesce((select sum(l.amount) from public.customer_ledger l where l.customer_id = cu.id), 0))
                     order by cu.name)
      from public.customers cu where cu.company_id = c.company_id), '[]'::jsonb));
end;
$$;

create or replace function public.customer_statement_secure(p_token text, p_customer_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
begin
  select * into c from public.pos_ctx(p_token, null);
  return jsonb_build_object('ok', true, 'entries', coalesce((
    select jsonb_agg(jsonb_build_object('at', l.created_at, 'type', l.transaction_type, 'amount', l.amount, 'balance_after', l.balance_after,
                                        'reference', l.reference_number, 'notes', l.notes) order by l.created_at)
      from public.customer_ledger l join public.customers cu on cu.id = l.customer_id
     where l.customer_id = p_customer_id and cu.company_id = c.company_id), '[]'::jsonb));
end;
$$;

create or replace function public.customer_receive_secure(p_token text, p_customer_id uuid, p_amount numeric, p_source text, p_reference text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
  v_amount numeric := round(coalesce(p_amount, 0), 2);
  v_bal numeric;
  v_shift uuid;
  v_id uuid;
begin
  select * into c from public.pos_ctx(p_token, null);
  if not public.pos_is_manager(c.role_name)
     and not exists (select 1 from public.role_permissions rp where rp.role_name = c.role_name and rp.perm in ('accounting', 'shift')) then
    return jsonb_build_object('ok', false, 'reason', 'not_allowed');
  end if;
  perform 1 from public.customers cu where cu.id = p_customer_id and cu.company_id = c.company_id for update;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'not_found');
  end if;
  select coalesce(sum(l.amount), 0) into v_bal from public.customer_ledger l where l.customer_id = p_customer_id;
  if v_amount <= 0 or v_amount > v_bal then
    return jsonb_build_object('ok', false, 'reason', 'invalid_amount', 'balance', v_bal);
  end if;
  if coalesce(p_source, '') not in ('drawer', 'main_cash', 'bank') then
    return jsonb_build_object('ok', false, 'reason', 'invalid_destination');
  end if;
  if p_source = 'drawer' then
    select s.id into v_shift from public.pos_shifts s where s.staff_id = c.staff_id and s.status = 'open';
    if v_shift is null then
      return jsonb_build_object('ok', false, 'reason', 'no_open_shift');
    end if;
  end if;
  v_id := gen_random_uuid();
  insert into public.customer_ledger (id, company_id, customer_id, transaction_type, amount, payment_method, reference_number,
                                      balance_after, notes, created_by)
  values (v_id, c.company_id, p_customer_id, 'payment_received', -v_amount, case when p_source = 'bank' then 'bank_transfer' else 'cash' end,
          left(coalesce(p_reference, ''), 100), v_bal - v_amount, 'تحصيل', c.staff_id);
  update public.customers set current_balance = v_bal - v_amount where id = p_customer_id;
  if p_source = 'drawer' then
    insert into public.pos_cash_moves (shift_id, company_id, branch_id, move_type, amount, source, destination, reason, staff_id)
    values (v_shift, c.company_id, c.branch_id, 'cash_in', v_amount, 'customer', 'drawer', 'تحصيل من عميل', c.staff_id);
  end if;
  perform public.pos_post_je(c.company_id, c.branch_id, 'receipt', 'payment', v_id, 'تحصيل من عميل',
    jsonb_build_array(public.pos_je_line(public.pos_box_code(p_source), v_amount, 0, 'تحصيل'),
                      public.pos_je_line('1120', 0, v_amount, 'العملاء')), c.staff_id);
  return jsonb_build_object('ok', true, 'balance', v_bal - v_amount);
end;
$$;

-- -----------------------------------------------------------------------------------
-- More settings: stations, recipes, ingredients, discounts, cancel reasons, areas,
-- payment accounts, tax flags. Manager / owner (permission 'settings').
-- -----------------------------------------------------------------------------------
create or replace function public.settings2_secure(p_token text, p_action text, p_data jsonb)
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
  v_txt text;
  v_num numeric;
  l jsonb;
  v_result jsonb := '{}'::jsonb;
begin
  select * into c from public.pos_ctx(p_token, 'settings');
  select b.brand_id into v_brand from public.branches b where b.id = c.branch_id;

  case coalesce(p_action, '')
  when 'get' then
    v_result := jsonb_build_object(
      'categories', (select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'name', x.name, 'station', x.station) order by x.name), '[]')
                       from public.categories x where x.brand_id = v_brand),
      'ingredients', (select coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'name', i.name, 'unit', i.unit, 'cost_per_unit', i.cost_per_unit,
                                                                    'min_stock_alert', i.min_stock_alert) order by i.name), '[]') from public.ingredients i),
      'discounts', (select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'name', x.name, 'discount_type', x.discount_type, 'value', x.value,
                                                                  'requires_approval', x.requires_approval) order by x.name), '[]')
                      from public.discounts x where x.brand_id = v_brand),
      'cancel_reasons', (select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'reason', x.reason, 'reason_type', x.reason_type) order by x.reason), '[]')
                           from public.cancel_reasons x where x.brand_id = v_brand),
      'areas', (select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'name', x.name) order by x.sort_order, x.name), '[]')
                  from public.areas x where x.branch_id = c.branch_id),
      'payment_accounts', (select coalesce(jsonb_agg(jsonb_build_object('method', m.method, 'account_id', pm.account_id) order by m.ord), '[]')
                             from unnest(array['cash', 'card', 'instapay', 'wallet', 'on_account']) with ordinality as m(method, ord)
                             left join public.payment_method_account_mappings pm on pm.company_id = c.company_id and pm.payment_method = m.method),
      'asset_accounts', (select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'name', a.code || ' - ' || a.name_ar) order by a.code), '[]')
                           from public.accounts a where a.company_id = c.company_id and a.account_type = 'asset'),
      'tax', (select coalesce(jsonb_agg(jsonb_build_object('branch_id', b.id, 'branch', b.name, 'vat_percentage', t.vat_percentage,
                                                           'service_charge_percentage', t.service_charge_percentage,
                                                           'is_vat_inclusive', coalesce(t.is_vat_inclusive, false),
                                                           'is_service_taxable', coalesce(t.is_service_taxable, true)) order by b.name), '[]')
                from public.branches b left join public.branch_tax_settings t on t.branch_id = b.id where b.brand_id = v_brand));

  when 'get_recipe' then
    v_id := public.pos_uuid(d->>'product_id');
    v_result := jsonb_build_object('lines', (select coalesce(jsonb_agg(jsonb_build_object('ingredient_id', r.ingredient_id, 'ingredient', i.name,
                                                   'unit', i.unit, 'qty', r.quantity_required, 'cost', round(r.quantity_required * i.cost_per_unit, 2))
                                                   order by i.name), '[]')
                                               from public.recipes r join public.ingredients i on i.id = r.ingredient_id where r.product_id = v_id),
                                   'unit_cost', round(public.pos_product_cost(v_id), 2));

  when 'save_recipe' then
    v_id := public.pos_uuid(d->>'product_id');
    if v_id is null or not exists (select 1 from public.products p where p.id = v_id and p.brand_id = v_brand) then
      return jsonb_build_object('ok', false, 'reason', 'product_not_found');
    end if;
    if jsonb_typeof(d->'lines') is distinct from 'array' or jsonb_array_length(d->'lines') > 50 then
      return jsonb_build_object('ok', false, 'reason', 'invalid_items');
    end if;
    for l in select e.value from jsonb_array_elements(d->'lines') e(value) loop
      if not exists (select 1 from public.ingredients i where i.id = public.pos_uuid(l->>'ingredient_id'))
         or coalesce(public.pos_amount(l->>'qty'), 0) <= 0 then
        return jsonb_build_object('ok', false, 'reason', 'invalid_items');
      end if;
    end loop;
    delete from public.recipes where product_id = v_id;
    insert into public.recipes (product_id, ingredient_id, quantity_required)
    select v_id, (e.value->>'ingredient_id')::uuid, sum((e.value->>'qty')::numeric)
      from jsonb_array_elements(d->'lines') e(value) group by 2;

  when 'save_ingredient' then
    v_id := public.pos_uuid(d->>'id');
    v_txt := nullif(btrim(coalesce(d->>'name', '')), '');
    if v_txt is null or nullif(btrim(coalesce(d->>'unit', '')), '') is null then
      return jsonb_build_object('ok', false, 'reason', 'invalid_name');
    end if;
    if v_id is null then
      insert into public.ingredients (name, unit, cost_per_unit, min_stock_alert, brand_id)
      values (left(v_txt, 100), left(btrim(d->>'unit'), 20), coalesce(public.pos_amount(d->>'cost_per_unit'), 0),
              coalesce(public.pos_amount(d->>'min_stock_alert'), 0), v_brand) returning id into v_id;
    else
      -- the cost changes only through purchases (average cost), never by hand
      update public.ingredients set name = left(v_txt, 100), unit = left(btrim(d->>'unit'), 20),
             min_stock_alert = coalesce(public.pos_amount(d->>'min_stock_alert'), min_stock_alert)
       where id = v_id;
    end if;

  when 'set_category_station' then
    v_txt := d->>'station';
    if v_txt is null or v_txt not in ('kitchen', 'bar', 'shisha') then
      return jsonb_build_object('ok', false, 'reason', 'invalid_value');
    end if;
    update public.categories set station = v_txt where id = public.pos_uuid(d->>'category_id') and brand_id = v_brand;

  when 'save_discount' then
    v_id := public.pos_uuid(d->>'id');
    v_txt := nullif(btrim(coalesce(d->>'name', '')), '');
    v_num := public.pos_amount(d->>'value');
    if v_txt is null or coalesce(d->>'discount_type', '') not in ('percentage', 'fixed') or v_num is null or v_num <= 0
       or (d->>'discount_type' = 'percentage' and v_num > 100) then
      return jsonb_build_object('ok', false, 'reason', 'invalid_value');
    end if;
    if v_id is null then
      insert into public.discounts (brand_id, name, discount_type, value, requires_approval)
      values (v_brand, left(v_txt, 100), d->>'discount_type', v_num, coalesce(d->>'requires_approval', 'true') = 'true');
    else
      update public.discounts set name = left(v_txt, 100), discount_type = d->>'discount_type', value = v_num,
             requires_approval = coalesce(d->>'requires_approval', 'true') = 'true'
       where id = v_id and brand_id = v_brand;
    end if;

  when 'save_cancel_reason' then
    v_id := public.pos_uuid(d->>'id');
    v_txt := nullif(btrim(coalesce(d->>'reason', '')), '');
    if v_txt is null or coalesce(d->>'reason_type', '') not in ('void_item', 'cancel_order', 'return') then
      return jsonb_build_object('ok', false, 'reason', 'invalid_value');
    end if;
    if v_id is null then
      insert into public.cancel_reasons (brand_id, reason, reason_type) values (v_brand, left(v_txt, 150), d->>'reason_type');
    else
      update public.cancel_reasons set reason = left(v_txt, 150), reason_type = d->>'reason_type' where id = v_id and brand_id = v_brand;
    end if;

  when 'add_area' then
    v_txt := nullif(btrim(coalesce(d->>'name', '')), '');
    if v_txt is null then
      return jsonb_build_object('ok', false, 'reason', 'invalid_name');
    end if;
    insert into public.areas (branch_id, name) values (c.branch_id, left(v_txt, 100)) returning id into v_id;

  when 'set_payment_account' then
    if c.role_name <> 'owner' then
      return jsonb_build_object('ok', false, 'reason', 'not_allowed');
    end if;
    v_txt := d->>'method';
    v_id := public.pos_uuid(d->>'account_id');
    if v_txt is null or v_txt not in ('cash', 'card', 'instapay', 'wallet', 'on_account')
       or not exists (select 1 from public.accounts a where a.id = v_id and a.company_id = c.company_id and a.account_type = 'asset') then
      return jsonb_build_object('ok', false, 'reason', 'invalid_value');
    end if;
    insert into public.payment_method_account_mappings (company_id, payment_method, account_id)
    values (c.company_id, v_txt, v_id)
    on conflict (company_id, payment_method) do update set account_id = excluded.account_id;

  when 'save_tax_flags' then
    v_id := public.pos_uuid(d->>'branch_id');
    if v_id is null or not exists (select 1 from public.branches b where b.id = v_id and b.brand_id = v_brand)
       or coalesce(d->>'is_vat_inclusive', '') not in ('true', 'false') or coalesce(d->>'is_service_taxable', '') not in ('true', 'false') then
      return jsonb_build_object('ok', false, 'reason', 'invalid_value');
    end if;
    update public.branch_tax_settings
       set is_vat_inclusive = (d->>'is_vat_inclusive') = 'true', is_service_taxable = (d->>'is_service_taxable') = 'true'
     where branch_id = v_id;
    if not found then
      insert into public.branch_tax_settings (branch_id, is_vat_inclusive, is_service_taxable)
      values (v_id, (d->>'is_vat_inclusive') = 'true', (d->>'is_service_taxable') = 'true');
    end if;

  else
    return jsonb_build_object('ok', false, 'reason', 'unknown_action');
  end case;

  if p_action not in ('get', 'get_recipe') then
    insert into public.settings_logs (staff_id, action, details) values (c.staff_id, p_action, jsonb_build_object('data', d, 'id', v_id));
  end if;
  return jsonb_build_object('ok', true, 'id', v_id) || v_result;
end;
$$;

-- ===================================================================================
-- PART D: permissions + self-test
-- ===================================================================================
do $grants$
declare
  f record;
begin
  -- internal helpers and trigger functions: never callable with the public key
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and (p.proname like 'pos\_%' or p.proname like 'trg\_%')
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
  end loop;
  -- screen functions: callable, each one checks the shift ticket inside
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname like '%\_secure'
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to anon, authenticated, service_role', f.sig);
  end loop;
  -- customer QR page: no login, only these two
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname like '%\_public'
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to anon, authenticated, service_role', f.sig);
  end loop;
end;
$grants$;

do $selftest$
declare
  v_cashier uuid;
  v_manager uuid;
  v_branch uuid;
  v_tok_c text := 'mp-t8-c-' || md5(random()::text || clock_timestamp()::text);
  v_tok_m text := 'mp-t8-m-' || md5(random()::text || clock_timestamp()::text);
  v_res jsonb;
  v_product uuid;
  v_category uuid;
  v_order uuid;
  v_qr text;
  v_key text;
  v_acc_cash uuid;
  v_acc_owner uuid;
begin
  begin
    select s.id, s.branch_id into v_cashier, v_branch from public.staff s join public.roles r on r.id = s.role_id
     where s.is_active is true and r.name = 'cashier' and s.branch_id is not null limit 1;
    select s.id into v_manager from public.staff s join public.roles r on r.id = s.role_id
     where s.is_active is true and r.name = 'branch_manager' and s.branch_id = v_branch limit 1;
    if v_cashier is null or v_manager is null then
      raise notice 'selftest skipped';
      raise exception using errcode = 'P0099', message = 'selftest_skip';
    end if;
    insert into public.staff_sessions (token_hash, staff_id, expires_at) values
      (encode(extensions.digest(v_tok_c, 'sha256'), 'hex'), v_cashier, now() + interval '10 minutes'),
      (encode(extensions.digest(v_tok_m, 'sha256'), 'hex'), v_manager, now() + interval '10 minutes');

    -- 1) settings: manager can save receipt settings, cannot touch general ones; unknown keys are dropped
    v_res := public.app_settings_save_secure(v_tok_m, 'receipt', jsonb_build_object('footer', 'test', 'hack', 'x'));
    if not coalesce((v_res->>'ok')::boolean, false) or v_res->'settings'->'receipt'->>'footer' <> 'test'
       or v_res->'settings'->'receipt' ? 'hack' then
      raise exception 'SELFTEST settings save failed: %', v_res;
    end if;
    v_res := public.app_settings_save_secure(v_tok_m, 'general', jsonb_build_object('company_name', 'x'));
    if coalesce(v_res->>'reason', '') <> 'not_allowed' then raise exception 'SELFTEST manager changed general settings'; end if;
    v_res := public.app_settings_save_secure(v_tok_m, 'receipt', jsonb_build_object('copies', 'many'));
    if coalesce(v_res->>'reason', '') <> 'invalid_value' then raise exception 'SELFTEST wrong type accepted'; end if;

    -- 2) station routing: the product's category goes to the bar, the bar screen sees it, ready reaches the waiter feed
    select p.id, p.category_id into v_product, v_category from public.products p join public.branches b on b.brand_id = p.brand_id
     where b.id = v_branch and p.is_available is true and p.price > 1 and p.category_id is not null
       and not exists (select 1 from public.product_modifier_groups g join public.modifier_groups mg on mg.id = g.group_id
                        where g.product_id = p.id and (coalesce(mg.min_selection, 0) > 0 or coalesce(mg.is_required, false)))
     order by p.id limit 1;
    if v_product is not null then
      v_res := public.settings2_secure(v_tok_m, 'set_category_station', jsonb_build_object('category_id', v_category, 'station', 'bar'));
      if not coalesce((v_res->>'ok')::boolean, false) then raise exception 'SELFTEST station set failed: %', v_res; end if;
      v_res := public.submit_order_items_secure(v_tok_c, null::uuid, 'takeaway', null::uuid, null::uuid, null::uuid, null::uuid, 1,
                 jsonb_build_array(jsonb_build_object('product_id', v_product, 'quantity', 1, 'modifier_ids', '[]'::jsonb)));
      if not coalesce((v_res->>'ok')::boolean, false) then raise exception 'SELFTEST submit failed: %', v_res; end if;
      v_order := (v_res->>'order_id')::uuid;
      v_res := public.kds_station_list_secure(v_tok_c, 'bar');
      if not exists (select 1 from jsonb_array_elements(v_res->'orders') e(value) where (e.value->>'id')::uuid = v_order) then
        raise exception 'SELFTEST bar screen does not show the order';
      end if;
      v_res := public.kds_station_list_secure(v_tok_c, 'kitchen');
      if exists (select 1 from jsonb_array_elements(v_res->'orders') e(value) where (e.value->>'id')::uuid = v_order) then
        raise exception 'SELFTEST kitchen screen shows a bar order';
      end if;
      v_res := public.kds_station_set_secure(v_tok_c, v_order, 'bar', 'ready');
      if (select o.kitchen_status from public.orders o where o.id = v_order) <> 'ready' then
        raise exception 'SELFTEST order not ready after its only station is ready';
      end if;
      v_res := public.waiter_feed_secure(v_tok_m);
      if not exists (select 1 from jsonb_array_elements(v_res->'ready') e(value) where (e.value->>'order_id')::uuid = v_order) then
        raise exception 'SELFTEST waiter feed misses the ready order';
      end if;
      v_res := public.order_print_data_secure(v_tok_c, v_order);
      if not coalesce((v_res->>'ok')::boolean, false) or jsonb_array_length(v_res->'order'->'items') < 1 then
        raise exception 'SELFTEST print data failed: %', v_res;
      end if;
    end if;

    -- 3) QR page and table calls
    select t.qr_token into v_qr from public.tables t join public.areas a on a.id = t.area_id where a.branch_id = v_branch limit 1;
    if v_qr is not null then
      v_res := public.qr_menu_public(v_qr);
      if not coalesce((v_res->>'ok')::boolean, false) then raise exception 'SELFTEST qr menu failed: %', v_res; end if;
      v_res := public.qr_request_public(v_qr, 'waiter');
      if not coalesce((v_res->>'ok')::boolean, false) then raise exception 'SELFTEST qr call failed: %', v_res; end if;
      v_res := public.qr_request_public(v_qr, 'waiter');
      if not coalesce((v_res->>'already')::boolean, false) then raise exception 'SELFTEST duplicate call not merged'; end if;
      v_res := public.qr_menu_public('000000000000000000000000');
      if coalesce((v_res->>'ok')::boolean, true) then raise exception 'SELFTEST fake qr accepted'; end if;
    end if;

    -- 4) every report runs
    foreach v_key in array array['sales_daily','sales_monthly','sales_hourly','sales_weekday','sales_payment_method','sales_order_type',
      'sales_category','sales_item','sales_modifiers','sales_waiter','sales_cashier','sales_compare','item_profit','category_profit',
      'daily_profit','discounts_detail','voids_detail','refunds_detail','theft_indicators','long_open_orders','manager_approvals',
      'stock_valuation','waste_by_reason','count_variances','low_stock','stock_turnover','transfers','purchases_by_supplier',
      'purchases_by_ingredient','price_changes','unmatched_invoices','supplier_aging','cash_movements','shifts','expenses_by_category',
      'customer_balances','top_customers','attendance','tips_by_staff','staff_balances','vat_monthly']
    loop
      v_res := public.report_secure(v_tok_m, v_key, current_date - 60, current_date, null);
      if not coalesce((v_res->>'ok')::boolean, false) or jsonb_typeof(v_res->'rows') <> 'array' then
        raise exception 'SELFTEST report % failed: %', v_key, v_res;
      end if;
    end loop;
    begin
      perform public.report_secure(v_tok_c, 'sales_daily', null, null, null);
      raise exception 'SELFTEST the cashier can see reports';
    exception when sqlstate '42501' then null;
    end;

    -- 5) accounting: manual entry (balanced ok, unbalanced refused), statements
    select a.id into v_acc_cash from public.accounts a join public.staff s on s.company_id = a.company_id where s.id = v_manager and a.code = '1100';
    select a.id into v_acc_owner from public.accounts a join public.staff s on s.company_id = a.company_id where s.id = v_manager and a.code = '3300';
    v_res := public.journal_manual_secure(v_tok_m, current_date, 'selftest', jsonb_build_array(
               jsonb_build_object('account_id', v_acc_cash, 'debit', 10), jsonb_build_object('account_id', v_acc_owner, 'credit', 10)), null);
    if not coalesce((v_res->>'ok')::boolean, false) then raise exception 'SELFTEST manual entry failed: %', v_res; end if;
    if (public.journal_get_secure(v_tok_m, (v_res->>'id')::uuid)->>'ok')::boolean is not true then raise exception 'SELFTEST journal get failed'; end if;
    v_res := public.journal_manual_secure(v_tok_m, current_date, 'selftest', jsonb_build_array(
               jsonb_build_object('account_id', v_acc_cash, 'debit', 10), jsonb_build_object('account_id', v_acc_owner, 'credit', 9)), null);
    if coalesce(v_res->>'reason', '') <> 'not_balanced' then raise exception 'SELFTEST unbalanced entry accepted: %', v_res; end if;
    if (public.pnl_secure(v_tok_m, null, null, null)->>'ok')::boolean is not true
       or (public.balance_sheet_secure(v_tok_m, null)->>'ok')::boolean is not true
       or (public.general_ledger_secure(v_tok_m, v_acc_cash, null, null, null)->>'ok')::boolean is not true
       or (public.journal_list_secure(v_tok_m, null, null, null, null, null)->>'ok')::boolean is not true
       or (public.fiscal_periods_secure(v_tok_m, null, null)->>'ok')::boolean is not true then
      raise exception 'SELFTEST accounting screens failed';
    end if;
    v_res := public.fiscal_periods_secure(v_tok_m, (select f.id from public.fiscal_periods f limit 1), 'close');
    if coalesce(v_res->>'reason', '') <> 'not_allowed' then raise exception 'SELFTEST manager closed a period'; end if;

    -- 6) customers: save one, receiving more than the balance is refused
    v_res := public.customers_secure(v_tok_m, jsonb_build_object('name', 'selftest customer', 'customer_type', 'on_account', 'credit_limit', '500'));
    if not coalesce((v_res->>'ok')::boolean, false) then raise exception 'SELFTEST customer save failed: %', v_res; end if;
    v_res := public.customer_receive_secure(v_tok_m, (v_res->>'id')::uuid, 10, 'main_cash', 'x');
    if coalesce(v_res->>'reason', '') <> 'invalid_amount' then raise exception 'SELFTEST receive above balance accepted: %', v_res; end if;

    -- 7) settings screens
    if (public.settings2_secure(v_tok_m, 'get', null)->>'ok')::boolean is not true then raise exception 'SELFTEST settings get failed'; end if;
    if (public.app_settings_get_secure(v_tok_c)->>'ok')::boolean is not true then raise exception 'SELFTEST settings read failed'; end if;

    raise notice 'MOTIONPOS-PH8-11-SELFTEST-OK';
    raise exception using errcode = 'P0099', message = 'selftest_rollback';
  exception when sqlstate 'P0099' then
    null;
  end;
end;
$selftest$;

commit;
