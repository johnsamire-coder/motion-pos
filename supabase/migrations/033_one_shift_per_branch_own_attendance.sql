-- 033_one_shift_per_branch_own_attendance.sql
-- 1) shift_open_secure: a branch can have only one open shift at a time (anyone's). Refusal says who has it open.
-- 2) attendance_punch_secure: only the person logged in on the screen can punch, with his own PIN
--    (another employee's PIN is refused with not_your_account).
-- Both functions copied from 011 with only those changes. No tables changed, no data changed.
-- Rules: begin/commit, preflight (needs 032), version bump to 033, grants loop, rolled-back self-test.

begin;

do $preflight$
begin
  if length('إكراميات') <> 8 then
    raise exception 'file_encoding_broken: read the file as UTF-8';
  end if;
  if public.motionpos_version_public() not in ('032', '033') then
    raise exception 'schema_preflight_failed: run 032 first';
  end if;
end;
$preflight$;

create or replace function public.shift_open_secure(p_token text, p_opening_float numeric)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
  v_id uuid;
  v_float numeric := round(coalesce(p_opening_float, 0), 2);
begin
  select * into c from public.pos_ctx(p_token, 'shift');
  -- one open shift per branch: two people opening at the same moment wait for each other here
  perform pg_advisory_xact_lock(hashtext('motionpos_shift_open:' || coalesce(c.branch_id::text, '')));
  if exists (select 1 from public.pos_shifts s where s.staff_id = c.staff_id and s.status = 'open') then
    return jsonb_build_object('ok', false, 'reason', 'shift_already_open');
  end if;
  if exists (select 1 from public.pos_shifts s where s.branch_id = c.branch_id and s.status = 'open') then
    return jsonb_build_object('ok', false, 'reason', 'branch_shift_open',
      'staff', (select st.name from public.pos_shifts s join public.staff st on st.id = s.staff_id
                 where s.branch_id = c.branch_id and s.status = 'open' order by s.opened_at limit 1),
      'opened_at', (select min(s.opened_at) from public.pos_shifts s where s.branch_id = c.branch_id and s.status = 'open'));
  end if;
  if v_float < 0 or v_float > 1000000 then
    return jsonb_build_object('ok', false, 'reason', 'invalid_amount');
  end if;
  insert into public.pos_shifts (company_id, branch_id, staff_id, opening_float)
  values (c.company_id, c.branch_id, c.staff_id, v_float) returning id into v_id;
  if v_float > 0 then
    insert into public.pos_cash_moves (shift_id, company_id, branch_id, move_type, amount, source, destination, reason, staff_id)
    values (v_id, c.company_id, c.branch_id, 'float', v_float, 'main_cash', 'drawer', 'عهدة أول الوردية', c.staff_id);
    perform public.pos_post_je(c.company_id, c.branch_id, 'payment', 'shift', v_id, 'عهدة أول الوردية',
      jsonb_build_array(public.pos_je_line('1101', v_float, 0, 'درج الكاشير'),
                        public.pos_je_line('1100', 0, v_float, 'من الخزينة الرئيسية')), c.staff_id);
  end if;
  return jsonb_build_object('ok', true, 'shift_id', v_id);
end;
$$;

create or replace function public.attendance_punch_secure(p_token text, p_pin text)
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
  v_open uuid;
begin
  select * into c from public.pos_ctx(p_token, null);
  select count(*) into v_fail from public.manager_pin_attempts
   where client_ip = v_ip and not success and attempted_at > now() - interval '10 minutes';
  if v_fail >= 10 then
    return jsonb_build_object('ok', false, 'reason', 'locked');
  end if;
  -- only the person logged in on this screen can punch, with his own PIN
  if p_pin is not null and p_pin ~ '^[0-9]{4}$' then
    select s.id, s.name into v_sid, v_sname
      from public.staff s
     where s.id = c.staff_id and s.is_active is true and s.pin_hash is not null
       and s.pin_hash = extensions.crypt(p_pin, s.pin_hash);
  end if;
  if v_sid is null then
    insert into public.manager_pin_attempts (client_ip, success) values (v_ip, false);
    if p_pin ~ '^[0-9]{4}$' and exists (select 1 from public.staff s
         where s.branch_id = c.branch_id and s.id <> c.staff_id and s.is_active is true and s.pin_hash is not null
           and s.pin_hash = extensions.crypt(p_pin, s.pin_hash)) then
      return jsonb_build_object('ok', false, 'reason', 'not_your_account');
    end if;
    return jsonb_build_object('ok', false, 'reason', 'wrong_pin');
  end if;

  select a.id into v_open from public.staff_attendance a
   where a.staff_id = v_sid and a.clock_out is null and a.clock_in > now() - interval '20 hours'
   order by a.clock_in desc limit 1 for update;
  if v_open is null then
    insert into public.staff_attendance (company_id, branch_id, staff_id, device_staff_id)
    values (c.company_id, c.branch_id, v_sid, c.staff_id);
    return jsonb_build_object('ok', true, 'action', 'in', 'name', v_sname, 'at', now());
  end if;
  update public.staff_attendance
     set clock_out = now(), minutes = greatest(0, round(extract(epoch from (now() - clock_in)) / 60))::int
   where id = v_open;
  return jsonb_build_object('ok', true, 'action', 'out', 'name', v_sname, 'at', now());
end;
$$;

create or replace function public.motionpos_version_public()
returns text
language sql
immutable
as $$
  select '033'
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
  v_src text;
begin
  begin
    select pg_get_functiondef('public.shift_open_secure(text,numeric)'::regprocedure) into v_src;
    if position('branch_shift_open' in v_src) = 0 then raise exception 'SELFTEST shift_open_secure not replaced'; end if;
    select pg_get_functiondef('public.attendance_punch_secure(text,text)'::regprocedure) into v_src;
    if position('not_your_account' in v_src) = 0 or position('s.id = c.staff_id' in v_src) = 0 then
      raise exception 'SELFTEST attendance_punch_secure not replaced';
    end if;
    if public.motionpos_version_public() <> '033' then raise exception 'SELFTEST version'; end if;
    raise notice 'MOTIONPOS-033-SELFTEST-OK';
    raise exception using errcode = 'P0099', message = 'selftest_rollback';
  exception when sqlstate 'P0099' then
    null;
  end;
end;
$selftest$;

notify pgrst, 'reload schema';

commit;
