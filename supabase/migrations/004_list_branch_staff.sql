-- 004_list_branch_staff.sql
-- Phase 1 / Step 1.4: staff list for the cashier screen (waiter + tip dropdowns).
-- Needs a valid shift ticket. Returns only active staff of the caller's own branch,
-- and only id / name / role. No PIN, no hash, no other columns.

begin;

create or replace function public.list_branch_staff(p_token text)
returns table (id uuid, name text, role_id uuid, role_name text, branch_id uuid)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_branch uuid;
begin
  select rs.branch_id into v_branch from public.require_session(p_token) rs;

  return query
    select s.id, s.name::text, s.role_id, coalesce(r.name, 'cashier')::text, s.branch_id
      from public.staff s
      left join public.roles r on r.id = s.role_id
     where s.is_active = true
       and s.branch_id = v_branch
     order by s.name;
end;
$$;

commit;
