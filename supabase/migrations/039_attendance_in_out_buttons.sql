-- 039_attendance_in_out_buttons.sql
-- Attendance screen with two buttons: the employee types his PIN, sees his name and whether he is clocked in,
-- then presses "in" or "out". Only the right one is open: after "in", "in" closes and "out" opens.
-- New attendance_action_secure(token, pin, action): 'status' (no change), 'in' (refused if already in),
-- 'out' (refused if not in). Same rules as attendance_punch_secure (033): only the logged-in person, with his own PIN,
-- 10 wrong PINs from one device = 10 minutes stop, an open attendance older than 20 hours does not count.
-- attendance_punch_secure stays as it is (old screens). No tables changed.
-- Rules: begin/commit, preflight (needs 038), version bump to 039, grants loop, rolled-back self-test.

begin;

do $preflight$
begin
  if length('إكراميات') <> 8 then
    raise exception 'file_encoding_broken: read the file as UTF-8';
  end if;
  if public.motionpos_version_public() not in ('038', '039') then
    raise exception 'schema_preflight_failed: run 038 first';
  end if;
end;
$preflight$;

create or replace function public.attendance_action_secure(p_token text, p_pin text, p_action text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
  v_ip text := public.request_client_ip();
  v_fail int;
  v_sid uuid;
  v_sname text;
  v_open record;
begin
  select * into c from public.pos_ctx(p_token, null);
  if coalesce(p_action, '') not in ('status', 'in', 'out') then
    return jsonb_build_object('ok', false, 'reason', 'unknown_action');
  end if;
  select count(*) into v_fail from public.manager_pin_attempts
   where client_ip = v_ip and not success and attempted_at > now() - interval '10 minutes';
  if v_fail >= 10 then
    return jsonb_build_object('ok', false, 'reason', 'locked');
  end if;
  -- only the person logged in on this screen, with his own PIN (same as attendance_punch_secure)
  if p_pin is not null and p_pin ~ '^[0-9]{4}$' then
    select s.id, s.name into v_sid, v_sname
      from public.staff s
     where s.id = c.staff_id and s.is_active is true and s.pin_hash is not null
       and s.pin_hash = extensions.crypt(p_pin, s.pin_hash);
  end if;
  if v_sid is null then
    insert into public.manager_pin_attempts (client_ip, success) values (v_ip, false);
    return jsonb_build_object('ok', false, 'reason', 'wrong_pin');
  end if;

  select a.id, a.clock_in into v_open from public.staff_attendance a
   where a.staff_id = v_sid and a.clock_out is null and a.clock_in > now() - interval '20 hours'
   order by a.clock_in desc limit 1 for update;

  if p_action = 'status' then
    return jsonb_build_object('ok', true, 'name', v_sname, 'open', v_open.id is not null, 'clock_in', v_open.clock_in,
      'last_out', (select max(a.clock_out) from public.staff_attendance a where a.staff_id = v_sid and a.clock_out > now() - interval '20 hours'));
  end if;
  if p_action = 'in' then
    if v_open.id is not null then
      return jsonb_build_object('ok', false, 'reason', 'already_in', 'name', v_sname, 'clock_in', v_open.clock_in);
    end if;
    insert into public.staff_attendance (company_id, branch_id, staff_id, device_staff_id)
    values (c.company_id, c.branch_id, v_sid, c.staff_id);
    return jsonb_build_object('ok', true, 'action', 'in', 'name', v_sname, 'at', now());
  end if;
  -- out
  if v_open.id is null then
    return jsonb_build_object('ok', false, 'reason', 'not_in', 'name', v_sname);
  end if;
  update public.staff_attendance
     set clock_out = now(), minutes = greatest(0, round(extract(epoch from (now() - clock_in)) / 60))::int
   where id = v_open.id;
  return jsonb_build_object('ok', true, 'action', 'out', 'name', v_sname, 'at', now(), 'clock_in', v_open.clock_in,
                            'minutes', greatest(0, round(extract(epoch from (now() - v_open.clock_in)) / 60))::int);
end;
$$;

create or replace function public.motionpos_version_public()
returns text
language sql
immutable
as $$
  select '039'
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
  v_br uuid;
  v_sid uuid;
  v_tok text;
  v_res jsonb;
begin
  begin
    perform set_config('motionpos.sync_apply', 'on', true);
    insert into public.companies (name) values ('selftest039') returning id into v_co;
    insert into public.branches (name) values ('selftest039') returning id into v_br;
    insert into public.staff (name, company_id, branch_id, is_active, pin_hash, role_id)
    values ('selftest039', v_co, v_br, true, extensions.crypt('4739', extensions.gen_salt('bf')), (select id from public.roles where name = 'waiter' limit 1))
    returning id into v_sid;
    v_tok := public.staff_login('4739')->>'session_token';
    if v_tok is null then raise exception 'SELFTEST login'; end if;
    v_res := public.attendance_action_secure(v_tok, '4739', 'status');
    if (v_res->>'open')::boolean then raise exception 'SELFTEST status before'; end if;
    if public.attendance_action_secure(v_tok, '4739', 'out')->>'reason' <> 'not_in' then raise exception 'SELFTEST out before in'; end if;
    if public.attendance_action_secure(v_tok, '4739', 'in')->>'action' <> 'in' then raise exception 'SELFTEST in'; end if;
    if public.attendance_action_secure(v_tok, '4739', 'in')->>'reason' <> 'already_in' then raise exception 'SELFTEST in twice'; end if;
    if not (public.attendance_action_secure(v_tok, '4739', 'status')->>'open')::boolean then raise exception 'SELFTEST status after in'; end if;
    if public.attendance_action_secure(v_tok, '4739', 'out')->>'action' <> 'out' then raise exception 'SELFTEST out'; end if;
    if (public.attendance_action_secure(v_tok, '4739', 'status')->>'open')::boolean then raise exception 'SELFTEST status after out'; end if;
    if public.attendance_action_secure(v_tok, '0000', 'status')->>'reason' <> 'wrong_pin' then raise exception 'SELFTEST wrong pin'; end if;
    if public.motionpos_version_public() <> '039' then raise exception 'SELFTEST version'; end if;
    raise notice 'MOTIONPOS-039-SELFTEST-OK';
    raise exception using errcode = 'P0099', message = 'selftest_rollback';
  exception when sqlstate 'P0099' then
    null;
  end;
end;
$selftest$;

notify pgrst, 'reload schema';

commit;
