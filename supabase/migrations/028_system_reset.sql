-- 028_system_reset.sql
-- Start clean: deletes every sale, purchase, shift, cash move, journal entry, stock movement and stock balance, the customers,
-- the suppliers and every user except the owner(s). Keeps: products, categories, ingredients (with their prices and packs),
-- recipes, add-ons, settings, company, branches, warehouses, tables, chart of accounts, roles and permissions.
-- Used by the owner from Settings (PIN + typed sentence) and by the shop tool (-Step wipe) on the cloud and the shop PC.
-- The deletes are written to the sync log, so the other copy deletes the same rows.
-- Rules: begin/commit, preflight, rolled-back self-test, grants loop.

begin;

do $preflight$
begin
  if length('إكراميات') <> 8 then
    raise exception 'file_encoding_broken: read the file as UTF-8';
  end if;
  if public.motionpos_version_public() not in ('027', '028') then
    raise exception 'schema_preflight_failed: run 027 first';
  end if;
end;
$preflight$;

-- posted entries cannot be deleted, except by the full reset
create or replace function public.prevent_posted_journal_deletion()
returns trigger
language plpgsql
as $$
begin
  if old.status = 'posted' and coalesce(current_setting('motionpos.system_reset', true), '') <> 'on' then
    raise exception 'عملية غير مسموحة: لا يمكن حذف القيد المحاسبي المعتمد برقم (%). يرجى استخدام دالة عكس القيد (Reverse Entry) بدلاً من الحذف', old.entry_number;
  end if;
  return old;
end;
$$;

create or replace function public.pos_system_reset()
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  t text;
  n bigint;
  v_counts jsonb := '{}'::jsonb;
begin
  perform set_config('motionpos.system_reset', 'on', true);
  foreach t in array array['order_item_modifiers', 'order_split_items', 'payments', 'order_splits', 'order_station_status', 'order_logs', 'order_items', 'customer_ledger', 'customer_followups', 'customer_feedback', 'qr_orders', 'service_requests', 'tip_payouts', 'pos_cash_moves', 'expenses', 'orders', 'pos_days', 'pos_shifts', 'accounting_audit_logs', 'journal_entry_lines', 'journal_entries', 'opening_balances', 'custody_ledger', 'staff_ledger', 'staff_attendance', 'payroll_lines', 'payroll_runs', 'goods_receipt_files', 'goods_receipt_items', 'goods_receipts', 'supplier_invoices', 'supplier_payments', 'supplier_ledger', 'supplier_prices', 'purchase_order_items', 'purchase_orders', 'suppliers', 'stock_movements', 'warehouse_stock', 'inv_counts', 'inv_transfer_lines', 'inv_transfers', 'stock_adjustments', 'stock_takes', 'stock_transfers', 'waste_logs', 'variance_investigations', 'ingredient_cost_history', 'customers', 'settings_logs', 'sync_conflicts', 'order_sequences', 'login_attempts', 'manager_pin_attempts'] loop
    if to_regclass('public.' || quote_ident(t)) is not null then
      execute format('delete from public.%I x where x.ctid is not null', t);
      get diagnostics n = row_count;
      if n > 0 then
        v_counts := v_counts || jsonb_build_object(t, n);
      end if;
    end if;
  end loop;
  -- every user except the owner(s)
  delete from public.staff s
   where not exists (select 1 from public.roles r where r.id = s.role_id and r.name = 'owner');
  get diagnostics n = row_count;
  v_counts := v_counts || jsonb_build_object('staff', n);
  update public.tables set status = 'available' where status is distinct from 'available';
  update public.ingredients set stock_quantity = 0 where coalesce(stock_quantity, 0) <> 0;
  update public.fiscal_periods set status = 'open', closed_by = null, closed_at = null where status is distinct from 'open';
  perform set_config('motionpos.system_reset', 'off', true);
  return jsonb_build_object('ok', true, 'deleted', v_counts, 'at', now());
end;
$$;

-- the owner, from Settings: his PIN + the sentence typed by hand
create or replace function public.system_reset_secure(p_token text, p_pin text, p_confirm text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
begin
  select * into c from public.pos_ctx(p_token, 'settings');
  if c.role_name <> 'owner' then
    return jsonb_build_object('ok', false, 'reason', 'not_allowed');
  end if;
  if btrim(coalesce(p_confirm, '')) <> 'امسح كل حاجة' then
    return jsonb_build_object('ok', false, 'reason', 'confirm_text');
  end if;
  if public.pos_verify_owner_pin(p_pin, c.company_id) is null then
    return jsonb_build_object('ok', false, 'reason', 'manager_pin');
  end if;
  return public.pos_system_reset();
end;
$$;

create or replace function public.motionpos_version_public()
returns text
language sql
immutable
as $$
  select '028'
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
  v_res jsonb;
  v_owners int;
  v_products int;
  v_recipes int;
  v_ings int;
begin
  begin
    select count(*) into v_owners from public.staff s join public.roles r on r.id = s.role_id where r.name = 'owner';
    select count(*) into v_products from public.products;
    select count(*) into v_recipes from public.recipes;
    select count(*) into v_ings from public.ingredients;
    v_res := public.pos_system_reset();
    if not coalesce((v_res->>'ok')::boolean, false) then raise exception 'SELFTEST reset failed: %', v_res; end if;
    if exists (select 1 from public.orders) or exists (select 1 from public.journal_entries) or exists (select 1 from public.pos_shifts)
       or exists (select 1 from public.purchase_orders) or exists (select 1 from public.customers) or exists (select 1 from public.suppliers)
       or exists (select 1 from public.stock_movements) or exists (select 1 from public.warehouse_stock) then
      raise exception 'SELFTEST something was left';
    end if;
    if exists (select 1 from public.staff s join public.roles r on r.id = s.role_id where r.name <> 'owner') then
      raise exception 'SELFTEST a non-owner user was left';
    end if;
    if (select count(*) from public.staff s join public.roles r on r.id = s.role_id where r.name = 'owner') <> v_owners
       or (select count(*) from public.products) <> v_products or (select count(*) from public.recipes) <> v_recipes
       or (select count(*) from public.ingredients) <> v_ings then
      raise exception 'SELFTEST kept data was touched';
    end if;
    -- a posted entry still cannot be deleted by hand
    if current_setting('motionpos.system_reset', true) = 'on' then raise exception 'SELFTEST reset flag left on'; end if;
    raise notice 'MOTIONPOS-028-SELFTEST-OK';
    raise exception using errcode = 'P0099', message = 'selftest_rollback';
  exception when sqlstate 'P0099' then
    null;
  end;
end;
$selftest$;

notify pgrst, 'reload schema';

commit;
