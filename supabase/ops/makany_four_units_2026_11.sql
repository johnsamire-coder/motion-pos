-- Makany (2026-11-25): the 4 items counted on the paper in another unit than the system's:
--   كابونشي (كيلو) counted 1 قطعة, نعناع فريش (كيلو) 2 ربطة, ستربس (قطعة) 600 جرام, بسكويت أوريو (قطعة) 800 جرام.
-- The unit becomes the paper's one and the stock = the count. How:
--   1) stock to 0 in the old unit (stocktake, at the old cost), 2) unit changed, cost 0 (the old cost was per the old
--   unit; the next purchase sets it), 3) stock = the count (stocktake).
-- An item that a menu recipe or an extra still takes is NOT changed (those quantities are in the old unit and would
-- take the wrong amount): it is listed with the recipes, to change them first.
-- All or nothing, runs once. Run: sudo bash /opt/motionpos/repo/supabase/ops/makany_four_units_2026_11.sh
\set ON_ERROR_STOP 1
\pset footer off
\pset pager off
begin;

create temp table mk4 (n int, old_name text, old_unit text, new_name text, new_unit text, qty numeric, ing uuid, note text) on commit drop;
insert into mk4 (n, old_name, old_unit, new_name, new_unit, qty) values
 (1, 'كابونشي', 'كيلو', 'كابونشي', 'قطعة', 1),
 (2, 'نعناع فريش', 'كيلو', 'نعناع فريش', 'ربطة', 2),
 (3, 'ستربس (قطعة)', 'قطعة', 'ستربس', 'كيلو', 0.6),
 (4, 'بسكويت أوريو', 'قطعة', 'بسكويت أوريو', 'كيلو', 0.8);

\echo '== recipes / extras that take these items (in the old unit)'
select m.old_name as item, m.old_unit as unit, coalesce(p.name, '?') as menu_item, r.quantity_required as qty, 'recipe' as kind
  from mk4 m join ingredients x on btrim(x.name) = m.old_name join recipes r on r.ingredient_id = x.id left join products p on p.id = r.product_id
union all
select m.old_name, m.old_unit, d.name, d.ingredient_quantity, 'extra'
  from mk4 m join ingredients x on btrim(x.name) = m.old_name join modifiers d on d.ingredient_id = x.id
 order by 1, 3;

do $fix$
declare
  v_co uuid;
  v_wh uuid;
  v_br uuid;
  v_c1 uuid;
  v_c2 uuid;
  v_now numeric;
  v_unit numeric;
  v_cost numeric;
  v_short numeric := 0;
  v_over numeric := 0;
  r record;
  v_ids uuid[];
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
  if exists (select 1 from inv_counts where notes like 'جرد الورق 2026-11 - تغيير وحدة%') then
    raise exception 'STOP: this was already applied, nothing changed';
  end if;

  for r in select * from mk4 order by n loop
    select array_agg(x.id) into v_ids from ingredients x where btrim(x.name) = r.old_name and x.unit = r.old_unit;
    if v_ids is null or array_length(v_ids, 1) <> 1 then
      update mk4 set note = 'اتساب: مش لاقي صنف واحد بالاسم والوحدة دي' where n = r.n;
    elsif exists (select 1 from recipes where ingredient_id = v_ids[1] and coalesce(quantity_required, 0) > 0)
       or exists (select 1 from modifiers where ingredient_id = v_ids[1] and coalesce(ingredient_quantity, 0) > 0) then
      update mk4 set note = 'اتساب: داخل في وصفات (شوف الجدول فوق)' where n = r.n;
    else
      update mk4 set ing = v_ids[1] where n = r.n;
    end if;
  end loop;
  if not exists (select 1 from mk4 where ing is not null) then
    raise notice 'nothing to change';
    return;
  end if;

  insert into inv_counts (company_id, warehouse_id, notes)
  values (v_co, v_wh, 'جرد الورق 2026-11 - تغيير وحدة: تصفير بالوحدة القديمة') returning id into v_c1;
  insert into inv_counts (company_id, warehouse_id, notes)
  values (v_co, v_wh, 'جرد الورق 2026-11 - تغيير وحدة: الكمية المعدودة بالوحدة الجديدة') returning id into v_c2;

  for r in select * from mk4 where ing is not null order by n loop
    -- 1) to zero in the old unit
    insert into warehouse_stock (warehouse_id, ingredient_id, quantity) values (v_wh, r.ing, 0)
    on conflict (warehouse_id, ingredient_id) do nothing;
    select quantity into v_now from warehouse_stock where warehouse_id = v_wh and ingredient_id = r.ing for update;
    select coalesce(cost_per_unit, 0) into v_unit from ingredients where id = r.ing;
    v_cost := round(-v_now * v_unit, 2);
    insert into stock_takes (warehouse_id, ingredient_id, theoretical_qty, actual_qty, variance_qty, variance_cost, count_id)
    values (v_wh, r.ing, v_now, 0, -v_now, v_cost, v_c1);
    if v_now <> 0 then
      perform pos_stock_move(v_co, v_br, v_wh, r.ing, 'adjustment', -v_now, v_unit, 'stocktake', v_c1, 'تصفير قبل تغيير الوحدة', null);
      if v_cost < 0 then v_short := v_short - v_cost; else v_over := v_over + v_cost; end if;
    end if;
    -- 2) the new unit (a bag/pack set for the old unit does not fit any more)
    update ingredients set name = r.new_name, unit = r.new_unit, cost_per_unit = 0, pack_unit = null, pack_size = null
     where id = r.ing;
    -- 3) the count
    insert into stock_takes (warehouse_id, ingredient_id, theoretical_qty, actual_qty, variance_qty, variance_cost, count_id)
    values (v_wh, r.ing, 0, r.qty, r.qty, 0, v_c2);
    perform pos_stock_move(v_co, v_br, v_wh, r.ing, 'adjustment', r.qty, 0, 'stocktake', v_c2, 'فرق جرد', null);
    update mk4 set note = 'تم' where n = r.n;
  end loop;

  perform pos_post_je(v_co, v_br, 'inventory', 'stocktake', v_c1, 'تسوية جرد (تغيير وحدة)',
    jsonb_build_array(pos_je_line('5300', v_short, 0, 'عجز جرد'), pos_je_line('1200', 0, v_short, 'عجز جرد')), null);
  perform pos_post_je(v_co, v_br, 'inventory', 'stocktake', v_c1, 'تسوية جرد (تغيير وحدة)',
    jsonb_build_array(pos_je_line('1200', v_over, 0, 'زيادة جرد'), pos_je_line('5300', 0, v_over, 'زيادة جرد')), null);
  update inv_counts set total_variance_cost = v_over - v_short where id = v_c1;
  raise notice 'DONE: shortage value %, overage value %', v_short, v_over;
end;
$fix$;

\echo '== the 4 items now'
select m.n, m.old_name || ' (' || m.old_unit || ')' as was, x.name as item, x.unit,
       round((select ws.quantity from warehouse_stock ws where ws.warehouse_id = (select id from warehouses where name like '%المهندسين%')
               and ws.ingredient_id = x.id), 3) as stock, m.note
  from mk4 m left join ingredients x on x.id = m.ing order by m.n;
commit;
