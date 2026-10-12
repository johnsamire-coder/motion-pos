-- 030_custom_cancel_reason.sql
-- One new function: create_cancel_reason_secure. Lets the cashier screen register a custom cancel
-- reason typed by the manager at void / cancel / refund time, instead of only picking from the
-- settings list. Security: staff session + manager PIN (verify_manager_pin - the same gate used by
-- void_order_item_secure / cancel_order_secure / refund_order_secure).
-- Text rules are the same as the settings screen: trimmed, max 150 chars, type must be one of
-- void_item / cancel_order / return. If the same text already exists for the brand it is reused
-- (no duplicate rows). Returns the reason id so the caller continues the void/cancel immediately.
-- No tables are changed and no existing function is touched.
-- Rules: begin/commit, preflight (needs 029), version bump to 030, grants loop, rolled-back self-test.

begin;

do $preflight$
begin
  if length('إكراميات') <> 8 then
    raise exception 'file_encoding_broken: read the file as UTF-8';
  end if;
  if public.motionpos_version_public() not in ('029', '030') then
    raise exception 'schema_preflight_failed: run 029 first';
  end if;
end;
$preflight$;

create or replace function public.create_cancel_reason_secure(
  p_token text, p_reason text, p_reason_type text, p_manager_pin text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_branch uuid;
  v_brand uuid;
  v_manager uuid;
  v_txt text;
  v_id uuid;
begin
  select rs.branch_id into v_branch from public.require_session(p_token) rs;

  v_txt := nullif(btrim(coalesce(p_reason, '')), '');
  if v_txt is null or coalesce(p_reason_type, '') not in ('void_item', 'cancel_order', 'return') then
    return jsonb_build_object('ok', false, 'reason', 'invalid_value');
  end if;
  v_txt := left(v_txt, 150);

  v_manager := public.verify_manager_pin(p_manager_pin, v_branch);
  if v_manager is null then
    return jsonb_build_object('ok', false, 'reason', 'manager_pin');
  end if;

  select b.brand_id into v_brand from public.branches b where b.id = v_branch;

  select x.id into v_id
    from public.cancel_reasons x
   where x.brand_id = v_brand and x.reason = v_txt
   limit 1;
  if v_id is not null then
    return jsonb_build_object('ok', true, 'id', v_id, 'reason', v_txt, 'existing', true);
  end if;

  insert into public.cancel_reasons (brand_id, reason, reason_type)
  values (v_brand, v_txt, p_reason_type)
  returning id into v_id;

  return jsonb_build_object('ok', true, 'id', v_id, 'reason', v_txt, 'existing', false);
end;
$$;

create or replace function public.motionpos_version_public()
returns text
language sql
immutable
as $$
  select '030'
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
  v_token text := 'motionpos-selftest-' || md5(random()::text || clock_timestamp()::text);
  v_mgr uuid;
  v_branch uuid;
  v_res jsonb;
  v_id uuid;
  v_txt text;
begin
  begin
    select s.id, s.branch_id into v_mgr, v_branch
      from public.staff s join public.roles r on r.id = s.role_id
     where s.is_active is true and s.branch_id is not null and r.name in ('owner', 'branch_manager')
     order by case r.name when 'owner' then 0 else 1 end
     limit 1;
    if v_mgr is null then
      raise notice 'selftest skipped: no active owner or branch manager';
      raise exception using errcode = 'P0099', message = 'selftest_skip';
    end if;

    -- temporary known PIN for the manager (the whole test rolls back)
    update public.staff set pin_hash = extensions.crypt('4321', '$2a$06$abcdefghijklmnopqrstuu') where id = v_mgr;

    insert into public.staff_sessions (token_hash, staff_id, expires_at)
    values (encode(extensions.digest(v_token, 'sha256'), 'hex'), v_mgr, now() + interval '10 minutes');

    -- a) empty / whitespace reason is rejected
    v_res := public.create_cancel_reason_secure(v_token, '   ', 'cancel_order', '4321');
    if (v_res->>'ok')::boolean is not false or v_res->>'reason' <> 'invalid_value' then
      raise exception 'SELFTEST empty reason: %', v_res;
    end if;

    -- b) wrong type is rejected
    v_res := public.create_cancel_reason_secure(v_token, 'سبب تجربة', 'wrong_type', '4321');
    if (v_res->>'ok')::boolean is not false or v_res->>'reason' <> 'invalid_value' then
      raise exception 'SELFTEST bad type: %', v_res;
    end if;

    -- c) wrong manager PIN is rejected
    v_res := public.create_cancel_reason_secure(v_token, 'سبب تجربة', 'cancel_order', 'abc');
    if (v_res->>'ok')::boolean is not false or v_res->>'reason' <> 'manager_pin' then
      raise exception 'SELFTEST bad pin: %', v_res;
    end if;

    -- d) happy path: creates the reason and returns its id
    v_txt := 'سبب تجربة 030 ' || md5(random()::text);
    v_res := public.create_cancel_reason_secure(v_token, v_txt, 'cancel_order', '4321');
    if not coalesce((v_res->>'ok')::boolean, false) then
      raise exception 'SELFTEST create: %', v_res;
    end if;
    v_id := public.pos_uuid(v_res->>'id');
    if v_id is null or not exists (select 1 from public.cancel_reasons c where c.id = v_id and c.reason = v_txt and c.reason_type = 'cancel_order') then
      raise exception 'SELFTEST row missing';
    end if;

    -- e) same text again returns the same id (no duplicate row)
    v_res := public.create_cancel_reason_secure(v_token, v_txt, 'cancel_order', '4321');
    if not coalesce((v_res->>'ok')::boolean, false) or public.pos_uuid(v_res->>'id') <> v_id then
      raise exception 'SELFTEST dedupe: %', v_res;
    end if;

    raise notice 'MOTIONPOS-030-SELFTEST-OK';
    raise exception using errcode = 'P0099', message = 'selftest_rollback';
  exception when sqlstate 'P0099' then
    null;
  end;
end;
$selftest$;

notify pgrst, 'reload schema';

commit;
