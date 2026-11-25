-- Makany (2026-11-25), after the paper stocktake: every item still below zero in "مخزن فرع المهندسين" goes to zero,
-- except tobacco (معسل...) and charcoal (فحم...), which are counted tomorrow.
-- Same way as the stocktake screen (inv_counts + stock_takes + 'adjustment' moves + journal 5300/1200).
-- All or nothing, runs once. Run: sudo bash /opt/motionpos/repo/supabase/ops/makany_zero_negatives_2026_11.sh
\set ON_ERROR_STOP 1
\pset footer off
\pset pager off
begin;

create temp table mkz (ing uuid, name text, unit text, before numeric) on commit drop;

do $fix$
declare
  v_co uuid;
  v_wh uuid;
  v_br uuid;
  v_count uuid;
  v_now numeric;
  v_unit numeric;
  v_cost numeric;
  v_over numeric := 0;
  r record;
begin
  if length('إكراميات') <> 8 then
    raise exception 'STOP: file read with the wrong encoding, nothing changed';
  end if;
  if (select count(*) from companies) <> 1 then
    raise exception 'STOP: more than one company here, nothing changed';
  end if;
  select id into v_co from companies;
  if (select count(*) from warehouses w where w.name like '%المهندسين%') <> 1 then
    raise exception 'STOP: could not find exactly one store named المهندسين, nothing changed';
  end if;
  select w.id, w.branch_id into v_wh, v_br from warehouses w where w.name like '%المهندسين%';
  if exists (select 1 from inv_counts where notes like 'جرد الورق 2026-11 - تصفير السالب%') then
    raise exception 'STOP: this was already applied, nothing changed';
  end if;

  insert into mkz
  select x.id, x.name, x.unit, ws.quantity
    from warehouse_stock ws join ingredients x on x.id = ws.ingredient_id
   where ws.warehouse_id = v_wh and ws.quantity < 0
     and x.name not like '%معسل%' and x.name not like '%فحم%';

  insert into inv_counts (company_id, warehouse_id, notes)
  values (v_co, v_wh, 'جرد الورق 2026-11 - تصفير السالب (ما عدا المعسل والفحم)') returning id into v_count;
  for r in select * from mkz order by name loop
    select quantity into v_now from warehouse_stock where warehouse_id = v_wh and ingredient_id = r.ing for update;
    select coalesce(cost_per_unit, 0) into v_unit from ingredients where id = r.ing;
    v_cost := round(-v_now * v_unit, 2);
    insert into stock_takes (warehouse_id, ingredient_id, theoretical_qty, actual_qty, variance_qty, variance_cost, count_id)
    values (v_wh, r.ing, v_now, 0, -v_now, v_cost, v_count);
    perform pos_stock_move(v_co, v_br, v_wh, r.ing, 'adjustment', -v_now, v_unit, 'stocktake', v_count, 'تصفير رصيد سالب', null);
    v_over := v_over + v_cost;
  end loop;
  perform pos_post_je(v_co, v_br, 'inventory', 'stocktake', v_count, 'تسوية جرد (تصفير السالب)',
    jsonb_build_array(pos_je_line('1200', v_over, 0, 'زيادة جرد'), pos_je_line('5300', 0, v_over, 'زيادة جرد')), null);
  update inv_counts set total_variance_cost = v_over where id = v_count;
  raise notice 'DONE: % items to zero, value %', (select count(*) from mkz), v_over;
end;
$fix$;

\echo '== set to zero'
select z.name as item, z.unit, round(z.before, 3) as was, round(ws.quantity, 3) as now
  from mkz z join warehouse_stock ws on ws.ingredient_id = z.ing
 where ws.warehouse_id = (select id from warehouses where name like '%المهندسين%') order by z.before;
\echo '== still below zero (counted tomorrow)'
select x.name as item, x.unit, round(ws.quantity, 3) as stock
  from warehouse_stock ws join ingredients x on x.id = ws.ingredient_id
 where ws.warehouse_id = (select id from warehouses where name like '%المهندسين%') and ws.quantity < 0 order by 1;
commit;
