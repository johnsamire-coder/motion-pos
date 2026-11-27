-- Makany (2026-11-27), after makany_shisha_count_2026_11: the recipes took "معسل_قص برج" 0.25 of a piece a stone, so
-- a piece was a 100 g pack (not a stone of 25 g as that script took): the recipes it turned into 6.25 g become 25 g
-- (0.25 x 100), and its alert level x 4. Stock is not touched (it was counted in grams).
-- "شيشة معسل سلوم" took قص برج: it takes "معسل سلوم" 25 g now.
-- All or nothing, runs once (only 6.25 g lines are changed). Run: sudo bash /opt/motionpos/repo/supabase/ops/makany_shisha_recipes_fix_2026_11.sh
\set ON_ERROR_STOP 1
\pset footer off
\pset pager off
begin;

do $fix$
declare
  v_qas uuid;
  v_sal uuid;
  n int;
begin
  if length('إكراميات') <> 8 then
    raise exception 'STOP: file read with the wrong encoding, nothing changed';
  end if;
  select id into v_qas from ingredients where replace(btrim(name), '_', ' ') = 'معسل قص برج' and unit = 'جرام';
  select id into v_sal from ingredients where btrim(name) = 'معسل سلوم' and unit = 'جرام';
  if v_qas is null or v_sal is null then
    raise exception 'STOP: قص برج / سلوم are not in grams (run makany_shisha_count first), nothing changed';
  end if;
  if not exists (select 1 from recipes where ingredient_id = v_qas and quantity_required = 6.25) then
    raise exception 'STOP: no 6.25 g line left (already fixed?), nothing changed';
  end if;
  update recipes set quantity_required = 25 where ingredient_id = v_qas and quantity_required = 6.25;
  get diagnostics n = row_count;
  update modifiers set ingredient_quantity = ingredient_quantity * 4 where ingredient_id = v_qas and ingredient_quantity > 0;
  update ingredients set min_stock_alert = coalesce(min_stock_alert, 0) * 4 where id = v_qas;
  raise notice 'قص برج recipe lines to 25 g: %', n;
  update recipes r set ingredient_id = v_sal
    from products p where p.id = r.product_id and r.ingredient_id = v_qas and p.name like '%سلوم%';
  get diagnostics n = row_count;
  raise notice 'سلوم shisha now takes معسل سلوم: % line(s)', n;
end;
$fix$;

\echo '== recipes that take the tobacco now'
select x.name as item, x.unit, coalesce(p.name, '?') as menu_item, r.quantity_required as grams
  from recipes r join ingredients x on x.id = r.ingredient_id left join products p on p.id = r.product_id
 where x.name like '%معسل%' order by 1, 3;
commit;
