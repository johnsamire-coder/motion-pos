-- Read-only report: items whose stock is below zero, per store: what came in, what went out, what is still waiting
-- on a purchase order. Changes nothing (read only, rolled back).
-- Run: sudo bash /opt/motionpos/repo/tools/motionpos_server.sh update && sudo cat /opt/motionpos/repo/supabase/ops/negative_stock_report.sql | sudo -u postgres psql -X -q -P pager=off -p 5433 -d motionpos
\pset footer off
begin read only;
\echo '== items below zero (per store), what came in, what went out, and what is still waiting on a purchase order'
select i.name as item, i.unit, w.name as store, round(ws.quantity, 2) as stock_now,
       round(coalesce((select sum(sm.quantity) from stock_movements sm where sm.ingredient_id = i.id and sm.warehouse_id = ws.warehouse_id and sm.quantity > 0), 0), 2) as came_in,
       round(coalesce((select -sum(sm.quantity) from stock_movements sm where sm.ingredient_id = i.id and sm.warehouse_id = ws.warehouse_id and sm.quantity < 0), 0), 2) as went_out,
       round(coalesce((select sum(x.quantity - x.qty_received) from purchase_order_items x join purchase_orders p on p.id = x.purchase_order_id
                        where x.ingredient_id = i.id and p.warehouse_id = ws.warehouse_id and p.status in ('draft', 'approved', 'partially_received')), 0), 2) as waiting_on_po,
       (select string_agg(p.po_number || ' (' || p.status || ')', ', ' order by p.created_at) from purchase_order_items x join purchase_orders p on p.id = x.purchase_order_id
         where x.ingredient_id = i.id and p.warehouse_id = ws.warehouse_id and p.status in ('draft', 'approved', 'partially_received')) as orders
  from warehouse_stock ws join ingredients i on i.id = ws.ingredient_id left join warehouses w on w.id = ws.warehouse_id
 where ws.quantity < 0
 order by ws.quantity;
\echo '== count'
select count(*) as items_below_zero from warehouse_stock where quantity < 0;
rollback;
