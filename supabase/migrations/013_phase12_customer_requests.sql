-- 013_phase12_customer_requests.sql
-- Phase 12 (customer requests):
--   * every item keeps its times: sent / started / ready / served, and every order its close time
--   * sales screen (every order with all its details) + preparation-time analysis (what is late)
--   * customers screen: profile, history, follow-up; one phone number = one customer; quick add from the cashier
--   * modifiers (extras) admin screen with prices, optional stock usage, linked to products
--   * quick notes (no onion, sugar aside...) from the settings
--   * late limit per station (kitchen 20 min, bar 10, shisha 10 by default)
-- Same rules as before. If anything fails (including the self-test) the WHOLE file is rolled back.

begin;

do $preflight$
begin
  if length('إكراميات') <> 8 then
    raise exception 'file_encoding_broken: read the file as UTF-8';
  end if;
  if to_regprocedure('public.order_print_data_secure(text,uuid)') is null
     or to_regprocedure('public.settings2_secure(text,text,jsonb)') is null
     or to_regprocedure('public.kds_station_set_secure(text,uuid,text,text)') is null
     or to_regclass('public.order_station_status') is null then
    raise exception 'schema_preflight_failed: run 001 to 012 first';
  end if;
end;
$preflight$;

-- ===================================================================================
-- PART A: permissions (two new screens: sales, customers)
-- ===================================================================================
create or replace function public.pos_all_perms()
returns text[]
language sql
immutable
as $$
  select array['pos','kds','shift','inventory','inventory_approve','purchasing','treasury','expenses','staff','payroll',
               'reports','settings','accounting','sales','customers']
$$;

insert into public.role_permissions (role_name, perm)
values ('branch_manager', 'sales'), ('branch_manager', 'customers'), ('cashier', 'customers')
on conflict do nothing;

create or replace function public.role_permissions_secure(p_token text, p_role text, p_perms jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
  v_all text[] := public.pos_all_perms();
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
    'perms', case when c.role_name = 'owner' then to_jsonb(public.pos_all_perms())
             else coalesce((select jsonb_agg(rp.perm) from public.role_permissions rp where rp.role_name = c.role_name), '[]'::jsonb) end);
end;
$$;

-- ===================================================================================
-- PART B: settings: quick notes + late limit per station
-- ===================================================================================
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
                              'require_waiter', false, 'round_total', false,
                              'quick_notes', jsonb_build_array('بدون بصل', 'بدون طماطم', 'بدون مايونيز', 'حار', 'سكر زيادة',
                                                               'سكر خفيف', 'سكر بره', 'من غير سكر', 'من غير تلج', 'تلج زيادة')),
    'kds', jsonb_build_object('stations', jsonb_build_array('kitchen', 'bar', 'shisha'), 'warn_minutes', 15, 'sound', true,
                              'refresh_seconds', 10, 'warn_kitchen_minutes', 20, 'warn_bar_minutes', 10, 'warn_shisha_minutes', 10),
    'waiter_qr', jsonb_build_object('qr_enabled', true, 'qr_call_waiter', true, 'qr_request_bill', true, 'qr_show_prices', true),
    'shift', jsonb_build_object('default_float', 0, 'drawer_alert_limit', 5000),
    'inventory', jsonb_build_object('allow_negative_stock', true, 'default_min_stock', 5),
    'staff', jsonb_build_object('work_start_time', '09:00', 'late_grace_minutes', 15),
    'offline', jsonb_build_object('mode', 'none', 'local_server_url', '')
  )
$$;

-- Same as before, plus: lists must be short texts, late limits between 1 and 240 minutes
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

-- Late limit (minutes) of one station
create or replace function public.pos_station_warn(p_company_id uuid, p_station text)
returns numeric
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
declare
  v_txt text;
  v_default numeric := 10;
begin
  if p_station = 'kitchen' then
    v_default := 20;
  end if;
  v_txt := public.pos_app_settings(p_company_id) -> 'kds' ->> ('warn_' || coalesce(p_station, 'kitchen') || '_minutes');
  if v_txt is null or v_txt !~ '^[0-9]{1,3}(\.[0-9]+)?$' then
    return v_default;
  end if;
  return v_txt::numeric;
end;
$$;

-- ===================================================================================
-- PART C: times of every item (sent, started, ready, served) and of every order (closed)
-- ===================================================================================
alter table public.order_items add column if not exists sent_at timestamptz;
alter table public.order_items add column if not exists prep_started_at timestamptz;
alter table public.order_items add column if not exists ready_at timestamptz;
alter table public.order_items add column if not exists served_at timestamptz;
alter table public.orders add column if not exists closed_at timestamptz;

update public.order_items oi set sent_at = o.created_at
  from public.orders o
 where o.id = oi.order_id and oi.sent_at is null;
alter table public.order_items alter column sent_at set default now();

update public.order_items oi set ready_at = coalesce(s.ready_at, s.updated_at)
  from public.order_station_status s
 where s.order_id = oi.order_id and s.station = public.pos_item_station(oi.product_id)
   and s.status in ('ready', 'served') and oi.ready_at is null;

update public.orders o
   set closed_at = coalesce((select max(p.created_at) from public.payments p where p.order_id = o.id), o.created_at)
 where o.closed_at is null and o.status in ('closed', 'paid', 'cancelled');

create index if not exists order_items_order_sent_idx on public.order_items (order_id, sent_at);
create index if not exists orders_company_created_idx on public.orders (company_id, created_at);
create index if not exists orders_customer_idx on public.orders (customer_id);

create or replace function public.trg_orders_closed_at()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if coalesce(new.status, '') in ('closed', 'paid', 'cancelled') then
    if coalesce(old.status, '') not in ('closed', 'paid', 'cancelled') then
      new.closed_at := now();
    end if;
  else
    new.closed_at := null;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_orders_closed_at on public.orders;
create trigger trg_orders_closed_at
before update of status on public.orders
for each row execute function public.trg_orders_closed_at();

-- A new item makes its station wait again. An item that was already prepared (moved by split / merge)
-- keeps its times and does not go back to the kitchen.
create or replace function public.trg_order_items_station()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_station text := public.pos_item_station(new.product_id);
  v_status text := 'ready';
begin
  if coalesce(new.status, 'active') = 'active' then
    if new.ready_at is null then
      insert into public.order_station_status (order_id, station, status)
      values (new.order_id, v_station, 'pending')
      on conflict (order_id, station)
      do update set status = 'pending', updated_at = now(), ready_at = null
              where public.order_station_status.status in ('ready', 'served');
    else
      if new.served_at is not null then
        v_status := 'served';
      end if;
      insert into public.order_station_status (order_id, station, status, ready_at)
      values (new.order_id, v_station, v_status, new.ready_at)
      on conflict (order_id, station) do nothing;
    end if;
  end if;
  perform public.pos_order_kitchen_sync(new.order_id);
  if tg_op = 'UPDATE' then
    if old.order_id is distinct from new.order_id then
      perform public.pos_order_kitchen_sync(old.order_id);
    end if;
  end if;
  return null;
end;
$$;

drop trigger if exists trg_order_items_station on public.order_items;
create trigger trg_order_items_station
after insert or update of order_id on public.order_items
for each row execute function public.trg_order_items_station();

-- When a station starts / finishes / the waiter takes it: stamp the times of its waiting items
create or replace function public.trg_station_item_times()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if new.status is not distinct from old.status then
    return null;
  end if;
  if new.status = 'preparing' then
    update public.order_items oi set prep_started_at = now()
     where oi.order_id = new.order_id and coalesce(oi.status, 'active') = 'active'
       and oi.ready_at is null and oi.prep_started_at is null
       and public.pos_item_station(oi.product_id) = new.station;
  elsif new.status = 'ready' then
    update public.order_items oi set ready_at = now(), prep_started_at = coalesce(oi.prep_started_at, oi.sent_at, now())
     where oi.order_id = new.order_id and coalesce(oi.status, 'active') = 'active'
       and oi.ready_at is null
       and public.pos_item_station(oi.product_id) = new.station;
  elsif new.status = 'served' then
    update public.order_items oi set served_at = now()
     where oi.order_id = new.order_id and coalesce(oi.status, 'active') = 'active'
       and oi.ready_at is not null and oi.served_at is null
       and public.pos_item_station(oi.product_id) = new.station;
  end if;
  return null;
end;
$$;

drop trigger if exists trg_station_item_times on public.order_station_status;
create trigger trg_station_item_times
after update of status on public.order_station_status
for each row execute function public.trg_station_item_times();

-- Kitchen / bar / shisha screen: only items not prepared yet, each with its sent time; the card timer
-- starts from the oldest waiting item, and the late limit of the station comes with the list.
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
  return jsonb_build_object('ok', true, 'warn_minutes', public.pos_station_warn(c.company_id, p_station), 'orders', coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', o.id, 'order_number', o.order_number, 'order_type', o.order_type, 'status', s.status,
             'created_at', o.created_at, 'station_since', s.updated_at, 'table_number', t.table_number, 'waiter', w.name,
             'since', (select min(x.sent_at) from public.order_items x
                        where x.order_id = o.id and coalesce(x.status, 'active') = 'active' and x.ready_at is null
                          and public.pos_item_station(x.product_id) = p_station),
             'items', (select jsonb_agg(jsonb_build_object(
                         'name', coalesce(p.name, 'صنف'), 'quantity', oi.quantity, 'item_notes', oi.item_notes, 'sent_at', oi.sent_at,
                         'modifiers', coalesce((select jsonb_agg(m.modifier_name) from public.order_item_modifiers m
                                                 where m.order_item_id = oi.id), '[]'::jsonb)) order by oi.sent_at, p.name)
                         from public.order_items oi left join public.products p on p.id = oi.product_id
                        where oi.order_id = o.id and coalesce(oi.status, 'active') = 'active' and oi.ready_at is null
                          and public.pos_item_station(oi.product_id) = p_station)) order by o.created_at)
      from public.order_station_status s
      join public.orders o on o.id = s.order_id
      left join public.tables t on t.id = o.table_id
      left join public.staff w on w.id = o.waiter_id
     where o.branch_id = c.branch_id and s.station = p_station and s.status in ('pending', 'preparing')
       and coalesce(o.status, '') <> 'cancelled' and o.created_at > now() - interval '24 hours'
       and exists (select 1 from public.order_items x where x.order_id = o.id and coalesce(x.status, 'active') = 'active'
                     and x.ready_at is null and public.pos_item_station(x.product_id) = p_station)), '[]'::jsonb));
end;
$$;

-- Split: the part of an item that moves to the new order keeps its times (same as before otherwise)
create or replace function public.split_order_items_secure(p_token text, p_order_id uuid, p_items jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_staff uuid;
  v_branch uuid;
  v_order public.orders%rowtype;
  v_e jsonb;
  v_item_id uuid;
  v_qty int;
  v_item public.order_items%rowtype;
  v_moved int := 0;
  v_total_qty int;
  v_count int;
  v_distinct int;
  v_new_id uuid;
  v_new_number text;
  v_new_item uuid;
begin
  select rs.staff_id, rs.branch_id into v_staff, v_branch from public.require_session(p_token) rs;

  select o.* into v_order from public.orders o where o.id = p_order_id and o.branch_id = v_branch for update;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'order_not_found');
  end if;
  if coalesce(v_order.status, '') in ('paid', 'closed', 'cancelled') then
    return jsonb_build_object('ok', false, 'reason', 'order_not_open');
  end if;
  if jsonb_typeof(p_items) is distinct from 'array' or jsonb_array_length(p_items) < 1 or jsonb_array_length(p_items) > 200 then
    return jsonb_build_object('ok', false, 'reason', 'invalid_items');
  end if;

  select count(*), count(distinct e.value->>'order_item_id') into v_count, v_distinct
    from jsonb_array_elements(p_items) as e(value);
  if v_count <> v_distinct then
    return jsonb_build_object('ok', false, 'reason', 'duplicate_item');
  end if;

  -- First pass: check everything before changing anything
  for v_e in select e.value from jsonb_array_elements(p_items) as e(value)
  loop
    v_item_id := public.pos_uuid(v_e->>'order_item_id');
    if v_item_id is null or coalesce(v_e->>'quantity', '') !~ '^[1-9][0-9]{0,5}$' then
      return jsonb_build_object('ok', false, 'reason', 'invalid_items');
    end if;
    v_qty := (v_e->>'quantity')::int;
    select oi.* into v_item
      from public.order_items oi
     where oi.id = v_item_id and oi.order_id = p_order_id and coalesce(oi.status, 'active') = 'active'
     for update;
    if not found then
      return jsonb_build_object('ok', false, 'reason', 'item_not_found');
    end if;
    if v_qty > v_item.quantity then
      return jsonb_build_object('ok', false, 'reason', 'quantity_too_big');
    end if;
    v_moved := v_moved + v_qty;
  end loop;

  select coalesce(sum(oi.quantity), 0) into v_total_qty
    from public.order_items oi
   where oi.order_id = p_order_id and coalesce(oi.status, 'active') = 'active';
  if v_total_qty - v_moved < 1 then
    return jsonb_build_object('ok', false, 'reason', 'nothing_left');
  end if;

  insert into public.orders (company_id, brand_id, branch_id, area_id, table_id, waiter_id, customer_id,
                             order_type, guest_count, status, kitchen_status, vat_enabled, service_enabled, notes)
  values (v_order.company_id, v_order.brand_id, v_order.branch_id, v_order.area_id, v_order.table_id,
          v_order.waiter_id, v_order.customer_id, v_order.order_type, 1, v_order.status, v_order.kitchen_status,
          v_order.vat_enabled, v_order.service_enabled, 'تقسيم من ' || coalesce(v_order.order_number, ''))
  returning id, order_number into v_new_id, v_new_number;

  -- Second pass: move
  for v_e in select e.value from jsonb_array_elements(p_items) as e(value)
  loop
    v_item_id := (v_e->>'order_item_id')::uuid;
    v_qty := (v_e->>'quantity')::int;
    select oi.* into v_item from public.order_items oi where oi.id = v_item_id;
    if v_qty = v_item.quantity then
      update public.order_items set order_id = v_new_id where id = v_item_id;
    else
      update public.order_items
         set quantity = v_item.quantity - v_qty,
             total_price = round(v_item.unit_price * (v_item.quantity - v_qty), 2)
       where id = v_item_id;
      insert into public.order_items (order_id, product_id, quantity, unit_price, total_price, item_notes,
                                      sent_at, prep_started_at, ready_at, served_at)
      values (v_new_id, v_item.product_id, v_qty, v_item.unit_price, round(v_item.unit_price * v_qty, 2), v_item.item_notes,
              coalesce(v_item.sent_at, now()), v_item.prep_started_at, v_item.ready_at, v_item.served_at)
      returning id into v_new_item;
      insert into public.order_item_modifiers (order_item_id, modifier_id, modifier_name, unit_price)
      select v_new_item, m.modifier_id, m.modifier_name, m.unit_price
        from public.order_item_modifiers m
       where m.order_item_id = v_item_id;
    end if;
  end loop;

  insert into public.order_logs (order_id, user_id, action, details)
  values (p_order_id, v_staff, 'SPLIT_ORDER', jsonb_build_object('new_order', v_new_number, 'items', p_items)),
         (v_new_id, v_staff, 'SPLIT_FROM', jsonb_build_object('source_order', v_order.order_number));

  return jsonb_build_object('ok', true, 'new_order_id', v_new_id, 'new_order_number', v_new_number);
end;
$$;

-- ===================================================================================
-- PART D: modifiers (extras) admin. Prices are still read on the server when an order is sent.
-- A modifier that was already sold is never deleted: it is only taken out of its group (history stays).
-- ===================================================================================
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

-- ===================================================================================
-- PART E: customers. One phone number = one customer (0100..., +20100..., ٠١٠٠... are the same number).
-- ===================================================================================
create or replace function public.pos_phone_norm(p text)
returns text
language sql
immutable
as $$
  select case when x.d ~ '^20[0-9]{10}$' then '0' || substr(x.d, 3) else x.d end
    from (select regexp_replace(translate(coalesce(p, ''), '٠١٢٣٤٥٦٧٨٩۰۱۲۳۴۵۶۷۸۹', '01234567890123456789'), '[^0-9]', '', 'g') as d) x
$$;

do $dupes$
begin
  if exists (select 1 from public.customers cu where public.pos_phone_norm(cu.phone) <> ''
              group by cu.company_id, public.pos_phone_norm(cu.phone) having count(*) > 1) then
    raise exception 'duplicate_customer_phones: two customers have the same phone number. Fix them first.';
  end if;
end;
$dupes$;

create unique index if not exists customers_company_phone_uq
  on public.customers (company_id, public.pos_phone_norm(phone)) where public.pos_phone_norm(phone) <> '';

alter table public.customers add column if not exists birthday date;
alter table public.customers add column if not exists notes text;
alter table public.customers add column if not exists created_by uuid;
alter table public.customers add column if not exists updated_at timestamptz;

create table if not exists public.customer_followups (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null,
  customer_id uuid not null references public.customers(id) on delete cascade,
  staff_id uuid,
  note text not null,
  next_date date,
  done_at timestamptz,
  done_by uuid,
  created_at timestamptz not null default now()
);
create index if not exists customer_followups_customer_idx on public.customer_followups (customer_id, created_at);
create index if not exists customer_followups_due_idx on public.customer_followups (company_id, next_date) where done_at is null;
alter table public.customer_followups enable row level security;

-- Can this session give credit (on account) to customers?
create or replace function public.pos_can_credit(p_role text)
returns boolean
language sql
stable
security definer
set search_path = public, extensions
as $$
  select public.pos_is_manager(p_role)
      or exists (select 1 from public.role_permissions rp where rp.role_name = p_role and rp.perm = 'accounting')
$$;

create or replace function public.pos_customer_brief(p_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public, extensions
as $$
  select jsonb_build_object('id', cu.id, 'name', cu.name, 'phone', cu.phone, 'customer_type', cu.customer_type)
    from public.customers cu where cu.id = p_id
$$;

-- Accounting tab "customers" (same as before) + same-phone check
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
  v_phone text;
  v_other uuid;
begin
  select * into c from public.pos_ctx(p_token, null);
  if p_data is not null then
    if not public.pos_can_credit(c.role_name) then
      return jsonb_build_object('ok', false, 'reason', 'not_allowed');
    end if;
    v_id := public.pos_uuid(p_data->>'id');
    v_name := nullif(btrim(coalesce(p_data->>'name', '')), '');
    v_type := coalesce(p_data->>'customer_type', 'registered');
    v_limit := coalesce(public.pos_amount(p_data->>'credit_limit'), 0);
    v_phone := left(public.pos_phone_norm(p_data->>'phone'), 20);
    if v_name is null or length(v_name) > 150 or v_type not in ('cash', 'registered', 'on_account') then
      return jsonb_build_object('ok', false, 'reason', 'invalid_value');
    end if;
    if v_phone <> '' then
      select cu.id into v_other from public.customers cu
       where cu.company_id = c.company_id and public.pos_phone_norm(cu.phone) = v_phone and cu.id is distinct from v_id limit 1;
      if v_other is not null then
        return jsonb_build_object('ok', false, 'reason', 'phone_taken', 'customer', public.pos_customer_brief(v_other));
      end if;
    end if;
    if v_id is null then
      insert into public.customers (company_id, name, phone, address, customer_type, credit_limit, created_by)
      values (c.company_id, v_name, nullif(v_phone, ''), left(coalesce(p_data->>'address', ''), 300), v_type, v_limit, c.staff_id)
      returning id into v_id;
    else
      update public.customers
         set name = v_name, phone = nullif(v_phone, ''), address = left(coalesce(p_data->>'address', ''), 300),
             customer_type = v_type, credit_limit = v_limit, updated_at = now()
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

-- Customers screen: list with search and quick filters
--   p_filter: all | due (follow-up today or earlier) | inactive (bought before, nothing in 30 days) | birthday (this month)
create or replace function public.customers_list2_secure(p_token text, p_search text, p_filter text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
  v_q text := nullif(btrim(coalesce(p_search, '')), '');
  v_digits text := public.pos_phone_norm(p_search);
  v_filter text := coalesce(nullif(p_filter, ''), 'all');
  v_today date := public.pos_local_date(now());
begin
  select * into c from public.pos_ctx(p_token, 'customers');
  if v_filter not in ('all', 'due', 'inactive', 'birthday') then
    return jsonb_build_object('ok', false, 'reason', 'invalid_value');
  end if;
  return jsonb_build_object('ok', true, 'today', v_today, 'can_credit', public.pos_can_credit(c.role_name), 'customers', coalesce((
    select jsonb_agg(to_jsonb(y) order by y.next_followup nulls last, y.last_visit desc nulls last, y.name)
      from (
        select x.* from (
          select cu.id, cu.name, cu.phone, cu.address, cu.birthday, cu.notes, cu.customer_type, cu.credit_limit, cu.created_at,
                 coalesce(st.orders_count, 0) as orders_count, coalesce(st.total_spent, 0) as total_spent, st.last_visit,
                 coalesce((select sum(l.amount) from public.customer_ledger l where l.customer_id = cu.id), 0) as balance,
                 (select min(f.next_date) from public.customer_followups f
                   where f.customer_id = cu.id and f.done_at is null and f.next_date is not null) as next_followup
            from public.customers cu
            left join lateral (select count(*) as orders_count, sum(o.total_amount) as total_spent, max(o.created_at) as last_visit
                                 from public.orders o where o.customer_id = cu.id and o.status in ('closed', 'paid')) st on true
           where cu.company_id = c.company_id
             and (v_q is null or cu.name ilike '%' || v_q || '%'
                  or (length(v_digits) >= 3 and public.pos_phone_norm(cu.phone) like '%' || v_digits || '%'))
        ) x
         where v_filter = 'all'
            or (v_filter = 'due' and x.next_followup <= v_today)
            or (v_filter = 'inactive' and x.orders_count > 0 and x.last_visit < now() - interval '30 days')
            or (v_filter = 'birthday' and extract(month from x.birthday) = extract(month from v_today))
         order by x.next_followup nulls last, x.last_visit desc nulls last, x.name
         limit 1000
      ) y), '[]'::jsonb));
end;
$$;

-- One customer: details, numbers, favourite items, orders, follow-ups, account balance
create or replace function public.customer_profile_secure(p_token text, p_customer_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
  v_cu public.customers%rowtype;
begin
  select * into c from public.pos_ctx(p_token, 'customers');
  select cu.* into v_cu from public.customers cu where cu.id = p_customer_id and cu.company_id = c.company_id;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'not_found');
  end if;
  return jsonb_build_object('ok', true, 'can_credit', public.pos_can_credit(c.role_name),
    'customer', jsonb_build_object('id', v_cu.id, 'name', v_cu.name, 'phone', v_cu.phone, 'address', v_cu.address,
                                   'birthday', v_cu.birthday, 'notes', v_cu.notes, 'customer_type', v_cu.customer_type,
                                   'credit_limit', v_cu.credit_limit, 'created_at', v_cu.created_at,
                                   'created_by', (select s.name from public.staff s where s.id = v_cu.created_by)),
    'stats', (select jsonb_build_object('orders_count', count(*), 'total_spent', coalesce(sum(o.total_amount), 0),
                                        'avg_ticket', round(coalesce(avg(o.total_amount), 0), 2),
                                        'first_visit', min(o.created_at), 'last_visit', max(o.created_at),
                                        'balance', coalesce((select sum(l.amount) from public.customer_ledger l where l.customer_id = v_cu.id), 0))
                from public.orders o where o.customer_id = v_cu.id and o.status in ('closed', 'paid')),
    'favorites', coalesce((select jsonb_agg(jsonb_build_object('name', f.name, 'quantity', f.qty, 'times', f.times) order by f.qty desc)
                             from (select coalesce(p.name, 'صنف') as name, sum(oi.quantity) as qty, count(distinct o.id) as times
                                     from public.orders o
                                     join public.order_items oi on oi.order_id = o.id and coalesce(oi.status, 'active') = 'active'
                                     left join public.products p on p.id = oi.product_id
                                    where o.customer_id = v_cu.id and o.status in ('closed', 'paid')
                                    group by 1 order by 2 desc limit 5) f), '[]'::jsonb),
    'orders', coalesce((select jsonb_agg(jsonb_build_object('id', o.id, 'order_number', o.order_number, 'created_at', o.created_at,
                                                            'order_type', o.order_type, 'status', o.status, 'total_amount', o.total_amount,
                                                            'branch', b.name) order by o.created_at desc)
                          from (select * from public.orders o2 where o2.customer_id = v_cu.id order by o2.created_at desc limit 100) o
                          left join public.branches b on b.id = o.branch_id), '[]'::jsonb),
    'followups', coalesce((select jsonb_agg(jsonb_build_object('id', f.id, 'note', f.note, 'next_date', f.next_date, 'done_at', f.done_at,
                                                               'created_at', f.created_at, 'by', s.name) order by f.created_at desc)
                             from (select * from public.customer_followups f2 where f2.customer_id = v_cu.id order by f2.created_at desc limit 200) f
                             left join public.staff s on s.id = f.staff_id), '[]'::jsonb));
end;
$$;

-- Add / edit a customer from the customers screen. Phone is required. Credit (on account) only for
-- managers / accounting; everyone else saves the customer as "registered" without touching the credit.
create or replace function public.customer_save2_secure(p_token text, p_data jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
  d jsonb := coalesce(p_data, '{}'::jsonb);
  v_id uuid := public.pos_uuid(d->>'id');
  v_name text := nullif(btrim(coalesce(d->>'name', '')), '');
  v_phone text := public.pos_phone_norm(d->>'phone');
  v_birthday date;
  v_other uuid;
  v_credit boolean;
  v_type text;
  v_limit numeric;
begin
  select * into c from public.pos_ctx(p_token, 'customers');
  v_credit := public.pos_can_credit(c.role_name);
  if v_name is null or length(v_name) > 150 then
    return jsonb_build_object('ok', false, 'reason', 'invalid_name');
  end if;
  if length(v_phone) < 8 or length(v_phone) > 15 then
    return jsonb_build_object('ok', false, 'reason', 'invalid_phone');
  end if;
  if nullif(d->>'birthday', '') is not null then
    if (d->>'birthday') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then
      return jsonb_build_object('ok', false, 'reason', 'invalid_date');
    end if;
    begin
      v_birthday := (d->>'birthday')::date;
    exception when others then
      return jsonb_build_object('ok', false, 'reason', 'invalid_date');
    end;
  end if;
  if length(coalesce(d->>'notes', '')) > 1000 or length(coalesce(d->>'address', '')) > 300 then
    return jsonb_build_object('ok', false, 'reason', 'value_too_long');
  end if;
  select cu.id into v_other from public.customers cu
   where cu.company_id = c.company_id and public.pos_phone_norm(cu.phone) = v_phone and cu.id is distinct from v_id limit 1;
  if v_other is not null then
    return jsonb_build_object('ok', false, 'reason', 'phone_taken', 'customer', public.pos_customer_brief(v_other));
  end if;

  v_type := coalesce(nullif(d->>'customer_type', ''), 'registered');
  v_limit := coalesce(public.pos_amount(d->>'credit_limit'), 0);
  if v_type not in ('cash', 'registered', 'on_account') then
    return jsonb_build_object('ok', false, 'reason', 'invalid_value');
  end if;

  if v_id is null then
    if not v_credit then
      v_type := 'registered';
      v_limit := 0;
    end if;
    insert into public.customers (company_id, name, phone, address, birthday, notes, customer_type, credit_limit, created_by)
    values (c.company_id, v_name, v_phone, nullif(btrim(coalesce(d->>'address', '')), ''), v_birthday,
            nullif(btrim(coalesce(d->>'notes', '')), ''), v_type, v_limit, c.staff_id)
    returning id into v_id;
  else
    update public.customers
       set name = v_name, phone = v_phone, address = nullif(btrim(coalesce(d->>'address', '')), ''), birthday = v_birthday,
           notes = nullif(btrim(coalesce(d->>'notes', '')), ''), updated_at = now()
     where id = v_id and company_id = c.company_id;
    if not found then
      return jsonb_build_object('ok', false, 'reason', 'not_found');
    end if;
    if v_credit and d ? 'customer_type' then
      update public.customers set customer_type = v_type, credit_limit = v_limit where id = v_id;
    end if;
  end if;
  insert into public.settings_logs (staff_id, action, details) values (c.staff_id, 'customer_save', jsonb_build_object('id', v_id, 'data', d));
  return jsonb_build_object('ok', true, 'id', v_id, 'customer', public.pos_customer_brief(v_id));
end;
$$;

-- Follow-up: add a note (closes the earlier open follow-ups of the customer), mark one done, list what is due
create or replace function public.customer_followup_secure(p_token text, p_action text, p_data jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
  d jsonb := coalesce(p_data, '{}'::jsonb);
  v_cust uuid;
  v_note text;
  v_next date;
  v_id uuid;
  v_today date := public.pos_local_date(now());
begin
  select * into c from public.pos_ctx(p_token, 'customers');
  if p_action = 'add' then
    v_cust := public.pos_uuid(d->>'customer_id');
    if v_cust is null or not exists (select 1 from public.customers cu where cu.id = v_cust and cu.company_id = c.company_id) then
      return jsonb_build_object('ok', false, 'reason', 'not_found');
    end if;
    v_note := nullif(btrim(coalesce(d->>'note', '')), '');
    if v_note is null then
      return jsonb_build_object('ok', false, 'reason', 'reason_required');
    end if;
    if length(v_note) > 1000 then
      return jsonb_build_object('ok', false, 'reason', 'value_too_long');
    end if;
    if nullif(d->>'next_date', '') is not null then
      if (d->>'next_date') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then
        return jsonb_build_object('ok', false, 'reason', 'invalid_date');
      end if;
      begin
        v_next := (d->>'next_date')::date;
      exception when others then
        return jsonb_build_object('ok', false, 'reason', 'invalid_date');
      end;
    end if;
    update public.customer_followups set done_at = now(), done_by = c.staff_id
     where customer_id = v_cust and done_at is null;
    insert into public.customer_followups (company_id, customer_id, staff_id, note, next_date, done_at, done_by)
    values (c.company_id, v_cust, c.staff_id, v_note, v_next,
            case when v_next is null then now() end, case when v_next is null then c.staff_id end)
    returning id into v_id;
    return jsonb_build_object('ok', true, 'id', v_id);
  elsif p_action = 'done' then
    v_id := public.pos_uuid(d->>'id');
    update public.customer_followups set done_at = now(), done_by = c.staff_id
     where id = v_id and company_id = c.company_id and done_at is null;
    if not found then
      return jsonb_build_object('ok', false, 'reason', 'not_found');
    end if;
    return jsonb_build_object('ok', true, 'id', v_id);
  elsif p_action = 'due' then
    return jsonb_build_object('ok', true, 'today', v_today, 'followups', coalesce((
      select jsonb_agg(jsonb_build_object('id', f.id, 'customer_id', cu.id, 'name', cu.name, 'phone', cu.phone, 'note', f.note,
                                          'next_date', f.next_date, 'by', s.name, 'created_at', f.created_at) order by f.next_date, cu.name)
        from public.customer_followups f
        join public.customers cu on cu.id = f.customer_id
        left join public.staff s on s.id = f.staff_id
       where f.company_id = c.company_id and f.done_at is null and f.next_date <= v_today + 7), '[]'::jsonb));
  end if;
  return jsonb_build_object('ok', false, 'reason', 'unknown_action');
end;
$$;

-- Cashier: find a customer by phone, or add one in a second (name + phone only, never credit)
create or replace function public.customer_lookup_secure(p_token text, p_phone text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
  v_phone text := public.pos_phone_norm(p_phone);
  v_id uuid;
begin
  select * into c from public.pos_ctx(p_token, 'pos');
  if length(v_phone) < 8 or length(v_phone) > 15 then
    return jsonb_build_object('ok', false, 'reason', 'invalid_phone');
  end if;
  select cu.id into v_id from public.customers cu
   where cu.company_id = c.company_id and public.pos_phone_norm(cu.phone) = v_phone limit 1;
  if v_id is null then
    return jsonb_build_object('ok', true, 'found', false, 'phone', v_phone);
  end if;
  return jsonb_build_object('ok', true, 'found', true, 'customer', public.pos_customer_brief(v_id) || jsonb_build_object(
    'orders_count', (select count(*) from public.orders o where o.customer_id = v_id and o.status in ('closed', 'paid')),
    'last_visit', (select max(o.created_at) from public.orders o where o.customer_id = v_id and o.status in ('closed', 'paid')),
    'notes', (select cu.notes from public.customers cu where cu.id = v_id)));
end;
$$;

create or replace function public.customer_quick_add_secure(p_token text, p_name text, p_phone text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
  v_phone text := public.pos_phone_norm(p_phone);
  v_name text := nullif(btrim(coalesce(p_name, '')), '');
  v_id uuid;
begin
  select * into c from public.pos_ctx(p_token, 'pos');
  if v_name is null or length(v_name) > 150 then
    return jsonb_build_object('ok', false, 'reason', 'invalid_name');
  end if;
  if length(v_phone) < 8 or length(v_phone) > 15 then
    return jsonb_build_object('ok', false, 'reason', 'invalid_phone');
  end if;
  select cu.id into v_id from public.customers cu
   where cu.company_id = c.company_id and public.pos_phone_norm(cu.phone) = v_phone limit 1;
  if v_id is not null then
    return jsonb_build_object('ok', false, 'reason', 'phone_taken', 'customer', public.pos_customer_brief(v_id));
  end if;
  insert into public.customers (company_id, name, phone, customer_type, credit_limit, created_by)
  values (c.company_id, v_name, v_phone, 'registered', 0, c.staff_id)
  returning id into v_id;
  return jsonb_build_object('ok', true, 'id', v_id, 'customer', public.pos_customer_brief(v_id));
end;
$$;

-- ===================================================================================
-- PART F: sales screen. Owner: any branch (or all). Everyone else: own branch only.
-- ===================================================================================
create or replace function public.sales_orders_secure(p_token text, p_from date, p_to date, p_branch_id uuid, p_filters jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
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
                                        > (case public.pos_item_station(oi.product_id) when 'kitchen' then v_wk when 'bar' then v_wb else v_ws end)
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

-- One order with everything: items (also cancelled ones), extras, notes, times, payments, discount, history
create or replace function public.sales_order_detail_secure(p_token text, p_order_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
  v_o public.orders%rowtype;
  v_wk numeric;
  v_wb numeric;
  v_ws numeric;
begin
  select * into c from public.pos_ctx(p_token, 'sales');
  select o.* into v_o from public.orders o
   where o.id = p_order_id and o.company_id = c.company_id and (c.role_name = 'owner' or o.branch_id = c.branch_id);
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'order_not_found');
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

-- What is late: preparation times per station, per item, per hour, and the slowest orders
create or replace function public.sales_timing_secure(p_token text, p_from date, p_to date, p_branch_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
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
             extract(epoch from (oi.ready_at - oi.sent_at)) / 60.0 as total_m
        from public.order_items oi
        join public.orders o on o.id = oi.order_id
        left join public.products p on p.id = oi.product_id
        left join public.tables t on t.id = o.table_id
        left join public.staff w on w.id = o.waiter_id
       where o.company_id = c.company_id and (v_branch is null or o.branch_id = v_branch)
         and public.pos_local_date(oi.sent_at) between v_from and v_to
         and coalesce(oi.status, 'active') = 'active' and oi.ready_at is not null and oi.sent_at is not null
    ), lim as (
      select it.*, (case it.station when 'kitchen' then v_wk when 'bar' then v_wb else v_ws end) as limit_m from it
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

-- ===================================================================================
-- PART G: permissions + self-test
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
  -- customer QR page: no login
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
  v_brand uuid;
  v_tok_c text := 'mp-t12-c-' || md5(random()::text || clock_timestamp()::text);
  v_tok_m text := 'mp-t12-m-' || md5(random()::text || clock_timestamp()::text);
  v_res jsonb;
  v_card jsonb;
  v_cat_food uuid;
  v_cat_drink uuid;
  v_burger uuid;
  v_coffee uuid;
  v_ing uuid;
  v_group uuid;
  v_cheese uuid;
  v_cust uuid;
  v_order uuid;
  v_order_no text;
  v_item uuid;
  v_new_order uuid;
  v_num numeric;
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
    select b.brand_id into v_brand from public.branches b where b.id = v_branch;
    insert into public.staff_sessions (token_hash, staff_id, expires_at) values
      (encode(extensions.digest(v_tok_c, 'sha256'), 'hex'), v_cashier, now() + interval '10 minutes'),
      (encode(extensions.digest(v_tok_m, 'sha256'), 'hex'), v_manager, now() + interval '10 minutes');

    -- 1) permissions: the manager has the two new screens, the cashier cannot open the sales screen
    v_res := public.pos_settings_list_secure(v_tok_m);
    if not (v_res->'perms' ? 'sales') or not (v_res->'perms' ? 'customers') then
      raise exception 'SELFTEST manager misses the new permissions: %', v_res;
    end if;
    begin
      perform public.sales_orders_secure(v_tok_c, null, null, null, null);
      raise exception 'SELFTEST the cashier can see the sales screen';
    exception when sqlstate '42501' then null;
    end;
    begin
      perform public.modifiers_admin_secure(v_tok_c, 'get', null);
      raise exception 'SELFTEST the cashier can manage modifiers';
    exception when sqlstate '42501' then null;
    end;

    -- 2) settings: quick notes and late limits
    v_res := public.app_settings_save_secure(v_tok_m, 'pos', jsonb_build_object('quick_notes', jsonb_build_array('بدون بصل', 'سكر بره')));
    if not coalesce((v_res->>'ok')::boolean, false) or jsonb_array_length(v_res->'settings'->'pos'->'quick_notes') <> 2 then
      raise exception 'SELFTEST quick notes not saved: %', v_res;
    end if;
    v_res := public.app_settings_save_secure(v_tok_m, 'pos', jsonb_build_object('quick_notes', jsonb_build_array(5)));
    if coalesce(v_res->>'reason', '') <> 'invalid_value' then raise exception 'SELFTEST bad quick note accepted: %', v_res; end if;
    v_res := public.app_settings_save_secure(v_tok_m, 'kds', jsonb_build_object('warn_kitchen_minutes', 0));
    if coalesce(v_res->>'reason', '') <> 'invalid_value' then raise exception 'SELFTEST zero late limit accepted: %', v_res; end if;
    v_res := public.app_settings_save_secure(v_tok_m, 'kds', jsonb_build_object('warn_kitchen_minutes', 20, 'warn_bar_minutes', 10));
    if not coalesce((v_res->>'ok')::boolean, false) then raise exception 'SELFTEST late limits not saved: %', v_res; end if;

    -- 3) a small menu for the test (all of it is rolled back at the end)
    insert into public.categories (name, brand_id, station) values ('selftest food', v_brand, 'kitchen') returning id into v_cat_food;
    insert into public.categories (name, brand_id, station) values ('selftest drinks', v_brand, 'bar') returning id into v_cat_drink;
    insert into public.products (category_id, name, price, is_available, brand_id)
    values (v_cat_food, 'selftest burger', 95, true, v_brand) returning id into v_burger;
    insert into public.products (category_id, name, price, is_available, brand_id)
    values (v_cat_drink, 'selftest coffee', 65, true, v_brand) returning id into v_coffee;
    insert into public.ingredients (name, unit, cost_per_unit, min_stock_alert, brand_id)
    values ('selftest cheese', 'kg', 100, 0, v_brand) returning id into v_ing;

    -- 4) modifiers screen: one group with a priced extra that uses stock, linked to the burger
    v_res := public.modifiers_admin_secure(v_tok_m, 'save_group', jsonb_build_object(
               'name', 'selftest extras', 'min_selection', 0, 'max_selection', 2,
               'modifiers', jsonb_build_array(
                 jsonb_build_object('name', 'جبنة', 'price', 15, 'ingredient_id', v_ing, 'ingredient_quantity', 0.05),
                 jsonb_build_object('name', 'بيكون', 'price', 25)),
               'product_ids', jsonb_build_array(v_burger)));
    if not coalesce((v_res->>'ok')::boolean, false) then raise exception 'SELFTEST modifier group save failed: %', v_res; end if;
    v_group := (v_res->>'id')::uuid;
    select x.id into v_cheese from public.modifiers x where x.group_id = v_group and x.name = 'جبنة';
    if v_cheese is null then raise exception 'SELFTEST modifier not created'; end if;
    v_res := public.modifiers_admin_secure(v_tok_m, 'save_group', jsonb_build_object(
               'name', 'bad', 'min_selection', 3, 'max_selection', 2,
               'modifiers', jsonb_build_array(jsonb_build_object('name', 'x', 'price', 1)), 'product_ids', '[]'::jsonb));
    if coalesce(v_res->>'reason', '') <> 'invalid_selection_limits' then raise exception 'SELFTEST bad limits accepted: %', v_res; end if;
    v_res := public.modifiers_admin_secure(v_tok_m, 'get', null);
    if not exists (select 1 from jsonb_array_elements(v_res->'groups') e(value) where (e.value->>'id')::uuid = v_group) then
      raise exception 'SELFTEST modifiers list misses the group';
    end if;

    -- 5) customers: quick add from the cashier, same phone in another shape is refused, lookup finds it
    v_res := public.customer_quick_add_secure(v_tok_c, 'selftest client', '0991 234 5678');
    if not coalesce((v_res->>'ok')::boolean, false) then raise exception 'SELFTEST quick add failed: %', v_res; end if;
    v_cust := (v_res->>'id')::uuid;
    v_res := public.customer_quick_add_secure(v_tok_c, 'other', '+20 991 234 5678');
    if coalesce(v_res->>'reason', '') <> 'phone_taken' or (v_res->'customer'->>'id')::uuid <> v_cust then
      raise exception 'SELFTEST duplicate phone accepted: %', v_res;
    end if;
    v_res := public.customer_lookup_secure(v_tok_c, '٠٩٩١٢٣٤٥٦٧٨');
    if not coalesce((v_res->>'found')::boolean, false) or (v_res->'customer'->>'id')::uuid <> v_cust then
      raise exception 'SELFTEST lookup failed: %', v_res;
    end if;
    -- the cashier cannot give credit
    v_res := public.customer_save2_secure(v_tok_c, jsonb_build_object('id', v_cust, 'name', 'selftest client', 'phone', '09912345678',
               'birthday', '1990-05-20', 'customer_type', 'on_account', 'credit_limit', '999'));
    if not coalesce((v_res->>'ok')::boolean, false) then raise exception 'SELFTEST customer edit failed: %', v_res; end if;
    if (select cu.customer_type from public.customers cu where cu.id = v_cust) <> 'registered' then
      raise exception 'SELFTEST the cashier gave credit';
    end if;
    v_res := public.customer_save2_secure(v_tok_c, jsonb_build_object('name', 'dup', 'phone', '0991-234-5678'));
    if coalesce(v_res->>'reason', '') <> 'phone_taken' then raise exception 'SELFTEST duplicate phone saved: %', v_res; end if;
    v_res := public.customers_secure(v_tok_m, jsonb_build_object('name', 'dup', 'phone', '09912345678', 'customer_type', 'registered', 'credit_limit', '0'));
    if coalesce(v_res->>'reason', '') <> 'phone_taken' then raise exception 'SELFTEST accounting tab saved a duplicate phone: %', v_res; end if;
    -- follow-up due today shows in the list
    v_res := public.customer_followup_secure(v_tok_c, 'add', jsonb_build_object('customer_id', v_cust, 'note', 'اتصلت بيه',
               'next_date', to_char(public.pos_local_date(now()), 'YYYY-MM-DD')));
    if not coalesce((v_res->>'ok')::boolean, false) then raise exception 'SELFTEST follow-up add failed: %', v_res; end if;
    v_res := public.customers_list2_secure(v_tok_c, null, 'due');
    if not exists (select 1 from jsonb_array_elements(v_res->'customers') e(value) where (e.value->>'id')::uuid = v_cust) then
      raise exception 'SELFTEST due list misses the customer: %', v_res;
    end if;
    v_res := public.customer_followup_secure(v_tok_c, 'due', null);
    if not coalesce((v_res->>'ok')::boolean, false) or jsonb_array_length(v_res->'followups') < 1 then
      raise exception 'SELFTEST due follow-ups failed: %', v_res;
    end if;

    -- 6) one order: burger + cheese + note (kitchen), coffee + note (bar), for the customer
    v_res := public.submit_order_items_secure(v_tok_c, null::uuid, 'takeaway', null::uuid, null::uuid, null::uuid, v_cust, 1,
               jsonb_build_array(
                 jsonb_build_object('product_id', v_burger, 'quantity', 2, 'modifier_ids', jsonb_build_array(v_cheese), 'item_notes', 'بدون بصل'),
                 jsonb_build_object('product_id', v_coffee, 'quantity', 1, 'modifier_ids', '[]'::jsonb, 'item_notes', 'سكر بره')));
    if not coalesce((v_res->>'ok')::boolean, false) then raise exception 'SELFTEST submit failed: %', v_res; end if;
    v_order := (v_res->>'order_id')::uuid;
    select o.order_number into v_order_no from public.orders o where o.id = v_order;
    select oi.unit_price into v_num from public.order_items oi where oi.order_id = v_order and oi.product_id = v_burger;
    if v_num <> 110 then raise exception 'SELFTEST extra price not added on the server: %', v_num; end if;
    if exists (select 1 from public.order_items oi where oi.order_id = v_order and oi.sent_at is null) then
      raise exception 'SELFTEST sent time missing';
    end if;

    -- kitchen sees only the burger (with extra and note), bar only the coffee
    v_res := public.kds_station_list_secure(v_tok_c, 'kitchen');
    select e.value into v_card from jsonb_array_elements(v_res->'orders') e(value) where (e.value->>'id')::uuid = v_order;
    if v_card is null or jsonb_array_length(v_card->'items') <> 1 or v_card->'items'->0->>'name' <> 'selftest burger'
       or v_card->'items'->0->>'item_notes' <> 'بدون بصل' or not (v_card->'items'->0->'modifiers' ? 'جبنة')
       or v_card->>'since' is null or (v_res->>'warn_minutes')::numeric <> 20 then
      raise exception 'SELFTEST kitchen card wrong: %', v_res;
    end if;
    v_res := public.kds_station_list_secure(v_tok_c, 'bar');
    select e.value into v_card from jsonb_array_elements(v_res->'orders') e(value) where (e.value->>'id')::uuid = v_order;
    if v_card is null or jsonb_array_length(v_card->'items') <> 1 or v_card->'items'->0->>'name' <> 'selftest coffee' then
      raise exception 'SELFTEST bar card wrong: %', v_res;
    end if;

    -- times: start, ready, served
    v_res := public.kds_station_set_secure(v_tok_c, v_order, 'kitchen', 'preparing');
    if exists (select 1 from public.order_items oi where oi.order_id = v_order and oi.product_id = v_burger and oi.prep_started_at is null)
       or exists (select 1 from public.order_items oi where oi.order_id = v_order and oi.product_id = v_coffee and oi.prep_started_at is not null) then
      raise exception 'SELFTEST start time wrong';
    end if;
    v_res := public.kds_station_set_secure(v_tok_c, v_order, 'kitchen', 'ready');
    if exists (select 1 from public.order_items oi where oi.order_id = v_order and oi.product_id = v_burger and oi.ready_at is null) then
      raise exception 'SELFTEST ready time missing';
    end if;
    if (select o.kitchen_status from public.orders o where o.id = v_order) = 'ready' then
      raise exception 'SELFTEST order ready while the bar is still waiting';
    end if;
    v_res := public.kds_station_list_secure(v_tok_c, 'kitchen');
    if exists (select 1 from jsonb_array_elements(v_res->'orders') e(value) where (e.value->>'id')::uuid = v_order) then
      raise exception 'SELFTEST ready order still in the kitchen';
    end if;
    v_res := public.waiter_ack_secure(v_tok_c, 'ready', v_order, 'kitchen');
    if exists (select 1 from public.order_items oi where oi.order_id = v_order and oi.product_id = v_burger and oi.served_at is null) then
      raise exception 'SELFTEST served time missing';
    end if;

    -- second round on the same order: the kitchen sees only the new burger
    v_res := public.submit_order_items_secure(v_tok_c, v_order, 'takeaway', null::uuid, null::uuid, null::uuid, v_cust, 1,
               jsonb_build_array(jsonb_build_object('product_id', v_burger, 'quantity', 1, 'modifier_ids', '[]'::jsonb)));
    if not coalesce((v_res->>'ok')::boolean, false) then raise exception 'SELFTEST second round failed: %', v_res; end if;
    v_res := public.kds_station_list_secure(v_tok_c, 'kitchen');
    select e.value into v_card from jsonb_array_elements(v_res->'orders') e(value) where (e.value->>'id')::uuid = v_order;
    if v_card is null or jsonb_array_length(v_card->'items') <> 1 or (v_card->'items'->0->>'quantity')::int <> 1 then
      raise exception 'SELFTEST second round card wrong: %', v_res;
    end if;

    -- split one prepared burger to a new order: it keeps its times and does not go back to the kitchen
    select oi.id into v_item from public.order_items oi
     where oi.order_id = v_order and oi.product_id = v_burger and oi.ready_at is not null limit 1;
    v_res := public.split_order_items_secure(v_tok_c, v_order, jsonb_build_array(jsonb_build_object('order_item_id', v_item, 'quantity', 1)));
    if not coalesce((v_res->>'ok')::boolean, false) then raise exception 'SELFTEST split failed: %', v_res; end if;
    v_new_order := (v_res->>'new_order_id')::uuid;
    if exists (select 1 from public.order_items oi where oi.order_id = v_new_order and (oi.ready_at is null or oi.sent_at is null)) then
      raise exception 'SELFTEST split lost the times';
    end if;
    v_res := public.kds_station_list_secure(v_tok_c, 'kitchen');
    if exists (select 1 from jsonb_array_elements(v_res->'orders') e(value) where (e.value->>'id')::uuid = v_new_order) then
      raise exception 'SELFTEST a prepared item went back to the kitchen after split';
    end if;

    -- 7) sales screen: the order is found by its number, with all details
    v_res := public.sales_orders_secure(v_tok_m, null, null, null, jsonb_build_object('search', v_order_no));
    if not coalesce((v_res->>'ok')::boolean, false)
       or not exists (select 1 from jsonb_array_elements(v_res->'rows') e(value) where (e.value->>'id')::uuid = v_order)
       or (v_res->'summary'->>'count')::int < 1 then
      raise exception 'SELFTEST sales list failed: %', v_res;
    end if;
    v_res := public.sales_orders_secure(v_tok_m, null, null, null, jsonb_build_object('status', 'open', 'late_only', 'true'));
    if not coalesce((v_res->>'ok')::boolean, false) then raise exception 'SELFTEST sales filters failed: %', v_res; end if;
    v_res := public.sales_order_detail_secure(v_tok_m, v_order);
    if not coalesce((v_res->>'ok')::boolean, false)
       or not exists (select 1 from jsonb_array_elements(v_res->'items') e(value)
                       where e.value->>'notes' = 'بدون بصل' and jsonb_array_length(e.value->'modifiers') = 1
                         and e.value->>'ready_at' is not null and e.value->>'total_minutes' is not null)
       or jsonb_array_length(v_res->'logs') < 1 or v_res->'order'->'customer'->>'name' <> 'selftest client' then
      raise exception 'SELFTEST order detail wrong: %', v_res;
    end if;
    v_res := public.sales_timing_secure(v_tok_m, null, null, null);
    if not coalesce((v_res->>'ok')::boolean, false)
       or not exists (select 1 from jsonb_array_elements(v_res->'by_station') e(value) where e.value->>'station' = 'kitchen') then
      raise exception 'SELFTEST timing failed: %', v_res;
    end if;
    v_res := public.customer_profile_secure(v_tok_m, v_cust);
    if not coalesce((v_res->>'ok')::boolean, false)
       or not exists (select 1 from jsonb_array_elements(v_res->'orders') e(value) where (e.value->>'id')::uuid = v_order)
       or jsonb_array_length(v_res->'followups') < 1 then
      raise exception 'SELFTEST customer profile failed: %', v_res;
    end if;

    -- 8) deleting a used group keeps the sold extra for history, the group itself is gone
    v_res := public.modifiers_admin_secure(v_tok_m, 'delete_group', jsonb_build_object('id', v_group));
    if not coalesce((v_res->>'ok')::boolean, false) then raise exception 'SELFTEST group delete failed: %', v_res; end if;
    if exists (select 1 from public.modifier_groups g where g.id = v_group)
       or not exists (select 1 from public.modifiers x where x.id = v_cheese and x.group_id is null) then
      raise exception 'SELFTEST group delete wrong';
    end if;

    raise notice 'MOTIONPOS-PH12-SELFTEST-OK';
    raise exception using errcode = 'P0099', message = 'selftest_rollback';
  exception when sqlstate 'P0099' then
    null;
  end;
end;
$selftest$;

commit;
