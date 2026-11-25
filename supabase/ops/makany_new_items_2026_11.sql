-- Makany (2026-11-25), after the paper stocktake: the things counted on the paper that were not items in the system
-- are added as items (cost 0 until the first purchase) with the counted stock, in store "مخزن فرع المهندسين".
-- Also "سكر دايت": its unit was كيلو with a bag (كيس) of 95, i.e. it is counted in pieces (sticks): unit -> قطعة,
-- nothing else changes (only if every recipe / extra takes it in whole pieces), then its stock = 36.
-- Same way as the stocktake screen (inv_counts + stock_takes + 'adjustment' moves + journal 5300/1200).
-- An item with the same name already there is not doubled: it is used if its unit is the same, else skipped.
-- All or nothing, runs once. Run: sudo bash /opt/motionpos/repo/supabase/ops/makany_new_items_2026_11.sh
\set ON_ERROR_STOP 1
\pset footer off
\pset pager off
begin;

create function pg_temp.mk_norm(p text) returns text language sql immutable as $f$
  select regexp_replace(replace(translate(lower(regexp_replace(coalesce(p, ''), '\([^)]*\)', '', 'g')), 'ةأإآىـ', 'هااايـ'), 'ـ', ''),
                        '[[:space:][:punct:]]', '', 'g')
$f$;

create temp table mk_new (n int, name text, unit text, qty numeric, supply boolean, ing uuid, note text) on commit drop;
insert into mk_new (n, name, unit, qty, supply) values
 (1, 'توست', 'قطعة', 14, false),
 (2, 'فلفل', 'كيلو', 0.1, false),
 (3, 'صوص تكساس', 'كيلو', 3, false),
 (4, 'كاتشب', 'كيلو', 0.4, false),
 (5, 'صوص باربكيو', 'كيلو', 0.15, false),
 (6, 'عصير زبادي فراولة (جاهز - فريزر)', 'لتر', 0.5, false),
 (7, 'عصير فراولة بلبن (جاهز - فريزر)', 'لتر', 0.1, false),
 (8, 'عصير فراولة (جاهز - فريزر)', 'لتر', 0.2, false),
 (9, 'أصابع موتزاريلا', 'كيلو', 0.8, false),
 (10, 'عيش كايزر', 'رغيف', 9, false),
 (11, 'شاي فراولة فتلة', 'قطعة', 9, false),
 (12, 'شاي خوخ فتلة', 'قطعة', 1, false),
 (13, 'شاي مانجو فتلة', 'قطعة', 12, false),
 (14, 'جوانتيات', 'كيس', 1, true),
 (15, 'ملح', 'كيس', 1, false),
 (16, 'كاكاو', 'كيلو', 0.75, false),
 (17, 'بن غامق', 'كيلو', 0.1, false),
 (18, 'زبيب', 'كيلو', 0.05, false),
 (19, 'سوداني', 'كيلو', 0.07, false),
 (20, 'نشادر', 'كيلو', 0.14, false),
 (21, 'قرنفل حبوب', 'كيلو', 0.06, false),
 (22, 'قرفة عيدان', 'كيلو', 0.15, false),
 (23, 'نشا', 'كيلو', 0.5, false),
 (24, 'دوم بودر', 'كيلو', 1, false),
 (25, 'بسكوت لوتس', 'كيلو', 0.9, false),
 (26, 'فليفر كراميل', 'لتر', 1, false),
 (27, 'فليفر فانيليا', 'لتر', 0.5, false),
 (28, 'فليفر نعناع', 'لتر', 0.2, false),
 (29, 'توبينج مكس بيري', 'لتر', 0.7, false),
 (30, 'توبينج خوخ', 'لتر', 1.3, false),
 (31, 'وايت شوكولاتة سبريد', 'كيلو', 0.5, false),
 (32, 'فرابيه شوكولاتة', 'كيلو', 0.44, false),
 (33, 'فرابيه كراميل', 'كيلو', 0.24, false),
 (34, 'كوبايات بلاستيك ساقع', 'قطعة', 90, true),
 (35, 'كوبايات سخن وسط', 'قطعة', 43, true),
 (36, 'كوبايات سخن صغير', 'قطعة', 33, true);

do $fix$
declare
  v_co uuid;
  v_wh uuid;
  v_br uuid;
  v_brand uuid;
  v_count uuid;
  v_ids uuid[];
  v_new uuid;
  v_diet uuid;
  v_now numeric;
  v_var numeric;
  v_unit numeric;
  v_cost numeric;
  v_short numeric := 0;
  v_over numeric := 0;
  r record;
  n_new int := 0;
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
  if exists (select 1 from inv_counts where notes like 'جرد الورق 2026-11 - أصناف جديدة%') then
    raise exception 'STOP: this was already applied, nothing changed';
  end if;
  -- new items go under the brand most items are under (like the items screen does)
  select brand_id into v_brand from ingredients where brand_id is not null group by brand_id order by count(*) desc limit 1;

  for r in select * from mk_new order by n loop
    select array_agg(x.id) into v_ids from ingredients x where pg_temp.mk_norm(x.name) = pg_temp.mk_norm(r.name);
    if v_ids is null then
      insert into ingredients (name, unit, cost_per_unit, min_stock_alert, brand_id, is_supply)
      values (r.name, r.unit, 0, 0, v_brand, r.supply) returning id into v_new;
      update mk_new set ing = v_new, note = 'جديد' where n = r.n;
      n_new := n_new + 1;
    elsif array_length(v_ids, 1) = 1 and (select x.unit from ingredients x where x.id = v_ids[1]) = r.unit then
      update mk_new set ing = v_ids[1], note = 'موجود قبل كده' where n = r.n;
    else
      update mk_new set note = 'اتساب: فيه صنف بنفس الاسم بوحدة تانية' where n = r.n;
    end if;
  end loop;

  -- سكر دايت: unit كيلو + bag of 95 = pieces; recipes must already take whole pieces
  select x.id into v_diet from ingredients x where btrim(x.name) = 'سكر دايت' and x.unit = 'كيلو';
  if v_diet is null then
    raise notice 'سكر دايت: not in كيلو any more, left as it is';
  elsif exists (select 1 from recipes where ingredient_id = v_diet and quantity_required > 0 and quantity_required <> round(quantity_required))
     or exists (select 1 from modifiers where ingredient_id = v_diet and ingredient_quantity > 0 and ingredient_quantity <> round(ingredient_quantity)) then
    raise notice 'سكر دايت: some recipe takes part of a piece, unit NOT changed: %',
      (select string_agg(quantity_required::text, ', ') from recipes where ingredient_id = v_diet);
  else
    update ingredients set unit = 'قطعة' where id = v_diet;
    insert into mk_new (n, name, unit, qty, supply, ing, note) values (37, 'سكر دايت', 'قطعة', 36, false, v_diet, 'الوحدة بقت قطعة (الكيس 95)');
  end if;

  insert into inv_counts (company_id, warehouse_id, notes)
  values (v_co, v_wh, 'جرد الورق 2026-11 - أصناف جديدة مكانتش متعرّفة + سكر دايت بالقطعة')
  returning id into v_count;
  for r in select * from mk_new where ing is not null order by n loop
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
  raise notice 'DONE: % new items, shortage value %, overage value %', n_new, v_short, v_over;
end;
$fix$;

\echo '== items now'
select m.n, x.name as item, x.unit, case when x.is_supply then 'مستلزمات' else '' end as kind,
       round((select ws.quantity from warehouse_stock ws join warehouses w on w.id = ws.warehouse_id
               where ws.ingredient_id = x.id and w.name like '%المهندسين%'), 3) as stock, m.note
  from mk_new m left join ingredients x on x.id = m.ing order by m.n;
\echo '== skipped'
select n, name, unit, qty, note from mk_new where ing is null order by n;
commit;
