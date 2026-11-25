-- Makany (2026-11-25): the 3 items counted in another unit that menu recipes take in the system's unit
-- (so their unit stays, the count is turned into it):
--   بسكويت أوريو: 800 g counted, recipes take 2 pieces -> 70 pieces (an Oreo biscuit is about 11.3 g);
--   كابونشي (lettuce): 1 head counted, recipe takes 0.2 kg -> 0.5 kg (a head is about half a kilo);
--   نعناع فريش: 2 bundles counted, recipes take 5-10 g -> 0.2 kg (a bundle is about 100 g).
-- Same way as the stocktake screen. All or nothing, runs once.
-- Run: sudo bash /opt/motionpos/repo/supabase/ops/makany_three_counts_2026_11.sh
\set ON_ERROR_STOP 1
\pset footer off
\pset pager off
begin;

create temp table mk3 (n int, name text, unit text, qty numeric, how text, ing uuid) on commit drop;
insert into mk3 (n, name, unit, qty, how) values
 (1, 'بسكويت أوريو', 'قطعة', 70, '800 جرام = حوالي 70 قطعة'),
 (2, 'كابونشي', 'كيلو', 0.5, '1 رأس = حوالي نص كيلو'),
 (3, 'نعناع فريش', 'كيلو', 0.2, '2 ربطة = حوالي 200 جرام');

do $fix$
declare
  v_co uuid;
  v_wh uuid;
  v_br uuid;
  v_count uuid;
  v_now numeric;
  v_var numeric;
  v_unit numeric;
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
  if exists (select 1 from inv_counts where notes like 'جرد الورق 2026-11 - 3 أصناف%') then
    raise exception 'STOP: this was already applied, nothing changed';
  end if;
  update mk3 m set ing = x.id from ingredients x where btrim(x.name) = m.name and x.unit = m.unit;
  if exists (select 1 from mk3 where ing is null)
     or (select count(*) from ingredients x join mk3 m on btrim(x.name) = m.name and x.unit = m.unit) <> 3 then
    raise exception 'STOP: the 3 items are not as checked (name / unit), nothing changed';
  end if;

  insert into inv_counts (company_id, warehouse_id, notes)
  values (v_co, v_wh, 'جرد الورق 2026-11 - 3 أصناف محوّلة لوحدة السيستم (أوريو 70 قطعة، كابونشي 0.5 كيلو، نعناع فريش 0.2 كيلو)')
  returning id into v_count;
  for r in select * from mk3 order by n loop
    insert into warehouse_stock (warehouse_id, ingredient_id, quantity) values (v_wh, r.ing, 0)
    on conflict (warehouse_id, ingredient_id) do nothing;
    select quantity into v_now from warehouse_stock where warehouse_id = v_wh and ingredient_id = r.ing for update;
    v_var := r.qty - v_now;
    select coalesce(cost_per_unit, 0) into v_unit from ingredients where id = r.ing;
    v_cost := round(v_var * v_unit, 2);
    insert into stock_takes (warehouse_id, ingredient_id, theoretical_qty, actual_qty, variance_qty, variance_cost, count_id)
    values (v_wh, r.ing, v_now, r.qty, v_var, v_cost, v_count);
    if v_var <> 0 then
      perform pos_stock_move(v_co, v_br, v_wh, r.ing, 'adjustment', v_var, v_unit, 'stocktake', v_count, 'فرق جرد', null);
      if v_cost < 0 then v_short := v_short - v_cost; else v_over := v_over + v_cost; end if;
    end if;
  end loop;
  perform pos_post_je(v_co, v_br, 'inventory', 'stocktake', v_count, 'تسوية جرد',
    jsonb_build_array(pos_je_line('5300', v_short, 0, 'عجز جرد'), pos_je_line('1200', 0, v_short, 'عجز جرد')), null);
  perform pos_post_je(v_co, v_br, 'inventory', 'stocktake', v_count, 'تسوية جرد',
    jsonb_build_array(pos_je_line('1200', v_over, 0, 'زيادة جرد'), pos_je_line('5300', 0, v_over, 'زيادة جرد')), null);
  update inv_counts set total_variance_cost = v_over - v_short where id = v_count;
  raise notice 'DONE: shortage value %, overage value %', v_short, v_over;
end;
$fix$;

\echo '== the 3 items now'
select m.name as item, m.unit, m.how,
       round((select ws.quantity from warehouse_stock ws where ws.warehouse_id = (select id from warehouses where name like '%المهندسين%')
               and ws.ingredient_id = m.ing), 3) as stock
  from mk3 m order by m.n;
commit;
