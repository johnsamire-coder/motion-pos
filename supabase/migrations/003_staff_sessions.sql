-- 003_staff_sessions.sql
-- Phase 1 / Step 1.3: shift ticket (session token).
-- staff_login() now also returns a secret ticket valid for 12 hours.
-- Only a fingerprint (sha256) of the ticket is stored, never the ticket itself.
-- require_session(ticket) tells the server which staff member is calling; every
-- sensitive server function will use it (phase 1.5 and phase 2).
-- staff_logout(ticket) cancels a ticket. Inactive staff lose their tickets at once.

begin;

create table if not exists public.staff_sessions (
  token_hash text primary key,
  staff_id uuid not null references public.staff(id) on delete cascade,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  revoked_at timestamptz
);
create index if not exists staff_sessions_staff_idx on public.staff_sessions (staff_id);
create index if not exists staff_sessions_expires_idx on public.staff_sessions (expires_at);
alter table public.staff_sessions enable row level security;
-- No policies on purpose: only the functions below can touch this table.

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
  v_token text;
  v_expires timestamptz;
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

  delete from public.staff_sessions where expires_at < now() - interval '7 days';
  v_token := encode(extensions.gen_random_bytes(32), 'hex');
  v_expires := now() + interval '12 hours';
  insert into public.staff_sessions (token_hash, staff_id, expires_at)
  values (encode(extensions.digest(v_token, 'sha256'), 'hex'), v_staff.id, v_expires);

  return jsonb_build_object(
    'ok', true,
    'session_token', v_token,
    'session_expires_at', v_expires,
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

create or replace function public.require_session(p_token text)
returns table (staff_id uuid, company_id uuid, branch_id uuid, role_name text)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  return query
    select st.id, st.company_id, st.branch_id, coalesce(r.name, 'cashier')::text
      from public.staff_sessions ss
      join public.staff st on st.id = ss.staff_id
      left join public.roles r on r.id = st.role_id
     where ss.token_hash = encode(extensions.digest(coalesce(p_token, ''), 'sha256'), 'hex')
       and ss.revoked_at is null
       and ss.expires_at > now()
       and st.is_active = true;
  if not found then
    raise exception 'session_invalid' using errcode = '28000';
  end if;
end;
$$;

create or replace function public.staff_logout(p_token text)
returns boolean
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  update public.staff_sessions
     set revoked_at = now()
   where token_hash = encode(extensions.digest(coalesce(p_token, ''), 'sha256'), 'hex')
     and revoked_at is null;
  return found;
end;
$$;

commit;
