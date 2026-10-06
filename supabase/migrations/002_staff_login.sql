-- 002_staff_login.sql
-- Phase 1 / Step 1.2: server-side staff login + limit on wrong attempts.
-- The browser sends the PIN only. The server answers with who the staff member is,
-- never with any PIN or hash. Inactive staff cannot log in.
-- Wrong attempts are counted: max 10 per device address and 100 in total per 10 minutes.
-- The current screens still use the old login until step 1.4.

begin;

create table if not exists public.login_attempts (
  id bigserial primary key,
  attempted_at timestamptz not null default now(),
  client_ip text not null default 'unknown',
  success boolean not null default false
);
create index if not exists login_attempts_time_idx on public.login_attempts (attempted_at);
alter table public.login_attempts enable row level security;
-- No policies on purpose: nobody reads or writes this table directly, only staff_login().

create or replace function public.staff_login(p_pin text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_headers json;
  v_ip text;
  v_ip_failures int;
  v_all_failures int;
  v_staff public.staff%rowtype;
  v_role_name text;
  v_branch jsonb;
  v_tax jsonb;
begin
  begin
    v_headers := nullif(current_setting('request.headers', true), '')::json;
  exception when others then
    v_headers := null;
  end;
  v_ip := coalesce(v_headers->>'cf-connecting-ip',
                   nullif(trim(split_part(coalesce(v_headers->>'x-forwarded-for', ''), ',', 1)), ''),
                   'unknown');

  delete from public.login_attempts where attempted_at < now() - interval '1 day';

  select count(*) into v_ip_failures from public.login_attempts
   where client_ip = v_ip and not success and attempted_at > now() - interval '10 minutes';
  select count(*) into v_all_failures from public.login_attempts
   where not success and attempted_at > now() - interval '10 minutes';

  if v_ip_failures >= 10 or v_all_failures >= 100 then
    return jsonb_build_object('ok', false, 'reason', 'locked');
  end if;

  if p_pin is null or p_pin !~ '^[0-9]{4}$' then
    insert into public.login_attempts (client_ip, success) values (v_ip, false);
    return jsonb_build_object('ok', false, 'reason', 'wrong_pin');
  end if;

  select s.* into v_staff
    from public.staff s
   where s.is_active = true
     and s.pin_hash is not null
     and s.pin_hash = extensions.crypt(p_pin, s.pin_hash)
   limit 1;

  if v_staff.id is null then
    insert into public.login_attempts (client_ip, success) values (v_ip, false);
    return jsonb_build_object('ok', false, 'reason', 'wrong_pin');
  end if;

  delete from public.login_attempts where client_ip = v_ip and not success;
  insert into public.login_attempts (client_ip, success) values (v_ip, true);

  select r.name into v_role_name from public.roles r where r.id = v_staff.role_id;
  select to_jsonb(b) into v_branch from public.branches b where b.id = v_staff.branch_id;
  select jsonb_build_object('vat_percentage', t.vat_percentage,
                            'service_charge_percentage', t.service_charge_percentage)
    into v_tax
    from public.branch_tax_settings t
   where t.branch_id = v_staff.branch_id
   limit 1;

  return jsonb_build_object(
    'ok', true,
    'staff', jsonb_build_object(
      'id', v_staff.id,
      'name', v_staff.name,
      'email', v_staff.email,
      'role_id', v_staff.role_id,
      'branch_id', v_staff.branch_id,
      'company_id', v_staff.company_id,
      'brand_id', v_branch->>'brand_id',
      'is_active', v_staff.is_active),
    'role', jsonb_build_object('name', coalesce(v_role_name, 'cashier')),
    'branch', v_branch,
    'tax', v_tax
  );
end;
$$;

commit;
