-- 043_demo_license.sql
-- Demo copies (for a reseller to show the program to customers): a copy can be marked "demo" with a limit on the number
-- of orders and/or an end date. When the limit is reached or the date passes, NEW orders are refused (error demo_limit /
-- demo_expired); everything else (reports, dashboard, accounts) keeps working so the copy can still be shown.
-- * One row in motionpos_license (id = 1). No row, or mode 'full' = a normal copy, nothing changes (all real clients).
-- * The counter lives in that table, so the "system reset" button does not give the orders back.
-- * Only the database owner can change it (SQL), never the screens:
--     select public.pos_license_set('demo', 300, 60, 'نسخة عرض');   -- 300 orders, 60 days from now
--     select public.pos_license_add(200, 30);                       -- renew: +200 orders, +30 days
--     select public.pos_license_set('full', null, null, null);      -- turn it into a normal copy
-- * motionpos_license_public() tells the screens to show the "demo" badge and the line on printed paper.
-- * Orders written by the sync engine / system reset (motionpos.sync_apply / motionpos.system_reset = on) are not counted.
-- Rules: begin/commit, preflight (needs 042), version bump to 043, grants loop, rolled-back self-test.

begin;

do $preflight$
begin
  if length('إكراميات') <> 8 then
    raise exception 'file_encoding_broken: read the file as UTF-8';
  end if;
  if public.motionpos_version_public() not in ('042', '043') then
    raise exception 'schema_preflight_failed: run 042 first';
  end if;
end;
$preflight$;

create table if not exists public.motionpos_license (
  id integer primary key default 1 check (id = 1),
  mode text not null default 'full' check (mode in ('full', 'demo')),
  max_orders integer check (max_orders is null or max_orders >= 0),
  orders_used integer not null default 0,
  expires_at timestamptz,
  label text,
  updated_at timestamptz not null default now()
);
alter table public.motionpos_license enable row level security;
revoke all on table public.motionpos_license from anon, authenticated;

-- before every new order: count it, or refuse it when the demo is over
create or replace function public.trg_orders_license()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  l public.motionpos_license%rowtype;
begin
  if current_setting('motionpos.sync_apply', true) = 'on' or current_setting('motionpos.system_reset', true) = 'on' then
    return new;
  end if;
  select * into l from public.motionpos_license where id = 1 for update;
  if not found or l.mode <> 'demo' then
    return new;
  end if;
  if l.expires_at is not null and now() >= l.expires_at then
    raise exception 'demo_expired' using errcode = 'P0001', hint = 'انتهت مدة النسخة التجريبية';
  end if;
  if l.max_orders is not null and l.orders_used >= l.max_orders then
    raise exception 'demo_limit' using errcode = 'P0001', hint = 'خلص عدد الطلبات المسموح في النسخة التجريبية';
  end if;
  update public.motionpos_license set orders_used = orders_used + 1 where id = 1;
  return new;
end;
$$;

drop trigger if exists trg_orders_license on public.orders;
create trigger trg_orders_license before insert on public.orders
  for each row execute function public.trg_orders_license();

-- for the screens: is this a demo copy, and how much is left (no secrets in it)
create or replace function public.motionpos_license_public()
returns jsonb
language sql
stable
security definer
set search_path = public, extensions
as $$
  select coalesce((
    select jsonb_build_object(
      'demo', true,
      'label', coalesce(l.label, ''),
      'max_orders', l.max_orders,
      'orders_left', case when l.max_orders is null then null else greatest(l.max_orders - l.orders_used, 0) end,
      'expires_at', l.expires_at,
      'days_left', case when l.expires_at is null then null
                        else greatest(ceil(extract(epoch from (l.expires_at - now())) / 86400.0), 0)::int end,
      'ended', (l.expires_at is not null and now() >= l.expires_at)
               or (l.max_orders is not null and l.orders_used >= l.max_orders))
      from public.motionpos_license l
     where l.id = 1 and l.mode = 'demo'), jsonb_build_object('demo', false));
$$;

-- owner tools (SQL only: the grants loop below takes pos_* away from the screens)
create or replace function public.pos_license_set(p_mode text, p_max_orders integer, p_days integer, p_label text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if p_mode not in ('full', 'demo') then
    raise exception 'mode must be full or demo';
  end if;
  insert into public.motionpos_license (id, mode, max_orders, orders_used, expires_at, label, updated_at)
  values (1, p_mode, p_max_orders, 0,
          case when p_days is null then null else now() + make_interval(days => p_days) end, p_label, now())
  on conflict (id) do update
     set mode = excluded.mode, max_orders = excluded.max_orders, expires_at = excluded.expires_at,
         label = excluded.label, updated_at = now(),
         orders_used = case when excluded.mode = 'full' then 0 else public.motionpos_license.orders_used end;
  return public.motionpos_license_public();
end;
$$;

create or replace function public.pos_license_add(p_orders integer, p_days integer)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  update public.motionpos_license
     set max_orders = case when max_orders is null or p_orders is null then max_orders else max_orders + p_orders end,
         expires_at = case when expires_at is null or p_days is null then expires_at
                           else greatest(expires_at, now()) + make_interval(days => p_days) end,
         updated_at = now()
   where id = 1;
  if not found then
    raise exception 'no license row: use pos_license_set first';
  end if;
  return public.motionpos_license_public();
end;
$$;

create or replace function public.motionpos_version_public()
returns text
language sql
immutable
as $$
  select '043'
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
  v_res jsonb;
  v_ok boolean;
begin
  begin
    perform set_config('motionpos.sync_apply', 'off', true);
    perform set_config('motionpos.system_reset', 'off', true);
    delete from public.motionpos_license;
    if (public.motionpos_license_public()->>'demo')::boolean then raise exception 'SELFTEST no row must be full'; end if;
    insert into public.orders (order_type, total_amount, status) values ('takeaway', 0, 'open');   -- full copy: not counted, not refused

    v_res := public.pos_license_set('demo', 2, 30, 'selftest');
    if (v_res->>'orders_left')::int <> 2 or (v_res->>'days_left')::int <> 30 or (v_res->>'ended')::boolean then
      raise exception 'SELFTEST set %', v_res;
    end if;
    insert into public.orders (order_type, total_amount, status) values ('takeaway', 0, 'open');
    insert into public.orders (order_type, total_amount, status) values ('takeaway', 0, 'open');
    if (public.motionpos_license_public()->>'orders_left')::int <> 0 then raise exception 'SELFTEST count'; end if;
    v_ok := false;
    begin
      insert into public.orders (order_type, total_amount, status) values ('takeaway', 0, 'open');
    exception when others then
      v_ok := sqlerrm = 'demo_limit';
    end;
    if not v_ok then raise exception 'SELFTEST limit not enforced'; end if;

    perform set_config('motionpos.sync_apply', 'on', true);   -- the sync engine is never blocked
    insert into public.orders (order_type, total_amount, status) values ('takeaway', 0, 'open');
    perform set_config('motionpos.sync_apply', 'off', true);

    v_res := public.pos_license_add(5, 10);
    if (v_res->>'orders_left')::int <> 5 or (v_res->>'days_left')::int <> 40 then raise exception 'SELFTEST add %', v_res; end if;
    insert into public.orders (order_type, total_amount, status) values ('takeaway', 0, 'open');

    update public.motionpos_license set expires_at = now() - interval '1 minute';
    v_ok := false;
    begin
      insert into public.orders (order_type, total_amount, status) values ('takeaway', 0, 'open');
    exception when others then
      v_ok := sqlerrm = 'demo_expired';
    end;
    if not v_ok then raise exception 'SELFTEST expiry not enforced'; end if;
    if not (public.motionpos_license_public()->>'ended')::boolean then raise exception 'SELFTEST ended flag'; end if;

    v_res := public.pos_license_set('full', null, null, null);
    if (v_res->>'demo')::boolean then raise exception 'SELFTEST back to full'; end if;
    insert into public.orders (order_type, total_amount, status) values ('takeaway', 0, 'open');

    if has_function_privilege('anon', 'public.pos_license_set(text,integer,integer,text)', 'execute') then
      raise exception 'SELFTEST screens can change the license';
    end if;
    if not has_function_privilege('anon', 'public.motionpos_license_public()', 'execute') then
      raise exception 'SELFTEST screens cannot read the badge';
    end if;
    if has_table_privilege('anon', 'public.motionpos_license', 'select') or has_table_privilege('anon', 'public.motionpos_license', 'update') then
      raise exception 'SELFTEST license table is open';
    end if;
    if public.motionpos_version_public() <> '043' then raise exception 'SELFTEST version'; end if;
    raise notice 'MOTIONPOS-043-SELFTEST-OK';
    raise exception using errcode = 'P0099', message = 'selftest_rollback';
  exception when sqlstate 'P0099' then
    null;
  end;
end;
$selftest$;

notify pgrst, 'reload schema';

commit;
