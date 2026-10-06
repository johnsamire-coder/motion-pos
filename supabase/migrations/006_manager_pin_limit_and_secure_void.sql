-- 006_manager_pin_limit_and_secure_void.sql
-- Phase 1 / Step 1.5 (b):
-- 1) verify_manager_pin gets an attempt limit (10 wrong per address / 100 total per 10 minutes)
--    and now returns NULL on a wrong PIN instead of raising an error
--    (an error would roll back the counting of the wrong attempt).
-- 2) void_order_item_secure: cancelling an item needs the cashier's shift ticket AND a manager PIN,
--    checked on the server. The item must belong to an open order of the cashier's branch.
--    Cashier, approving manager and reason are logged in order_logs.
--    No stock is returned: sales do not deduct stock yet (phase 2), so returning it created fake stock.
-- 3) secure_adjust_tip (not used by any screen, relied on the old error) is closed to the public key.
-- The old void_order_item is closed later (007), after the cashier screen moves to the new one.

begin;

create table if not exists public.manager_pin_attempts (
  id bigserial primary key,
  attempted_at timestamptz not null default now(),
  client_ip text not null default 'unknown',
  success boolean not null default false
);
create index if not exists manager_pin_attempts_time_idx on public.manager_pin_attempts (attempted_at);
alter table public.manager_pin_attempts enable row level security;
-- No policies on purpose.

create or replace function public.request_client_ip()
returns text
language plpgsql
stable
as $$
declare
  v_headers json;
begin
  begin
    v_headers := nullif(current_setting('request.headers', true), '')::json;
  exception when others then
    v_headers := null;
  end;
  return coalesce(v_headers->>'cf-connecting-ip',
                  nullif(trim(split_part(coalesce(v_headers->>'x-forwarded-for', ''), ',', 1)), ''),
                  'unknown');
end;
$$;

create or replace function public.verify_manager_pin(p_pin text, p_branch_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_ip text := public.request_client_ip();
  v_ip_failures int;
  v_all_failures int;
  v_user_id uuid;
begin
  delete from public.manager_pin_attempts where attempted_at < now() - interval '1 day';

  select count(*) into v_ip_failures from public.manager_pin_attempts
   where client_ip = v_ip and not success and attempted_at > now() - interval '10 minutes';
  select count(*) into v_all_failures from public.manager_pin_attempts
   where not success and attempted_at > now() - interval '10 minutes';
  if v_ip_failures >= 10 or v_all_failures >= 100 then
    return null;
  end if;

  if p_pin is not null and p_pin ~ '^[0-9]{4}$' then
    select s.id into v_user_id
      from public.staff s
      join public.roles r on r.id = s.role_id
     where s.branch_id = p_branch_id
       and s.is_active = true
       and r.name in ('owner', 'branch_manager')
       and s.pin_hash is not null
       and s.pin_hash = extensions.crypt(p_pin, s.pin_hash)
     limit 1;
  end if;

  if v_user_id is null then
    insert into public.manager_pin_attempts (client_ip, success) values (v_ip, false);
    return null;
  end if;

  delete from public.manager_pin_attempts where client_ip = v_ip and not success;
  insert into public.manager_pin_attempts (client_ip, success) values (v_ip, true);
  return v_user_id;
end;
$$;

create or replace function public.void_order_item_secure(
  p_token text,
  p_order_item_id uuid,
  p_reason_id uuid,
  p_manager_pin text
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_staff_id uuid;
  v_branch_id uuid;
  v_order_id uuid;
  v_product_name text;
  v_qty numeric;
  v_unit_price numeric;
  v_manager_id uuid;
begin
  select rs.staff_id, rs.branch_id into v_staff_id, v_branch_id from public.require_session(p_token) rs;

  select oi.order_id, p.name, oi.quantity, oi.unit_price
    into v_order_id, v_product_name, v_qty, v_unit_price
    from public.order_items oi
    join public.orders o on o.id = oi.order_id
    left join public.products p on p.id = oi.product_id
   where oi.id = p_order_item_id
     and oi.status = 'active'
     and o.branch_id = v_branch_id
     and coalesce(o.status, '') not in ('closed', 'cancelled');

  if v_order_id is null then
    return jsonb_build_object('ok', false, 'reason', 'item_not_found');
  end if;

  if p_reason_id is null or not exists (select 1 from public.cancel_reasons c where c.id = p_reason_id) then
    return jsonb_build_object('ok', false, 'reason', 'bad_reason');
  end if;

  v_manager_id := public.verify_manager_pin(p_manager_pin, v_branch_id);
  if v_manager_id is null then
    return jsonb_build_object('ok', false, 'reason', 'manager_pin');
  end if;

  update public.order_items
     set status = 'voided', void_reason_id = p_reason_id
   where id = p_order_item_id;

  insert into public.order_logs (order_id, user_id, action, details)
  values (v_order_id, v_staff_id, 'VOID_ITEM', jsonb_build_object(
    'product', v_product_name,
    'qty_voided', v_qty,
    'unit_price', v_unit_price,
    'reason_id', p_reason_id,
    'cashier_id', v_staff_id,
    'approved_by_manager_id', v_manager_id,
    'stock_returned', false
  ));

  return jsonb_build_object('ok', true);
end;
$$;

revoke execute on function public.secure_adjust_tip(uuid, numeric, text, uuid, text) from public, anon, authenticated;

commit;
