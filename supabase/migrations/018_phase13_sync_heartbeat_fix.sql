-- 018_phase13_sync_heartbeat_fix.sql
-- Phase 13 fix: in 017 the shop server stamped the heartbeat with dblink_exec, which refuses a statement that
-- returns a result ("statement returning results not allowed"), so every sync run failed and rolled back.
-- Now the heartbeat is called through dblink(...) like the other calls. Only pos_sync_run changes.

begin;

do $preflight$
begin
  if length('إكراميات') <> 8 then
    raise exception 'file_encoding_broken: read the file as UTF-8';
  end if;
  if public.motionpos_version_public() not in ('017', '018') then
    raise exception 'schema_preflight_failed: run 017 first';
  end if;
end;
$preflight$;

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
    perform x.v from extensions.dblink(v_name, 'select public.pos_sync_heartbeat()::text') as x(v text);
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

create or replace function public.motionpos_version_public()
returns text
language sql
immutable
as $$
  select '018'
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

-- self-test (rolled back): the exact heartbeat statement the shop sends stamps the time, and no dblink_exec is left
do $selftest$
declare
  v text;
begin
  begin
    insert into public.sync_state (key, value) values ('store_seen', '2000-01-01') on conflict (key) do update set value = '2000-01-01';
    execute 'select public.pos_sync_heartbeat()::text' into v;
    if (select s.value::timestamptz from public.sync_state s where s.key = 'store_seen') < now() - interval '1 minute' then
      raise exception 'SELFTEST heartbeat statement did not stamp';
    end if;
    if position('dblink_exec' in pg_get_functiondef('public.pos_sync_run(text, integer)'::regprocedure)) > 0 then
      raise exception 'SELFTEST pos_sync_run still uses dblink_exec';
    end if;
    raise notice 'MOTIONPOS-018-SELFTEST-OK';
    raise exception using errcode = 'P0099', message = 'selftest_rollback';
  exception when sqlstate 'P0099' then
    null;
  end;
end;
$selftest$;

commit;
