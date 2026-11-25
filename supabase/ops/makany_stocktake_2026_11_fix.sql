-- Correction (2026-11-25) after the Makany paper stocktake was applied (makany_stocktake_2026_11, run before the client's
-- last answers):
--   * espresso was counted 972 g, not 9972 g: 9 kilo out (stock now - 9, what was sold since then stays counted);
--   * ice is not stocked (it comes from the machine): stock to zero, and out of every recipe / extra.
-- Same way as the stocktake screen: inv_counts + stock_takes + 'adjustment' moves + journal 5300/1200.
-- Stops and changes nothing if the first stocktake is not there, its espresso line is not 9.972, or this ran already.
-- All or nothing. Run: sudo bash /opt/motionpos/repo/supabase/ops/makany_stocktake_2026_11_fix.sh
\set ON_ERROR_STOP 1
\pset footer off
\pset pager off
begin;

\echo '== before'
select x.name as item, x.unit, round(ws.quantity, 3) as stock
  from warehouse_stock ws join ingredients x on x.id = ws.ingredient_id join warehouses w on w.id = ws.warehouse_id
 where w.name like '%المهندسين%' and btrim(x.name) in ('بن اسبريسو', 'تلج') order by 1;

do $fix$
declare
  v_co uuid;
  v_wh uuid;
  v_br uuid;
  v_first uuid;
  v_count uuid;
  v_esp uuid;
  v_ice uuid;
  v_now numeric;
  v_unit numeric;
  v_var numeric;
  v_cost numeric;
  v_short numeric := 0;
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
  select id into v_first from inv_counts where notes like 'جرد الورق 2026-11%' order by created_at limit 1;
  if v_first is null then
    raise exception 'STOP: the paper stocktake is not there, nothing changed';
  end if;
  if exists (select 1 from inv_counts where notes like 'تصحيح جرد الورق 2026-11%') then
    raise exception 'STOP: this correction was already applied, nothing changed';
  end if;
  select x.id into v_esp from ingredients x where btrim(x.name) = 'بن اسبريسو';
  if v_esp is null or not exists (select 1 from stock_takes t where t.count_id = v_first and t.ingredient_id = v_esp and t.actual_qty = 9.972) then
    raise exception 'STOP: the espresso line of the stocktake is not 9.972, nothing changed';
  end if;
  if (select count(*) from ingredients x where btrim(x.name) = 'تلج') <> 1 then
    raise exception 'STOP: not exactly one item named تلج, nothing changed';
  end if;
  select x.id into v_ice from ingredients x where btrim(x.name) = 'تلج';

  raise notice 'ice in recipes: %, in extras: %, last sale move: %',
    (select count(*) from recipes where ingredient_id = v_ice),
    (select count(*) from modifiers where ingredient_id = v_ice),
    (select max(created_at) from stock_movements where ingredient_id = v_ice and movement_type = 'sale');
  delete from recipes where ingredient_id = v_ice;
  update modifiers set ingredient_id = null, ingredient_quantity = null where ingredient_id = v_ice;

  insert into inv_counts (company_id, warehouse_id, notes)
  values (v_co, v_wh, 'تصحيح جرد الورق 2026-11: بن اسبريسو 972 جرام مش 9972، والتلج صفر (من الماكينة)')
  returning id into v_count;

  for r in select v_esp as ing, -9::numeric as delta union all select v_ice, null loop
    insert into warehouse_stock (warehouse_id, ingredient_id, quantity) values (v_wh, r.ing, 0)
    on conflict (warehouse_id, ingredient_id) do nothing;
    select quantity into v_now from warehouse_stock where warehouse_id = v_wh and ingredient_id = r.ing for update;
    v_var := coalesce(r.delta, -v_now);
    select coalesce(cost_per_unit, 0) into v_unit from ingredients where id = r.ing;
    v_cost := round(v_var * v_unit, 2);
    insert into stock_takes (warehouse_id, ingredient_id, theoretical_qty, actual_qty, variance_qty, variance_cost, count_id)
    values (v_wh, r.ing, v_now, v_now + v_var, v_var, v_cost, v_count);
    if v_var <> 0 then
      perform pos_stock_move(v_co, v_br, v_wh, r.ing, 'adjustment', v_var, v_unit, 'stocktake', v_count, 'تصحيح جرد', null);
      if v_cost < 0 then v_short := v_short - v_cost; else v_over := v_over + v_cost; end if;
    end if;
  end loop;

  perform pos_post_je(v_co, v_br, 'inventory', 'stocktake', v_count, 'تصحيح جرد',
    jsonb_build_array(pos_je_line('5300', v_short, 0, 'عجز جرد'), pos_je_line('1200', 0, v_short, 'عجز جرد')), null);
  perform pos_post_je(v_co, v_br, 'inventory', 'stocktake', v_count, 'تصحيح جرد',
    jsonb_build_array(pos_je_line('1200', v_over, 0, 'زيادة جرد'), pos_je_line('5300', 0, v_over, 'زيادة جرد')), null);
  update inv_counts set total_variance_cost = v_over - v_short where id = v_count;
  raise notice 'CORRECTED: shortage value %, overage value %', v_short, v_over;
end;
$fix$;

\echo '== after'
select x.name as item, x.unit, round(ws.quantity, 3) as stock
  from warehouse_stock ws join ingredients x on x.id = ws.ingredient_id join warehouses w on w.id = ws.warehouse_id
 where w.name like '%المهندسين%' and btrim(x.name) in ('بن اسبريسو', 'تلج') order by 1;
\echo '== stocktakes'
select left(notes, 70) as stocktake, created_at::timestamp(0) as at, total_variance_cost,
       (select count(*) from stock_takes t where t.count_id = c.id) as lines
  from inv_counts c where notes like '%جرد الورق 2026-11%' order by created_at;
commit;
