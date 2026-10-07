-- 017_phase13_sync_admin.sql
-- Phase 13 (whole shop works without internet), step 6: the owner's sync screen.
--   * pos_sync_heartbeat(): every good sync run, the shop server stamps "store_seen" on the cloud copy
--   * qr_request_public: for a shop-server branch, if the shop has not synced for 3 minutes the QR call
--     answers store_offline (the menu page tells the customer to call the waiter by hand)
--   * sync_admin_secure (owner only): status, list of conflicts/errors, keep (close), use the other version,
--     try again, and switch "this branch has a shop server" on/off
--   * pos_sync_write: writes one row in normal mode (logged), so a chosen version reaches the other side too
-- Nothing changes for the screens until the owner opens Settings > "الشغل من غير نت".

begin;

do $preflight$
begin
  if length('إكراميات') <> 8 then
    raise exception 'file_encoding_broken: read the file as UTF-8';
  end if;
  if public.motionpos_version_public() not in ('016', '017') then
    raise exception 'schema_preflight_failed: run 016 first';
  end if;
end;
$preflight$;

-- 1) heartbeat (runs on the cloud copy, called by the shop server) ---------------------------------
create or replace function public.pos_sync_heartbeat()
returns void
language sql
set search_path = public
as $$
  insert into public.sync_state (key, value, updated_at) values ('store_seen', now()::text, now())
  on conflict (key) do update set value = excluded.value, updated_at = excluded.updated_at
$$;

-- 2) the regular run, now with the heartbeat ---------------------------------------------------------
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
    perform extensions.dblink_exec(v_name, 'select public.pos_sync_heartbeat()');
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

-- 3) QR call refuses when the shop is offline ----------------------------------------------------------
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
  -- shop server branch, shop internet down (no sync for 3 minutes): the call would not reach the waiter in time
  if exists (select 1 from public.sync_node n where n.node = 'cloud')
     and exists (select 1 from public.branches b where b.id = t.branch_id and b.has_store_server)
     and coalesce((select s.value::timestamptz from public.sync_state s where s.key = 'store_seen'), '-infinity'::timestamptz) < now() - interval '3 minutes' then
    return jsonb_build_object('ok', false, 'reason', 'store_offline');
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

-- 4) write one row in normal mode (logged -> goes to the other side) -----------------------------------
create or replace function public.pos_sync_write(p_tbl text, p_pk jsonb, p_data jsonb)
returns void
language plpgsql
set search_path = public
as $$
declare
  v_cols text;
  v_set text;
  v_pk text[];
begin
  if to_regclass('public.' || quote_ident(p_tbl)) is null or p_tbl = any (public.pos_sync_skip()) then
    raise exception 'sync_unknown_table: %', p_tbl;
  end if;
  if jsonb_typeof(p_data) is distinct from 'object' then
    execute format('delete from public.%I t where %s', p_tbl, public.pos_sync_where(p_tbl)) using p_pk;
  else
    v_cols := public.pos_sync_cols(p_tbl);
    v_pk := public.pos_sync_pk(p_tbl);
    select string_agg(format('%I = excluded.%I', a.attname, a.attname), ', ' order by a.attnum) into v_set
      from pg_attribute a
     where a.attrelid = ('public.' || quote_ident(p_tbl))::regclass
       and a.attnum > 0 and not a.attisdropped and a.attgenerated = ''
       and not (a.attname::text = any (v_pk));
    execute format('insert into public.%I (%s) select %s from jsonb_populate_record(null::public.%I, $1) on conflict (%s) do %s',
                   p_tbl, v_cols, v_cols, p_tbl,
                   (select string_agg(quote_ident(x), ', ') from unnest(v_pk) x),
                   coalesce('update set ' || v_set, 'nothing'))
      using p_data;
  end if;
  if p_tbl in ('stock_movements') then
    perform public.pos_sync_recalc('[]'::jsonb, '{}'::uuid[], '{}'::uuid[], true);
  elsif p_tbl in ('customers', 'customer_ledger') then
    perform public.pos_sync_recalc('[]'::jsonb,
      array[coalesce((p_data->>'customer_id')::uuid, (p_data->>'id')::uuid, (p_pk->>'id')::uuid)], '{}'::uuid[], false);
  elsif p_tbl in ('suppliers', 'supplier_ledger') then
    perform public.pos_sync_recalc('[]'::jsonb, '{}'::uuid[],
      array[coalesce((p_data->>'supplier_id')::uuid, (p_data->>'id')::uuid, (p_pk->>'id')::uuid)], false);
  end if;
end;
$$;

-- 5) owner screen -------------------------------------------------------------------------------------
create or replace function public.sync_admin_secure(p_token text, p_action text, p_data jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
  v_node text;
  v_key text;
  x public.sync_conflicts%rowtype;
  v_data jsonb;
  v_branch uuid;
begin
  select * into c from public.pos_ctx(p_token, 'settings');
  if c.role_name <> 'owner' then
    return jsonb_build_object('ok', false, 'reason', 'owner_only');
  end if;
  v_node := (select n.node from public.sync_node n);

  if p_action = 'status' then
    v_key := 'store_seen';
    if v_node = 'store' then
      v_key := 'last_ok';
    end if;
    return jsonb_build_object('ok', true, 'node', v_node,
      'last_sync', (select s.value from public.sync_state s where s.key = v_key),
      'branches', coalesce((select jsonb_agg(jsonb_build_object('id', b.id, 'name', b.name, 'has_store_server', b.has_store_server) order by b.name)
                             from public.branches b), '[]'::jsonb),
      'items', coalesce((select jsonb_agg(to_jsonb(q) order by q.created_at desc)
                          from (select * from public.sync_conflicts k where k.resolved_at is null order by k.created_at desc limit 200) q), '[]'::jsonb),
      'open_count', (select count(*) from public.sync_conflicts k where k.resolved_at is null));
  end if;

  if p_action = 'set_store_server' then
    v_branch := public.pos_uuid(p_data->>'branch_id');
    if v_branch is null or not exists (select 1 from public.branches b where b.id = v_branch) then
      return jsonb_build_object('ok', false, 'reason', 'invalid_branch');
    end if;
    update public.branches set has_store_server = coalesce((p_data->>'on')::boolean, false) where id = v_branch;
    return jsonb_build_object('ok', true);
  end if;

  if p_action not in ('keep', 'use_other', 'retry') then
    return jsonb_build_object('ok', false, 'reason', 'unknown_action');
  end if;
  select * into x from public.sync_conflicts k where k.id = public.pos_uuid(p_data->>'id') and k.resolved_at is null;
  if x.id is null then
    return jsonb_build_object('ok', false, 'reason', 'conflict_not_found');
  end if;

  if p_action = 'use_other' then
    if x.kind <> 'conflict' then
      return jsonb_build_object('ok', false, 'reason', 'invalid_value');
    end if;
    v_data := x.cloud_data;
    if x.winner = 'cloud' then
      v_data := x.store_data;
    end if;
    begin
      perform public.pos_sync_write(x.tbl, x.pk, v_data);
    exception when others then
      return jsonb_build_object('ok', false, 'reason', 'retry_failed', 'message', sqlerrm);
    end;
  elsif p_action = 'retry' then
    if x.kind <> 'error' then
      return jsonb_build_object('ok', false, 'reason', 'invalid_value');
    end if;
    begin
      perform public.pos_sync_write(x.tbl, x.pk, coalesce(x.store_data, x.cloud_data));
    exception when others then
      return jsonb_build_object('ok', false, 'reason', 'retry_failed', 'message', sqlerrm);
    end;
  end if;
  update public.sync_conflicts set resolved_at = now(), resolved_by = c.staff_id where id = x.id;
  return jsonb_build_object('ok', true);
end;
$$;

-- 6) status + version ---------------------------------------------------------------------------------
create or replace function public.motionpos_version_public()
returns text
language sql
immutable
as $$
  select '017'
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

-- 7) self-test (rolled back) -----------------------------------------------------------------------------
do $selftest$
declare
  v_branch uuid;
  v_unit uuid;
  v_conf uuid;
  v_after bigint;
  v_res jsonb;
  v_table uuid;
  v_qr text;
  v_node text;
  v_company uuid;
  v_brand uuid;
  v_area uuid;
begin
  begin
    -- heartbeat
    perform public.pos_sync_heartbeat();
    if (select s.value::timestamptz from public.sync_state s where s.key = 'store_seen') < now() - interval '1 minute' then
      raise exception 'SELFTEST heartbeat wrong';
    end if;

    -- normal-mode write is logged and lands
    insert into public.units (code, name_ar, name_en, unit_type)
    values ('selftest017', 'اختبار', 'selftest', 'count') returning id into v_unit;
    v_after := public.pos_sync_log_max();
    perform public.pos_sync_write('units', jsonb_build_object('id', v_unit),
      (select to_jsonb(u) from public.units u where u.id = v_unit) || jsonb_build_object('name_en', 'chosen'));
    if (select u.name_en from public.units u where u.id = v_unit) <> 'chosen' or public.pos_sync_log_max() = v_after then
      raise exception 'SELFTEST pos_sync_write wrong';
    end if;
    perform public.pos_sync_write('units', jsonb_build_object('id', v_unit), null);
    if exists (select 1 from public.units u where u.id = v_unit) then
      raise exception 'SELFTEST pos_sync_write delete wrong';
    end if;

    -- QR refuses for a shop-server branch with an old heartbeat (cloud copy only)
    v_node := (select n.node from public.sync_node n);
    update public.sync_node set node = 'cloud';
    insert into public.companies (name) values ('selftest017') returning id into v_company;
    insert into public.brands (company_id, name) values (v_company, 'selftest017') returning id into v_brand;
    insert into public.branches (name, brand_id, has_store_server) values ('selftest017', v_brand, true) returning id into v_branch;
    insert into public.areas (branch_id, name) values (v_branch, 'selftest017') returning id into v_area;
    insert into public.tables (area_id, table_number) values (v_area, 'ST17') returning id into v_table;
    select t.qr_token into v_qr from public.tables t where t.id = v_table;
    update public.sync_state set value = (now() - interval '1 hour')::text where key = 'store_seen';
    if v_qr is not null then
      v_res := public.qr_request_public(v_qr, 'waiter');
      if coalesce(v_res->>'reason', '') <> 'store_offline' then
        raise exception 'SELFTEST QR offline check wrong: %', v_res;
      end if;
    else
      raise notice 'selftest QR part skipped (no qr_token on new table)';
    end if;
    update public.sync_node set node = v_node;

    raise notice 'MOTIONPOS-017-SELFTEST-OK';
    raise exception using errcode = 'P0099', message = 'selftest_rollback';
  exception when sqlstate 'P0099' then
    null;
  end;
end;
$selftest$;

commit;
