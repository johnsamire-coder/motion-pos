-- One-time data fix (2026-11-17), Makany, as the client said:
--   * ice: most of it comes from the ice machine, so it is no longer counted in stock: removed from every recipe
--     and extra (bought ice is recorded as an expense);
--   * shisha tobacco (items "معسل..." counted in grams): a stone takes 25 grams, so a recipe line below 5 grams
--     (it was 1) becomes 25; the pack is "باكو" = 100 grams (a kilo = 10 packs, a quarter = 2.5 packs);
--   * tea bags ("شاي فتلة"): a box of 25 bags.
-- Shows every line it changes. All or nothing.
-- Run: sudo bash /opt/motionpos/repo/supabase/ops/fix_ice_shisha_tea.sh
\set ON_ERROR_STOP 1
\pset footer off
begin;

\echo '== ice lines removed from recipes / extras'
select p.name as product, r.quantity_required as qty from recipes r join products p on p.id = r.product_id join ingredients i on i.id = r.ingredient_id
 where btrim(i.name) = 'تلج'
union all
select 'extra: ' || m.name, m.ingredient_quantity from modifiers m join ingredients i on i.id = m.ingredient_id where btrim(i.name) = 'تلج'
order by 1;
delete from recipes r using ingredients i where i.id = r.ingredient_id and btrim(i.name) = 'تلج';
update modifiers m set ingredient_id = null, ingredient_quantity = null from ingredients i where i.id = m.ingredient_id and btrim(i.name) = 'تلج';

\echo '== shisha tobacco: recipe lines set to 25 grams a stone'
select p.name as product, i.name as tobacco, r.quantity_required as was, 25 as now
  from recipes r join products p on p.id = r.product_id join ingredients i on i.id = r.ingredient_id
 where btrim(i.name) like 'معسل%' and i.unit = 'جرام' and r.quantity_required < 5
 order by 1;
update recipes r set quantity_required = 25 from ingredients i
 where i.id = r.ingredient_id and btrim(i.name) like 'معسل%' and i.unit = 'جرام' and r.quantity_required < 5;
update ingredients set pack_unit = 'باكو', pack_size = 100 where btrim(name) like 'معسل%' and unit = 'جرام';

\echo '== tea bags: a box of 25'
update ingredients set pack_unit = 'علبة', pack_size = 25 where btrim(name) = 'شاي فتلة';

\echo '== the items now'
select i.name, i.unit, coalesce(i.pack_unit || ' = ' || trim(to_char(i.pack_size, 'FM999990.##')), '-') as pack,
       (select count(*) from recipes r where r.ingredient_id = i.id) as recipes,
       (select string_agg(distinct trim(to_char(r.quantity_required, 'FM999990.##')), ', ') from recipes r where r.ingredient_id = i.id) as recipe_qty
  from ingredients i where btrim(i.name) = 'تلج' or btrim(i.name) like 'معسل%' or btrim(i.name) = 'شاي فتلة'
 order by i.name;
commit;
