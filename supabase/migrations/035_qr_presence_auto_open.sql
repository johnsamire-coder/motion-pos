-- 035_qr_presence_auto_open.sql
-- QR ordering from home: the table QR never changes, so a saved link worked from anywhere.
-- Now the phone has to show it is in the shop:
--   1) on the shop wifi (the cloud compares the phone's address with the shop's internet address: the one the shop
--      server's sync comes from, or ones added by hand in settings) -> the order opens the table / adds to its order
--      by itself and goes to the kitchen, no waiter click (done by the next waiter-bell refresh of any POS screen);
--   2) else the menu asks for the phone's location: inside the circle around the shop -> same as 1;
--      far away -> refused ("ordering is only from inside the shop");
--   3) location refused / shop place not set -> waits for the waiter to confirm, like before.
-- Same for "call the waiter" and "ask for the bill": refused from far away.
-- Tables: branches.qr_lat/qr_lng, qr_orders.presence/distance_m/auto_accept/auto_tried_at.
-- Functions copied from their latest files (021 QR orders/feed, 017 request + heartbeat) with only these changes.
-- qr_order_public / qr_request_public get 3 more arguments (lat, lng, accuracy); the old ones stay as wrappers
-- for menu pages still open on phones (they count as "cannot tell").
-- New settings (section waiter_qr, from qr_presence_admin_secure): qr_presence_auto, qr_radius_m, qr_shop_ips.
-- Rules: begin/commit, preflight (needs 034), version bump to 035, grants loop, rolled-back self-test.

begin;

do $preflight$
begin
  if length('إكراميات') <> 8 then
    raise exception 'file_encoding_broken: read the file as UTF-8';
  end if;
  if public.motionpos_version_public() not in ('034', '035') then
    raise exception 'schema_preflight_failed: run 034 first';
  end if;
end;
$preflight$;

-- ---------------------------------------------------------------- 1) new columns
-- the shop's place on the map (set once from settings > waiter & QR, from a phone inside the shop)
alter table public.branches add column if not exists qr_lat numeric;
alter table public.branches add column if not exists qr_lng numeric;
-- how the QR order proved the phone is in the shop, and whether it opens the table without the waiter
alter table public.qr_orders add column if not exists presence text;
alter table public.qr_orders add column if not exists distance_m integer;
alter table public.qr_orders add column if not exists auto_accept boolean not null default false;
alter table public.qr_orders add column if not exists auto_tried_at timestamptz;

-- ---------------------------------------------------------------- 2) helpers
-- The real address of the phone. nginx ADDS the address it sees at the END of X-Forwarded-For, so the last entry
-- is the true one (the first entries, and cf-connecting-ip, are whatever the phone chose to send).
create or replace function public.pos_request_real_ip()
returns text
language plpgsql
stable
as $$
declare
  v_headers json;
  v_ip text;
begin
  begin
    v_headers := nullif(current_setting('request.headers', true), '')::json;
  exception when others then
    v_headers := null;
  end;
  v_ip := btrim(regexp_replace(coalesce(v_headers->>'x-forwarded-for', ''), '^.*,', ''));
  if v_ip = '' then
    return null;
  end if;
  begin
    return host(v_ip::inet);
  exception when others then
    return null;
  end;
end;
$$;

create or replace function public.pos_ip_is_private(p_ip inet)
returns boolean
language sql
immutable
as $$
  select p_ip is null
      or p_ip <<= inet '127.0.0.0/8' or p_ip <<= inet '10.0.0.0/8' or p_ip <<= inet '172.16.0.0/12'
      or p_ip <<= inet '192.168.0.0/16' or p_ip <<= inet '169.254.0.0/16' or p_ip <<= inet '100.64.0.0/10'
      or p_ip <<= inet '::1/128' or p_ip <<= inet 'fc00::/7' or p_ip <<= inet 'fe80::/10'
$$;

create or replace function public.pos_geo_distance_m(p_lat1 numeric, p_lng1 numeric, p_lat2 numeric, p_lng2 numeric)
returns double precision
language sql
immutable
as $$
  select 2 * 6371000 * asin(least(1, sqrt(
           power(sin(radians((p_lat2 - p_lat1)::float8) / 2), 2)
           + cos(radians(p_lat1::float8)) * cos(radians(p_lat2::float8)) * power(sin(radians((p_lng2 - p_lng1)::float8) / 2), 2))))
$$;

-- the presence settings (kept in settings section waiter_qr, written by qr_presence_admin_secure)
create or replace function public.pos_qr_cfg(p_company_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public, extensions
as $$
  select jsonb_build_object(
           'auto', coalesce(case when w->>'qr_presence_auto' in ('true', 'false') then (w->>'qr_presence_auto')::boolean end, true),
           'radius_m', greatest(30, least(2000, coalesce(public.pos_num(w->>'qr_radius_m'), 150))),
           'ips', case when jsonb_typeof(w->'qr_shop_ips') = 'array' then w->'qr_shop_ips' else '[]'::jsonb end)
    from (select coalesce((select s.data from public.app_settings s where s.company_id = p_company_id and s.section = 'waiter_qr'),
                          '{}'::jsonb) as w) x
$$;

-- Is this address the shop's internet?
--   * automatic: the public address the shop server's sync came from in the last 10 minutes (stamped by pos_sync_heartbeat)
--   * by hand: the addresses added in settings ("add the wifi I am on now")
create or replace function public.pos_qr_on_shop_wifi(p_branch_id uuid, p_company_id uuid, p_ip text)
returns boolean
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
declare
  v_ip inet;
  v_store text;
  e text;
begin
  begin
    v_ip := p_ip::inet;
  exception when others then
    return false;
  end;
  if v_ip is null or public.pos_ip_is_private(v_ip) then
    return false;
  end if;
  if exists (select 1 from public.branches b where b.id = p_branch_id and b.has_store_server) then
    select s.value into v_store from public.sync_state s where s.key = 'store_ip' and s.updated_at > now() - interval '10 minutes';
    if v_store is not null and v_store = host(v_ip) then
      return true;
    end if;
  end if;
  for e in select x.v from jsonb_array_elements_text(public.pos_qr_cfg(p_company_id) -> 'ips') x(v) loop
    begin
      if v_ip <<= e::inet then
        return true;
      end if;
    exception when others then
      null;
    end;
  end loop;
  return false;
end;
$$;

-- where is the phone: wifi (shop internet) / location (inside the circle) / outside (far away) / none (we cannot tell)
create or replace function public.pos_qr_presence(p_branch_id uuid, p_company_id uuid, p_lat numeric, p_lng numeric, p_accuracy numeric)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
declare
  b record;
  v_d double precision;
  v_r numeric;
begin
  if public.pos_qr_on_shop_wifi(p_branch_id, p_company_id, public.pos_request_real_ip()) then
    return jsonb_build_object('presence', 'wifi');
  end if;
  select x.qr_lat, x.qr_lng into b from public.branches x where x.id = p_branch_id;
  if p_lat is null or p_lng is null or b.qr_lat is null or b.qr_lng is null or abs(p_lat) > 90 or abs(p_lng) > 180 then
    return jsonb_build_object('presence', 'none');
  end if;
  v_r := (public.pos_qr_cfg(p_company_id) ->> 'radius_m')::numeric;
  v_d := public.pos_geo_distance_m(b.qr_lat, b.qr_lng, p_lat, p_lng);
  -- a phone inside a building is not exact: its own error margin counts, up to the radius again
  return jsonb_build_object('presence', case when v_d <= v_r + least(greatest(coalesce(p_accuracy, 0), 0), v_r) then 'location' else 'outside' end,
                            'distance_m', round(v_d)::int);
end;
$$;

-- ---------------------------------------------------------------- 3) heartbeat: also keep the shop's public address
create or replace function public.pos_sync_heartbeat()
returns void
language sql
set search_path = public
as $$
  insert into public.sync_state (key, value, updated_at) values ('store_seen', now()::text, now())
  on conflict (key) do update set value = excluded.value, updated_at = excluded.updated_at;
  insert into public.sync_state (key, value, updated_at)
  select 'store_ip', host(inet_client_addr()), now() where not public.pos_ip_is_private(inet_client_addr())
  on conflict (key) do update set value = excluded.value, updated_at = excluded.updated_at;
$$;

-- ---------------------------------------------------------------- 4) public: the menu asks before sending
-- wifi = the phone is on the shop internet (send now). location = the shop has a place on the map (ask the phone where it is).
create or replace function public.qr_presence_public(p_qr text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
declare
  t record;
begin
  select * into t from public.pos_qr_table(p_qr);
  if t.table_id is null then
    return jsonb_build_object('ok', false, 'reason', 'not_found');
  end if;
  return jsonb_build_object('ok', true,
    'wifi', public.pos_qr_on_shop_wifi(t.branch_id, t.company_id, public.pos_request_real_ip()),
    'location', exists (select 1 from public.branches b where b.id = t.branch_id and b.qr_lat is not null and b.qr_lng is not null));
end;
$$;

-- ---------------------------------------------------------------- 5) settings screen
create or replace function public.qr_presence_admin_secure(p_token text, p_action text, p_data jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
  d jsonb := coalesce(p_data, '{}'::jsonb);
  v_cfg jsonb;
  v_ip text := public.pos_request_real_ip();
  v_inet inet;
  v_entry text;
  v_ips jsonb;
  v_lat numeric;
  v_lng numeric;
  v_num numeric;
  v_patch jsonb;
  b record;
begin
  select * into c from public.pos_ctx(p_token, 'settings');
  v_cfg := public.pos_qr_cfg(c.company_id);
  v_ips := v_cfg -> 'ips';

  if coalesce(p_action, '') = 'save' then
    v_patch := '{}'::jsonb;
    if d ? 'auto' then
      if jsonb_typeof(d->'auto') <> 'boolean' then
        return jsonb_build_object('ok', false, 'reason', 'invalid_value', 'key', 'auto');
      end if;
      v_patch := v_patch || jsonb_build_object('qr_presence_auto', d->'auto');
    end if;
    if d ? 'radius_m' then
      v_num := public.pos_num(d->>'radius_m');
      if v_num is null or v_num < 30 or v_num > 2000 then
        return jsonb_build_object('ok', false, 'reason', 'invalid_value', 'key', 'radius_m');
      end if;
      v_patch := v_patch || jsonb_build_object('qr_radius_m', round(v_num));
    end if;
  elsif p_action = 'add_my_ip' then
    begin
      v_inet := v_ip::inet;
    exception when others then
      v_inet := null;
    end;
    if v_inet is null or public.pos_ip_is_private(v_inet) then
      return jsonb_build_object('ok', false, 'reason', 'qr_ip_unknown');
    end if;
    -- IPv4: this one address. IPv6: the whole home network (/64), since each phone gets its own address in it
    v_entry := case when family(v_inet) = 4 then host(v_inet) else text(network(set_masklen(v_inet, 64))) end;
    if not exists (select 1 from jsonb_array_elements_text(v_ips) x(v) where x.v = v_entry) then
      if jsonb_array_length(v_ips) >= 20 then
        return jsonb_build_object('ok', false, 'reason', 'too_many');
      end if;
      v_ips := v_ips || jsonb_build_array(v_entry);
    end if;
    v_patch := jsonb_build_object('qr_shop_ips', v_ips);
  elsif p_action = 'remove_ip' then
    select coalesce(jsonb_agg(x.v), '[]'::jsonb) into v_ips from jsonb_array_elements_text(v_ips) x(v) where x.v <> coalesce(d->>'ip', '');
    v_patch := jsonb_build_object('qr_shop_ips', v_ips);
  elsif p_action = 'set_location' then
    v_lat := public.pos_num(d->>'lat');
    v_lng := public.pos_num(d->>'lng');
    if v_lat is null or v_lng is null or abs(v_lat) > 90 or abs(v_lng) > 180 or (v_lat = 0 and v_lng = 0) then
      return jsonb_build_object('ok', false, 'reason', 'invalid_value', 'key', 'location');
    end if;
    update public.branches set qr_lat = round(v_lat, 6), qr_lng = round(v_lng, 6) where id = c.branch_id;
  elsif p_action = 'clear_location' then
    update public.branches set qr_lat = null, qr_lng = null where id = c.branch_id;
  elsif coalesce(p_action, '') <> 'get' then
    return jsonb_build_object('ok', false, 'reason', 'unknown_action');
  end if;

  if v_patch is not null and v_patch <> '{}'::jsonb then
    insert into public.app_settings (company_id, section, data, updated_by)
    values (c.company_id, 'waiter_qr', v_patch, c.staff_id)
    on conflict (company_id, section)
    do update set data = public.app_settings.data || excluded.data, updated_at = now(), updated_by = excluded.updated_by;
  end if;
  if p_action <> 'get' then
    insert into public.settings_logs (staff_id, action, details)
    values (c.staff_id, 'qr_presence', jsonb_build_object('action', p_action, 'data', d, 'ip', v_ip));
  end if;

  v_cfg := public.pos_qr_cfg(c.company_id);
  select x.name, x.qr_lat, x.qr_lng, x.has_store_server into b from public.branches x where x.id = c.branch_id;
  return jsonb_build_object('ok', true,
    'auto', v_cfg->'auto', 'radius_m', v_cfg->'radius_m', 'ips', v_cfg->'ips',
    'branch', b.name, 'lat', b.qr_lat, 'lng', b.qr_lng,
    'has_store_server', coalesce(b.has_store_server, false),
    'is_cloud', exists (select 1 from public.sync_node n where n.node = 'cloud'),
    'store_ip_seen', exists (select 1 from public.sync_state s where s.key = 'store_ip' and s.updated_at > now() - interval '10 minutes'),
    'my_ip', v_ip,
    'on_shop_wifi', public.pos_qr_on_shop_wifi(c.branch_id, c.company_id, v_ip));
end;
$$;

-- ---------------------------------------------------------------- 6) QR order / call (copied from 021 / 017 + presence)
create or replace function public.qr_order_public(p_qr text, p_items jsonb, p_name text, p_phone text, p_birthday text, p_note text,
                                                p_lat numeric, p_lng numeric, p_accuracy numeric)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  t record;
  s jsonb;
  v_name text := nullif(btrim(coalesce(p_name, '')), '');
  v_phone text := public.pos_phone_norm(p_phone);
  v_birthday date;
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  e jsonb;
  p record;
  g record;
  v_qty int;
  v_mods uuid[];
  v_mod_total numeric;
  v_total numeric := 0;
  v_items jsonb := '[]'::jsonb;
  v_ref text;
  v_count int;
  v_notes text;
  v_pres jsonb;
  v_auto boolean;
begin
  select * into t from public.pos_qr_table(p_qr);
  if t.table_id is null then
    return jsonb_build_object('ok', false, 'reason', 'not_found');
  end if;
  s := public.pos_app_settings(t.company_id);
  if not coalesce((s->'waiter_qr'->>'qr_enabled')::boolean, true) or not coalesce((s->'waiter_qr'->>'qr_ordering')::boolean, true) then
    return jsonb_build_object('ok', false, 'reason', 'qr_disabled');
  end if;
  if public.pos_qr_store_offline(t.branch_id) then
    return jsonb_build_object('ok', false, 'reason', 'store_offline');
  end if;
  -- is the phone in the shop? shop wifi or inside the circle -> opens the table by itself. far away -> refused.
  -- cannot tell (location refused / not set) -> waits for the waiter like before.
  v_pres := public.pos_qr_presence(t.branch_id, t.company_id, p_lat, p_lng, p_accuracy);
  if v_pres->>'presence' = 'outside' then
    return jsonb_build_object('ok', false, 'reason', 'not_in_shop');
  end if;
  v_auto := v_pres->>'presence' in ('wifi', 'location') and (public.pos_qr_cfg(t.company_id)->>'auto')::boolean;
  if v_name is null or length(v_name) > 80 then
    return jsonb_build_object('ok', false, 'reason', 'invalid_name');
  end if;
  if length(v_phone) < 8 or length(v_phone) > 15 then
    return jsonb_build_object('ok', false, 'reason', 'invalid_phone');
  end if;
  if nullif(btrim(coalesce(p_birthday, '')), '') is not null then
    if p_birthday !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then
      return jsonb_build_object('ok', false, 'reason', 'invalid_date');
    end if;
    begin
      v_birthday := p_birthday::date;
    exception when others then
      return jsonb_build_object('ok', false, 'reason', 'invalid_date');
    end;
    if v_birthday > current_date or v_birthday < date '1900-01-01' then
      return jsonb_build_object('ok', false, 'reason', 'invalid_date');
    end if;
  end if;
  if v_note is not null and length(v_note) > 300 then
    return jsonb_build_object('ok', false, 'reason', 'item_notes_too_long');
  end if;
  if jsonb_typeof(p_items) is distinct from 'array' or jsonb_array_length(p_items) < 1 or jsonb_array_length(p_items) > 30 then
    return jsonb_build_object('ok', false, 'reason', 'invalid_item_count');
  end if;
  -- too many waiting orders from this table / this phone: someone is playing
  select count(*) into v_count from public.qr_orders q where q.table_id = t.table_id and q.status = 'pending';
  if v_count >= 3 then
    return jsonb_build_object('ok', false, 'reason', 'too_many');
  end if;
  select count(*) into v_count from public.qr_orders q where q.table_id = t.table_id and q.created_at > now() - interval '1 hour';
  if v_count >= 15 then
    return jsonb_build_object('ok', false, 'reason', 'too_many');
  end if;
  select count(*) into v_count from public.qr_orders q
   where q.company_id = t.company_id and public.pos_phone_norm(q.customer_phone) = v_phone and q.status = 'pending';
  if v_count >= 2 then
    return jsonb_build_object('ok', false, 'reason', 'too_many');
  end if;

  for e in select x.value from jsonb_array_elements(p_items) x(value) loop
    if jsonb_typeof(e) is distinct from 'object' or coalesce(e->>'quantity', '') !~ '^[0-9]{1,2}$' then
      return jsonb_build_object('ok', false, 'reason', 'invalid_quantity');
    end if;
    v_qty := (e->>'quantity')::int;
    if v_qty < 1 or v_qty > 20 then
      return jsonb_build_object('ok', false, 'reason', 'invalid_quantity');
    end if;
    select pr.id, pr.price into p from public.products pr
     where pr.id = public.pos_uuid(e->>'product_id') and pr.brand_id = t.brand_id and pr.is_available is true and pr.show_in_menu is true;
    if p.id is null then
      return jsonb_build_object('ok', false, 'reason', 'product_not_available');
    end if;
    v_notes := nullif(btrim(coalesce(e->>'item_notes', '')), '');
    if v_notes is not null and length(v_notes) > 200 then
      return jsonb_build_object('ok', false, 'reason', 'item_notes_too_long');
    end if;
    v_mods := '{}'::uuid[];
    if e ? 'modifier_ids' and jsonb_typeof(e->'modifier_ids') = 'array' then
      if jsonb_array_length(e->'modifier_ids') > 10
         or exists (select 1 from jsonb_array_elements_text(e->'modifier_ids') m(v) where public.pos_uuid(m.v) is null) then
        return jsonb_build_object('ok', false, 'reason', 'invalid_modifier_ids');
      end if;
      select coalesce(array_agg(distinct m.v::uuid), '{}'::uuid[]) into v_mods from jsonb_array_elements_text(e->'modifier_ids') m(v);
    end if;
    if exists (select 1 from unnest(v_mods) u(id)
                where not exists (select 1 from public.modifiers m join public.product_modifier_groups pg on pg.group_id = m.group_id
                                   where m.id = u.id and pg.product_id = p.id)) then
      return jsonb_build_object('ok', false, 'reason', 'modifier_not_for_product');
    end if;
    for g in
      select mg.id, greatest(coalesce(mg.min_selection, 0), case when coalesce(mg.is_required, false) then 1 else 0 end) as mn,
             coalesce(mg.max_selection, 0) as mx,
             (select count(*) from public.modifiers m where m.group_id = mg.id and m.id = any (v_mods)) as picked
        from public.product_modifier_groups pg join public.modifier_groups mg on mg.id = pg.group_id
       where pg.product_id = p.id and exists (select 1 from public.modifiers m where m.group_id = mg.id)
    loop
      if g.picked < g.mn then
        return jsonb_build_object('ok', false, 'reason', 'required_modifier_missing');
      end if;
      if g.mx > 0 and g.picked > g.mx then
        return jsonb_build_object('ok', false, 'reason', 'too_many_modifiers');
      end if;
    end loop;
    select coalesce(sum(m.price), 0) into v_mod_total from public.modifiers m where m.id = any (v_mods);
    v_total := v_total + (coalesce(p.price, 0) + v_mod_total) * v_qty;
    v_items := v_items || jsonb_build_array(jsonb_build_object('product_id', p.id, 'quantity', v_qty,
                 'modifier_ids', to_jsonb(v_mods), 'item_notes', v_notes));
  end loop;

  insert into public.qr_orders (company_id, branch_id, table_id, table_number, items, total_estimate, customer_name, customer_phone,
                                customer_birthday, note, presence, distance_m, auto_accept)
  values (t.company_id, t.branch_id, t.table_id, t.table_number, v_items, round(v_total, 2), left(v_name, 80), v_phone, v_birthday,
          left(v_note, 300), v_pres->>'presence', (v_pres->>'distance_m')::int, v_auto)
  returning public_ref into v_ref;
  return jsonb_build_object('ok', true, 'ref', v_ref, 'total_estimate', round(v_total, 2), 'auto', v_auto);
end;
$$;

-- the old menu page (still open on a phone): same, location unknown
create or replace function public.qr_order_public(p_qr text, p_items jsonb, p_name text, p_phone text, p_birthday text, p_note text)
returns jsonb
language sql
security definer
set search_path = public, extensions
as $$
  select public.qr_order_public(p_qr, p_items, p_name, p_phone, p_birthday, p_note, null::numeric, null::numeric, null::numeric)
$$;

create or replace function public.qr_request_public(p_qr text, p_type text, p_lat numeric, p_lng numeric, p_accuracy numeric)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  t record;
  s jsonb;
  v_pres jsonb;
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
  -- shop server branch, shop internet down (no sync for 3 minutes): the call would not reach the waiter in time
  if exists (select 1 from public.sync_node n where n.node = 'cloud')
     and exists (select 1 from public.branches b where b.id = t.branch_id and b.has_store_server)
     and coalesce((select s.value::timestamptz from public.sync_state s where s.key = 'store_seen'), '-infinity'::timestamptz) < now() - interval '3 minutes' then
    return jsonb_build_object('ok', false, 'reason', 'store_offline');
  end if;
  -- a call from far away (the saved link at home) is refused
  v_pres := public.pos_qr_presence(t.branch_id, t.company_id, p_lat, p_lng, p_accuracy);
  if v_pres->>'presence' = 'outside' then
    return jsonb_build_object('ok', false, 'reason', 'not_in_shop');
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

create or replace function public.qr_request_public(p_qr text, p_type text)
returns jsonb
language sql
security definer
set search_path = public, extensions
as $$
  select public.qr_request_public(p_qr, p_type, null::numeric, null::numeric, null::numeric)
$$;

-- ---------------------------------------------------------------- 7) accepting by itself (copied from 021)
create or replace function public.qr_orders_secure(p_token text, p_action text, p_data jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
  d jsonb := coalesce(p_data, '{}'::jsonb);
  v_q public.qr_orders%rowtype;
  v_order uuid;
  v_area uuid;
  v_waiter uuid;
  v_cust uuid;
  v_res jsonb;
  v_reason text;
  v_auto boolean;
begin
  select * into c from public.pos_ctx(p_token, 'pos');
  if coalesce(p_action, '') = 'list' then
    return jsonb_build_object('ok', true, 'orders', public.pos_qr_orders_list(c.branch_id, c.company_id));
  end if;
  if coalesce(p_action, '') not in ('accept', 'reject') then
    return jsonb_build_object('ok', false, 'reason', 'unknown_action');
  end if;
  select q.* into v_q from public.qr_orders q where q.id = public.pos_uuid(d->>'id') and q.branch_id = c.branch_id for update;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'not_found');
  end if;
  if v_q.status <> 'pending' then
    return jsonb_build_object('ok', false, 'reason', 'qr_handled');
  end if;
  -- accepted by the screens on their own (the phone proved it is in the shop): the order is not given to whoever's screen asked
  v_auto := coalesce(d->>'auto', '') = 'true' and v_q.auto_accept;

  if p_action = 'reject' then
    v_reason := nullif(btrim(coalesce(d->>'reason', '')), '');
    update public.qr_orders set status = 'rejected', reject_reason = left(coalesce(v_reason, 'اترفض'), 200),
           handled_by = c.staff_id, handled_at = now()
     where id = v_q.id;
    return jsonb_build_object('ok', true);
  end if;

  -- accept: add to the open order of the table, or open a new one on the table
  select o.id into v_order from public.orders o
   where o.table_id = v_q.table_id and o.branch_id = c.branch_id and coalesce(o.status, '') not in ('paid', 'closed', 'cancelled')
   order by o.created_at desc limit 1;
  if v_order is null then
    select t.area_id into v_area from public.tables t where t.id = v_q.table_id;
    if c.role_name = 'waiter' and not v_auto then
      v_waiter := c.staff_id;
    end if;
    v_res := public.submit_order_items_secure(p_token, null::uuid, 'dine_in', v_area, v_q.table_id, v_waiter, null::uuid, 1, v_q.items);
  else
    v_res := public.submit_order_items_secure(p_token, v_order, 'dine_in', null::uuid, null::uuid, null::uuid, null::uuid, 1, v_q.items);
  end if;
  if not coalesce((v_res->>'ok')::boolean, false) then
    return v_res;
  end if;
  v_order := (v_res->>'order_id')::uuid;

  -- the customer: found by mobile, or added now (birthday kept if we did not have it)
  select cu.id into v_cust from public.customers cu
   where cu.company_id = c.company_id and public.pos_phone_norm(cu.phone) = public.pos_phone_norm(v_q.customer_phone) limit 1;
  if v_cust is null then
    insert into public.customers (company_id, name, phone, customer_type, credit_limit, created_by, birthday, notes)
    values (c.company_id, v_q.customer_name, public.pos_phone_norm(v_q.customer_phone), 'registered', 0, c.staff_id, v_q.customer_birthday,
            'سجّل نفسه من منيو الـ QR')
    returning id into v_cust;
  else
    update public.customers set birthday = coalesce(birthday, v_q.customer_birthday) where id = v_cust and birthday is null;
  end if;
  update public.orders set customer_id = v_cust where id = v_order and customer_id is null;
  if coalesce((v_res->>'created')::boolean, false) then
    update public.orders set source = 'qr', notes = coalesce(nullif(notes, '') || ' | ', '') || coalesce('ملاحظة العميل: ' || v_q.note, 'طلب QR')
     where id = v_order;
  end if;
  update public.qr_orders set status = 'accepted', order_id = v_order, handled_by = c.staff_id, handled_at = now() where id = v_q.id;
  insert into public.order_logs (order_id, user_id, action, details)
  values (v_order, c.staff_id, case when v_auto then 'QR_ORDER_AUTO_ACCEPTED' else 'QR_ORDER_ACCEPTED' end,
          jsonb_build_object('qr_order', v_q.id, 'customer', v_q.customer_name,
          'table', v_q.table_number, 'estimate', v_q.total_estimate, 'presence', v_q.presence, 'distance_m', v_q.distance_m));
  return jsonb_build_object('ok', true, 'order_id', v_order, 'order_number', v_res->>'order_number', 'created', v_res->'created');
end;
$$;

create or replace function public.pos_qr_orders_list(p_branch_id uuid, p_company_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public, extensions
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', q.id, 'table_number', q.table_number, 'table_id', q.table_id, 'created_at', q.created_at,
           'customer_name', q.customer_name, 'customer_phone', q.customer_phone, 'note', q.note, 'total_estimate', q.total_estimate,
           'presence', q.presence, 'distance_m', q.distance_m, 'auto_failed', (q.auto_accept and q.auto_tried_at is not null),
           'known_customer', (select jsonb_build_object('name', cu.name, 'orders_count',
                                       (select count(*) from public.orders o where o.customer_id = cu.id and o.status = 'closed'))
                                from public.customers cu
                               where cu.company_id = p_company_id and public.pos_phone_norm(cu.phone) = public.pos_phone_norm(q.customer_phone)
                               limit 1),
           'has_open_order', exists (select 1 from public.orders o where o.table_id = q.table_id
                                       and coalesce(o.status, '') not in ('paid', 'closed', 'cancelled')),
           'items', (select jsonb_agg(jsonb_build_object(
                        'name', coalesce(pr.name, 'صنف'), 'quantity', (e.value->>'quantity')::int, 'notes', e.value->>'item_notes',
                        'modifiers', (select coalesce(jsonb_agg(m.name), '[]'::jsonb) from public.modifiers m
                                       where m.id in (select x.v::uuid from jsonb_array_elements_text(coalesce(e.value->'modifier_ids', '[]'::jsonb)) x(v))))
                        order by e.ord)
                       from jsonb_array_elements(q.items) with ordinality e(value, ord)
                       left join public.products pr on pr.id = (e.value->>'product_id')::uuid)
         ) order by q.created_at), '[]'::jsonb)
    from public.qr_orders q
   where q.branch_id = p_branch_id and q.status = 'pending' and q.created_at > now() - interval '12 hours'
$$;

create or replace function public.waiter_feed_secure(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
  v_id uuid;
  v_res jsonb;
  v_auto jsonb := '[]'::jsonb;
begin
  select * into c from public.pos_ctx(p_token, 'pos');
  -- QR orders whose phone proved it is in the shop: accepted here, with no click (each one tried once; if it fails,
  -- e.g. "waiter required before sending", it stays for the waiter to confirm by hand).
  -- Not on the cloud copy of a branch that has a shop server: the order is opened on the shop server (its order numbers).
  if not (exists (select 1 from public.sync_node n where n.node = 'cloud')
          and exists (select 1 from public.branches b where b.id = c.branch_id and b.has_store_server)) then
    for v_id in
      select q.id from public.qr_orders q
       where q.branch_id = c.branch_id and q.status = 'pending' and q.auto_accept and q.auto_tried_at is null
         and q.created_at > now() - interval '30 minutes'
       order by q.created_at
       for update skip locked
    loop
      update public.qr_orders set auto_tried_at = now() where id = v_id;
      begin
        v_res := public.qr_orders_secure(p_token, 'accept', jsonb_build_object('id', v_id, 'auto', true));
      exception when others then
        v_res := jsonb_build_object('ok', false, 'reason', sqlerrm);
      end;
      if coalesce((v_res->>'ok')::boolean, false) then
        v_auto := v_auto || jsonb_build_array(jsonb_build_object('order_number', v_res->>'order_number',
                    'table_number', (select q.table_number from public.qr_orders q where q.id = v_id)));
      end if;
    end loop;
  end if;
  return jsonb_build_object('ok', true,
    'auto_accepted', v_auto,
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
       where r.branch_id = c.branch_id and r.status = 'open'), '[]'::jsonb),
    'qr_orders', public.pos_qr_orders_list(c.branch_id, c.company_id));
end;
$$;

create or replace function public.motionpos_version_public()
returns text
language sql
immutable
as $$
  select '035'
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
  v_branch uuid;
  v_area uuid;
  v_qr text;
  v_res jsonb;
  v_src text;
  v_d double precision;
begin
  begin
    perform set_config('motionpos.sync_apply', 'on', true);
    -- distance: 0.001 degree of latitude is about 111 m
    v_d := public.pos_geo_distance_m(30.0444, 31.2357, 30.0454, 31.2357);
    if v_d < 105 or v_d > 117 then raise exception 'SELFTEST distance %', v_d; end if;
    -- the real address is the LAST one nginx added, not what the phone wrote first
    perform set_config('request.headers', '{"x-forwarded-for": "9.9.9.9, 41.33.20.7"}', true);
    if public.pos_request_real_ip() is distinct from '41.33.20.7' then raise exception 'SELFTEST real ip'; end if;
    perform set_config('request.headers', '{"x-forwarded-for": "not-an-ip"}', true);
    if public.pos_request_real_ip() is not null then raise exception 'SELFTEST bad ip'; end if;
    if not public.pos_ip_is_private(inet '192.168.1.5') or public.pos_ip_is_private(inet '41.33.20.7') then
      raise exception 'SELFTEST private ip';
    end if;

    insert into public.companies (name) values ('selftest035') returning id into v_co;
    insert into public.brands (name, company_id) values ('selftest035', v_co) returning id into v_brand;
    insert into public.branches (name, brand_id, has_store_server, qr_lat, qr_lng)
    values ('selftest035', v_brand, false, 30.0444, 31.2357) returning id into v_branch;
    insert into public.areas (name, branch_id) values ('selftest035', v_branch) returning id into v_area;
    insert into public.tables (table_number, area_id) values ('ST35', v_area) returning qr_token into v_qr;
    insert into public.app_settings (company_id, section, data)
    values (v_co, 'waiter_qr', '{"qr_shop_ips": ["41.33.20.0/24"], "qr_radius_m": 100}'::jsonb);

    -- on the shop wifi
    perform set_config('request.headers', '{"x-forwarded-for": "41.33.20.7"}', true);
    v_res := public.qr_presence_public(v_qr);
    if not (v_res->>'wifi')::boolean or not (v_res->>'location')::boolean then raise exception 'SELFTEST wifi %', v_res; end if;
    if public.pos_qr_presence(v_branch, v_co, null, null, null)->>'presence' <> 'wifi' then raise exception 'SELFTEST presence wifi'; end if;
    -- mobile data: by location
    perform set_config('request.headers', '{"x-forwarded-for": "8.8.8.8"}', true);
    if (public.qr_presence_public(v_qr)->>'wifi')::boolean then raise exception 'SELFTEST not wifi'; end if;
    if public.pos_qr_presence(v_branch, v_co, 30.0450, 31.2357, 20)->>'presence' <> 'location' then raise exception 'SELFTEST inside'; end if;
    if public.pos_qr_presence(v_branch, v_co, 30.0800, 31.2357, 50)->>'presence' <> 'outside' then raise exception 'SELFTEST outside'; end if;
    if public.pos_qr_presence(v_branch, v_co, null, null, null)->>'presence' <> 'none' then raise exception 'SELFTEST none'; end if;
    -- the saved link at home (4 km away) is refused, for orders and for calls
    v_res := public.qr_order_public(v_qr, '[]'::jsonb, 'x', '01000000000', null, null, 30.0800, 31.2357, 50);
    if v_res->>'reason' is distinct from 'not_in_shop' then raise exception 'SELFTEST order from home %', v_res; end if;
    v_res := public.qr_request_public(v_qr, 'waiter', 30.0800, 31.2357, 50);
    if v_res->>'reason' is distinct from 'not_in_shop' then raise exception 'SELFTEST call from home %', v_res; end if;
    -- the old page (no location) still works: it is "cannot tell", so the call goes through like before
    v_res := public.qr_request_public(v_qr, 'waiter');
    if not coalesce((v_res->>'ok')::boolean, false) then raise exception 'SELFTEST old call %', v_res; end if;

    select pg_get_functiondef('public.waiter_feed_secure(text)'::regprocedure) into v_src;
    if position('auto_accepted' in v_src) = 0 then raise exception 'SELFTEST feed'; end if;
    select pg_get_functiondef('public.qr_orders_secure(text,text,jsonb)'::regprocedure) into v_src;
    if position('QR_ORDER_AUTO_ACCEPTED' in v_src) = 0 then raise exception 'SELFTEST accept'; end if;
    if to_regprocedure('public.qr_order_public(text,jsonb,text,text,text,text)') is null then raise exception 'SELFTEST old order wrapper'; end if;
    if public.motionpos_version_public() <> '035' then raise exception 'SELFTEST version'; end if;
    raise notice 'MOTIONPOS-035-SELFTEST-OK';
    raise exception using errcode = 'P0099', message = 'selftest_rollback';
  exception when sqlstate 'P0099' then
    null;
  end;
end;
$selftest$;

notify pgrst, 'reload schema';

commit;
