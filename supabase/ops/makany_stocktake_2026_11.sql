-- One-time stocktake (2026-11-25), Makany, store "مخزن فرع المهندسين": the counts from the client's paper sheets,
-- typed into جرد_مكاني.xlsx and corrected by the client.
--   mode=preview : shows each line -> the item it lands on, its unit, stock now, new stock, difference. Changes NOTHING.
--   mode=apply   : the same, then sets the stock exactly like the stocktake screen does (inv_counts + stock_takes +
--                  'adjustment' stock moves + journal 5300/1200), only for lines marked OK. Other lines are skipped.
--   since        : optional 'YYYY-MM-DD HH:MI' (Cairo time) when the counting was done; what moved after it is added.
-- Items in the system that are not on the paper are NOT touched.
-- Run: sudo bash /opt/motionpos/repo/supabase/ops/makany_stocktake_2026_11.sh preview   (then: apply)
\set ON_ERROR_STOP 1
\pset footer off
\pset pager off
begin;
select set_config('motionpos.fix_mode', :'mode', true) as m, set_config('motionpos.count_since', :'since', true) as s \gset

do $pre$
begin
  if length('إكراميات') <> 8 then
    raise exception 'STOP: file read with the wrong encoding, nothing changed';
  end if;
  if current_setting('motionpos.fix_mode') not in ('preview', 'apply') then
    raise exception 'STOP: mode must be preview or apply';
  end if;
end;
$pre$;

create function pg_temp.mk_norm(p text) returns text language sql immutable as $f$
  select regexp_replace(
           replace(replace(replace(
             translate(lower(regexp_replace(coalesce(p, ''), '\([^)]*\)', '', 'g')), 'ةأإآىـ', 'هااايـ'),
             'ـ', ''), 'شيكولا', 'شوكولا'), 'توبنج', 'توبينج'),
           '[[:space:][:punct:]]', '', 'g')
$f$;

-- unit family: g / kg / ml / l / pc (pieces of any kind); null = unknown
create function pg_temp.mk_unit(p text) returns text language sql immutable as $f$
  select case
    when pg_temp.mk_norm(p) in ('جرام', 'جم', 'جرامات', 'g', 'gm', 'gram') then 'g'
    when pg_temp.mk_norm(p) in ('كيلو', 'كجم', 'كيلوجرام', 'kg') then 'kg'
    when pg_temp.mk_norm(p) in ('مل', 'مللي', 'ملي', 'ملليلتر', 'ml') then 'ml'
    when pg_temp.mk_norm(p) in ('لتر', 'l', 'liter') then 'l'
    when pg_temp.mk_norm(p) in ('قطعه', 'حبه', 'رغيف', 'pc', 'piece', 'pcs') then 'pc'
    else null end
$f$;

-- how many item-units one paper-unit is; approx = weight <-> volume taken as 1 g = 1 ml
create function pg_temp.mk_factor(p_from text, p_to text, p_pack_unit text, p_pack_size numeric, out f numeric, out approx boolean)
language plpgsql immutable as $f$
declare
  a text := pg_temp.mk_unit(p_from);
  b text := pg_temp.mk_unit(p_to);
  base numeric := case a when 'g' then 1 when 'ml' then 1 when 'kg' then 1000 when 'l' then 1000 end;
  tob numeric := case b when 'g' then 1 when 'ml' then 1 when 'kg' then 1000 when 'l' then 1000 end;
begin
  approx := false;
  if pg_temp.mk_norm(p_from) = pg_temp.mk_norm(p_to) then f := 1; return; end if;
  if p_pack_unit is not null and pg_temp.mk_norm(p_from) = pg_temp.mk_norm(p_pack_unit) and p_pack_size > 0 then
    f := p_pack_size; return;
  end if;
  if a = 'pc' and b = 'pc' then f := 1; return; end if;
  if base is not null and tob is not null then
    f := base / tob;
    approx := (a in ('g', 'kg')) <> (b in ('g', 'kg'));
    return;
  end if;
  f := null;
end;
$f$;

create temp table mk_lines (n int primary key, label text, qty numeric, unit text, aliases text[]) on commit drop;
insert into mk_lines values
 (1, 'مياه صغيرة', 22, 'قطعة', '{مياه صغيرة,مياه معدنية,مياه}'),
 (2, 'توست', 14, 'قطعة', '{عيش توست,توست}'),
 (3, 'بيبسي', 13, 'قطعة', '{بيبسي}'),
 (4, 'ردبول', 4, 'قطعة', '{ردبول,ريد بول}'),
 (5, 'فيروز', 6, 'قطعة', '{فيروز}'),
 (6, 'طماطم', 0.25, 'كيلو', '{طماطم}'),
 (7, 'عنب', 400, 'جرام', '{عنب}'),
 (8, 'فلفل', 100, 'جرام', '{فلفل}'),
 (9, 'ليمون', 0.5, 'كيلو', '{ليمون}'),
 (10, 'كابوتشينو', 1, 'قطعة', '{كابوتشينو,كابتشينو,كابونشي}'),
 (11, 'جبنة أمريكان', 1.25, 'كيلو', '{جبنة أمريكان,جبنة أمريكاني,جبنة شرائح,جبنة}'),
 (12, 'لبن', 1, 'لتر', '{لبن}'),
 (13, 'صوص رانش', 3.35, 'كيلو', '{صوص رانش,رانش,صوصو رانش}'),
 (14, 'صوص تكساس', 3, 'كيلو', '{صوص تكساس,تكساس}'),
 (15, 'مايونيز', 3, 'كيلو', '{مايونيز,صوصو مايونيز}'),
 (16, 'كاتشب', 400, 'جرام', '{كاتشب}'),
 (17, 'صوص كراميل', 1.25, 'كيلو', '{صوص كراميل}'),
 (18, 'صوص باربكيو', 150, 'جرام', '{صوص باربكيو,صوص بربكيو,باربكيو}'),
 (19, 'نعناع فريش', 2, 'ربطة', '{نعناع فريش,نعناع فراش,نعناء فراش}'),
 (20, 'تشيز كيك', 1, 'قطعة', '{تشيز كيك}'),
 (21, 'عصير زبادي فراولة (فريزر)', 500, 'مل', '{عصير زبادي فراولة,زبادي فراولة}'),
 (22, 'عصير فراولة بلبن', 100, 'مل', '{عصير فراولة بلبن,فراولة بلبن}'),
 (23, 'عصير فراولة', 200, 'مل', '{عصير فراولة}'),
 (24, 'آيس كريم شوكولاتة', 3, 'كيلو', '{آيس كريم شوكولاتة,ايس كريم شوكولاتة}'),
 (25, 'آيس كريم لوتس', 1.25, 'كيلو', '{آيس كريم لوتس}'),
 (26, 'آيس كريم مانجو', 1.5, 'كيلو', '{آيس كريم مانجو}'),
 (27, 'بطاطس فرايز', 250, 'جرام', '{بطاطس فرايز,بطاطس مجمدة}'),
 (28, 'أصابع موتزاريلا', 800, 'جرام', '{أصابع موتزاريلا,صوابع موتزاريلا,موتزاريلا ستيكس}'),
 (29, 'كفتة', 200, 'جرام', '{كفتة}'),
 (30, 'استربس', 600, 'جرام', '{استربس,ستربس,تشيكن استربس}'),
 (31, 'عيش كايزر', 9, 'رغيف', '{عيش كايزر,كايزر}'),
 (32, 'عيش فرنساوي', 9, 'رغيف', '{عيش فرنساوي,عيش فينو}'),
 (33, 'سكر', 1, 'كيلو', '{سكر}'),
 (34, 'كركديه فتلة', 6, 'قطعة', '{كركديه فتلة}'),
 (35, 'شاي فتلة', 131, 'قطعة', '{شاي فتلة}'),
 (36, 'نعناع فتلة', 14, 'قطعة', '{نعناع فتلة}'),
 (37, 'ينسون فتلة', 12, 'قطعة', '{ينسون فتلة}'),
 (38, 'شاي أخضر فتلة', 45, 'قطعة', '{شاي أخضر فتلة}'),
 (39, 'شاي فراولة فتلة', 9, 'قطعة', '{شاي فراولة فتلة,شاي فراولة}'),
 (40, 'شاي خوخ فتلة', 1, 'قطعة', '{شاي خوخ فتلة,شاي خوخ}'),
 (41, 'شاي مانجو فتلة', 12, 'قطعة', '{شاي مانجو فتلة,شاي مانجو}'),
 (42, 'سكر دايت', 36, 'قطعة', '{سكر دايت}'),
 (43, 'نسكافيه', 200, 'جرام', '{نسكافيه}'),
 (44, 'جوانتيات', 1, 'كيس', '{جوانتيات,جوانتي}'),
 (45, 'لبن مكثف', 100, 'جرام', '{لبن مكثف}'),
 (46, 'عسل أبيض', 250, 'جرام', '{عسل أبيض,عسل}'),
 (47, 'صوص بستاشيو', 100, 'جرام', '{صوص بستاشيو,صوص فستق,بستاشيو}'),
 (48, 'صوص شوكولاتة', 500, 'جرام', '{صوص شوكولاتة}'),
 (49, 'ملح', 1, 'كيس', '{ملح}'),
 (50, 'كاكاو', 750, 'جرام', '{كاكاو}'),
 (51, 'بن محوج', 150, 'جرام', '{بن محوج,بن تركي محوج}'),
 (52, 'بن غامق', 100, 'جرام', '{بن غامق,بن تركي غامق}'),
 (53, 'بن سادة', 200, 'جرام', '{بن سادة,بن تركي سادة,بن تركي}'),
 (54, 'شاي سايب', 450, 'جرام', '{شاي سايب,شاي}'),
 (55, 'بن اسبريسو', 9972, 'جرام', '{بن اسبريسو,بن اسبرسو,اسبريسو}'),
 (56, 'بن بندق', 250, 'جرام', '{بن بندق,بن فرنساوي بندق}'),
 (57, 'جوز هند', 288, 'جرام', '{جوز هند,جوز هند مبشور}'),
 (58, 'زبيب', 50, 'جرام', '{زبيب}'),
 (59, 'سوداني', 70, 'جرام', '{سوداني,فول سوداني}'),
 (60, 'قرفة بودرة', 650, 'جرام', '{قرفة بودرة,قرفة بودر,قرفة}'),
 (61, 'جنزبيل', 500, 'جرام', '{جنزبيل,زنجبيل}'),
 (62, 'نشادر', 140, 'جرام', '{نشادر}'),
 (63, 'قرنفل حبوب', 60, 'جرام', '{قرنفل حبوب,قرنفل}'),
 (64, 'قرفة عيدان', 150, 'جرام', '{قرفة عيدان}'),
 (66, 'نشا', 500, 'جرام', '{نشا}'),
 (67, 'دوم بودر', 1, 'كيلو', '{دوم بودر,دوم}'),
 (68, 'بسكوت لوتس', 900, 'جرام', '{بسكوت لوتس}'),
 (69, 'بسكوت أوريو', 800, 'جرام', '{بسكوت أوريو,أوريو}'),
 (70, 'فليفر كراميل', 1, 'لتر', '{فليفر كراميل,سيرب كراميل}'),
 (71, 'فليفر بلو كوراساو', 1, 'لتر', '{فليفر بلو كوراساو,فليفر بلو كوراسو,سيرب بلو كوراساو,بلو كوراساو}'),
 (72, 'فليفر فانيليا', 500, 'جرام', '{فليفر فانيليا,سيرب فانيليا,فانيليا}'),
 (73, 'فليفر بندق', 400, 'جرام', '{فليفر بندق,سيرب بندق}'),
 (74, 'فليفر نعناع', 200, 'جرام', '{فليفر نعناع,سيرب نعناع}'),
 (75, 'توبينج فراولة', 500, 'جرام', '{توبينج فراولة}'),
 (76, 'توبينج جوز هند', 600, 'جرام', '{توبينج جوز هند,بيوريه جوز هند}'),
 (77, 'توبينج كريز', 426, 'جرام', '{توبينج كريز,بيوريه كريز}'),
 (78, 'توبينج باشون فروت', 1, 'كيلو', '{توبينج باشون فروت,سيرب باشون فروت,بيوريه باشون فروت}'),
 (79, 'توبينج مكس بيري', 700, 'جرام', '{توبينج مكس بيري,بيوريه مكس بيري,مكس بيري}'),
 (80, 'توبينج مانجو (بيوريه)', 800, 'جرام', '{توبينج مانجو,بيوريه مانجو}'),
 (81, 'توبينج خوخ', 1300, 'جرام', '{توبينج خوخ,بيوريه خوخ}'),
 (82, 'توبينج أناناس', 400, 'جرام', '{توبينج أناناس,بيوريه أناناس}'),
 (83, 'توبينج بلوبيري', 213, 'جرام', '{توبينج بلوبيري,فليفر بلوبيري,بيوريه بلوبيري}'),
 (84, 'كركديه سايب', 880, 'جرام', '{كركديه سايب,كركديه}'),
 (85, 'بودرة سحلب', 600, 'جرام', '{بودرة سحلب,سحلب}'),
 (86, 'وايت شوكولاتة سبريد', 500, 'جرام', '{وايت شوكولاتة سبريد,صوص وايت شوكولاتة}'),
 (87, 'شوكولاتة سبريد', 960, 'جرام', '{شوكولاتة سبريد,صوص نوتيلا,نوتيلا}'),
 (88, 'لوتس سبريد', 850, 'جرام', '{لوتس سبريد,صوص لوتس}'),
 (89, 'كريم شانتيه', 200, 'جرام', '{كريم شانتيه,كريم شانتي}'),
 (90, 'فرابيه كوفي', 1250, 'جرام', '{فرابيه كوفي,بودرة فرابيه كوفي}'),
 (91, 'فرابيه شوكولاتة', 440, 'جرام', '{فرابيه شوكولاتة}'),
 (92, 'فرابيه كراميل', 240, 'جرام', '{فرابيه كراميل}'),
 (93, 'كوبايات بلاستيك ساقع', 90, 'قطعة', '{كوبايات بلاستيك ساقع,كوبايات بلاستيك,كوبايات ساقع}'),
 (94, 'كوبايات سخن وسط', 43, 'قطعة', '{كوبايات سخن وسط,كوبايات ورق وسط}'),
 (95, 'كوبايات سخن صغير', 33, 'قطعة', '{كوبايات سخن صغير,كوبايات ورق صغير}'),
 -- the water counted on the paper is all in line 1; the purchase item "كرتونه مياه" never goes down with sales
 (96, 'كرتونه مياه (المياه كلها في سطر 1)', 0, 'زجاجة', '{كرتونه مياه}');

create temp table mk_res (
  n int, label text, paper text, ing_id uuid, item text, item_unit text, qty_item numeric,
  stock_now numeric, after_count numeric, new_stock numeric, diff numeric, cost numeric, status text, hint text) on commit drop;

do $fix$
declare
  v_co uuid;
  v_wh uuid;
  v_br uuid;
  v_since timestamptz := case when nullif(current_setting('motionpos.count_since'), '') is null then null
                              else (current_setting('motionpos.count_since')::timestamp at time zone 'Africa/Cairo') end;
  l record;
  a text;
  v_ids uuid[];
  i record;
  fx record;
  v_q numeric;
  v_now numeric;
  v_adj numeric;
  v_count uuid;
  v_short numeric := 0;
  v_over numeric := 0;
  v_cost numeric;
  n_ok int := 0;
begin
  if (select count(*) from companies) <> 1 then
    raise exception 'STOP: more than one company here, nothing changed';
  end if;
  select id into v_co from companies;
  select w.id, w.branch_id into v_wh, v_br from warehouses w where w.name like '%المهندسين%';
  if (select count(*) from warehouses w where w.name like '%المهندسين%') <> 1 then
    raise exception 'STOP: could not find exactly one store named المهندسين, nothing changed';
  end if;
  if current_setting('motionpos.fix_mode') = 'apply'
     and exists (select 1 from inv_counts where notes like 'جرد الورق 2026-11%') then
    raise exception 'STOP: this stocktake was already applied, nothing changed';
  end if;

  for l in select * from mk_lines order by n loop
    v_ids := null;
    foreach a in array l.aliases loop
      select array_agg(x.id order by x.name) into v_ids from ingredients x where pg_temp.mk_norm(x.name) = pg_temp.mk_norm(a);
      exit when v_ids is not null;
    end loop;
    if v_ids is null then
      insert into mk_res (n, label, paper, status, hint)
      select l.n, l.label, l.qty || ' ' || l.unit, 'NO MATCH',
             (select string_agg(x.name || ' [' || x.unit || ']', ' | ') from (
                select y.name, y.unit from ingredients y
                 where exists (select 1 from unnest(l.aliases) u(al)
                                where length(pg_temp.mk_norm(u.al)) >= 3
                                  and (pg_temp.mk_norm(y.name) like '%' || pg_temp.mk_norm(u.al) || '%'
                                       or (length(pg_temp.mk_norm(y.name)) >= 4 and pg_temp.mk_norm(u.al) like '%' || pg_temp.mk_norm(y.name) || '%')))
                 order by y.name limit 5) x);
      continue;
    end if;
    -- several items with the same name (e.g. كفتة in kilo and كفتة (قطعة)): take the one whose unit fits the paper
    if array_length(v_ids, 1) > 1
       and (select count(*) from ingredients x, pg_temp.mk_factor(l.unit, x.unit, x.pack_unit, x.pack_size) z
             where x.id = any (v_ids) and z.f is not null and not z.approx) = 1 then
      select array[x.id] into v_ids from ingredients x, pg_temp.mk_factor(l.unit, x.unit, x.pack_unit, x.pack_size) z
       where x.id = any (v_ids) and z.f is not null and not z.approx;
    end if;
    if array_length(v_ids, 1) > 1 then
      insert into mk_res (n, label, paper, status, hint)
      select l.n, l.label, l.qty || ' ' || l.unit, 'MANY ITEMS',
             (select string_agg(x.name || ' [' || x.unit || '] stock ' ||
                       coalesce((select ws.quantity from warehouse_stock ws where ws.warehouse_id = v_wh and ws.ingredient_id = x.id), 0), ' | ')
                from ingredients x where x.id = any (v_ids));
      continue;
    end if;
    select * into i from ingredients x where x.id = v_ids[1];
    select * into fx from pg_temp.mk_factor(l.unit, i.unit, i.pack_unit, i.pack_size);
    select coalesce((select ws.quantity from warehouse_stock ws where ws.warehouse_id = v_wh and ws.ingredient_id = i.id), 0) into v_now;
    if fx.f is null then
      insert into mk_res (n, label, paper, ing_id, item, item_unit, stock_now, status, hint)
      values (l.n, l.label, l.qty || ' ' || l.unit, i.id, i.name, i.unit, v_now, 'UNIT?',
              'paper unit ' || l.unit || ' vs item unit ' || i.unit || coalesce(' (pack ' || i.pack_unit || ' = ' || i.pack_size || ')', ''));
      continue;
    end if;
    v_q := round(l.qty * fx.f, 4);
    v_adj := 0;
    if v_since is not null then
      select coalesce(sum(m.quantity), 0) into v_adj from stock_movements m
       where m.warehouse_id = v_wh and m.ingredient_id = i.id and m.created_at >= v_since
         and m.reference_type is distinct from 'stocktake';
    end if;
    insert into mk_res (n, label, paper, ing_id, item, item_unit, qty_item, stock_now, after_count, new_stock, diff, cost, status)
    values (l.n, l.label, l.qty || ' ' || l.unit, i.id, i.name, i.unit, v_q, v_now, v_adj, v_q + v_adj,
            round(v_q + v_adj - v_now, 4), coalesce(i.cost_per_unit, 0), case when fx.approx then 'OK (1g=1ml)' else 'OK' end);
  end loop;

  -- two paper lines on the same item: neither is applied
  update mk_res r set status = 'SAME ITEM TWICE', hint = 'also line ' ||
         (select string_agg(o.n::text, ',') from mk_res o where o.ing_id = r.ing_id and o.n <> r.n)
   where r.status like 'OK%' and exists (select 1 from mk_res o where o.ing_id = r.ing_id and o.n <> r.n);

  if current_setting('motionpos.fix_mode') = 'apply' then
    insert into inv_counts (company_id, warehouse_id, notes)
    values (v_co, v_wh, left('جرد الورق 2026-11 (مكاني) من ملف جرد_مكاني.xlsx' || coalesce(' - العد يوم ' || current_setting('motionpos.count_since'), ''), 500))
    returning id into v_count;
    for l in select * from mk_res where status like 'OK%' order by n loop
      v_cost := round(l.diff * l.cost, 2);
      insert into stock_takes (warehouse_id, ingredient_id, theoretical_qty, actual_qty, variance_qty, variance_cost, count_id)
      values (v_wh, l.ing_id, l.stock_now, l.new_stock, l.diff, v_cost, v_count);
      if l.diff <> 0 then
        perform pos_stock_move(v_co, v_br, v_wh, l.ing_id, 'adjustment', l.diff, l.cost, 'stocktake', v_count, 'فرق جرد', null);
        if v_cost < 0 then v_short := v_short - v_cost; else v_over := v_over + v_cost; end if;
      end if;
      n_ok := n_ok + 1;
    end loop;
    perform pos_post_je(v_co, v_br, 'inventory', 'stocktake', v_count, 'تسوية جرد',
      jsonb_build_array(pos_je_line('5300', v_short, 0, 'عجز جرد'), pos_je_line('1200', 0, v_short, 'عجز جرد')), null);
    perform pos_post_je(v_co, v_br, 'inventory', 'stocktake', v_count, 'تسوية جرد',
      jsonb_build_array(pos_je_line('1200', v_over, 0, 'زيادة جرد'), pos_je_line('5300', 0, v_over, 'زيادة جرد')), null);
    update inv_counts set total_variance_cost = v_over - v_short where id = v_count;
    raise notice 'APPLIED: % lines, shortage value %, overage value %', n_ok, v_short, v_over;
  end if;
end;
$fix$;

\echo '== lines ready (OK): paper -> item, new stock in the item unit'
select n, label, paper, item, item_unit as unit, round(qty_item, 3) as counted, round(stock_now, 3) as stock_before,
       round(after_count, 3) as moved_after_count, round(new_stock, 3) as new_stock, round(diff, 3) as diff, status
  from mk_res where status like 'OK%' order by n;
\echo '== lines NOT applied (need a decision)'
select n, label, paper, item, item_unit as unit, status, hint from mk_res where status not like 'OK%' order by n;
\echo '== items in this store with stock that are not on the paper (left as they are)'
select x.name as item, x.unit, round(ws.quantity, 3) as stock
  from warehouse_stock ws join ingredients x on x.id = ws.ingredient_id
 where ws.warehouse_id = (select id from warehouses where name like '%المهندسين%')
   and ws.quantity <> 0 and x.id not in (select ing_id from mk_res where ing_id is not null)
 order by ws.quantity, x.name;
\echo '== totals'
select count(*) filter (where status like 'OK%') as ok_lines, count(*) filter (where status not like 'OK%') as not_applied,
       round(sum(diff * cost) filter (where status like 'OK%'), 2) as value_change
  from mk_res;

select case current_setting('motionpos.fix_mode') when 'apply' then 'commit' else 'rollback' end as fin \gset
\echo '== mode:' :m ' -> ' :fin
:fin;
