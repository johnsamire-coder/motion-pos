-- 009_server_order_totals.sql
-- Phase 2 / Step 2.2: order totals are calculated on the server only.
--
-- Decisions (John, 2026-10-06):
--   * VAT on the service charge follows each branch setting (branch_tax_settings.is_service_taxable).
--   * Menu prices include VAT or not: follows each branch setting (branch_tax_settings.is_vat_inclusive).
--   * Removing VAT or service from an order needs a manager PIN and is logged.
--   * Service charge applies to dine_in orders only (same as the current cashier screen).
--
-- What this file adds:
--   1) orders.vat_enabled, orders.service_enabled (default true) and orders.order_discount_amount
--      (order-level discount only; orders.discount_amount stays the TOTAL discount = items + order).
--   2) compute_order_totals(order_id): reads active items + branch settings, returns the totals. Writes nothing.
--   3) recalc_order_totals(order_id): writes those totals on the order (open orders only; closed/paid/cancelled untouched).
--   4) Automatic recalculation (triggers) whenever order items change, or when an order's
--      vat/service switches, order discount, order type or branch change.
--      So submit_order_items_secure (008) and void_order_item_secure (006) get correct totals without being rewritten.
--   5) set_order_charges_secure(token, order, vat_on, service_on, manager_pin): turning VAT or service OFF needs a manager PIN.
--      Wrong PIN returns {ok:false, reason:'manager_pin'} (no error, so the attempt limit keeps counting).
--   Functions 2-4 cannot be called with the public key.
--
-- NOT in this file: update_order_financials stays open until step 2.7, because the live cashier
-- screen (shared database) still calls it. It is closed together with the screen change.
-- Existing orders are not recalculated by this file.
-- If a branch has no row in branch_tax_settings, the table defaults are used (14 / 12 / not inclusive / service taxable)
-- and compute_order_totals reports tax_settings_found = false.

begin;

do $preflight$
declare
  v_missing text;
begin
  if to_regprocedure('public.require_session(text)') is null
     or to_regprocedure('public.verify_manager_pin(text,uuid)') is null then
    raise exception 'schema_preflight_failed: require_session or verify_manager_pin is missing';
  end if;

  with expected(t, c) as (
    values
      ('orders','id'), ('orders','branch_id'), ('orders','order_type'), ('orders','status'),
      ('orders','sub_total'), ('orders','discount_amount'), ('orders','service_charge_amount'),
      ('orders','tax_amount'), ('orders','total_amount'),
      ('order_items','order_id'), ('order_items','total_price'), ('order_items','discount_amount'), ('order_items','status'),
      ('branch_tax_settings','branch_id'), ('branch_tax_settings','vat_percentage'),
      ('branch_tax_settings','service_charge_percentage'), ('branch_tax_settings','is_vat_inclusive'),
      ('branch_tax_settings','is_service_taxable'),
      ('order_logs','order_id'), ('order_logs','user_id'), ('order_logs','action'), ('order_logs','details')
  )
  select string_agg(e.t || '.' || e.c, ', ' order by e.t, e.c)
    into v_missing
    from expected e
   where not exists (
     select 1 from information_schema.columns ic
      where ic.table_schema = 'public' and ic.table_name = e.t and ic.column_name = e.c
   );

  if v_missing is not null then
    raise exception 'schema_preflight_failed: missing columns: %', v_missing;
  end if;
end;
$preflight$;

-- 1) New columns on orders
alter table public.orders add column if not exists vat_enabled boolean not null default true;
alter table public.orders add column if not exists service_enabled boolean not null default true;
alter table public.orders add column if not exists order_discount_amount numeric not null default 0;

-- Order-level discount for existing orders = old total discount minus item discounts.
-- Runs before the triggers exist, so no order total is changed here.
update public.orders o
   set order_discount_amount = greatest(0, coalesce(o.discount_amount, 0) - coalesce((
         select sum(coalesce(oi.discount_amount, 0))
           from public.order_items oi
          where oi.order_id = o.id
            and coalesce(oi.status, 'active') = 'active'), 0))
 where o.order_discount_amount = 0
   and coalesce(o.discount_amount, 0) > 0;

-- 2) Calculator (read only)
create or replace function public.compute_order_totals(p_order_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
declare
  v_order public.orders%rowtype;
  v_gross numeric;
  v_item_disc numeric;
  v_disc numeric;
  v_net numeric;
  v_vat_pct numeric;
  v_srv_pct numeric;
  v_inclusive boolean;
  v_srv_taxable boolean;
  v_found boolean;
  v_r numeric;
  v_base numeric;
  v_service numeric;
  v_vat numeric;
begin
  select o.* into v_order from public.orders o where o.id = p_order_id;
  if not found then
    return null;
  end if;

  select coalesce(sum(coalesce(oi.total_price, 0)), 0),
         coalesce(sum(coalesce(oi.discount_amount, 0)), 0)
    into v_gross, v_item_disc
    from public.order_items oi
   where oi.order_id = p_order_id
     and coalesce(oi.status, 'active') = 'active';

  v_disc := least(v_gross, greatest(0, v_item_disc + greatest(0, coalesce(v_order.order_discount_amount, 0))));
  v_net := v_gross - v_disc;

  select t.vat_percentage, t.service_charge_percentage, t.is_vat_inclusive, t.is_service_taxable
    into v_vat_pct, v_srv_pct, v_inclusive, v_srv_taxable
    from public.branch_tax_settings t
   where t.branch_id = v_order.branch_id
   limit 1;
  v_found := found;

  v_vat_pct := coalesce(v_vat_pct, 14);
  v_srv_pct := coalesce(v_srv_pct, 12);
  v_inclusive := coalesce(v_inclusive, false);
  v_srv_taxable := coalesce(v_srv_taxable, true);
  v_r := v_vat_pct / 100;

  -- Value of the food before VAT
  if v_inclusive then
    v_base := round(v_net / (1 + v_r), 2);
  else
    v_base := v_net;
  end if;

  if v_order.order_type = 'dine_in' and v_order.service_enabled then
    v_service := round(v_base * v_srv_pct / 100, 2);
  else
    v_service := 0;
  end if;

  if v_order.vat_enabled then
    v_vat := round(
      (case when v_inclusive then v_net - v_base else v_base * v_r end)
      + (case when v_srv_taxable then v_service * v_r else 0 end), 2);
  else
    v_vat := 0;
  end if;

  return jsonb_build_object(
    'order_id', v_order.id,
    'sub_total', v_gross,
    'discount_amount', v_disc,
    'service_charge_amount', v_service,
    'tax_amount', v_vat,
    'total_amount', v_base + v_service + v_vat,
    'vat_enabled', v_order.vat_enabled,
    'service_enabled', v_order.service_enabled,
    'vat_percentage', v_vat_pct,
    'service_charge_percentage', v_srv_pct,
    'is_vat_inclusive', v_inclusive,
    'is_service_taxable', v_srv_taxable,
    'tax_settings_found', v_found
  );
end;
$$;

-- 3) Write the totals on an open order
create or replace function public.recalc_order_totals(p_order_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_status text;
  v_t jsonb;
begin
  select o.status into v_status from public.orders o where o.id = p_order_id for update;
  if not found then
    return null;
  end if;
  if coalesce(v_status, '') in ('paid', 'closed', 'cancelled') then
    return null;
  end if;

  v_t := public.compute_order_totals(p_order_id);

  update public.orders
     set sub_total = (v_t->>'sub_total')::numeric,
         discount_amount = (v_t->>'discount_amount')::numeric,
         service_charge_amount = (v_t->>'service_charge_amount')::numeric,
         tax_amount = (v_t->>'tax_amount')::numeric,
         total_amount = (v_t->>'total_amount')::numeric
   where id = p_order_id;

  return v_t;
end;
$$;

-- 4) Automatic recalculation
create or replace function public.trg_order_items_recalc()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if tg_op in ('INSERT', 'UPDATE') then
    perform public.recalc_order_totals(new.order_id);
  end if;
  if tg_op = 'DELETE' or (tg_op = 'UPDATE' and old.order_id is distinct from new.order_id) then
    perform public.recalc_order_totals(old.order_id);
  end if;
  return null;
end;
$$;

drop trigger if exists trg_order_items_recalc on public.order_items;
create trigger trg_order_items_recalc
after insert or delete or update of order_id, quantity, unit_price, total_price, discount_amount, status
on public.order_items
for each row execute function public.trg_order_items_recalc();

create or replace function public.trg_orders_recalc()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  perform public.recalc_order_totals(new.id);
  return null;
end;
$$;

-- recalc_order_totals only sets the total columns, which are not in this list, so it does not fire itself again.
drop trigger if exists trg_orders_recalc on public.orders;
create trigger trg_orders_recalc
after update of vat_enabled, service_enabled, order_discount_amount, order_type, branch_id
on public.orders
for each row execute function public.trg_orders_recalc();

-- 5) Turning VAT / service on or off for one order
create or replace function public.set_order_charges_secure(
  p_token text,
  p_order_id uuid,
  p_vat_enabled boolean,
  p_service_enabled boolean,
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
  v_order public.orders%rowtype;
  v_needs_manager boolean;
  v_manager_id uuid;
begin
  select rs.staff_id, rs.branch_id into v_staff_id, v_branch_id from public.require_session(p_token) rs;

  if p_vat_enabled is null or p_service_enabled is null then
    return jsonb_build_object('ok', false, 'reason', 'invalid_input');
  end if;

  select o.* into v_order
    from public.orders o
   where o.id = p_order_id
     and o.branch_id = v_branch_id
   for update;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'order_not_found');
  end if;
  if coalesce(v_order.status, '') in ('paid', 'closed', 'cancelled') then
    return jsonb_build_object('ok', false, 'reason', 'order_not_open');
  end if;

  if v_order.vat_enabled = p_vat_enabled and v_order.service_enabled = p_service_enabled then
    return jsonb_build_object('ok', true, 'changed', false, 'totals', public.compute_order_totals(p_order_id));
  end if;

  v_needs_manager := (v_order.vat_enabled and not p_vat_enabled)
                  or (v_order.service_enabled and not p_service_enabled);
  if v_needs_manager then
    v_manager_id := public.verify_manager_pin(p_manager_pin, v_branch_id);
    if v_manager_id is null then
      return jsonb_build_object('ok', false, 'reason', 'manager_pin');
    end if;
  end if;

  update public.orders
     set vat_enabled = p_vat_enabled,
         service_enabled = p_service_enabled
   where id = p_order_id;

  insert into public.order_logs (order_id, user_id, action, details)
  values (p_order_id, v_staff_id, 'CHANGE_CHARGES', jsonb_build_object(
    'vat_before', v_order.vat_enabled,
    'vat_after', p_vat_enabled,
    'service_before', v_order.service_enabled,
    'service_after', p_service_enabled,
    'total_before', v_order.total_amount,
    'cashier_id', v_staff_id,
    'approved_by_manager_id', v_manager_id
  ));

  return jsonb_build_object('ok', true, 'changed', true, 'totals', public.compute_order_totals(p_order_id));
end;
$$;

-- Permissions: only set_order_charges_secure can be called with the public key.
revoke all on function public.compute_order_totals(uuid) from public, anon, authenticated;
revoke all on function public.recalc_order_totals(uuid) from public, anon, authenticated;
revoke all on function public.trg_order_items_recalc() from public, anon, authenticated;
revoke all on function public.trg_orders_recalc() from public, anon, authenticated;
revoke all on function public.set_order_charges_secure(text, uuid, boolean, boolean, text) from public, anon, authenticated;
grant execute on function public.set_order_charges_secure(text, uuid, boolean, boolean, text) to anon, authenticated, service_role;

commit;
