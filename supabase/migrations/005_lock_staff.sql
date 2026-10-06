-- 005_lock_staff.sql
-- Phase 1 / Step 1.4 (d): lock the staff table and delete the plain PIN column for good.
-- Screens no longer read staff directly (login = staff_login, list = list_branch_staff,
-- manager check = verify_manager_pin, all with server rights). Checked before this file:
-- no function with caller rights reads staff, and only our sync trigger used pin_code.
-- After this file: the public key cannot read or change any staff row.
-- To set or reset a PIN until the staff screen exists (phase 5), run in SQL Editor:
--   update public.staff set pin_hash = extensions.crypt('1234', extensions.gen_salt('bf', 8)) where id = '<staff id>';
--   (make sure no other active staff member already uses the same PIN)

begin;

drop trigger if exists trg_staff_sync_pin_hash on public.staff;
drop function if exists public.staff_sync_pin_hash();

alter table public.staff drop column if exists pin_code;

alter table public.staff enable row level security;
-- No policies on purpose: only server functions can read staff.

commit;
