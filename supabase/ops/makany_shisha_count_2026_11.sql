-- Makany (2026-11-26): shisha count from the client (Hanan), store "مخزن فرع المهندسين":
--   fruit tobacco, all flavours together -> "معسل فواكه": 150+50+200+400+200+100+90+40+70+40+60+20+60+150+65+100+120+300+40
--     = 2255 g (تفاح، لاف، لاف، عنب فاخر، برتقال قشطة، توست، كيوي، لبان نعناع، ليمون نعناع، فانيليا، علكة قرفة، ردبول،
--       بطيخ، كنتالوب، ميجا بيري، انجليزي، عنب دندش، كولا، روبي كراش);
--   (عنب فاخر 400 g goes on "معسل فاخر" when that item is there, the rest 1855 g on "معسل فواكه");
--   "معسل سلوم" 6.5 kg = 6500 g;
--   "قص" 3.5 kg -> "معسل_قص برج". Both were in pieces (قطعة, box of 50): a piece is one stone = 25 g (what the client
--     said, fix_ice_shisha_tea), so they become grams like the other tobacco (pack باكو 100 g), recipes / extras x 25,
--     recipe lines of 0 take 25 g;
--   "لي فواكه" 160;  charcoal 7.5 kg (3.5 bags) -> "فحم"; the other charcoal items ("شوال فحم", "فحم كؤكؤ نار") are the
--     same charcoal bought under another name: to zero, the 7.5 kg is all the charcoal there is.
-- Same way as the stocktake screen (inv_counts + stock_takes + 'adjustment' moves + journal 5300/1200).
-- All or nothing, runs once. Run: sudo bash /opt/motionpos/repo/supabase/ops/makany_shisha_count_2026_11.sh
\set ON_ERROR_STOP 1
\pset footer off
\pset pager off
begin;

\echo '== shisha items before'
select x.name as item, x.unit, x.pack_unit, x.pack_size,
       round(coalesce((select ws.quantity from warehouse_stock ws join warehouses w on w.id = ws.warehouse_id
                        where ws.ingredient_id = x.id and w.name like '%المهندسين%'), 0), 3) as stock,
       (select count(*) from recipes r where r.ingredient_id = x.id) as recipes
  from ingredients x where x.name like '%معسل%' or x.name like '%فحم%' or btrim(x.name) in ('لي فواكه', 'لي شيشة') order by 1;

\echo '== recipes / extras that take the tobacco and hoses (before)'
select x.name as item, x.unit, coalesce(p.name, '?') as menu_item, r.quantity_required as qty
  from recipes r join ingredients x on x.id = r.ingredient_id left join products p on p.id = r.product_id
 where x.name like '%معسل%' or btrim(x.name) in ('لي فواكه', 'لي شيشة') order by 1, 3;

create temp table mks (n int, name text, unit text, qty numeric, ing uuid, note text) on commit drop;

do $fix$
declare
  v_co uuid;
  v_wh uuid;
  v_br uuid;
  v_brand uuid;
  v_count uuid;
  v_id uuid;
  v_ids uuid[];
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
  if exists (select 1 from inv_counts where notes like 'جرد الشيشة 2026-11%') then
    raise exception 'STOP: this was already applied, nothing changed';
  end if;
  select brand_id into v_brand from ingredients where brand_id is not null group by brand_id order by count(*) desc limit 1;

  -- fruit tobacco (all flavours but عنب فاخر, which goes on "معسل فاخر" when that item is there)
  if (select count(*) from ingredients where btrim(name) = 'معسل فواكه' and unit = 'جرام') <> 1 then
    raise exception 'STOP: not exactly one "معسل فواكه" in grams, nothing changed';
  end if;
  select id into v_id from ingredients where btrim(name) = 'معسل فاخر' and unit = 'جرام';
  if v_id is null then
    insert into mks select 1, name, unit, 2255, id, 'كل النكهات مع بعض' from ingredients where btrim(name) = 'معسل فواكه' and unit = 'جرام';
  else
    insert into mks select 1, name, unit, 1855, id, 'كل النكهات ما عدا عنب فاخر' from ingredients where btrim(name) = 'معسل فواكه' and unit = 'جرام';
    insert into mks values (2, 'معسل فاخر', 'جرام', 400, v_id, 'عنب فاخر');
  end if;

  -- سلوم and قص برج: in grams like the other tobacco. If an item is in pieces, a piece is one stone = 25 g
  -- (what the client said): stock to zero in pieces first, then grams (pack باكو 100 g), recipes / extras x 25,
  -- recipe lines of 0 take 25 g (a stone).
  for r in select * from (values (3, 'معسل سلوم', 6500::numeric, 'سلوم 6.5 كيلو'), (4, 'معسل قص برج', 3500::numeric, 'قص 3.5 كيلو')) t(n, nm, q, how) loop
    select array_agg(id) into v_ids from ingredients where replace(btrim(name), '_', ' ') = r.nm;
    if v_ids is null then
      insert into ingredients (name, unit, cost_per_unit, min_stock_alert, brand_id, pack_unit, pack_size)
      values (r.nm, 'جرام', 0, 0, v_brand, 'باكو', 100) returning id into v_id;
      insert into mks values (r.n, r.nm, 'جرام', r.q, v_id, r.how || ' - صنف جديد');
    elsif array_length(v_ids, 1) > 1 then
      raise exception 'STOP: more than one item named %, nothing changed', r.nm;
    elsif (select unit from ingredients where id = v_ids[1]) = 'جرام' then
      insert into mks values (r.n, r.nm, 'جرام', r.q, v_ids[1], r.how);
    else
      insert into mks values (r.n * 10, r.nm || ' (تصفير بالقطعة)', 'قطعة', 0, v_ids[1], ''),
                             (r.n, r.nm, 'جرام', r.q, v_ids[1], r.how || ' - الوحدة بقت جرام (القطعة = حجر = 25 جرام)');
    end if;
  end loop;

  select id into v_id from ingredients where btrim(name) = 'لي فواكه';
  insert into mks values (5, 'لي فواكه', 'قطعة', 160, v_id, case when v_id is null then 'اتساب: الصنف مش موجود' else '' end);

  if (select count(*) from ingredients where btrim(name) = 'فحم' and unit = 'كيلو') <> 1 then
    raise exception 'STOP: not exactly one "فحم" in kilo, nothing changed';
  end if;
  insert into mks select 6, name, unit, 7.5, id, '3 شكاير ونص' from ingredients where btrim(name) = 'فحم' and unit = 'كيلو';
  insert into mks select 7, name, unit, 0, id, 'نفس الفحم باسم تاني: الفحم كله في سطر الفحم'
    from ingredients where name like '%فحم%' and btrim(name) <> 'فحم';

  insert into inv_counts (company_id, warehouse_id, notes)
  values (v_co, v_wh, 'جرد الشيشة 2026-11 (حنان): معسل فواكه 1855 جم + فاخر 400، سلوم 6.5 ك، قص 3.5 ك، لي فواكه 160، فحم 7.5 ك')
  returning id into v_count;

  for r in select * from mks where ing is not null order by case when n >= 30 then n / 10.0 - 0.5 else n end loop
    if r.n in (3, 4) and (select unit from ingredients where id = r.ing) <> 'جرام' then
      -- the old pieces are at zero now (line 30 / 40): grams from here on, a piece (stone) = 25 g
      update ingredients set unit = 'جرام', pack_unit = 'باكو', pack_size = 100, cost_per_unit = 0,
                             min_stock_alert = coalesce(min_stock_alert, 0) * 25 where id = r.ing;
      update recipes set quantity_required = case when coalesce(quantity_required, 0) = 0 then 25 else quantity_required * 25 end
       where ingredient_id = r.ing;
      update modifiers set ingredient_quantity = ingredient_quantity * 25 where ingredient_id = r.ing and ingredient_quantity > 0;
    end if;
    insert into warehouse_stock (warehouse_id, ingredient_id, quantity) values (v_wh, r.ing, 0)
    on conflict (warehouse_id, ingredient_id) do nothing;
    select quantity into v_now from warehouse_stock where warehouse_id = v_wh and ingredient_id = r.ing for update;
    v_var := r.qty - v_now;
    select coalesce(cost_per_unit, 0) into v_unit from ingredients where id = r.ing;
    v_cost := round(v_var * v_unit, 2);
    insert into stock_takes (warehouse_id, ingredient_id, theoretical_qty, actual_qty, variance_qty, variance_cost, count_id)
    values (v_wh, r.ing, v_now, r.qty, v_var, v_cost, v_count);
    if v_var <> 0 then
      perform pos_stock_move(v_co, v_br, v_wh, r.ing, 'adjustment', v_var, v_unit, 'stocktake', v_count, 'جرد الشيشة', null);
      if v_cost < 0 then v_short := v_short - v_cost; else v_over := v_over + v_cost; end if;
    end if;
  end loop;
  perform pos_post_je(v_co, v_br, 'inventory', 'stocktake', v_count, 'تسوية جرد الشيشة',
    jsonb_build_array(pos_je_line('5300', v_short, 0, 'عجز جرد'), pos_je_line('1200', 0, v_short, 'عجز جرد')), null);
  perform pos_post_je(v_co, v_br, 'inventory', 'stocktake', v_count, 'تسوية جرد الشيشة',
    jsonb_build_array(pos_je_line('1200', v_over, 0, 'زيادة جرد'), pos_je_line('5300', 0, v_over, 'زيادة جرد')), null);
  update inv_counts set total_variance_cost = v_over - v_short where id = v_count;
  raise notice 'DONE: shortage value %, overage value %', v_short, v_over;
end;
$fix$;

\echo '== shisha count'
select m.n, coalesce(x.name, m.name) as item, x.unit,
       round((select ws.quantity from warehouse_stock ws where ws.ingredient_id = m.ing
               and ws.warehouse_id = (select id from warehouses where name like '%المهندسين%')), 3) as stock, m.note
  from mks m left join ingredients x on x.id = m.ing where m.n < 30 order by m.n, 2;
\echo '== recipes that take the tobacco now'
select x.name as item, x.unit, coalesce(p.name, '?') as menu_item, r.quantity_required as qty
  from recipes r join ingredients x on x.id = r.ingredient_id left join products p on p.id = r.product_id
 where x.name like '%معسل%' order by 1, 3;
commit;
