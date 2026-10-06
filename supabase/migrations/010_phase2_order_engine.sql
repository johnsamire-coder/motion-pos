-- 010_phase2_order_engine.sql
-- Phase 2 / Steps 2.3 - 2.8 in one file: the whole order engine runs on the server.
--
-- Decisions (John, 2026-10-06):
--   * Discounts come from the discounts table. A discount marked requires_approval, or a manual amount, needs a manager PIN.
--   * Tips are recorded apart from sales (liability account 2400, created here if missing).
--   * Credit (on_account) only for a registered customer (customer_type <> 'cash'); balance comes from customer_ledger.
--     If credit_limit > 0 it is enforced.
--   * Void: unsent items are removed in the browser. A sent item needs a manager PIN. If the kitchen already
--     started (kitchen_status preparing/ready) the item ingredients are recorded as waste (stock + waste_logs + GL).
--     After payment: full refund with a manager PIN, the sales journal entry is reversed (stock is not returned).
--
-- Contents:
--   1) Structure and test-data fixes (waiter role, missing order brand, tips account, wider stock quantities,
--      customer balance re-synced from its ledger, order type locked after creation).
--   2) record_stock_movement fixed (it used an undefined name, so waste / stock take / purchase never worked).
--   3) Helpers (accounts, warehouse, recipe consumption, free table). Not callable with the public key.
--   4) compute_order_totals knows percentage discounts.
--   5) Read functions: get_order_secure, list_open_orders_secure, list_customers_secure.
--   6) update_order_info_secure, apply_order_discount_secure.
--   7) void_order_item_secure (rewritten), cancel_order_secure.
--   8) close_order_secure: payments + tip + credit + stock + journal entries + close, in one transaction.
--   9) refund_order_secure.
--  10) transfer_table_order_secure, merge_orders_secure, split_order_items_secure.
--  11) Kitchen: kds_list_orders_secure, kds_set_status_secure.
--  12) Settings: settings_action_secure (+ settings_logs).
--  13) get_financial_summary_secure.
--  14) Locks: order tables closed, menu/setup tables read-only for the public key, old unsafe functions closed.
--  15) Open orders recalculated.
--  16) Self-test: a full sale is run and checked, then rolled back. If anything fails, the WHOLE file is rolled back.

begin;

-- 0) Preflight -------------------------------------------------------------
do $preflight$
begin
  -- If this file was read with the wrong encoding, Arabic text would be broken: stop.
  if length('إكراميات') <> 8 then
    raise exception 'file_encoding_broken: read the file as UTF-8';
  end if;
  if to_regprocedure('public.require_session(text)') is null
     or to_regprocedure('public.verify_manager_pin(text,uuid)') is null
     or to_regprocedure('public.compute_order_totals(uuid)') is null
     or to_regprocedure('public.recalc_order_totals(uuid)') is null
     or to_regprocedure('public.set_order_charges_secure(text,uuid,boolean,boolean,text)') is null
     or to_regprocedure('public.submit_order_items_secure(text,uuid,text,uuid,uuid,uuid,uuid,integer,jsonb)') is null
     or to_regprocedure('public.create_journal_entry(uuid,uuid,date,text,text,uuid,text,jsonb,boolean,uuid)') is null
     or to_regprocedure('public.reverse_journal_entry(uuid,uuid,text,uuid)') is null then
    raise exception 'schema_preflight_failed: run 001 to 009 first';
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'orders' and column_name = 'vat_enabled') then
    raise exception 'schema_preflight_failed: 009 is not applied';
  end if;
end;
$preflight$;

-- 1) Structure and data fixes -----------------------------------------------
alter table public.warehouse_stock alter column quantity type numeric(15,4);
alter table public.waste_logs alter column quantity type numeric(15,4);

alter table public.orders add column if not exists discount_id uuid;
alter table public.orders add column if not exists discount_percent numeric not null default 0;

insert into public.roles (name) values ('waiter') on conflict (name) do nothing;
update public.staff s
   set role_id = (select r.id from public.roles r where r.name = 'waiter')
 where s.role_id is null;

update public.orders o
   set brand_id = b.brand_id
  from public.branches b
 where o.brand_id is null
   and b.id = o.branch_id
   and b.brand_id is not null;

insert into public.accounts (company_id, code, name_ar, name_en, account_type, normal_balance, is_system_account)
select distinct a.company_id, '2400', 'إكراميات مستحقة للعاملين', 'Tips payable', 'liability', 'credit', true
  from public.accounts a
 where a.company_id is not null
   and not exists (select 1 from public.accounts x where x.company_id = a.company_id and x.code = '2400');

update public.customers c
   set current_balance = coalesce((select sum(l.amount) from public.customer_ledger l where l.customer_id = c.id), 0);

-- The order type cannot change after the order exists (changing it would remove the service charge).
create or replace function public.trg_orders_lock_type()
returns trigger
language plpgsql
as $$
begin
  if new.order_type is distinct from old.order_type then
    new.order_type := old.order_type;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_orders_lock_type on public.orders;
create trigger trg_orders_lock_type
before update of order_type on public.orders
for each row execute function public.trg_orders_lock_type();

-- 2) record_stock_movement fixed (same name and inputs) ----------------------
create or replace function public.record_stock_movement(
  p_company_id uuid, p_brand_id uuid, p_branch_id uuid, p_warehouse_id uuid, p_ingredient_id uuid,
  p_movement_type text, p_quantity numeric, p_unit_cost numeric, p_reference_type text, p_reference_id uuid,
  p_notes text default null, p_created_by uuid default null)
returns uuid
language plpgsql
set search_path = public, extensions
as $$
declare
  v_current numeric(15,4);
  v_new numeric(15,4);
  v_total numeric(15,2);
  v_id uuid;
begin
  if p_warehouse_id is null or p_ingredient_id is null then
    raise exception 'stock_movement_missing_warehouse_or_ingredient';
  end if;

  insert into public.warehouse_stock (warehouse_id, ingredient_id, quantity)
  values (p_warehouse_id, p_ingredient_id, 0)
  on conflict (warehouse_id, ingredient_id) do nothing;

  select ws.quantity into v_current
    from public.warehouse_stock ws
   where ws.warehouse_id = p_warehouse_id and ws.ingredient_id = p_ingredient_id
   for update;

  v_new := coalesce(v_current, 0) + coalesce(p_quantity, 0);
  v_total := abs(coalesce(p_quantity, 0)) * coalesce(p_unit_cost, 0);

  insert into public.stock_movements (
    company_id, brand_id, branch_id, warehouse_id, ingredient_id,
    movement_type, quantity, unit_cost, total_cost,
    reference_type, reference_id, balance_after, notes, created_by
  ) values (
    p_company_id, p_brand_id, p_branch_id, p_warehouse_id, p_ingredient_id,
    p_movement_type, coalesce(p_quantity, 0), coalesce(p_unit_cost, 0), v_total,
    p_reference_type, p_reference_id, v_new, p_notes, p_created_by
  ) returning id into v_id;

  update public.warehouse_stock
     set quantity = v_new
   where warehouse_id = p_warehouse_id and ingredient_id = p_ingredient_id;

  return v_id;
end;
$$;

-- 3) Helpers -----------------------------------------------------------------
create or replace function public.pos_uuid(p text)
returns uuid
language plpgsql
immutable
as $$
begin
  if p is not null and p ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    return p::uuid;
  end if;
  return null;
end;
$$;

create or replace function public.pos_amount(p text)
returns numeric
language plpgsql
immutable
as $$
begin
  if p is not null and p ~ '^[0-9]{1,8}(\.[0-9]{1,4})?$' then
    return p::numeric;
  end if;
  return null;
end;
$$;

create or replace function public.pos_gl_account(p_company_id uuid, p_code text)
returns uuid
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
declare
  v_id uuid;
begin
  select a.id into v_id from public.accounts a where a.company_id = p_company_id and a.code = p_code limit 1;
  if v_id is null then
    select a.id into v_id from public.accounts a where a.company_id is null and a.code = p_code limit 1;
  end if;
  if v_id is null then
    raise exception 'gl_account_missing: %', p_code;
  end if;
  return v_id;
end;
$$;

create or replace function public.pos_payment_account(p_company_id uuid, p_method text)
returns uuid
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
declare
  v_id uuid;
begin
  select m.account_id into v_id
    from public.payment_method_account_mappings m
   where m.company_id = p_company_id and m.payment_method = p_method
   limit 1;
  if v_id is null then
    v_id := public.pos_gl_account(p_company_id,
      case p_method when 'cash' then '1101' when 'on_account' then '1120' else '1110' end);
  end if;
  return v_id;
end;
$$;

create or replace function public.pos_branch_warehouse(p_branch_id uuid)
returns uuid
language sql
stable
security definer
set search_path = public, extensions
as $$
  select w.id
    from public.warehouses w
   where w.branch_id = p_branch_id
   order by w.is_main desc nulls last, w.created_at
   limit 1
$$;

create or replace function public.pos_item_consumption(p_order_item_id uuid, p_qty numeric)
returns table (ingredient_id uuid, qty numeric)
language sql
stable
security definer
set search_path = public, extensions
as $$
  select r.ingredient_id, (r.quantity_required * p_qty)::numeric
    from public.order_items oi
    join public.recipes r on r.product_id = oi.product_id
   where oi.id = p_order_item_id
     and r.ingredient_id is not null
  union all
  select m.ingredient_id, (coalesce(m.ingredient_quantity, 0) * p_qty)::numeric
    from public.order_item_modifiers oim
    join public.modifiers m on m.id = oim.modifier_id
   where oim.order_item_id = p_order_item_id
     and m.ingredient_id is not null
     and coalesce(m.ingredient_quantity, 0) > 0
$$;

create or replace function public.pos_free_table_if_empty(p_table_id uuid)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if p_table_id is null then
    return;
  end if;
  if not exists (
    select 1 from public.orders o
     where o.table_id = p_table_id
       and coalesce(o.status, '') not in ('paid', 'closed', 'cancelled')
  ) then
    update public.tables set status = 'available' where id = p_table_id and status = 'occupied';
  end if;
end;
$$;

-- 4) Totals calculator: now also handles a percentage discount ---------------
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
  v_order_disc numeric;
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

  if coalesce(v_order.discount_percent, 0) > 0 then
    v_order_disc := round(greatest(0, v_gross - v_item_disc) * least(v_order.discount_percent, 100) / 100, 2);
  else
    v_order_disc := greatest(0, coalesce(v_order.order_discount_amount, 0));
  end if;
  v_disc := least(v_gross, greatest(0, v_item_disc + v_order_disc));
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
    'order_discount', v_order_disc,
    'discount_percent', coalesce(v_order.discount_percent, 0),
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

drop trigger if exists trg_orders_recalc on public.orders;
create trigger trg_orders_recalc
after update of vat_enabled, service_enabled, order_discount_amount, discount_percent, order_type, branch_id
on public.orders
for each row execute function public.trg_orders_recalc();

-- 5) Read functions -------------------------------------------------------------
create or replace function public.get_order_secure(p_token text, p_order_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_branch uuid;
  v_res jsonb;
begin
  select rs.branch_id into v_branch from public.require_session(p_token) rs;

  select jsonb_build_object(
    'id', o.id, 'order_number', o.order_number, 'status', o.status, 'kitchen_status', o.kitchen_status,
    'order_type', o.order_type, 'area_id', o.area_id, 'table_id', o.table_id, 'table_number', t.table_number,
    'waiter_id', o.waiter_id, 'customer_id', o.customer_id, 'guest_count', o.guest_count,
    'sub_total', o.sub_total, 'discount_amount', o.discount_amount, 'service_charge_amount', o.service_charge_amount,
    'tax_amount', o.tax_amount, 'total_amount', o.total_amount,
    'vat_enabled', o.vat_enabled, 'service_enabled', o.service_enabled,
    'discount_id', o.discount_id, 'discount_percent', o.discount_percent, 'order_discount_amount', o.order_discount_amount,
    'paid_amount', coalesce((select sum(p.amount) from public.payments p where p.order_id = o.id), 0),
    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', oi.id, 'product_id', oi.product_id, 'name', coalesce(pr.name, 'صنف'),
               'quantity', oi.quantity, 'unit_price', oi.unit_price, 'total_price', oi.total_price,
               'discount_amount', coalesce(oi.discount_amount, 0), 'item_notes', oi.item_notes,
               'modifiers', coalesce((
                 select jsonb_agg(jsonb_build_object('id', m.id, 'modifier_id', m.modifier_id,
                                                     'modifier_name', m.modifier_name, 'unit_price', m.unit_price))
                   from public.order_item_modifiers m
                  where m.order_item_id = oi.id), '[]'::jsonb)
             ) order by pr.name, oi.id)
        from public.order_items oi
        left join public.products pr on pr.id = oi.product_id
       where oi.order_id = o.id
         and coalesce(oi.status, 'active') = 'active'), '[]'::jsonb)
  )
    into v_res
    from public.orders o
    left join public.tables t on t.id = o.table_id
   where o.id = p_order_id
     and o.branch_id = v_branch;

  if v_res is null then
    return jsonb_build_object('ok', false, 'reason', 'order_not_found');
  end if;
  return jsonb_build_object('ok', true, 'order', v_res);
end;
$$;

create or replace function public.list_open_orders_secure(p_token text, p_table_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_branch uuid;
begin
  select rs.branch_id into v_branch from public.require_session(p_token) rs;

  return jsonb_build_object('ok', true, 'orders', coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', o.id, 'order_number', o.order_number, 'order_type', o.order_type,
             'table_id', o.table_id, 'table_number', t.table_number, 'total_amount', o.total_amount,
             'kitchen_status', o.kitchen_status, 'created_at', o.created_at
           ) order by o.created_at)
      from public.orders o
      left join public.tables t on t.id = o.table_id
     where o.branch_id = v_branch
       and coalesce(o.status, '') not in ('paid', 'closed', 'cancelled')
       and (p_table_id is null or o.table_id = p_table_id)), '[]'::jsonb));
end;
$$;

create or replace function public.list_customers_secure(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_company uuid;
begin
  select rs.company_id into v_company from public.require_session(p_token) rs;

  return jsonb_build_object('ok', true, 'customers', coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', c.id, 'name', c.name, 'phone', c.phone, 'customer_type', c.customer_type,
             'credit_limit', c.credit_limit,
             'balance', coalesce((select sum(l.amount) from public.customer_ledger l where l.customer_id = c.id), 0)
           ) order by c.name)
      from public.customers c
     where c.company_id = v_company), '[]'::jsonb));
end;
$$;

-- 6) Order info and discounts ----------------------------------------------------
create or replace function public.update_order_info_secure(
  p_token text, p_order_id uuid, p_waiter_id uuid, p_customer_id uuid, p_guest_count integer)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_staff uuid;
  v_company uuid;
  v_branch uuid;
  v_order public.orders%rowtype;
begin
  select rs.staff_id, rs.company_id, rs.branch_id into v_staff, v_company, v_branch from public.require_session(p_token) rs;

  select o.* into v_order from public.orders o where o.id = p_order_id and o.branch_id = v_branch for update;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'order_not_found');
  end if;
  if coalesce(v_order.status, '') in ('paid', 'closed', 'cancelled') then
    return jsonb_build_object('ok', false, 'reason', 'order_not_open');
  end if;
  if p_guest_count is null or p_guest_count < 1 or p_guest_count > 9999 then
    return jsonb_build_object('ok', false, 'reason', 'invalid_guest_count');
  end if;
  if p_waiter_id is not null and not exists (
    select 1 from public.staff s where s.id = p_waiter_id and s.branch_id = v_branch and s.is_active is true) then
    return jsonb_build_object('ok', false, 'reason', 'waiter_not_in_branch');
  end if;
  if p_customer_id is not null and not exists (
    select 1 from public.customers c where c.id = p_customer_id and c.company_id = v_company) then
    return jsonb_build_object('ok', false, 'reason', 'customer_not_in_company');
  end if;

  update public.orders
     set waiter_id = p_waiter_id, customer_id = p_customer_id, guest_count = p_guest_count
   where id = p_order_id;

  insert into public.order_logs (order_id, user_id, action, details)
  values (p_order_id, v_staff, 'UPDATE_ORDER_INFO', jsonb_build_object(
    'waiter_before', v_order.waiter_id, 'waiter_after', p_waiter_id,
    'customer_before', v_order.customer_id, 'customer_after', p_customer_id,
    'guests_before', v_order.guest_count, 'guests_after', p_guest_count));

  return jsonb_build_object('ok', true);
end;
$$;

create or replace function public.apply_order_discount_secure(
  p_token text, p_order_id uuid, p_discount_id uuid, p_manual_amount numeric, p_manager_pin text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_staff uuid;
  v_branch uuid;
  v_order public.orders%rowtype;
  v_disc public.discounts%rowtype;
  v_needs_manager boolean := false;
  v_manager uuid;
  v_new_pct numeric := 0;
  v_new_amt numeric := 0;
  v_new_id uuid;
  v_kind text;
begin
  select rs.staff_id, rs.branch_id into v_staff, v_branch from public.require_session(p_token) rs;

  select o.* into v_order from public.orders o where o.id = p_order_id and o.branch_id = v_branch for update;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'order_not_found');
  end if;
  if coalesce(v_order.status, '') in ('paid', 'closed', 'cancelled') then
    return jsonb_build_object('ok', false, 'reason', 'order_not_open');
  end if;

  if p_discount_id is not null then
    select d.* into v_disc
      from public.discounts d
     where d.id = p_discount_id
       and d.brand_id is not distinct from v_order.brand_id;
    if not found then
      return jsonb_build_object('ok', false, 'reason', 'discount_not_found');
    end if;
    if v_disc.value is null or v_disc.value <= 0 then
      return jsonb_build_object('ok', false, 'reason', 'invalid_discount');
    end if;
    if v_disc.discount_type = 'percentage' then
      if v_disc.value > 100 then
        return jsonb_build_object('ok', false, 'reason', 'invalid_discount');
      end if;
      v_new_pct := v_disc.value;
    else
      v_new_amt := round(v_disc.value, 2);
    end if;
    v_new_id := v_disc.id;
    v_needs_manager := coalesce(v_disc.requires_approval, true);
    v_kind := 'list';
  elsif coalesce(p_manual_amount, 0) > 0 then
    if p_manual_amount > 99999999 then
      return jsonb_build_object('ok', false, 'reason', 'invalid_amount');
    end if;
    v_new_amt := round(p_manual_amount, 2);
    v_needs_manager := true;
    v_kind := 'manual';
  else
    v_kind := 'remove';
  end if;

  if v_needs_manager then
    v_manager := public.verify_manager_pin(p_manager_pin, v_branch);
    if v_manager is null then
      return jsonb_build_object('ok', false, 'reason', 'manager_pin');
    end if;
  end if;

  update public.orders
     set discount_id = v_new_id, discount_percent = v_new_pct, order_discount_amount = v_new_amt
   where id = p_order_id;

  insert into public.order_logs (order_id, user_id, action, details)
  values (p_order_id, v_staff, case when v_kind = 'remove' then 'REMOVE_DISCOUNT' else 'APPLY_DISCOUNT' end,
    jsonb_build_object('kind', v_kind, 'discount_id', v_new_id, 'percent', v_new_pct, 'amount', v_new_amt,
                       'total_before', v_order.total_amount, 'cashier_id', v_staff, 'approved_by_manager_id', v_manager));

  return jsonb_build_object('ok', true, 'totals', public.compute_order_totals(p_order_id));
end;
$$;

-- 7) Void and cancel -----------------------------------------------------------------
create or replace function public.pos_void_item_internal(
  p_order_item_id uuid, p_reason_id uuid, p_staff_id uuid, p_manager_id uuid, p_action text)
returns numeric
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_item record;
  v_order public.orders%rowtype;
  v_waste boolean;
  v_wh uuid;
  v_c record;
  v_unit numeric;
  v_line numeric;
  v_cost numeric := 0;
  v_waste_id uuid;
begin
  select oi.id, oi.order_id, oi.quantity, oi.unit_price, p.name as product_name
    into v_item
    from public.order_items oi
    left join public.products p on p.id = oi.product_id
   where oi.id = p_order_item_id
     and coalesce(oi.status, 'active') = 'active'
   for update of oi;
  if not found then
    return null;
  end if;

  select o.* into v_order from public.orders o where o.id = v_item.order_id;
  v_waste := coalesce(v_order.kitchen_status, 'pending') in ('preparing', 'ready');

  if v_waste then
    v_wh := public.pos_branch_warehouse(v_order.branch_id);
    if v_wh is not null then
      for v_c in
        select c.ingredient_id, sum(c.qty) as qty
          from public.pos_item_consumption(p_order_item_id, v_item.quantity) c
         group by c.ingredient_id
      loop
        if v_c.qty > 0 then
          select coalesce(i.cost_per_unit, 0) into v_unit from public.ingredients i where i.id = v_c.ingredient_id;
          v_line := round(v_c.qty * coalesce(v_unit, 0), 2);
          insert into public.waste_logs (warehouse_id, ingredient_id, quantity, reason, cost_loss)
          values (v_wh, v_c.ingredient_id, v_c.qty, 'إلغاء صنف بعد التحضير: ' || coalesce(v_item.product_name, ''), v_line)
          returning id into v_waste_id;
          perform public.record_stock_movement(
            v_order.company_id, v_order.brand_id, v_order.branch_id, v_wh, v_c.ingredient_id,
            'waste', -v_c.qty, coalesce(v_unit, 0), 'waste_log', v_waste_id,
            'هالك إلغاء صنف - طلب ' || coalesce(v_order.order_number, ''), p_staff_id);
          v_cost := v_cost + v_line;
        end if;
      end loop;
    end if;

    if v_cost > 0 then
      perform public.create_journal_entry(
        v_order.company_id, v_order.branch_id, current_date, 'inventory', 'order', v_order.id,
        'هالك إلغاء صنف بعد التحضير - طلب ' || coalesce(v_order.order_number, ''),
        jsonb_build_array(
          jsonb_build_object('account_id', public.pos_gl_account(v_order.company_id, '5100'),
                             'debit', v_cost, 'credit', 0, 'description', 'تكلفة هالك إلغاء صنف'),
          jsonb_build_object('account_id', public.pos_gl_account(v_order.company_id, '1200'),
                             'debit', 0, 'credit', v_cost, 'description', 'خصم الهالك من المخزون')),
        true, p_staff_id);
    end if;
  end if;

  update public.order_items
     set status = 'voided', void_reason_id = p_reason_id
   where id = p_order_item_id;

  insert into public.order_logs (order_id, user_id, action, details)
  values (v_order.id, p_staff_id, p_action, jsonb_build_object(
    'order_item_id', p_order_item_id, 'product', v_item.product_name, 'qty_voided', v_item.quantity,
    'unit_price', v_item.unit_price, 'reason_id', p_reason_id, 'cashier_id', p_staff_id,
    'approved_by_manager_id', p_manager_id, 'kitchen_status', v_order.kitchen_status,
    'recorded_as_waste', v_waste, 'waste_cost', v_cost, 'stock_returned', false));

  return v_cost;
end;
$$;

create or replace function public.void_order_item_secure(
  p_token text, p_order_item_id uuid, p_reason_id uuid, p_manager_pin text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_staff uuid;
  v_branch uuid;
  v_order_id uuid;
  v_manager uuid;
begin
  select rs.staff_id, rs.branch_id into v_staff, v_branch from public.require_session(p_token) rs;

  select o.id into v_order_id
    from public.order_items oi
    join public.orders o on o.id = oi.order_id
   where oi.id = p_order_item_id
     and coalesce(oi.status, 'active') = 'active'
     and o.branch_id = v_branch
     and coalesce(o.status, '') not in ('paid', 'closed', 'cancelled');
  if v_order_id is null then
    return jsonb_build_object('ok', false, 'reason', 'item_not_found');
  end if;

  if p_reason_id is null or not exists (select 1 from public.cancel_reasons c where c.id = p_reason_id) then
    return jsonb_build_object('ok', false, 'reason', 'bad_reason');
  end if;

  v_manager := public.verify_manager_pin(p_manager_pin, v_branch);
  if v_manager is null then
    return jsonb_build_object('ok', false, 'reason', 'manager_pin');
  end if;

  perform 1 from public.orders o where o.id = v_order_id for update;
  perform public.pos_void_item_internal(p_order_item_id, p_reason_id, v_staff, v_manager, 'VOID_ITEM');

  return jsonb_build_object('ok', true, 'totals', public.compute_order_totals(v_order_id));
end;
$$;

create or replace function public.cancel_order_secure(
  p_token text, p_order_id uuid, p_reason_id uuid, p_manager_pin text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_staff uuid;
  v_branch uuid;
  v_order public.orders%rowtype;
  v_active int;
  v_manager uuid;
  v_item record;
begin
  select rs.staff_id, rs.branch_id into v_staff, v_branch from public.require_session(p_token) rs;

  select o.* into v_order from public.orders o where o.id = p_order_id and o.branch_id = v_branch for update;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'order_not_found');
  end if;
  if coalesce(v_order.status, '') in ('paid', 'closed', 'cancelled') then
    return jsonb_build_object('ok', false, 'reason', 'order_not_open');
  end if;
  if exists (select 1 from public.payments p where p.order_id = p_order_id) then
    return jsonb_build_object('ok', false, 'reason', 'order_has_payments');
  end if;

  select count(*) into v_active
    from public.order_items oi
   where oi.order_id = p_order_id and coalesce(oi.status, 'active') = 'active';

  if v_active > 0 then
    if p_reason_id is null or not exists (select 1 from public.cancel_reasons c where c.id = p_reason_id) then
      return jsonb_build_object('ok', false, 'reason', 'bad_reason');
    end if;
    v_manager := public.verify_manager_pin(p_manager_pin, v_branch);
    if v_manager is null then
      return jsonb_build_object('ok', false, 'reason', 'manager_pin');
    end if;
    for v_item in
      select oi.id from public.order_items oi
       where oi.order_id = p_order_id and coalesce(oi.status, 'active') = 'active'
    loop
      perform public.pos_void_item_internal(v_item.id, p_reason_id, v_staff, v_manager, 'VOID_ITEM_CANCEL_ORDER');
    end loop;
  end if;

  update public.orders
     set status = 'cancelled',
         notes = left(coalesce(v_order.notes || ' | ', '') || 'ملغي', 500)
   where id = p_order_id;

  perform public.pos_free_table_if_empty(v_order.table_id);

  insert into public.order_logs (order_id, user_id, action, details)
  values (p_order_id, v_staff, 'CANCEL_ORDER', jsonb_build_object(
    'reason_id', p_reason_id, 'approved_by_manager_id', v_manager, 'items_voided', v_active,
    'total_before', v_order.total_amount));

  return jsonb_build_object('ok', true);
end;
$$;

-- 8) Pay and close: everything in one transaction ----------------------------------
create or replace function public.close_order_secure(
  p_token text, p_order_id uuid, p_payments jsonb, p_tip_amount numeric, p_tip_staff_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_staff uuid;
  v_branch uuid;
  v_order public.orders%rowtype;
  v_payments jsonb := coalesce(p_payments, '[]'::jsonb);
  v_totals jsonb;
  v_total numeric;
  v_tax numeric;
  v_service numeric;
  v_revenue numeric;
  v_tip numeric := round(coalesce(p_tip_amount, 0), 2);
  v_p jsonb;
  v_method text;
  v_amount numeric;
  v_paid numeric := 0;
  v_oa numeric := 0;
  v_idx int := 0;
  v_tip_line int := 0;
  v_cust public.customers%rowtype;
  v_balance numeric := 0;
  v_wh uuid;
  v_c record;
  v_unit numeric;
  v_cogs numeric := 0;
  v_lines jsonb := '[]'::jsonb;
  v_pm record;
  v_method_count int;
  v_first_method text;
begin
  select rs.staff_id, rs.branch_id into v_staff, v_branch from public.require_session(p_token) rs;

  select o.* into v_order from public.orders o where o.id = p_order_id and o.branch_id = v_branch for update;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'order_not_found');
  end if;
  if coalesce(v_order.status, '') in ('paid', 'closed', 'cancelled') then
    return jsonb_build_object('ok', false, 'reason', 'order_not_open');
  end if;
  if not exists (select 1 from public.order_items oi
                  where oi.order_id = p_order_id and coalesce(oi.status, 'active') = 'active') then
    return jsonb_build_object('ok', false, 'reason', 'empty_order');
  end if;
  if exists (select 1 from public.payments p where p.order_id = p_order_id) then
    return jsonb_build_object('ok', false, 'reason', 'order_has_old_payments');
  end if;

  v_totals := public.recalc_order_totals(p_order_id);
  v_total := (v_totals->>'total_amount')::numeric;
  v_tax := (v_totals->>'tax_amount')::numeric;
  v_service := (v_totals->>'service_charge_amount')::numeric;
  v_revenue := v_total - v_tax - v_service;

  if v_tip < 0 or v_tip > 99999999 then
    return jsonb_build_object('ok', false, 'reason', 'invalid_tip');
  end if;
  if jsonb_typeof(v_payments) is distinct from 'array' or jsonb_array_length(v_payments) > 10 then
    return jsonb_build_object('ok', false, 'reason', 'invalid_payments');
  end if;

  for v_p in select e.value from jsonb_array_elements(v_payments) as e(value)
  loop
    v_idx := v_idx + 1;
    if jsonb_typeof(v_p) is distinct from 'object' then
      return jsonb_build_object('ok', false, 'reason', 'invalid_payments');
    end if;
    v_method := v_p->>'method';
    if v_method is null or v_method not in ('cash', 'card', 'instapay', 'wallet', 'on_account') then
      return jsonb_build_object('ok', false, 'reason', 'invalid_payment_method');
    end if;
    if coalesce(v_p->>'amount', '') !~ '^[0-9]{1,9}(\.[0-9]{1,2})?$' then
      return jsonb_build_object('ok', false, 'reason', 'invalid_payment_amount');
    end if;
    v_amount := (v_p->>'amount')::numeric;
    if v_amount <= 0 then
      return jsonb_build_object('ok', false, 'reason', 'invalid_payment_amount');
    end if;
    v_paid := v_paid + v_amount;
    if v_method = 'on_account' then
      v_oa := v_oa + v_amount;
    elsif v_tip_line = 0 then
      v_tip_line := v_idx;
    end if;
  end loop;

  if abs(v_paid - v_total) > 0.004 then
    return jsonb_build_object('ok', false, 'reason', 'payment_mismatch', 'due', v_total, 'paid', v_paid);
  end if;

  if v_tip > 0 then
    if v_tip_line = 0 then
      return jsonb_build_object('ok', false, 'reason', 'tip_needs_cash_or_card');
    end if;
    if p_tip_staff_id is null or not exists (
      select 1 from public.staff s where s.id = p_tip_staff_id and s.branch_id = v_branch and s.is_active is true) then
      return jsonb_build_object('ok', false, 'reason', 'invalid_tip_staff');
    end if;
  end if;

  if v_oa > 0 then
    if v_order.customer_id is null then
      return jsonb_build_object('ok', false, 'reason', 'credit_needs_customer');
    end if;
    select c.* into v_cust
      from public.customers c
     where c.id = v_order.customer_id and c.company_id = v_order.company_id
     for update;
    if not found or coalesce(v_cust.customer_type, 'cash') = 'cash' then
      return jsonb_build_object('ok', false, 'reason', 'customer_not_allowed_credit');
    end if;
    select coalesce(sum(l.amount), 0) into v_balance from public.customer_ledger l where l.customer_id = v_cust.id;
    if coalesce(v_cust.credit_limit, 0) > 0 and v_balance + v_oa > v_cust.credit_limit then
      return jsonb_build_object('ok', false, 'reason', 'credit_limit_exceeded',
                                'balance', v_balance, 'limit', v_cust.credit_limit);
    end if;
  end if;

  -- Payments
  v_idx := 0;
  for v_p in select e.value from jsonb_array_elements(v_payments) as e(value)
  loop
    v_idx := v_idx + 1;
    insert into public.payments (order_id, payment_method, amount, tip_amount, tip_staff_id, reference_number)
    values (p_order_id, v_p->>'method', (v_p->>'amount')::numeric,
            case when v_idx = v_tip_line then v_tip else 0 end,
            case when v_idx = v_tip_line and v_tip > 0 then p_tip_staff_id else null end,
            nullif(left(btrim(coalesce(v_p->>'reference', '')), 100), ''));
  end loop;

  -- Credit sale on the customer's account
  if v_oa > 0 then
    v_balance := v_balance + v_oa;
    insert into public.customer_ledger (company_id, customer_id, order_id, transaction_type, amount,
                                        reference_number, balance_after, notes, created_by)
    values (v_order.company_id, v_cust.id, p_order_id, 'credit_sale', v_oa,
            v_order.order_number, v_balance, 'بيع آجل', v_staff);
    update public.customers set current_balance = v_balance where id = v_cust.id;
  end if;

  -- Stock: recipe + modifier ingredients of every active item
  v_wh := public.pos_branch_warehouse(v_order.branch_id);
  for v_c in
    select c.ingredient_id, sum(c.qty) as qty
      from public.order_items oi
      cross join lateral public.pos_item_consumption(oi.id, oi.quantity) c
     where oi.order_id = p_order_id
       and coalesce(oi.status, 'active') = 'active'
     group by c.ingredient_id
  loop
    if v_c.qty > 0 then
      if v_wh is null then
        raise exception 'no_branch_warehouse';
      end if;
      select coalesce(i.cost_per_unit, 0) into v_unit from public.ingredients i where i.id = v_c.ingredient_id;
      perform public.record_stock_movement(
        v_order.company_id, v_order.brand_id, v_order.branch_id, v_wh, v_c.ingredient_id,
        'sale', -v_c.qty, coalesce(v_unit, 0), 'order', p_order_id,
        'بيع - طلب ' || coalesce(v_order.order_number, ''), v_staff);
      v_cogs := v_cogs + round(v_c.qty * coalesce(v_unit, 0), 2);
    end if;
  end loop;

  -- Sales journal entry
  for v_pm in
    select p.payment_method, sum(p.amount + coalesce(p.tip_amount, 0)) as amt
      from public.payments p
     where p.order_id = p_order_id
     group by p.payment_method
  loop
    if v_pm.amt > 0 then
      v_lines := v_lines || jsonb_build_array(jsonb_build_object(
        'account_id', public.pos_payment_account(v_order.company_id, v_pm.payment_method),
        'debit', v_pm.amt, 'credit', 0, 'description', 'تحصيل ' || v_pm.payment_method));
    end if;
  end loop;
  if v_revenue > 0 then
    v_lines := v_lines || jsonb_build_array(jsonb_build_object(
      'account_id', public.pos_gl_account(v_order.company_id, '4000'),
      'debit', 0, 'credit', v_revenue, 'description', 'إيراد مبيعات'));
  end if;
  if v_service > 0 then
    v_lines := v_lines || jsonb_build_array(jsonb_build_object(
      'account_id', public.pos_gl_account(v_order.company_id, '4100'),
      'debit', 0, 'credit', v_service, 'description', 'إيراد خدمة'));
  end if;
  if v_tax > 0 then
    v_lines := v_lines || jsonb_build_array(jsonb_build_object(
      'account_id', public.pos_gl_account(v_order.company_id, '2200'),
      'debit', 0, 'credit', v_tax, 'description', 'ضريبة قيمة مضافة'));
  end if;
  if v_tip > 0 then
    v_lines := v_lines || jsonb_build_array(jsonb_build_object(
      'account_id', public.pos_gl_account(v_order.company_id, '2400'),
      'debit', 0, 'credit', v_tip, 'description', 'إكرامية مستحقة'));
  end if;
  if v_total + v_tip > 0 then
    perform public.create_journal_entry(
      v_order.company_id, v_order.branch_id, current_date, 'sales', 'order', p_order_id,
      'قيد مبيعات - طلب ' || coalesce(v_order.order_number, ''), v_lines, true, v_staff);
  end if;

  -- Cost of sales journal entry
  if v_cogs > 0 then
    perform public.create_journal_entry(
      v_order.company_id, v_order.branch_id, current_date, 'inventory', 'order', p_order_id,
      'قيد تكلفة مبيعات - طلب ' || coalesce(v_order.order_number, ''),
      jsonb_build_array(
        jsonb_build_object('account_id', public.pos_gl_account(v_order.company_id, '5000'),
                           'debit', v_cogs, 'credit', 0, 'description', 'تكلفة المبيعات'),
        jsonb_build_object('account_id', public.pos_gl_account(v_order.company_id, '1200'),
                           'debit', 0, 'credit', v_cogs, 'description', 'خصم المخزون')),
      true, v_staff);
  end if;

  select count(distinct p.payment_method), min(p.payment_method)
    into v_method_count, v_first_method
    from public.payments p
   where p.order_id = p_order_id;

  update public.orders
     set status = 'closed',
         is_posted_to_gl = true,
         payment_method = case when v_method_count = 1 then v_first_method
                               when v_method_count > 1 then 'split' else 'none' end
   where id = p_order_id;

  perform public.pos_free_table_if_empty(v_order.table_id);

  insert into public.order_logs (order_id, user_id, action, details)
  values (p_order_id, v_staff, 'CLOSE_ORDER', jsonb_build_object(
    'total', v_total, 'paid', v_paid, 'tip', v_tip, 'tip_staff_id', p_tip_staff_id,
    'on_account', v_oa, 'cogs', v_cogs, 'payments', v_payments));

  return jsonb_build_object('ok', true, 'order_number', v_order.order_number,
                            'total', v_total, 'tip', v_tip, 'cogs', v_cogs);
end;
$$;

-- 9) Refund after payment -------------------------------------------------------------
create or replace function public.refund_order_secure(
  p_token text, p_order_number text, p_reason_id uuid, p_manager_pin text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_staff uuid;
  v_branch uuid;
  v_order public.orders%rowtype;
  v_manager uuid;
  v_je record;
  v_pm record;
  v_cl record;
  v_balance numeric;
  v_reversed int := 0;
begin
  select rs.staff_id, rs.branch_id into v_staff, v_branch from public.require_session(p_token) rs;

  select o.* into v_order
    from public.orders o
   where o.branch_id = v_branch
     and o.order_number = btrim(coalesce(p_order_number, ''))
     and o.status in ('closed', 'paid')
   order by o.created_at desc
   limit 1
   for update;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'order_not_found');
  end if;

  if p_reason_id is null or not exists (select 1 from public.cancel_reasons c where c.id = p_reason_id) then
    return jsonb_build_object('ok', false, 'reason', 'bad_reason');
  end if;

  v_manager := public.verify_manager_pin(p_manager_pin, v_branch);
  if v_manager is null then
    return jsonb_build_object('ok', false, 'reason', 'manager_pin');
  end if;

  for v_je in
    select je.id
      from public.journal_entries je
     where je.reference_type = 'order'
       and je.reference_id = v_order.id
       and je.journal_type = 'sales'
       and je.status = 'posted'
  loop
    perform public.reverse_journal_entry(v_order.company_id, v_je.id,
                                         'مرتجع طلب ' || coalesce(v_order.order_number, ''), v_staff);
    v_reversed := v_reversed + 1;
  end loop;

  for v_pm in
    select p.payment_method, sum(p.amount) as amt, sum(coalesce(p.tip_amount, 0)) as tip
      from public.payments p
     where p.order_id = v_order.id
     group by p.payment_method
  loop
    if v_pm.amt <> 0 or v_pm.tip <> 0 then
      insert into public.payments (order_id, payment_method, amount, tip_amount, reference_number)
      values (v_order.id, v_pm.payment_method, -v_pm.amt, -v_pm.tip, 'REFUND');
    end if;
  end loop;

  for v_cl in
    select l.customer_id, sum(l.amount) as amt
      from public.customer_ledger l
     where l.order_id = v_order.id
     group by l.customer_id
  loop
    if v_cl.amt <> 0 then
      select coalesce(sum(x.amount), 0) - v_cl.amt into v_balance
        from public.customer_ledger x where x.customer_id = v_cl.customer_id;
      insert into public.customer_ledger (company_id, customer_id, order_id, transaction_type, amount,
                                          reference_number, balance_after, notes, created_by)
      values (v_order.company_id, v_cl.customer_id, v_order.id, 'refund', -v_cl.amt,
              v_order.order_number, v_balance, 'مرتجع', v_staff);
      update public.customers set current_balance = v_balance where id = v_cl.customer_id;
    end if;
  end loop;

  update public.orders
     set status = 'cancelled',
         notes = left(coalesce(v_order.notes || ' | ', '') || 'مرتجع', 500)
   where id = v_order.id;

  insert into public.order_logs (order_id, user_id, action, details)
  values (v_order.id, v_staff, 'REFUND_ORDER', jsonb_build_object(
    'reason_id', p_reason_id, 'approved_by_manager_id', v_manager, 'total', v_order.total_amount,
    'entries_reversed', v_reversed, 'stock_returned', false));

  return jsonb_build_object('ok', true, 'order_number', v_order.order_number, 'total', v_order.total_amount);
end;
$$;

-- 10) Transfer, merge, split -------------------------------------------------------------
create or replace function public.transfer_table_order_secure(p_token text, p_order_id uuid, p_new_table_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_staff uuid;
  v_branch uuid;
  v_order public.orders%rowtype;
  v_status text;
  v_area uuid;
begin
  select rs.staff_id, rs.branch_id into v_staff, v_branch from public.require_session(p_token) rs;

  select o.* into v_order from public.orders o where o.id = p_order_id and o.branch_id = v_branch for update;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'order_not_found');
  end if;
  if coalesce(v_order.status, '') in ('paid', 'closed', 'cancelled') then
    return jsonb_build_object('ok', false, 'reason', 'order_not_open');
  end if;
  if v_order.table_id is not distinct from p_new_table_id then
    return jsonb_build_object('ok', false, 'reason', 'same_table');
  end if;

  select t.status, t.area_id into v_status, v_area
    from public.tables t
    join public.areas a on a.id = t.area_id
   where t.id = p_new_table_id and a.branch_id = v_branch
   for update of t;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'table_not_in_branch');
  end if;
  if v_status not in ('available', 'reserved') then
    return jsonb_build_object('ok', false, 'reason', 'table_not_available');
  end if;

  update public.orders set table_id = p_new_table_id, area_id = v_area where id = p_order_id;
  update public.tables set status = 'occupied' where id = p_new_table_id;
  perform public.pos_free_table_if_empty(v_order.table_id);

  insert into public.order_logs (order_id, user_id, action, details)
  values (p_order_id, v_staff, 'TRANSFER_TABLE', jsonb_build_object(
    'from_table_id', v_order.table_id, 'to_table_id', p_new_table_id));

  return jsonb_build_object('ok', true);
end;
$$;

create or replace function public.merge_orders_secure(p_token text, p_source_order_id uuid, p_target_order_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_staff uuid;
  v_branch uuid;
  v_src public.orders%rowtype;
  v_dst public.orders%rowtype;
begin
  select rs.staff_id, rs.branch_id into v_staff, v_branch from public.require_session(p_token) rs;

  if p_source_order_id is null or p_target_order_id is null or p_source_order_id = p_target_order_id then
    return jsonb_build_object('ok', false, 'reason', 'invalid_orders');
  end if;

  perform 1 from public.orders o where o.id in (p_source_order_id, p_target_order_id) order by o.id for update;

  select o.* into v_src from public.orders o where o.id = p_source_order_id and o.branch_id = v_branch;
  if not found or coalesce(v_src.status, '') in ('paid', 'closed', 'cancelled') then
    return jsonb_build_object('ok', false, 'reason', 'source_not_open');
  end if;
  select o.* into v_dst from public.orders o where o.id = p_target_order_id and o.branch_id = v_branch;
  if not found or coalesce(v_dst.status, '') in ('paid', 'closed', 'cancelled') then
    return jsonb_build_object('ok', false, 'reason', 'target_not_open');
  end if;
  if exists (select 1 from public.payments p where p.order_id in (p_source_order_id, p_target_order_id)) then
    return jsonb_build_object('ok', false, 'reason', 'order_has_payments');
  end if;

  update public.order_items set order_id = p_target_order_id where order_id = p_source_order_id;

  update public.orders
     set status = 'cancelled',
         notes = left(coalesce(v_src.notes || ' | ', '') || 'دمج في ' || coalesce(v_dst.order_number, ''), 500)
   where id = p_source_order_id;

  perform public.pos_free_table_if_empty(v_src.table_id);

  insert into public.order_logs (order_id, user_id, action, details)
  values (p_target_order_id, v_staff, 'MERGE_ORDERS', jsonb_build_object(
            'source_order', v_src.order_number, 'target_order', v_dst.order_number)),
         (p_source_order_id, v_staff, 'MERGED_INTO', jsonb_build_object(
            'source_order', v_src.order_number, 'target_order', v_dst.order_number));

  return jsonb_build_object('ok', true, 'totals', public.compute_order_totals(p_target_order_id));
end;
$$;

create or replace function public.split_order_items_secure(p_token text, p_order_id uuid, p_items jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_staff uuid;
  v_branch uuid;
  v_order public.orders%rowtype;
  v_e jsonb;
  v_item_id uuid;
  v_qty int;
  v_item public.order_items%rowtype;
  v_moved int := 0;
  v_total_qty int;
  v_count int;
  v_distinct int;
  v_new_id uuid;
  v_new_number text;
  v_new_item uuid;
begin
  select rs.staff_id, rs.branch_id into v_staff, v_branch from public.require_session(p_token) rs;

  select o.* into v_order from public.orders o where o.id = p_order_id and o.branch_id = v_branch for update;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'order_not_found');
  end if;
  if coalesce(v_order.status, '') in ('paid', 'closed', 'cancelled') then
    return jsonb_build_object('ok', false, 'reason', 'order_not_open');
  end if;
  if jsonb_typeof(p_items) is distinct from 'array' or jsonb_array_length(p_items) < 1 or jsonb_array_length(p_items) > 200 then
    return jsonb_build_object('ok', false, 'reason', 'invalid_items');
  end if;

  select count(*), count(distinct e.value->>'order_item_id') into v_count, v_distinct
    from jsonb_array_elements(p_items) as e(value);
  if v_count <> v_distinct then
    return jsonb_build_object('ok', false, 'reason', 'duplicate_item');
  end if;

  -- First pass: check everything before changing anything
  for v_e in select e.value from jsonb_array_elements(p_items) as e(value)
  loop
    v_item_id := public.pos_uuid(v_e->>'order_item_id');
    if v_item_id is null or coalesce(v_e->>'quantity', '') !~ '^[1-9][0-9]{0,5}$' then
      return jsonb_build_object('ok', false, 'reason', 'invalid_items');
    end if;
    v_qty := (v_e->>'quantity')::int;
    select oi.* into v_item
      from public.order_items oi
     where oi.id = v_item_id and oi.order_id = p_order_id and coalesce(oi.status, 'active') = 'active'
     for update;
    if not found then
      return jsonb_build_object('ok', false, 'reason', 'item_not_found');
    end if;
    if v_qty > v_item.quantity then
      return jsonb_build_object('ok', false, 'reason', 'quantity_too_big');
    end if;
    v_moved := v_moved + v_qty;
  end loop;

  select coalesce(sum(oi.quantity), 0) into v_total_qty
    from public.order_items oi
   where oi.order_id = p_order_id and coalesce(oi.status, 'active') = 'active';
  if v_total_qty - v_moved < 1 then
    return jsonb_build_object('ok', false, 'reason', 'nothing_left');
  end if;

  insert into public.orders (company_id, brand_id, branch_id, area_id, table_id, waiter_id, customer_id,
                             order_type, guest_count, status, kitchen_status, vat_enabled, service_enabled, notes)
  values (v_order.company_id, v_order.brand_id, v_order.branch_id, v_order.area_id, v_order.table_id,
          v_order.waiter_id, v_order.customer_id, v_order.order_type, 1, v_order.status, v_order.kitchen_status,
          v_order.vat_enabled, v_order.service_enabled, 'تقسيم من ' || coalesce(v_order.order_number, ''))
  returning id, order_number into v_new_id, v_new_number;

  -- Second pass: move
  for v_e in select e.value from jsonb_array_elements(p_items) as e(value)
  loop
    v_item_id := (v_e->>'order_item_id')::uuid;
    v_qty := (v_e->>'quantity')::int;
    select oi.* into v_item from public.order_items oi where oi.id = v_item_id;
    if v_qty = v_item.quantity then
      update public.order_items set order_id = v_new_id where id = v_item_id;
    else
      update public.order_items
         set quantity = v_item.quantity - v_qty,
             total_price = round(v_item.unit_price * (v_item.quantity - v_qty), 2)
       where id = v_item_id;
      insert into public.order_items (order_id, product_id, quantity, unit_price, total_price, item_notes)
      values (v_new_id, v_item.product_id, v_qty, v_item.unit_price, round(v_item.unit_price * v_qty, 2), v_item.item_notes)
      returning id into v_new_item;
      insert into public.order_item_modifiers (order_item_id, modifier_id, modifier_name, unit_price)
      select v_new_item, m.modifier_id, m.modifier_name, m.unit_price
        from public.order_item_modifiers m
       where m.order_item_id = v_item_id;
    end if;
  end loop;

  insert into public.order_logs (order_id, user_id, action, details)
  values (p_order_id, v_staff, 'SPLIT_ORDER', jsonb_build_object('new_order', v_new_number, 'items', p_items)),
         (v_new_id, v_staff, 'SPLIT_FROM', jsonb_build_object('source_order', v_order.order_number));

  return jsonb_build_object('ok', true, 'new_order_id', v_new_id, 'new_order_number', v_new_number);
end;
$$;

-- 11) Kitchen screen -------------------------------------------------------------------------
create or replace function public.kds_list_orders_secure(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_branch uuid;
begin
  select rs.branch_id into v_branch from public.require_session(p_token) rs;

  return jsonb_build_object('ok', true, 'orders', coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', o.id, 'order_number', o.order_number, 'order_type', o.order_type,
             'kitchen_status', o.kitchen_status, 'status', o.status, 'created_at', o.created_at,
             'table_number', t.table_number,
             'items', coalesce((
               select jsonb_agg(jsonb_build_object(
                        'name', coalesce(p.name, 'صنف'), 'quantity', oi.quantity, 'item_notes', oi.item_notes,
                        'modifiers', coalesce((select jsonb_agg(m.modifier_name)
                                                 from public.order_item_modifiers m
                                                where m.order_item_id = oi.id), '[]'::jsonb)))
                 from public.order_items oi
                 left join public.products p on p.id = oi.product_id
                where oi.order_id = o.id and coalesce(oi.status, 'active') = 'active'), '[]'::jsonb)
           ) order by o.created_at)
      from public.orders o
      left join public.tables t on t.id = o.table_id
     where o.branch_id = v_branch
       and coalesce(o.status, '') <> 'cancelled'
       and coalesce(o.kitchen_status, 'pending') not in ('ready', 'served')
       and o.created_at > now() - interval '24 hours'
       and exists (select 1 from public.order_items x
                    where x.order_id = o.id and coalesce(x.status, 'active') = 'active')), '[]'::jsonb));
end;
$$;

create or replace function public.kds_set_status_secure(p_token text, p_order_id uuid, p_status text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_staff uuid;
  v_branch uuid;
  v_old text;
begin
  select rs.staff_id, rs.branch_id into v_staff, v_branch from public.require_session(p_token) rs;

  if p_status is null or p_status not in ('preparing', 'ready') then
    return jsonb_build_object('ok', false, 'reason', 'invalid_status');
  end if;

  select o.kitchen_status into v_old
    from public.orders o
   where o.id = p_order_id and o.branch_id = v_branch and coalesce(o.status, '') <> 'cancelled'
   for update;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'order_not_found');
  end if;

  update public.orders set kitchen_status = p_status where id = p_order_id;

  insert into public.order_logs (order_id, user_id, action, details)
  values (p_order_id, v_staff, 'KITCHEN_STATUS', jsonb_build_object('from', v_old, 'to', p_status));

  return jsonb_build_object('ok', true);
end;
$$;

-- 12) Settings (manager / owner only) --------------------------------------------------------
create table if not exists public.settings_logs (
  id bigserial primary key,
  created_at timestamptz not null default now(),
  staff_id uuid,
  action text not null,
  details jsonb
);
alter table public.settings_logs enable row level security;

create or replace function public.settings_action_secure(p_token text, p_action text, p_data jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_staff uuid;
  v_branch uuid;
  v_role text;
  v_brand uuid;
  v_data jsonb := coalesce(p_data, '{}'::jsonb);
  v_id uuid;
  v_id2 uuid;
  v_text text;
  v_text2 text;
  v_num numeric;
  v_num2 numeric;
  v_old jsonb;
begin
  select rs.staff_id, rs.branch_id, rs.role_name into v_staff, v_branch, v_role from public.require_session(p_token) rs;

  if v_role not in ('owner', 'branch_manager') then
    return jsonb_build_object('ok', false, 'reason', 'not_allowed');
  end if;
  select b.brand_id into v_brand from public.branches b where b.id = v_branch;
  if v_brand is null then
    return jsonb_build_object('ok', false, 'reason', 'branch_brand_not_configured');
  end if;

  case coalesce(p_action, '')
  when 'add_category' then
    v_text := nullif(btrim(v_data->>'name'), '');
    if v_text is null or length(v_text) > 100 then
      return jsonb_build_object('ok', false, 'reason', 'invalid_name');
    end if;
    insert into public.categories (brand_id, name) values (v_brand, v_text) returning id into v_id;

  when 'add_product' then
    v_text := nullif(btrim(v_data->>'name'), '');
    v_num := public.pos_amount(v_data->>'price');
    v_id2 := public.pos_uuid(v_data->>'category_id');
    if v_text is null or length(v_text) > 150 then
      return jsonb_build_object('ok', false, 'reason', 'invalid_name');
    end if;
    if v_num is null or v_num > 999999 then
      return jsonb_build_object('ok', false, 'reason', 'invalid_price');
    end if;
    if v_id2 is null or not exists (select 1 from public.categories c where c.id = v_id2 and c.brand_id = v_brand) then
      return jsonb_build_object('ok', false, 'reason', 'invalid_category');
    end if;
    insert into public.products (brand_id, category_id, name, price, is_available)
    values (v_brand, v_id2, v_text, round(v_num, 2), true) returning id into v_id;

  when 'set_product_price' then
    v_id := public.pos_uuid(v_data->>'product_id');
    v_num := public.pos_amount(v_data->>'price');
    if v_num is null or v_num > 999999 then
      return jsonb_build_object('ok', false, 'reason', 'invalid_price');
    end if;
    select jsonb_build_object('old_price', p.price, 'name', p.name) into v_old
      from public.products p where p.id = v_id and p.brand_id = v_brand;
    if v_old is null then
      return jsonb_build_object('ok', false, 'reason', 'product_not_found');
    end if;
    update public.products set price = round(v_num, 2) where id = v_id;

  when 'toggle_product' then
    v_id := public.pos_uuid(v_data->>'product_id');
    v_text := v_data->>'is_available';
    if v_text is null or v_text not in ('true', 'false') then
      return jsonb_build_object('ok', false, 'reason', 'invalid_value');
    end if;
    select jsonb_build_object('old_available', p.is_available, 'name', p.name) into v_old
      from public.products p where p.id = v_id and p.brand_id = v_brand;
    if v_old is null then
      return jsonb_build_object('ok', false, 'reason', 'product_not_found');
    end if;
    update public.products set is_available = (v_text = 'true') where id = v_id;

  when 'add_branch' then
    v_text := nullif(btrim(v_data->>'name'), '');
    v_text2 := left(coalesce(btrim(v_data->>'address'), ''), 300);
    if v_text is null or length(v_text) > 100 then
      return jsonb_build_object('ok', false, 'reason', 'invalid_name');
    end if;
    insert into public.branches (brand_id, name, address, has_tables)
    values (v_brand, v_text, v_text2, coalesce(v_data->>'has_tables', 'true') = 'true')
    returning id into v_id;
    insert into public.branch_tax_settings (branch_id) values (v_id) on conflict (branch_id) do nothing;

  when 'add_warehouse' then
    v_text := nullif(btrim(v_data->>'name'), '');
    v_id2 := public.pos_uuid(v_data->>'branch_id');
    if v_text is null or length(v_text) > 100 then
      return jsonb_build_object('ok', false, 'reason', 'invalid_name');
    end if;
    if v_id2 is not null and not exists (select 1 from public.branches b where b.id = v_id2 and b.brand_id = v_brand) then
      return jsonb_build_object('ok', false, 'reason', 'invalid_branch');
    end if;
    insert into public.warehouses (branch_id, name, is_main)
    values (v_id2, v_text, v_id2 is null) returning id into v_id;

  when 'save_tax' then
    v_id := public.pos_uuid(v_data->>'branch_id');
    v_num := public.pos_amount(v_data->>'vat_percentage');
    v_num2 := public.pos_amount(v_data->>'service_charge_percentage');
    if v_id is null or not exists (select 1 from public.branches b where b.id = v_id and b.brand_id = v_brand) then
      return jsonb_build_object('ok', false, 'reason', 'invalid_branch');
    end if;
    if v_num is null or v_num > 100 or v_num2 is null or v_num2 > 100 then
      return jsonb_build_object('ok', false, 'reason', 'invalid_percentage');
    end if;
    select jsonb_build_object('old_vat', t.vat_percentage, 'old_service', t.service_charge_percentage) into v_old
      from public.branch_tax_settings t where t.branch_id = v_id;
    update public.branch_tax_settings
       set vat_percentage = v_num, service_charge_percentage = v_num2
     where branch_id = v_id;
    if not found then
      insert into public.branch_tax_settings (branch_id, vat_percentage, service_charge_percentage)
      values (v_id, v_num, v_num2);
    end if;

  when 'set_table_capacity' then
    v_id := public.pos_uuid(v_data->>'table_id');
    if coalesce(v_data->>'capacity', '') !~ '^[1-9][0-9]{0,2}$' then
      return jsonb_build_object('ok', false, 'reason', 'invalid_capacity');
    end if;
    if v_id is null or not exists (
      select 1 from public.tables t join public.areas a on a.id = t.area_id join public.branches b on b.id = a.branch_id
       where t.id = v_id and b.brand_id = v_brand) then
      return jsonb_build_object('ok', false, 'reason', 'table_not_found');
    end if;
    update public.tables set capacity = (v_data->>'capacity')::int where id = v_id;

  when 'add_table' then
    v_id2 := public.pos_uuid(v_data->>'area_id');
    v_text := nullif(btrim(v_data->>'table_number'), '');
    if v_text is null or length(v_text) > 20 then
      return jsonb_build_object('ok', false, 'reason', 'invalid_table_number');
    end if;
    if coalesce(v_data->>'capacity', '') !~ '^[1-9][0-9]{0,2}$' then
      return jsonb_build_object('ok', false, 'reason', 'invalid_capacity');
    end if;
    if v_id2 is null or not exists (
      select 1 from public.areas a join public.branches b on b.id = a.branch_id
       where a.id = v_id2 and b.brand_id = v_brand) then
      return jsonb_build_object('ok', false, 'reason', 'area_not_found');
    end if;
    insert into public.tables (area_id, table_number, capacity)
    values (v_id2, v_text, (v_data->>'capacity')::int) returning id into v_id;

  when 'delete_table' then
    v_id := public.pos_uuid(v_data->>'table_id');
    if v_id is null or not exists (
      select 1 from public.tables t join public.areas a on a.id = t.area_id join public.branches b on b.id = a.branch_id
       where t.id = v_id and b.brand_id = v_brand) then
      return jsonb_build_object('ok', false, 'reason', 'table_not_found');
    end if;
    if exists (select 1 from public.orders o where o.table_id = v_id) then
      return jsonb_build_object('ok', false, 'reason', 'table_has_orders');
    end if;
    delete from public.tables where id = v_id;

  else
    return jsonb_build_object('ok', false, 'reason', 'unknown_action');
  end case;

  insert into public.settings_logs (staff_id, action, details)
  values (v_staff, p_action, jsonb_build_object('data', v_data, 'before', v_old, 'id', v_id));

  return jsonb_build_object('ok', true, 'id', v_id);
end;
$$;

-- 13) Financial summary for the reports screen (manager / owner, own company) ----------------
create or replace function public.get_financial_summary_secure(p_token text)
returns table (total_sales numeric, total_cogs numeric, total_waste_loss numeric, net_profit numeric)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_company uuid;
  v_role text;
  v_sales numeric := 0;
  v_cogs numeric := 0;
  v_waste numeric := 0;
begin
  select rs.company_id, rs.role_name into v_company, v_role from public.require_session(p_token) rs;
  if v_role not in ('owner', 'branch_manager') then
    raise exception 'not_allowed';
  end if;

  select coalesce(sum(o.total_amount - o.tax_amount), 0) into v_sales
    from public.orders o
   where o.company_id = v_company and o.status in ('closed', 'paid');

  select coalesce(sum(sm.total_cost), 0) into v_cogs
    from public.stock_movements sm
   where sm.company_id = v_company and sm.movement_type = 'sale';

  select coalesce(sum(w.cost_loss), 0) into v_waste from public.waste_logs w;

  return query select v_sales, v_cogs, v_waste, v_sales - v_cogs - v_waste;
end;
$$;

-- 14) Locks ------------------------------------------------------------------------------------
do $locks$
declare
  t text;
begin
  -- Fully closed to the public key: only the server functions above touch these.
  foreach t in array array['orders', 'order_items', 'order_item_modifiers', 'payments', 'customers',
                           'customer_ledger', 'order_logs', 'order_sequences', 'roles', 'brands'] loop
    execute format('alter table public.%I enable row level security', t);
  end loop;
  -- Read-only for the public key (menu and setup). Changes go through settings_action_secure.
  foreach t in array array['tables', 'products', 'categories', 'areas', 'branches', 'branch_tax_settings',
                           'warehouses', 'discounts', 'cancel_reasons', 'modifier_groups', 'modifiers',
                           'product_modifier_groups'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists pos_read_only on public.%I', t);
    execute format('create policy pos_read_only on public.%I for select to anon, authenticated using (true)', t);
  end loop;
end;
$locks$;

-- Old functions that no screen uses any more (or that bypass the server rules)
revoke all on function public.update_order_financials(uuid, numeric, numeric, numeric, numeric, numeric) from public, anon, authenticated;
revoke all on function public.transfer_table_order(uuid, uuid, uuid) from public, anon, authenticated;
revoke all on function public.merge_orders(uuid, uuid, uuid) from public, anon, authenticated;
revoke all on function public.post_order_to_gl(uuid) from public, anon, authenticated;
revoke all on function public.deduct_recipe_on_sale(uuid, uuid, integer) from public, anon, authenticated;
revoke all on function public.receive_customer_payment(uuid, uuid, uuid, numeric, text, text, text, uuid) from public, anon, authenticated;
revoke all on function public.get_customer_statement(uuid, date, date) from public, anon, authenticated;
revoke all on function public.get_financial_summary() from public, anon, authenticated;
revoke all on function public.adjust_stock(uuid, uuid, numeric, text, uuid, text, uuid) from public, anon, authenticated;
revoke all on function public.execute_stock_transfer(uuid, uuid, uuid, numeric) from public, anon, authenticated;
revoke all on function public.pay_supplier(uuid, numeric, text, uuid, text, text, uuid) from public, anon, authenticated;
revoke all on function public.receive_goods_receipt(uuid, uuid, text, jsonb, uuid) from public, anon, authenticated;
revoke all on function public.reverse_journal_entry(uuid, uuid, text, uuid) from public, anon, authenticated;
revoke all on function public.close_fiscal_period(uuid, uuid, uuid) from public, anon, authenticated;
revoke all on function public.get_theoretical_vs_actual_consumption(uuid, timestamp with time zone, timestamp with time zone) from public, anon, authenticated;

-- Internal helpers: not callable with the public key
revoke all on function public.pos_uuid(text) from public, anon, authenticated;
revoke all on function public.pos_amount(text) from public, anon, authenticated;
revoke all on function public.pos_gl_account(uuid, text) from public, anon, authenticated;
revoke all on function public.pos_payment_account(uuid, text) from public, anon, authenticated;
revoke all on function public.pos_branch_warehouse(uuid) from public, anon, authenticated;
revoke all on function public.pos_item_consumption(uuid, numeric) from public, anon, authenticated;
revoke all on function public.pos_free_table_if_empty(uuid) from public, anon, authenticated;
revoke all on function public.pos_void_item_internal(uuid, uuid, uuid, uuid, text) from public, anon, authenticated;
revoke all on function public.trg_orders_lock_type() from public, anon, authenticated;

-- Screen functions: need a valid shift ticket inside
do $grants$
declare
  f text;
begin
  foreach f in array array[
    'public.get_order_secure(text, uuid)',
    'public.list_open_orders_secure(text, uuid)',
    'public.list_customers_secure(text)',
    'public.update_order_info_secure(text, uuid, uuid, uuid, integer)',
    'public.apply_order_discount_secure(text, uuid, uuid, numeric, text)',
    'public.void_order_item_secure(text, uuid, uuid, text)',
    'public.cancel_order_secure(text, uuid, uuid, text)',
    'public.close_order_secure(text, uuid, jsonb, numeric, uuid)',
    'public.refund_order_secure(text, text, uuid, text)',
    'public.transfer_table_order_secure(text, uuid, uuid)',
    'public.merge_orders_secure(text, uuid, uuid)',
    'public.split_order_items_secure(text, uuid, jsonb)',
    'public.kds_list_orders_secure(text)',
    'public.kds_set_status_secure(text, uuid, text)',
    'public.settings_action_secure(text, text, jsonb)',
    'public.get_financial_summary_secure(text)'
  ] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to anon, authenticated, service_role', f);
  end loop;
end;
$grants$;

-- 15) Recalculate open orders with the server rules ---------------------------------------------
do $recalc$
declare
  r record;
begin
  for r in select o.id from public.orders o where coalesce(o.status, '') not in ('paid', 'closed', 'cancelled') loop
    perform public.recalc_order_totals(r.id);
  end loop;
end;
$recalc$;

-- 16) Self-test: run a real sale, check it, then undo it -------------------------------------------
do $selftest$
declare
  v_staff uuid;
  v_branch uuid;
  v_token text := 'motionpos-selftest-' || md5(random()::text || clock_timestamp()::text);
  v_product uuid;
  v_res jsonb;
  v_order uuid;
  v_order2 uuid;
  v_item uuid;
  v_total numeric;
  v_je int;
  v_moves int;
  v_has_recipe boolean;
begin
  begin
    select s.id, s.branch_id into v_staff, v_branch
      from public.staff s
      join public.roles r on r.id = s.role_id
     where s.is_active is true and s.branch_id is not null and r.name = 'cashier'
     limit 1;
    if v_staff is null then
      select s.id, s.branch_id into v_staff, v_branch
        from public.staff s where s.is_active is true and s.branch_id is not null limit 1;
    end if;
    if v_staff is null then
      raise notice 'selftest skipped: no active staff';
      raise exception using errcode = 'P0099', message = 'selftest_skip';
    end if;

    insert into public.staff_sessions (token_hash, staff_id, expires_at)
    values (encode(extensions.digest(v_token, 'sha256'), 'hex'), v_staff, now() + interval '10 minutes');

    select p.id into v_product
      from public.products p
      join public.branches b on b.brand_id = p.brand_id
     where b.id = v_branch
       and p.is_available is true
       and p.price > 1
       and not exists (
         select 1 from public.product_modifier_groups g
           join public.modifier_groups mg on mg.id = g.group_id
          where g.product_id = p.id
            and (coalesce(mg.min_selection, 0) > 0 or coalesce(mg.is_required, false)))
     order by (select count(*) from public.recipes r where r.product_id = p.id) desc, p.id
     limit 1;
    if v_product is null then
      raise notice 'selftest skipped: no product';
      raise exception using errcode = 'P0099', message = 'selftest_skip';
    end if;

    -- a) send 2 units to the kitchen (takeaway)
    v_res := public.submit_order_items_secure(v_token, null::uuid, 'takeaway', null::uuid, null::uuid, null::uuid,
               null::uuid, 1, jsonb_build_array(jsonb_build_object('product_id', v_product, 'quantity', 2,
               'modifier_ids', '[]'::jsonb)));
    if not coalesce((v_res->>'ok')::boolean, false) then
      raise exception 'SELFTEST submit failed: %', v_res;
    end if;
    v_order := (v_res->>'order_id')::uuid;
    v_item := (v_res->'items'->0->>'order_item_id')::uuid;

    -- b) totals were calculated on the server
    select o.total_amount into v_total from public.orders o where o.id = v_order;
    if v_total is null or v_total <= 0
       or v_total <> (public.compute_order_totals(v_order)->>'total_amount')::numeric then
      raise exception 'SELFTEST totals not calculated: %', v_total;
    end if;

    -- c) split 1 unit into a new order, then merge it back: same total
    v_res := public.split_order_items_secure(v_token, v_order,
               jsonb_build_array(jsonb_build_object('order_item_id', v_item, 'quantity', 1)));
    if not coalesce((v_res->>'ok')::boolean, false) then
      raise exception 'SELFTEST split failed: %', v_res;
    end if;
    v_order2 := (v_res->>'new_order_id')::uuid;
    v_res := public.merge_orders_secure(v_token, v_order2, v_order);
    if not coalesce((v_res->>'ok')::boolean, false) then
      raise exception 'SELFTEST merge failed: %', v_res;
    end if;
    if (select o.total_amount from public.orders o where o.id = v_order) <> v_total then
      raise exception 'SELFTEST merge changed the total';
    end if;

    -- d) wrong payment amount is refused
    v_res := public.close_order_secure(v_token, v_order,
               jsonb_build_array(jsonb_build_object('method', 'cash', 'amount', v_total - 1)), 0, null::uuid);
    if coalesce(v_res->>'reason', '') <> 'payment_mismatch' then
      raise exception 'SELFTEST wrong payment was not refused: %', v_res;
    end if;

    -- e) pay exactly + tip 5: closes, records everything
    v_res := public.close_order_secure(v_token, v_order,
               jsonb_build_array(jsonb_build_object('method', 'cash', 'amount', v_total)), 5, v_staff);
    if not coalesce((v_res->>'ok')::boolean, false) then
      raise exception 'SELFTEST close failed: %', v_res;
    end if;
    if (select o.status from public.orders o where o.id = v_order) <> 'closed' then
      raise exception 'SELFTEST order not closed';
    end if;
    if (select coalesce(sum(p.amount), 0) from public.payments p where p.order_id = v_order) <> v_total then
      raise exception 'SELFTEST payments do not match';
    end if;
    select count(*) into v_je
      from public.journal_entries je
     where je.reference_type = 'order' and je.reference_id = v_order and je.status = 'posted';
    if v_je < 1 then
      raise exception 'SELFTEST no journal entry';
    end if;
    if exists (
      select 1 from public.journal_entries je
        join public.journal_entry_lines l on l.journal_entry_id = je.id
       where je.reference_id = v_order
       group by je.id
      having abs(sum(l.debit) - sum(l.credit)) > 0.001) then
      raise exception 'SELFTEST journal entry not balanced';
    end if;
    select exists (select 1 from public.recipes r where r.product_id = v_product) into v_has_recipe;
    select count(*) into v_moves
      from public.stock_movements sm where sm.reference_id = v_order and sm.movement_type = 'sale';
    if v_has_recipe and v_moves = 0 then
      raise exception 'SELFTEST stock was not deducted';
    end if;

    -- f) a closed order cannot be paid twice
    v_res := public.close_order_secure(v_token, v_order,
               jsonb_build_array(jsonb_build_object('method', 'cash', 'amount', v_total)), 0, null::uuid);
    if coalesce(v_res->>'reason', '') <> 'order_not_open' then
      raise exception 'SELFTEST second close not refused: %', v_res;
    end if;

    -- g) a fake ticket is refused
    begin
      perform public.get_order_secure('fake-ticket', v_order);
      raise exception 'SELFTEST fake ticket accepted';
    exception when sqlstate '28000' then
      null;
    end;

    raise notice 'MOTIONPOS-SELFTEST-OK total=% entries=% stock_moves=%', v_total, v_je, v_moves;
    raise exception using errcode = 'P0099', message = 'selftest_rollback';
  exception when sqlstate 'P0099' then
    null;  -- everything done inside the test is undone here
  end;
end;
$selftest$;

commit;
