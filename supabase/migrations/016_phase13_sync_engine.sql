-- 016_phase13_sync_engine.sql
-- Phase 13 (whole shop works without internet), step 5: the two-way sync.
-- The shop server runs pos_sync_run(connection) every 30 seconds. It talks to the cloud copy through dblink
-- (dblink exists on the shop server only; the cloud copy only answers pos_sync_changes / pos_sync_apply / pos_sync_snapshot).
--   * first run: full copy cloud -> shop (pos_sync_initial)
--   * every run: changes since the last run on both sides (from sync_log), the same row changed on both sides
--     = conflict: the newer change wins, the other one is kept in sync_conflicts
--   * copied rows are written in replica mode (no triggers: same order numbers, same totals, not logged again)
--   * after copying: stock per warehouse, customer balance and supplier balance are recalculated from their movements
--   * a row that cannot be written (for example same phone on two customers) is skipped and kept in sync_conflicts as an error
-- Nothing changes for the screens.

begin;

do $preflight$
begin
  if length('إكراميات') <> 8 then
    raise exception 'file_encoding_broken: read the file as UTF-8';
  end if;
  if public.motionpos_version_public() not in ('015', '016') then
    raise exception 'schema_preflight_failed: run 015 first';
  end if;
end;
$preflight$;

-- 1) tables ----------------------------------------------------------------------------------------
create table if not exists public.sync_state (
  key text primary key,
  value text,
  updated_at timestamptz not null default now()
);
create table if not exists public.sync_runs (
  id bigserial primary key,
  started_at timestamptz not null default clock_timestamp(),
  finished_at timestamptz,
  pulled int not null default 0,
  pushed int not null default 0,
  conflicts int not null default 0,
  errors int not null default 0,
  note text
);
create table if not exists public.sync_conflicts (
  id uuid primary key default gen_random_uuid(),
  kind text not null check (kind in ('conflict', 'error')),
  tbl text not null,
  pk jsonb not null,
  winner text check (winner in ('store', 'cloud')),
  store_data jsonb,
  cloud_data jsonb,
  store_changed_at timestamptz,
  cloud_changed_at timestamptz,
  message text,
  created_at timestamptz not null default now(),
  resolved_at timestamptz,
  resolved_by uuid
);
create index if not exists sync_conflicts_open_idx on public.sync_conflicts (created_at desc) where resolved_at is null;
alter table public.sync_state enable row level security;
alter table public.sync_runs enable row level security;
alter table public.sync_conflicts enable row level security;

-- 2) helpers -----------------------------------------------------------------------------------------
create or replace function public.pos_sync_cols(p_table text)
returns text
language sql
stable
set search_path = public
as $$
  select string_agg(quote_ident(a.attname), ', ' order by a.attnum)
    from pg_attribute a
   where a.attrelid = ('public.' || quote_ident(p_table))::regclass
     and a.attnum > 0 and not a.attisdropped and a.attgenerated = ''
$$;

create or replace function public.pos_sync_pk(p_table text)
returns text[]
language sql
stable
set search_path = public
as $$
  select array_agg(a.attname::text order by k.ord)
    from pg_index ix
    cross join lateral unnest(ix.indkey::int2[]) with ordinality as k(attnum, ord)
    join pg_attribute a on a.attrelid = ix.indrelid and a.attnum = k.attnum
   where ix.indrelid = ('public.' || quote_ident(p_table))::regclass and ix.indisprimary
$$;

-- "t.col1 = ($1->>'col1')::type and ..." for a primary key held in $1
create or replace function public.pos_sync_where(p_table text)
returns text
language sql
stable
set search_path = public
as $$
  select string_agg(format('t.%I = ($1->>%L)::%s', a.attname, a.attname, format_type(a.atttypid, a.atttypmod)), ' and ' order by k.ord)
    from pg_index ix
    cross join lateral unnest(ix.indkey::int2[]) with ordinality as k(attnum, ord)
    join pg_attribute a on a.attrelid = ix.indrelid and a.attnum = k.attnum
   where ix.indrelid = ('public.' || quote_ident(p_table))::regclass and ix.indisprimary
$$;

-- tables never copied in normal runs (shop-only, calculated, or the sync itself)
create or replace function public.pos_sync_skip()
returns text[]
language sql
immutable
as $$
  select array['sync_log', 'sync_node', 'sync_state', 'sync_runs', 'login_attempts', 'manager_pin_attempts',
               'staff_sessions', 'order_sequences', 'warehouse_stock']
$$;

create or replace function public.pos_sync_attach_all()
returns integer
language plpgsql
set search_path = public
as $$
declare
  t record;
  v_args text;
  v_n int := 0;
begin
  for t in
    select c.oid, c.relname
      from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relkind in ('r', 'p') and not c.relispartition
     order by c.relname
  loop
    execute format('drop trigger if exists trg_sync_log on public.%I', t.relname);
    continue when t.relname = any (public.pos_sync_skip());
    select string_agg(quote_literal(x), ', ') into v_args from unnest(public.pos_sync_pk(t.relname)) x;
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

-- 3) what changed here after a given log number (latest state of each row; data = null means deleted)
create or replace function public.pos_sync_changes(p_after bigint, p_limit int default 500)
returns jsonb
language plpgsql
stable
set search_path = public
as $$
declare
  r record;
  v_data jsonb;
  v_max bigint;
  v_out jsonb := '[]'::jsonb;
begin
  select max(b.id) into v_max
    from (select l.id from public.sync_log l where l.id > p_after order by l.id limit p_limit) b;
  if v_max is null then
    return jsonb_build_object('max_id', p_after, 'count', 0, 'changes', '[]'::jsonb);
  end if;
  for r in
    select distinct on (l.tbl, l.pk::text) l.tbl, l.pk, l.changed_at
      from public.sync_log l
     where l.id > p_after and l.id <= v_max
     order by l.tbl, l.pk::text, l.id desc
  loop
    v_data := null;
    if to_regclass('public.' || quote_ident(r.tbl)) is not null then
      execute format('select to_jsonb(t) from public.%I t where %s', r.tbl, public.pos_sync_where(r.tbl))
        into v_data using r.pk;
    end if;
    v_out := v_out || jsonb_build_array(jsonb_build_object('tbl', r.tbl, 'pk', r.pk, 'changed_at', r.changed_at, 'data', v_data));
  end loop;
  return jsonb_build_object('max_id', v_max, 'count', jsonb_array_length(v_out), 'changes', v_out);
end;
$$;

-- 4) recalc stored totals from their movements
create or replace function public.pos_sync_recalc(p_pairs jsonb, p_customers uuid[], p_suppliers uuid[], p_all_stock boolean)
returns void
language plpgsql
set search_path = public
as $$
begin
  if p_all_stock then
    insert into public.warehouse_stock (warehouse_id, ingredient_id, quantity)
    select m.warehouse_id, m.ingredient_id, sum(m.quantity)
      from public.stock_movements m
     where m.warehouse_id is not null and m.ingredient_id is not null
     group by m.warehouse_id, m.ingredient_id
    on conflict (warehouse_id, ingredient_id) do update set quantity = excluded.quantity;
    update public.warehouse_stock ws set quantity = 0
     where not exists (select 1 from public.stock_movements m where m.warehouse_id = ws.warehouse_id and m.ingredient_id = ws.ingredient_id)
       and ws.quantity <> 0;
  elsif jsonb_array_length(coalesce(p_pairs, '[]'::jsonb)) > 0 then
    insert into public.warehouse_stock (warehouse_id, ingredient_id, quantity)
    select x.w, x.i, coalesce((select sum(m.quantity) from public.stock_movements m where m.warehouse_id = x.w and m.ingredient_id = x.i), 0)
      from (select distinct (e.value->>'w')::uuid as w, (e.value->>'i')::uuid as i from jsonb_array_elements(p_pairs) e) x
     where x.w is not null and x.i is not null
    on conflict (warehouse_id, ingredient_id) do update set quantity = excluded.quantity;
  end if;
  if coalesce(array_length(p_customers, 1), 0) > 0 then
    update public.customers c
       set current_balance = coalesce((select sum(l.amount) from public.customer_ledger l where l.customer_id = c.id), 0)
     where c.id = any (p_customers);
  end if;
  if coalesce(array_length(p_suppliers, 1), 0) > 0 then
    update public.suppliers s
       set current_balance = coalesce((select sum(l.amount) from public.supplier_ledger l where l.supplier_id = s.id), 0)
     where s.id = any (p_suppliers);
  end if;
end;
$$;

-- 5) write a batch of changes here (copied rows: no triggers, not logged), returns the rows that failed
create or replace function public.pos_sync_apply(p_changes jsonb)
returns jsonb
language plpgsql
set search_path = public
as $$
declare
  c jsonb;
  v_tbl text;
  v_cols text;
  v_set text;
  v_pk text[];
  v_ok int := 0;
  v_errors jsonb := '[]'::jsonb;
  v_pairs jsonb := '[]'::jsonb;
  v_customers uuid[] := '{}';
  v_suppliers uuid[] := '{}';
  v_all_stock boolean := false;
begin
  perform set_config('motionpos.sync_apply', 'on', true);
  begin
    set local session_replication_role = replica;
  exception when others then
    null;
  end;
  for c in select e.value from jsonb_array_elements(coalesce(p_changes, '[]'::jsonb)) e loop
    v_tbl := c->>'tbl';
    begin
      if to_regclass('public.' || quote_ident(v_tbl)) is null or v_tbl = any (public.pos_sync_skip()) then
        raise exception 'sync_unknown_table: %', v_tbl;
      end if;
      if jsonb_typeof(c->'data') is distinct from 'object' then
        execute format('delete from public.%I t where %s', v_tbl, public.pos_sync_where(v_tbl)) using c->'pk';
        if v_tbl = 'stock_movements' then
          v_all_stock := true;
        end if;
      else
        v_cols := public.pos_sync_cols(v_tbl);
        v_pk := public.pos_sync_pk(v_tbl);
        select string_agg(format('%I = excluded.%I', a.attname, a.attname), ', ' order by a.attnum) into v_set
          from pg_attribute a
         where a.attrelid = ('public.' || quote_ident(v_tbl))::regclass
           and a.attnum > 0 and not a.attisdropped and a.attgenerated = ''
           and not (a.attname::text = any (v_pk));
        execute format('insert into public.%I (%s) select %s from jsonb_populate_record(null::public.%I, $1) on conflict (%s) do %s',
                       v_tbl, v_cols, v_cols, v_tbl,
                       (select string_agg(quote_ident(x), ', ') from unnest(v_pk) x),
                       coalesce('update set ' || v_set, 'nothing'))
          using c->'data';
        if v_tbl = 'stock_movements' then
          v_pairs := v_pairs || jsonb_build_array(jsonb_build_object('w', c->'data'->>'warehouse_id', 'i', c->'data'->>'ingredient_id'));
        elsif v_tbl = 'customer_ledger' and (c->'data'->>'customer_id') is not null then
          v_customers := v_customers || (c->'data'->>'customer_id')::uuid;
        elsif v_tbl = 'customers' then
          v_customers := v_customers || (c->'data'->>'id')::uuid;
        elsif v_tbl = 'supplier_ledger' and (c->'data'->>'supplier_id') is not null then
          v_suppliers := v_suppliers || (c->'data'->>'supplier_id')::uuid;
        elsif v_tbl = 'suppliers' then
          v_suppliers := v_suppliers || (c->'data'->>'id')::uuid;
        end if;
      end if;
      v_ok := v_ok + 1;
    exception when others then
      v_errors := v_errors || jsonb_build_array(jsonb_build_object('tbl', v_tbl, 'pk', c->'pk', 'data', c->'data',
                                                                   'changed_at', c->'changed_at', 'message', sqlerrm));
    end;
  end loop;
  perform public.pos_sync_recalc(v_pairs, v_customers, v_suppliers, v_all_stock);
  begin
    set local session_replication_role = origin;
  exception when others then
    null;
  end;
  perform set_config('motionpos.sync_apply', 'off', true);
  return jsonb_build_object('applied', v_ok, 'errors', v_errors);
end;
$$;

-- 6) whole table as one answer (first copy)
create or replace function public.pos_sync_snapshot(p_table text)
returns jsonb
language plpgsql
stable
set search_path = public
as $$
declare
  v jsonb;
begin
  execute format('select coalesce(jsonb_agg(to_jsonb(t)), ''[]''::jsonb) from public.%I t', p_table) into v;
  return v;
end;
$$;

create or replace function public.pos_sync_log_max()
returns bigint
language sql
stable
set search_path = public
as $$
  select coalesce(max(l.id), 0) from public.sync_log l
$$;

-- 7) shop server only: first copy and the regular run (uses dblink, created on the shop server by its install script)
create or replace function public.pos_sync_state_set(p_key text, p_value text)
returns void
language sql
set search_path = public
as $$
  insert into public.sync_state (key, value, updated_at) values (p_key, p_value, now())
  on conflict (key) do update set value = excluded.value, updated_at = excluded.updated_at
$$;

create or replace function public.pos_sync_initial(p_conn_name text)
returns int
language plpgsql
set search_path = public, extensions
as $$
declare
  t record;
  v_cloud_max bigint;
  v_rows jsonb;
  v_cols text;
  v_n int := 0;
begin
  select x.v into v_cloud_max from extensions.dblink(p_conn_name, 'select public.pos_sync_log_max()') as x(v bigint);
  perform set_config('motionpos.sync_apply', 'on', true);
  set local session_replication_role = replica;
  for t in
    select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relkind in ('r', 'p') and not c.relispartition
       and c.relname not in ('sync_log', 'sync_node', 'sync_state', 'sync_runs', 'login_attempts', 'manager_pin_attempts', 'staff_sessions')
     order by c.relname
  loop
    select x.v::jsonb into v_rows
      from extensions.dblink(p_conn_name, format('select public.pos_sync_snapshot(%L)::text', t.relname)) as x(v text);
    execute format('delete from public.%I', t.relname);
    v_cols := public.pos_sync_cols(t.relname);
    execute format('insert into public.%I (%s) select %s from jsonb_populate_recordset(null::public.%I, $1)',
                   t.relname, v_cols, v_cols, t.relname) using v_rows;
    v_n := v_n + jsonb_array_length(v_rows);
  end loop;
  set local session_replication_role = origin;
  perform set_config('motionpos.sync_apply', 'off', true);
  perform public.pos_sync_state_set('pull_cursor', v_cloud_max::text);
  perform public.pos_sync_state_set('push_cursor', public.pos_sync_log_max()::text);
  perform public.pos_sync_state_set('initial_done', now()::text);
  return v_n;
end;
$$;

create or replace function public.pos_sync_run(p_conn text, p_limit int default 500)
returns jsonb
language plpgsql
set search_path = public, extensions
as $$
declare
  v_name text := 'motionpos_cloud';
  v_ver text;
  v_initial int := null;
  v_pull bigint;
  v_push bigint;
  v_r jsonb;
  v_l jsonb;
  v_r2 jsonb;
  v_l2 jsonb;
  v_res_local jsonb;
  v_res_cloud jsonb;
  v_conf int := 0;
  v_err int := 0;
  v_run bigint;
begin
  if (select n.node from public.sync_node n) <> 'store' then
    raise exception 'sync_run_only_on_shop_server';
  end if;
  if v_name = any (coalesce(extensions.dblink_get_connections(), '{}')) then
    perform extensions.dblink_disconnect(v_name);
  end if;
  perform extensions.dblink_connect(v_name, p_conn);
  begin
    select x.v into v_ver from extensions.dblink(v_name, 'select public.motionpos_version_public()') as x(v text);
    if v_ver is distinct from public.motionpos_version_public() then
      raise exception 'sync_version_mismatch: cloud % shop %', v_ver, public.motionpos_version_public();
    end if;
    if not exists (select 1 from public.sync_state s where s.key = 'initial_done') then
      v_initial := public.pos_sync_initial(v_name);
    end if;
    insert into public.sync_runs (note) values (case when v_initial is null then null else 'first copy: ' || v_initial || ' rows' end)
      returning id into v_run;

    v_pull := coalesce((select s.value::bigint from public.sync_state s where s.key = 'pull_cursor'), 0);
    v_push := coalesce((select s.value::bigint from public.sync_state s where s.key = 'push_cursor'), 0);
    select x.v::jsonb into v_r from extensions.dblink(v_name, format('select public.pos_sync_changes(%s, %s)::text', v_pull, p_limit)) as x(v text);
    v_l := public.pos_sync_changes(v_push, p_limit);

    -- same row changed on both sides with different data: newer wins, keep the other
    insert into public.sync_conflicts (kind, tbl, pk, winner, store_data, cloud_data, store_changed_at, cloud_changed_at)
    select 'conflict', r.value->>'tbl', r.value->'pk',
           case when (r.value->>'changed_at')::timestamptz > (l.value->>'changed_at')::timestamptz then 'cloud' else 'store' end,
           l.value->'data', r.value->'data', (l.value->>'changed_at')::timestamptz, (r.value->>'changed_at')::timestamptz
      from jsonb_array_elements(v_r->'changes') r
      join jsonb_array_elements(v_l->'changes') l on l.value->>'tbl' = r.value->>'tbl' and l.value->'pk' = r.value->'pk'
     where (l.value->'data') is distinct from (r.value->'data');
    get diagnostics v_conf = row_count;

    select coalesce(jsonb_agg(r.value), '[]'::jsonb) into v_r2
      from jsonb_array_elements(v_r->'changes') r
     where not exists (select 1 from jsonb_array_elements(v_l->'changes') l
                        where l.value->>'tbl' = r.value->>'tbl' and l.value->'pk' = r.value->'pk'
                          and (l.value->>'changed_at')::timestamptz >= (r.value->>'changed_at')::timestamptz);
    select coalesce(jsonb_agg(l.value), '[]'::jsonb) into v_l2
      from jsonb_array_elements(v_l->'changes') l
     where not exists (select 1 from jsonb_array_elements(v_r->'changes') r
                        where r.value->>'tbl' = l.value->>'tbl' and r.value->'pk' = l.value->'pk'
                          and (r.value->>'changed_at')::timestamptz > (l.value->>'changed_at')::timestamptz);

    v_res_local := public.pos_sync_apply(v_r2);
    if jsonb_array_length(v_l2) > 0 then
      select x.v::jsonb into v_res_cloud
        from extensions.dblink(v_name, format('select public.pos_sync_apply(%L::jsonb)::text', v_l2::text)) as x(v text);
    else
      v_res_cloud := jsonb_build_object('applied', 0, 'errors', '[]'::jsonb);
    end if;

    -- rows that could not be written: kept as errors (cloud rows that failed here = cloud_data, and the other way)
    insert into public.sync_conflicts (kind, tbl, pk, cloud_data, cloud_changed_at, message)
    select 'error', e.value->>'tbl', e.value->'pk', e.value->'data', (e.value->>'changed_at')::timestamptz, 'shop: ' || (e.value->>'message')
      from jsonb_array_elements(v_res_local->'errors') e;
    insert into public.sync_conflicts (kind, tbl, pk, store_data, store_changed_at, message)
    select 'error', e.value->>'tbl', e.value->'pk', e.value->'data', (e.value->>'changed_at')::timestamptz, 'cloud: ' || (e.value->>'message')
      from jsonb_array_elements(v_res_cloud->'errors') e;
    v_err := jsonb_array_length(v_res_local->'errors') + jsonb_array_length(v_res_cloud->'errors');

    perform public.pos_sync_state_set('pull_cursor', (v_r->>'max_id'));
    perform public.pos_sync_state_set('push_cursor', (v_l->>'max_id'));
    perform public.pos_sync_state_set('last_ok', now()::text);
    update public.sync_runs
       set finished_at = clock_timestamp(), pulled = (v_res_local->>'applied')::int, pushed = (v_res_cloud->>'applied')::int,
           conflicts = v_conf, errors = v_err
     where id = v_run;
    perform extensions.dblink_disconnect(v_name);
  exception when others then
    if v_name = any (coalesce(extensions.dblink_get_connections(), '{}')) then
      perform extensions.dblink_disconnect(v_name);
    end if;
    raise;
  end;
  return jsonb_build_object('first_copy', v_initial, 'pulled', (v_res_local->>'applied')::int, 'pushed', (v_res_cloud->>'applied')::int,
                            'conflicts', v_conf, 'errors', v_err,
                            'more', ((v_r->>'count')::int + (v_l->>'count')::int) > 0);
end;
$$;

-- 8) status + version --------------------------------------------------------------------------------------
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
    'guarded_tables', (select count(*) from pg_trigger tg where tg.tgname = 'trg_store_only' and not tg.tgisinternal),
    'last_ok', (select s.value from public.sync_state s where s.key = 'last_ok'),
    'open_conflicts', (select count(*) from public.sync_conflicts c where c.resolved_at is null))
$$;

create or replace function public.motionpos_version_public()
returns text
language sql
immutable
as $$
  select '016'
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
  revoke all on table public.sync_state, public.sync_runs, public.sync_conflicts from public, anon, authenticated;
  revoke all on sequence public.sync_runs_id_seq from public, anon, authenticated;
end;
$grants$;

-- 9) self-test (rolled back): changes -> apply on the same database, conflict-free round trip, recalc
do $selftest$
declare
  v_after bigint;
  v_ch jsonb;
  v_res jsonb;
  v_unit uuid;
  v_wh uuid;
  v_ing uuid;
  v_branch uuid;
  v_qty numeric;
begin
  begin
    v_after := public.pos_sync_log_max();
    insert into public.units (code, name_ar, name_en, unit_type)
    values ('selftest016', 'اختبار', 'selftest', 'count') returning id into v_unit;
    update public.units set name_en = 'selftest016b' where id = v_unit;
    v_ch := public.pos_sync_changes(v_after, 500);
    if (v_ch->>'count')::int <> 1 or (v_ch->'changes'->0->'data'->>'name_en') <> 'selftest016b' then
      raise exception 'SELFTEST changes wrong: %', v_ch;
    end if;

    -- apply the same row with another name: must update, must not be logged
    v_after := public.pos_sync_log_max();
    v_res := public.pos_sync_apply(jsonb_build_array(jsonb_build_object('tbl', 'units', 'pk', jsonb_build_object('id', v_unit),
               'data', (v_ch->'changes'->0->'data') || jsonb_build_object('name_en', 'fromcloud'))));
    if (v_res->>'applied')::int <> 1 or (select u.name_en from public.units u where u.id = v_unit) <> 'fromcloud' then
      raise exception 'SELFTEST apply update wrong: %', v_res;
    end if;
    if public.pos_sync_log_max() <> v_after then
      raise exception 'SELFTEST copied row was logged';
    end if;
    if current_setting('session_replication_role') <> 'origin' or coalesce(current_setting('motionpos.sync_apply', true), '') = 'on' then
      raise exception 'SELFTEST apply did not switch back to normal';
    end if;

    -- delete through apply
    v_res := public.pos_sync_apply(jsonb_build_array(jsonb_build_object('tbl', 'units', 'pk', jsonb_build_object('id', v_unit), 'data', null)));
    if exists (select 1 from public.units u where u.id = v_unit) then
      raise exception 'SELFTEST apply delete wrong';
    end if;

    -- a bad row is reported, not fatal
    v_res := public.pos_sync_apply(jsonb_build_array(jsonb_build_object('tbl', 'units', 'pk', jsonb_build_object('id', gen_random_uuid()),
               'data', jsonb_build_object('id', gen_random_uuid()))));
    if jsonb_array_length(v_res->'errors') <> 1 then
      raise exception 'SELFTEST bad row not reported: %', v_res;
    end if;

    -- stock recalculated from a copied movement
    insert into public.branches (name) values ('selftest016') returning id into v_branch;
    insert into public.warehouses (name, branch_id) values ('selftest016', v_branch) returning id into v_wh;
    insert into public.ingredients (name, unit) values ('selftest016', 'g') returning id into v_ing;
    if v_ing is not null then
      v_res := public.pos_sync_apply(jsonb_build_array(jsonb_build_object('tbl', 'stock_movements', 'pk', jsonb_build_object('id', gen_random_uuid()),
                 'data', jsonb_build_object('id', gen_random_uuid(), 'warehouse_id', v_wh, 'ingredient_id', v_ing,
                                            'movement_type', 'adjustment', 'quantity', 7.5, 'unit_cost', 0, 'total_cost', 0, 'balance_after', 0))));
      select ws.quantity into v_qty from public.warehouse_stock ws where ws.warehouse_id = v_wh and ws.ingredient_id = v_ing;
      if v_qty is distinct from 7.50 then
        raise exception 'SELFTEST stock recalc wrong: % / %', v_qty, v_res;
      end if;
    else
      raise notice 'selftest stock part skipped (no ingredients)';
    end if;

    raise notice 'MOTIONPOS-016-SELFTEST-OK';
    raise exception using errcode = 'P0099', message = 'selftest_rollback';
  exception when sqlstate 'P0099' then
    null;
  end;
end;
$selftest$;

commit;
