-- One-time data fix (2026-11-03): the test supplier FHVJNMBJMBM -> its purchase orders move to the cash supplier,
-- its test prices are removed, then it is deleted. Stops and changes nothing if it has invoices / payments / balance.
-- Run: sudo bash /opt/motionpos/repo/supabase/ops/fix_test_supplier.sh
\set ON_ERROR_STOP 1
\pset footer off
begin;
\echo '== the purchase order that moves (with its lines)'
select p.po_number, p.status, p.total_amount, i.name item, x.quantity, x.unit_price
  from purchase_orders p join suppliers s on s.id = p.supplier_id
  left join purchase_order_items x on x.purchase_order_id = p.id left join ingredients i on i.id = x.ingredient_id
 where s.name = 'FHVJNMBJMBM';
\echo '== the 9 saved test prices that are removed'
select i.name item, r.unit_price from supplier_prices r join suppliers s on s.id = r.supplier_id join ingredients i on i.id = r.ingredient_id
 where s.name = 'FHVJNMBJMBM' order by 1;
do $fix$
declare
  v_test uuid;
  v_cash uuid;
  n int;
begin
  select id into v_test from suppliers where name = 'FHVJNMBJMBM';
  select id into v_cash from suppliers where name = U&'\0645\0648\0631\062F \0646\0642\062F\064A';
  if (select count(*) from suppliers where name = 'FHVJNMBJMBM') <> 1 or v_cash is null then
    raise exception 'STOP: test supplier or cash supplier not found (nothing changed)';
  end if;
  -- money on the test supplier = stop, nothing changes
  if exists (select 1 from supplier_invoices where supplier_id = v_test) or exists (select 1 from supplier_payments where supplier_id = v_test)
     or exists (select 1 from supplier_ledger where supplier_id = v_test) or coalesce((select current_balance from suppliers where id = v_test), 0) <> 0 then
    raise exception 'STOP: the test supplier has invoices / payments / balance (nothing changed)';
  end if;
  update purchase_orders set supplier_id = v_cash where supplier_id = v_test;
  get diagnostics n = row_count;
  raise notice 'purchase orders moved to the cash supplier: %', n;
  delete from supplier_prices where supplier_id = v_test;
  get diagnostics n = row_count;
  raise notice 'test prices removed: %', n;
  delete from suppliers where id = v_test;
  raise notice 'test supplier deleted';
end;
$fix$;
\echo '== suppliers now'
select s.name, s.current_balance balance, (select count(*) from purchase_orders p where p.supplier_id = s.id) orders from suppliers s order by s.created_at;
commit;
