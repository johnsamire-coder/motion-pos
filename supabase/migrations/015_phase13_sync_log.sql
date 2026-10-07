-- 015_phase13_sync_log.sql
-- Phase 13 (whole shop works without internet), step 3: the ground the two-way sync stands on.
--   * sync_node: says whether this database is the cloud copy or the shop server
--   * sync_log: every insert / update / delete on every shared table is written here (who, which row, what)
--     rows written by the sync itself are NOT logged (setting motionpos.sync_apply = on, or replica mode)
--   * settings_logs.id becomes a unique code (uuid) so the two places never give the same number
--   * branches.has_store_server: when a branch has a shop server, the cloud copy refuses to
--     open a shift, start an order or close a day for that branch (those happen in the shop only)
--   * motionpos_sync_info_public(): small status answer for the install scripts (no data)
-- Nothing changes for the screens: has_store_server is false for every branch.
-- Same rules: if anything fails (including the self-test) the WHOLE file is rolled back.

begin;

do $preflight$
begin
  if length('إكراميات') <> 8 then
    raise exception 'file_encoding_broken: read the file as UTF-8';
  end if;
  if public.motionpos_version_public() not in ('014', '015') then
    raise exception 'schema_preflight_failed: run 014 first';
  end if;
end;
$preflight$;

-- 1) which copy is this ------------------------------------------------------------------------
create table if not exists public.sync_node (
  id boolean primary key default true check (id),
  node text not null default 'cloud' check (node in ('cloud', 'store')),
  node_id uuid not null default gen_random_uuid(),
  replica_ok boolean,
  updated_at timestamptz not null default now()
);
insert into public.sync_node (id) values (true) on conflict (id) do nothing;

-- 2) change log --------------------------------------------------------------------------------
create table if not exists public.sync_log (
  id bigserial primary key,
  tbl text not null,
  pk jsonb not null,
  op char(1) not null check (op in ('I', 'U', 'D')),
  changed_at timestamptz not null default clock_timestamp(),
  tx bigint not null default txid_current()
);
create index if not exists sync_log_tbl_pk_idx on public.sync_log (tbl, (pk::text));

alter table public.sync_node enable row level security;
alter table public.sync_log enable row level security;

create or replace function public.trg_sync_log()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row jsonb;
  v_old jsonb;
  v_pk jsonb := '{}'::jsonb;
  v_opk jsonb := '{}'::jsonb;
  i int;
begin
  if coalesce(current_setting('motionpos.sync_apply', true), '') = 'on' then
    return null;
  end if;
  if tg_op = 'DELETE' then
    v_row := to_jsonb(old);
  else
    v_row := to_jsonb(new);
  end if;
  if tg_op = 'UPDATE' then
    v_old := to_jsonb(old);
    if v_old = v_row then
      return null;
    end if;
    for i in 0 .. tg_nargs - 1 loop
      v_opk := v_opk || jsonb_build_object(tg_argv[i], v_old -> tg_argv[i]);
    end loop;
  end if;
  for i in 0 .. tg_nargs - 1 loop
    v_pk := v_pk || jsonb_build_object(tg_argv[i], v_row -> tg_argv[i]);
  end loop;
  if tg_op = 'UPDATE' and v_opk <> v_pk then
    insert into public.sync_log (tbl, pk, op) values (tg_table_name, v_opk, 'D');
    insert into public.sync_log (tbl, pk, op) values (tg_table_name, v_pk, 'I');
    return null;
  end if;
  insert into public.sync_log (tbl, pk, op) values (tg_table_name, v_pk, left(tg_op, 1));
  return null;
end;
$$;

-- 3) settings_logs: counter -> unique code (no screen or function reads its id) ------------------
do $settings_logs$
begin
  if (select c.data_type from information_schema.columns c
       where c.table_schema = 'public' and c.table_name = 'settings_logs' and c.column_name = 'id') <> 'uuid' then
    alter table public.settings_logs alter column id drop default;
    alter table public.settings_logs alter column id type uuid using gen_random_uuid();
    alter table public.settings_logs alter column id set default gen_random_uuid();
    drop sequence if exists public.settings_logs_id_seq;
  end if;
end;
$settings_logs$;

-- 4) put the log on every shared table (later files call this again for new tables) --------------
create or replace function public.pos_sync_attach_all()
returns integer
language plpgsql
set search_path = public
as $$
declare
  t record;
  v_args text;
  v_n int := 0;
  -- shop-only or calculated tables: never copied between the two places
  v_skip text[] := array['sync_log', 'sync_node', 'login_attempts', 'manager_pin_attempts',
                         'staff_sessions', 'order_sequences', 'warehouse_stock'];
begin
  for t in
    select c.oid, c.relname
      from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relkind in ('r', 'p') and not c.relispartition
     order by c.relname
  loop
    execute format('drop trigger if exists trg_sync_log on public.%I', t.relname);
    continue when t.relname = any (v_skip);
    select string_agg(quote_literal(a.attname), ', ' order by k.ord) into v_args
      from pg_index ix
      cross join lateral unnest(ix.indkey::int2[]) with ordinality as k(attnum, ord)
      join pg_attribute a on a.attrelid = ix.indrelid and a.attnum = k.attnum
     where ix.indrelid = t.oid and ix.indisprimary;
    if v_args is null then
      raise exception 'sync_no_primary_key: %', t.relname;
    end if;
    execute format('create trigger trg_sync_log after insert or update or delete on public.%I '
                   'for each row execute function public.trg_sync_log(%s)', t.relname, v_args);
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$$;

select public.pos_sync_attach_all();

-- 5) shop-only actions ---------------------------------------------------------------------------
alter table public.branches add column if not exists has_store_server boolean not null default false;

create or replace function public.trg_store_only()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if coalesce(current_setting('motionpos.sync_apply', true), '') = 'on' then
    return new;
  end if;
  if new.branch_id is not null
     and exists (select 1 from public.sync_node n where n.node = 'cloud')
     and exists (select 1 from public.branches b where b.id = new.branch_id and b.has_store_server) then
    raise exception 'store_server_only';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_store_only on public.pos_shifts;
create trigger trg_store_only before insert on public.pos_shifts for each row execute function public.trg_store_only();
drop trigger if exists trg_store_only on public.orders;
create trigger trg_store_only before insert on public.orders for each row execute function public.trg_store_only();
drop trigger if exists trg_store_only on public.pos_days;
create trigger trg_store_only before insert on public.pos_days for each row execute function public.trg_store_only();

-- 6) can the sync switch off the other triggers while it copies? (answer kept for step 5) ---------
do $replica$
declare
  v boolean;
begin
  begin
    set local session_replication_role = replica;
    set local session_replication_role = origin;
    v := true;
  exception when others then
    v := false;
  end;
  update public.sync_node set replica_ok = v, updated_at = now();
end;
$replica$;

-- 7) status + version ----------------------------------------------------------------------------
create or replace function public.motionpos_sync_info_public()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'node', (select n.node from public.sync_node n),
    'replica_ok', (select n.replica_ok from public.sync_node n),
    'logged_tables', (select count(*) from pg_trigger tg where tg.tgname = 'trg_sync_log' and not tg.tgisinternal),
    'guarded_tables', (select count(*) from pg_trigger tg where tg.tgname = 'trg_store_only' and not tg.tgisinternal))
$$;

create or replace function public.motionpos_version_public()
returns text
language sql
immutable
as $$
  select '015'
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
  revoke all on table public.sync_log, public.sync_node from public, anon, authenticated;
  revoke all on sequence public.sync_log_id_seq from public, anon, authenticated;
end;
$grants$;

-- 8) self-test (everything below is rolled back) ---------------------------------------------------
do $selftest$
declare
  v_unit uuid;
  v_branch uuid;
  v_ops text;
  v_err text := '';
begin
  begin
    insert into public.units (code, name_ar, name_en, unit_type)
    values ('selftest015', 'اختبار', 'selftest', 'count') returning id into v_unit;
    update public.units set name_en = 'selftest' where id = v_unit;   -- nothing changed: not logged
    update public.units set name_en = 'selftest2' where id = v_unit;
    delete from public.units where id = v_unit;
    select string_agg(l.op, '' order by l.id) into v_ops
      from public.sync_log l where l.tbl = 'units' and l.pk = jsonb_build_object('id', v_unit);
    if coalesce(v_ops, '') <> 'IUD' then
      raise exception 'SELFTEST sync log wrong: %', v_ops;
    end if;

    perform set_config('motionpos.sync_apply', 'on', true);
    insert into public.units (code, name_ar, name_en, unit_type)
    values ('selftest015b', 'اختبار', 'selftest', 'count') returning id into v_unit;
    perform set_config('motionpos.sync_apply', 'off', true);
    if exists (select 1 from public.sync_log l where l.tbl = 'units' and l.pk = jsonb_build_object('id', v_unit)) then
      raise exception 'SELFTEST sync copy was logged';
    end if;

    if exists (select 1 from public.settings_logs s where s.id is null) then
      raise exception 'SELFTEST settings_logs id empty';
    end if;

    update public.sync_node set node = 'cloud';
    insert into public.branches (name, has_store_server) values ('selftest015', true) returning id into v_branch;
    begin
      insert into public.pos_days (branch_id, business_date) values (v_branch, current_date);
    exception when others then
      v_err := sqlerrm;
    end;
    if v_err <> 'store_server_only' then
      raise exception 'SELFTEST shop-only guard wrong: %', v_err;
    end if;

    raise notice 'MOTIONPOS-015-SELFTEST-OK';
    raise exception using errcode = 'P0099', message = 'selftest_rollback';
  exception when sqlstate 'P0099' then
    null;
  end;
end;
$selftest$;

commit;
