-- 001_hash_staff_pins.sql
-- Phase 1 / Step 1.1: store staff PINs as one-way bcrypt hashes.
-- The old plain pin_code column stays for now so the current login keeps working.
-- It will be removed after the screens move to the server login (steps 1.3 / 1.4).

begin;

alter table public.staff add column if not exists pin_hash text;

update public.staff
set pin_hash = extensions.crypt(pin_code, extensions.gen_salt('bf', 8))
where pin_code is not null and pin_hash is null;

create or replace function public.staff_sync_pin_hash()
returns trigger
language plpgsql
set search_path = public, extensions
as $$
begin
  if tg_op = 'INSERT' then
    if new.pin_code is not null then
      new.pin_hash := extensions.crypt(new.pin_code, extensions.gen_salt('bf', 8));
    end if;
  elsif new.pin_code is distinct from old.pin_code then
    new.pin_hash := case when new.pin_code is null then null
                         else extensions.crypt(new.pin_code, extensions.gen_salt('bf', 8)) end;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_staff_sync_pin_hash on public.staff;
create trigger trg_staff_sync_pin_hash
before insert or update of pin_code on public.staff
for each row execute function public.staff_sync_pin_hash();

-- Same name and inputs as before, now checks the hash and runs with server rights.
create or replace function public.verify_manager_pin(p_pin text, p_branch_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_user_id uuid;
begin
  select s.id into v_user_id
  from public.staff s
  join public.roles r on r.id = s.role_id
  where s.branch_id = p_branch_id
    and s.is_active = true
    and r.name in ('owner', 'branch_manager')
    and s.pin_hash is not null
    and s.pin_hash = extensions.crypt(p_pin, s.pin_hash)
  limit 1;

  if v_user_id is null then
    raise exception 'Not authorized: manager PIN required';
  end if;
  return v_user_id;
end;
$$;

commit;
