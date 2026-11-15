-- One-time data fix (2026-11-15), Makany: the item "كرتونه مياه" was set up the wrong way round
-- (base unit carton, pack "bottle = 20 cartons"). What was received (PO-2026-00001) was 20 bottles at 5.75 = 115,
-- i.e. ONE carton, so the stored numbers (20 at 5.75) are right once the base unit is the bottle:
--   * the item: unit = bottle, pack = carton of 20 bottles (stock 20 bottles, cost 5.75 a bottle, nothing recalculated);
--   * PO-2026-00009 (not approved yet): 400 "cartons" x 0.30 -> 20 bottles x 6 = 120 (what was typed: 20 bottles at 6).
-- Stops and changes nothing if the item is not as checked on 2026-11-15 (no recipe / extra, only the one receipt).
-- All or nothing. Run: sudo bash /opt/motionpos/repo/supabase/ops/fix_water_carton.sh
\set ON_ERROR_STOP 1
\pset footer off
begin;

do $fix$
declare
  v_ing uuid;
  v_po uuid;
  n int;
begin
  select id into v_ing from ingredients
   where name = U&'\0643\0631\062A\0648\0646\0647 \0645\064A\0627\0647'           -- كرتونه مياه
     and unit = U&'\0643\0631\062A\0648\0646\0629'                                  -- كرتونة
     and pack_unit = U&'\0632\062C\0627\062C\0629' and pack_size = 20;              -- زجاجة / 20
  if v_ing is null then
    raise exception 'STOP: the item is not as checked (already fixed?), nothing changed';
  end if;
  if exists (select 1 from recipes where ingredient_id = v_ing) or exists (select 1 from modifiers where ingredient_id = v_ing)
     or (select count(*) from stock_movements where ingredient_id = v_ing) <> 1 then
    raise exception 'STOP: the item has recipes or more stock moves than checked, nothing changed';
  end if;

  update ingredients
     set unit = U&'\0632\062C\0627\062C\0629',          -- زجاجة
         pack_unit = U&'\0643\0631\062A\0648\0646\0629', -- كرتونة
         pack_size = 20
   where id = v_ing;
  raise notice 'item fixed: unit bottle, carton = 20 bottles (stock and cost unchanged)';

  select p.id into v_po from purchase_orders p where p.po_number = 'PO-2026-00009' and p.status = 'draft';
  if v_po is null then
    raise notice 'PO-2026-00009 is not a draft any more: left as it is, check it by hand';
  else
    update purchase_order_items set quantity = 20, unit_price = 6, total_price = 120
     where purchase_order_id = v_po and ingredient_id = v_ing and quantity = 400 and qty_received = 0;
    get diagnostics n = row_count;
    update purchase_orders set total_amount = (select coalesce(sum(total_price), 0) from purchase_order_items where purchase_order_id = v_po)
     where id = v_po;
    raise notice 'PO-2026-00009 lines fixed: %', n;
  end if;
end;
$fix$;

\echo '== the item now'
select name, unit, pack_unit, pack_size, cost_per_unit,
       (select sum(quantity) from warehouse_stock ws where ws.ingredient_id = i.id) as stock
  from ingredients i where name like U&'%\0645\064A\0627\0647%' order by name;
\echo '== PO-2026-00009 now'
select p.po_number, p.status, p.total_amount, x.quantity, x.unit_price, x.total_price
  from purchase_orders p join purchase_order_items x on x.purchase_order_id = p.id where p.po_number = 'PO-2026-00009';
commit;
