-- 043_ingredient_units_merge.sql
-- Items set up with wrong units / packs (a spice bag "1 gram", a gallon "2500 kg", sugar sticks "100 kg" instead of
-- 100 pieces) and the same item twice (جوافه / جوافة ...). The owner gets two tools, and the item screen a review:
--   * ingredient_fix_unit_secure: new unit and pack; "1 old unit = factor new units" converts recipes / extras and/or
--     stock, moves, purchases, receipts, counts and costs (quantity x factor, unit cost / factor: money stays the same);
--   * ingredient_merge_secure: moves everything of one item into another (converted by a factor) and deletes it;
--   * ingredients_review_secure: every item with its stock, what came in / went out and the recipes using it.
-- Unit costs and recipe quantities keep 6 decimals now (cost per gram). The unit of an item already used can no longer
-- be changed by the plain edit (it would not convert anything): settings2_secure copied from 027 with only that check.
-- Rules: begin/commit, preflight (needs 042), version bump to 043, grants loop, rolled-back self-test.

begin;

do $preflight$
begin
  if length('إكراميات') <> 8 then
    raise exception 'file_encoding_broken: read the file as UTF-8';
  end if;
  if public.motionpos_version_public() not in ('042', '043') then
    raise exception 'schema_preflight_failed: run 042 first';
  end if;
end;
$preflight$;

-- ---------------------------------------------------------------- 1) costs keep 6 decimals (cost per gram / per ml)
alter table public.ingredients alter column cost_per_unit type numeric(15,6);
alter table public.stock_movements alter column unit_cost type numeric(15,6);
alter table public.goods_receipt_items alter column unit_cost type numeric(15,6);
alter table public.purchase_order_items alter column unit_price type numeric(15,6);
alter table public.supplier_prices alter column unit_price type numeric(15,6);
alter table public.ingredient_cost_history alter column old_cost type numeric(15,6);
alter table public.ingredient_cost_history alter column new_cost type numeric(15,6);
alter table public.inv_transfer_lines alter column unit_cost type numeric(15,6);
alter table public.opening_balances alter column unit_cost type numeric(15,6);
alter table public.stock_adjustments alter column unit_cost type numeric(15,6);
alter table public.recipes alter column quantity_required type numeric(15,6);
alter table public.modifiers alter column ingredient_quantity type numeric(15,6);
alter table public.ingredients alter column min_stock_alert type numeric(15,4);
alter table public.ingredients alter column stock_quantity type numeric(15,4);
alter table public.stock_transfers alter column quantity type numeric(15,4);

-- ---------------------------------------------------------------- 2) rescale one item everywhere
-- new quantity = old quantity x factor, new unit cost = old unit cost / factor: the value in money stays the same.
-- p_stock: stock, moves, purchases, receipts, costs, counts. p_recipes: recipes and extras (modifiers).
create or replace function public.pos_ing_rescale(p_ing uuid, p_factor numeric, p_stock boolean, p_recipes boolean)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  f numeric := p_factor;
begin
  if f is null or f <= 0 then
    raise exception 'invalid_factor';
  end if;
  if f = 1 then
    return;
  end if;
  if p_recipes then
    update public.recipes set quantity_required = quantity_required * f where ingredient_id = p_ing;
    update public.modifiers set ingredient_quantity = ingredient_quantity * f where ingredient_id = p_ing and ingredient_quantity is not null;
  end if;
  if p_stock then
    update public.stock_movements set quantity = quantity * f, balance_after = balance_after * f, unit_cost = unit_cost / f where ingredient_id = p_ing;
    update public.warehouse_stock set quantity = quantity * f where ingredient_id = p_ing;
    update public.purchase_order_items set quantity = quantity * f, qty_received = qty_received * f, unit_price = unit_price / f where ingredient_id = p_ing;
    update public.goods_receipt_items set ordered_qty = ordered_qty * f, received_qty = received_qty * f, unit_cost = unit_cost / f where ingredient_id = p_ing;
    update public.waste_logs set quantity = quantity * f where ingredient_id = p_ing;
    update public.supplier_prices set unit_price = unit_price / f, min_order_qty = min_order_qty * f where ingredient_id = p_ing;
    update public.ingredient_cost_history set old_cost = old_cost / f, new_cost = new_cost / f where ingredient_id = p_ing;
    update public.inv_transfer_lines set qty_requested = qty_requested * f, qty_shipped = qty_shipped * f, qty_received = qty_received * f,
                                         unit_cost = unit_cost / f where ingredient_id = p_ing;
    update public.stock_adjustments set quantity = quantity * f, unit_cost = unit_cost / f where ingredient_id = p_ing;
    update public.stock_takes set theoretical_qty = theoretical_qty * f, actual_qty = actual_qty * f, variance_qty = variance_qty * f where ingredient_id = p_ing;
    update public.stock_transfers set quantity = quantity * f where ingredient_id = p_ing;
    update public.opening_balances set quantity = quantity * f, unit_cost = unit_cost / f where ingredient_id = p_ing;
    update public.variance_investigations set theoretical_qty = theoretical_qty * f, actual_qty = actual_qty * f, variance_qty = variance_qty * f
     where ingredient_id = p_ing;
    update public.ingredients set cost_per_unit = cost_per_unit / f, stock_quantity = stock_quantity * f, min_stock_alert = min_stock_alert * f,
                                  reorder_point = reorder_point * f, max_stock_level = max_stock_level * f where id = p_ing;
  end if;
end;
$$;

create or replace function public.pos_ing_row(p_ing uuid)
returns jsonb
language sql
stable
security definer
set search_path = public, extensions
as $$
  select jsonb_build_object('id', i.id, 'name', i.name, 'unit', i.unit, 'pack_unit', i.pack_unit, 'pack_size', i.pack_size,
           'cost_per_unit', i.cost_per_unit, 'min_stock_alert', i.min_stock_alert,
           'stock', coalesce((select sum(ws.quantity) from public.warehouse_stock ws where ws.ingredient_id = i.id), 0),
           'recipes', (select count(*) from public.recipes r where r.ingredient_id = i.id))
    from public.ingredients i where i.id = p_ing
$$;

-- ---------------------------------------------------------------- 3) owner: fix an item's unit / pack
-- p_data: ingredient_id, unit, factor (1 old unit = factor new units), convert_stock, convert_recipes, pack_unit, pack_size, reason
create or replace function public.ingredient_fix_unit_secure(p_token text, p_data jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
  d jsonb := coalesce(p_data, '{}'::jsonb);
  v_ing uuid := public.pos_uuid(d->>'ingredient_id');
  v_unit text := nullif(btrim(coalesce(d->>'unit', '')), '');
  v_factor numeric := coalesce(public.pos_num(d->>'factor'), 1);
  v_stock boolean := coalesce(d->>'convert_stock', 'true') = 'true';
  v_recipes boolean := coalesce(d->>'convert_recipes', 'true') = 'true';
  v_pack text := nullif(btrim(coalesce(d->>'pack_unit', '')), '');
  v_pack_size numeric := public.pos_num(d->>'pack_size');
  v_reason text := nullif(btrim(coalesce(d->>'reason', '')), '');
  v_before jsonb;
begin
  select * into c from public.pos_ctx(p_token, null);
  if c.role_name <> 'owner' then
    return jsonb_build_object('ok', false, 'reason', 'owner_only');
  end if;
  v_before := public.pos_ing_row(v_ing);
  if v_before is null then
    return jsonb_build_object('ok', false, 'reason', 'not_found');
  end if;
  if v_unit is null or length(v_unit) > 20 then
    return jsonb_build_object('ok', false, 'reason', 'invalid_value', 'key', 'unit');
  end if;
  if v_factor <= 0 or v_factor > 1000000 then
    return jsonb_build_object('ok', false, 'reason', 'invalid_value', 'key', 'factor');
  end if;
  if v_factor <> 1 and not (v_stock or v_recipes) then
    return jsonb_build_object('ok', false, 'reason', 'invalid_value', 'key', 'convert');
  end if;
  if v_pack is not null and (v_pack_size is null or v_pack_size <= 0 or v_pack = v_unit or length(v_pack) > 30) then
    return jsonb_build_object('ok', false, 'reason', 'invalid_value', 'key', 'pack');
  end if;
  if v_reason is null then
    return jsonb_build_object('ok', false, 'reason', 'reason_required');
  end if;
  perform public.pos_ing_rescale(v_ing, v_factor, v_stock, v_recipes);
  update public.ingredients set unit = v_unit, pack_unit = v_pack, pack_size = case when v_pack is null then null else v_pack_size end
   where id = v_ing;
  insert into public.settings_logs (staff_id, action, details)
  values (c.staff_id, 'ingredient_fix_unit', jsonb_build_object('before', v_before, 'after', public.pos_ing_row(v_ing), 'factor', v_factor,
          'convert_stock', v_stock, 'convert_recipes', v_recipes, 'reason', v_reason));
  return jsonb_build_object('ok', true, 'ingredient', public.pos_ing_row(v_ing));
end;
$$;

-- ---------------------------------------------------------------- 4) owner: merge a duplicate item into another
-- p_data: from_id (goes away), into_id (stays), factor (1 unit of "from" = factor units of "into"), reason.
-- Everything of "from" moves to "into": recipes (same product: quantities added), extras, stock and moves, purchases,
-- receipts, waste, counts, transfers, prices. The cost of "into" becomes the weighted cost of both stocks.
create or replace function public.ingredient_merge_secure(p_token text, p_data jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
  d jsonb := coalesce(p_data, '{}'::jsonb);
  v_from uuid := public.pos_uuid(d->>'from_id');
  v_into uuid := public.pos_uuid(d->>'into_id');
  v_factor numeric := coalesce(public.pos_num(d->>'factor'), 1);
  v_reason text := nullif(btrim(coalesce(d->>'reason', '')), '');
  v_a jsonb;
  v_b jsonb;
  v_qa numeric;
  v_qb numeric;
  v_ca numeric;
  v_cb numeric;
begin
  select * into c from public.pos_ctx(p_token, null);
  if c.role_name <> 'owner' then
    return jsonb_build_object('ok', false, 'reason', 'owner_only');
  end if;
  v_a := public.pos_ing_row(v_from);
  v_b := public.pos_ing_row(v_into);
  if v_a is null or v_b is null or v_from = v_into then
    return jsonb_build_object('ok', false, 'reason', 'not_found');
  end if;
  if v_factor <= 0 or v_factor > 1000000 then
    return jsonb_build_object('ok', false, 'reason', 'invalid_value', 'key', 'factor');
  end if;
  if v_reason is null then
    return jsonb_build_object('ok', false, 'reason', 'reason_required');
  end if;
  -- the "from" item in the unit of "into"
  perform public.pos_ing_rescale(v_from, v_factor, true, true);
  select greatest(coalesce(sum(quantity), 0), 0) into v_qa from public.warehouse_stock where ingredient_id = v_from;
  select greatest(coalesce(sum(quantity), 0), 0) into v_qb from public.warehouse_stock where ingredient_id = v_into;
  select cost_per_unit into v_ca from public.ingredients where id = v_from;
  select cost_per_unit into v_cb from public.ingredients where id = v_into;

  -- recipes: the same product with both = one line with both quantities
  update public.recipes r set quantity_required = r.quantity_required + x.quantity_required
    from public.recipes x where x.ingredient_id = v_from and r.ingredient_id = v_into and r.product_id = x.product_id;
  delete from public.recipes x where x.ingredient_id = v_from
     and exists (select 1 from public.recipes r where r.ingredient_id = v_into and r.product_id = x.product_id);
  update public.recipes set ingredient_id = v_into where ingredient_id = v_from;
  update public.modifiers set ingredient_id = v_into where ingredient_id = v_from;
  -- stock per store
  update public.warehouse_stock w set quantity = w.quantity + x.quantity
    from public.warehouse_stock x where x.ingredient_id = v_from and w.ingredient_id = v_into and w.warehouse_id = x.warehouse_id;
  delete from public.warehouse_stock x where x.ingredient_id = v_from
     and exists (select 1 from public.warehouse_stock w where w.ingredient_id = v_into and w.warehouse_id = x.warehouse_id);
  update public.warehouse_stock set ingredient_id = v_into where ingredient_id = v_from;
  -- prices per supplier: the one of "into" stays
  delete from public.supplier_prices x where x.ingredient_id = v_from
     and exists (select 1 from public.supplier_prices s where s.ingredient_id = v_into and s.supplier_id = x.supplier_id);
  update public.supplier_prices set ingredient_id = v_into where ingredient_id = v_from;
  -- history
  update public.stock_movements set ingredient_id = v_into where ingredient_id = v_from;
  update public.purchase_order_items set ingredient_id = v_into where ingredient_id = v_from;
  update public.goods_receipt_items set ingredient_id = v_into where ingredient_id = v_from;
  update public.waste_logs set ingredient_id = v_into where ingredient_id = v_from;
  update public.ingredient_cost_history set ingredient_id = v_into where ingredient_id = v_from;
  update public.inv_transfer_lines set ingredient_id = v_into where ingredient_id = v_from;
  update public.stock_adjustments set ingredient_id = v_into where ingredient_id = v_from;
  update public.stock_takes set ingredient_id = v_into where ingredient_id = v_from;
  update public.stock_transfers set ingredient_id = v_into where ingredient_id = v_from;
  update public.opening_balances set ingredient_id = v_into where ingredient_id = v_from;
  update public.variance_investigations set ingredient_id = v_into where ingredient_id = v_from;
  -- cost: weighted by the stock on hand; no stock on hand = keep the cost of "into" (or of "from" when "into" has none)
  update public.ingredients
     set cost_per_unit = case when v_qa + v_qb > 0 then round((v_qa * coalesce(v_ca, 0) + v_qb * coalesce(v_cb, 0)) / (v_qa + v_qb), 6)
                              when coalesce(v_cb, 0) > 0 then v_cb else coalesce(v_ca, 0) end,
         stock_quantity = coalesce(stock_quantity, 0) + coalesce((select stock_quantity from public.ingredients where id = v_from), 0)
   where id = v_into;
  delete from public.ingredients where id = v_from;
  insert into public.settings_logs (staff_id, action, details)
  values (c.staff_id, 'ingredient_merge', jsonb_build_object('from', v_a, 'into', v_b, 'factor', v_factor, 'reason', v_reason,
          'after', public.pos_ing_row(v_into)));
  return jsonb_build_object('ok', true, 'ingredient', public.pos_ing_row(v_into));
end;
$$;

-- ---------------------------------------------------------------- 5) review list for the settings screen
create or replace function public.ingredients_review_secure(p_token text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
declare
  c record;
begin
  select * into c from public.pos_ctx(p_token, 'settings');
  return jsonb_build_object('ok', true, 'items', coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', i.id, 'name', i.name, 'unit', i.unit, 'pack_unit', i.pack_unit, 'pack_size', i.pack_size,
             'cost_per_unit', i.cost_per_unit, 'min_stock_alert', i.min_stock_alert,
             'stock', coalesce((select sum(ws.quantity) from public.warehouse_stock ws where ws.ingredient_id = i.id), 0),
             'came_in', coalesce((select sum(sm.quantity) from public.stock_movements sm where sm.ingredient_id = i.id and sm.quantity > 0), 0),
             'went_out', coalesce((select -sum(sm.quantity) from public.stock_movements sm where sm.ingredient_id = i.id and sm.quantity < 0), 0),
             'receipts', (select count(*) from public.goods_receipt_items gi where gi.ingredient_id = i.id),
             'used_in', coalesce((select jsonb_agg(jsonb_build_object('product', p.name, 'qty', r.quantity_required) order by p.name)
                                    from public.recipes r join public.products p on p.id = r.product_id where r.ingredient_id = i.id), '[]'::jsonb),
             'extras', (select count(*) from public.modifiers m where m.ingredient_id = i.id))
           order by i.name)
      from public.ingredients i
     where i.brand_id is null or i.brand_id in (select b.brand_id from public.branches b join public.brands br on br.id = b.brand_id
                                                 where br.company_id = c.company_id)), '[]'::jsonb));
end;
$$;

-- the item edit, copied from 027 + the unit lock
create or replace function public.settings2_secure(p_token text, p_action text, p_data jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
  v_brand uuid;
  d jsonb := coalesce(p_data, '{}'::jsonb);
  v_id uuid;
  v_txt text;
  v_num numeric;
  l jsonb;
  v_result jsonb := '{}'::jsonb;
begin
  select * into c from public.pos_ctx(p_token, 'settings');
  select b.brand_id into v_brand from public.branches b where b.id = c.branch_id;

  case coalesce(p_action, '')
  when 'get' then
    v_result := jsonb_build_object(
      'categories', (select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'name', x.name, 'station', x.station) order by x.name), '[]')
                       from public.categories x where x.brand_id = v_brand),
      'ingredients', (select coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'name', i.name, 'unit', i.unit, 'cost_per_unit', i.cost_per_unit,
                                                                    'min_stock_alert', i.min_stock_alert, 'pack_unit', i.pack_unit, 'pack_size', i.pack_size)
                                                 order by i.name), '[]') from public.ingredients i),
      'discounts', (select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'name', x.name, 'discount_type', x.discount_type, 'value', x.value,
                                                                  'requires_approval', x.requires_approval) order by x.name), '[]')
                      from public.discounts x where x.brand_id = v_brand),
      'cancel_reasons', (select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'reason', x.reason, 'reason_type', x.reason_type) order by x.reason), '[]')
                           from public.cancel_reasons x where x.brand_id = v_brand),
      'areas', (select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'name', x.name) order by x.sort_order, x.name), '[]')
                  from public.areas x where x.branch_id = c.branch_id),
      'payment_accounts', (select coalesce(jsonb_agg(jsonb_build_object('method', m.method, 'account_id', pm.account_id) order by m.ord), '[]')
                             from unnest(array['cash', 'card', 'instapay', 'wallet', 'on_account']) with ordinality as m(method, ord)
                             left join public.payment_method_account_mappings pm on pm.company_id = c.company_id and pm.payment_method = m.method),
      'asset_accounts', (select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'name', a.code || ' - ' || a.name_ar) order by a.code), '[]')
                           from public.accounts a where a.company_id = c.company_id and a.account_type = 'asset'),
      'tax', (select coalesce(jsonb_agg(jsonb_build_object('branch_id', b.id, 'branch', b.name, 'vat_percentage', t.vat_percentage,
                                                           'service_charge_percentage', t.service_charge_percentage,
                                                           'is_vat_inclusive', coalesce(t.is_vat_inclusive, false),
                                                           'is_service_taxable', coalesce(t.is_service_taxable, true)) order by b.name), '[]')
                from public.branches b left join public.branch_tax_settings t on t.branch_id = b.id where b.brand_id = v_brand));

  when 'get_recipe' then
    v_id := public.pos_uuid(d->>'product_id');
    v_result := jsonb_build_object('lines', (select coalesce(jsonb_agg(jsonb_build_object('ingredient_id', r.ingredient_id, 'ingredient', i.name,
                                                   'unit', i.unit, 'qty', r.quantity_required, 'cost', round(r.quantity_required * i.cost_per_unit, 2))
                                                   order by i.name), '[]')
                                               from public.recipes r join public.ingredients i on i.id = r.ingredient_id where r.product_id = v_id),
                                   'unit_cost', round(public.pos_product_cost(v_id), 2));

  when 'save_recipe' then
    v_id := public.pos_uuid(d->>'product_id');
    if v_id is null or not exists (select 1 from public.products p where p.id = v_id and p.brand_id = v_brand) then
      return jsonb_build_object('ok', false, 'reason', 'product_not_found');
    end if;
    if jsonb_typeof(d->'lines') is distinct from 'array' or jsonb_array_length(d->'lines') > 50 then
      return jsonb_build_object('ok', false, 'reason', 'invalid_items');
    end if;
    for l in select e.value from jsonb_array_elements(d->'lines') e(value) loop
      if not exists (select 1 from public.ingredients i where i.id = public.pos_uuid(l->>'ingredient_id'))
         or coalesce(public.pos_amount(l->>'qty'), 0) <= 0 then
        return jsonb_build_object('ok', false, 'reason', 'invalid_items');
      end if;
    end loop;
    delete from public.recipes where product_id = v_id;
    insert into public.recipes (product_id, ingredient_id, quantity_required)
    select v_id, (e.value->>'ingredient_id')::uuid, sum((e.value->>'qty')::numeric)
      from jsonb_array_elements(d->'lines') e(value) group by 2;

  when 'save_ingredient' then
    v_id := public.pos_uuid(d->>'id');
    v_txt := nullif(btrim(coalesce(d->>'name', '')), '');
    if v_txt is null or nullif(btrim(coalesce(d->>'unit', '')), '') is null then
      return jsonb_build_object('ok', false, 'reason', 'invalid_name');
    end if;
    if nullif(btrim(coalesce(d->>'pack_unit', '')), '') is not null and coalesce(public.pos_amount(d->>'pack_size'), 0) <= 0 then
      return jsonb_build_object('ok', false, 'reason', 'invalid_value');
    end if;
    if v_id is null then
      insert into public.ingredients (name, unit, cost_per_unit, min_stock_alert, brand_id, pack_unit, pack_size)
      values (left(v_txt, 100), left(btrim(d->>'unit'), 20), coalesce(public.pos_amount(d->>'cost_per_unit'), 0),
              coalesce(public.pos_amount(d->>'min_stock_alert'), 0), v_brand,
              left(nullif(btrim(coalesce(d->>'pack_unit', '')), ''), 30),
              case when nullif(btrim(coalesce(d->>'pack_unit', '')), '') is null then null else public.pos_amount(d->>'pack_size') end)
      returning id into v_id;
    else
      -- the unit of an item already used (recipes, extras, stock moves) changes only through ingredient_fix_unit_secure,
      -- which converts every quantity with it (043)
      if exists (select 1 from public.ingredients i where i.id = v_id and i.unit is distinct from left(btrim(d->>'unit'), 20))
         and (exists (select 1 from public.recipes r where r.ingredient_id = v_id)
              or exists (select 1 from public.modifiers m where m.ingredient_id = v_id)
              or exists (select 1 from public.stock_movements sm where sm.ingredient_id = v_id)) then
        return jsonb_build_object('ok', false, 'reason', 'ingredient_unit_locked');
      end if;
      -- the cost changes only through purchases (average cost), never by hand
      update public.ingredients set name = left(v_txt, 100), unit = left(btrim(d->>'unit'), 20),
             min_stock_alert = coalesce(public.pos_amount(d->>'min_stock_alert'), min_stock_alert),
             pack_unit = left(nullif(btrim(coalesce(d->>'pack_unit', '')), ''), 30),
             pack_size = case when nullif(btrim(coalesce(d->>'pack_unit', '')), '') is null then null else public.pos_amount(d->>'pack_size') end
       where id = v_id;
    end if;

  when 'set_category_station' then
    v_txt := d->>'station';
    if v_txt is null or v_txt not in ('kitchen', 'bar', 'shisha') then
      return jsonb_build_object('ok', false, 'reason', 'invalid_value');
    end if;
    update public.categories set station = v_txt where id = public.pos_uuid(d->>'category_id') and brand_id = v_brand;

  when 'save_discount' then
    v_id := public.pos_uuid(d->>'id');
    v_txt := nullif(btrim(coalesce(d->>'name', '')), '');
    v_num := public.pos_amount(d->>'value');
    if v_txt is null or coalesce(d->>'discount_type', '') not in ('percentage', 'fixed') or v_num is null or v_num <= 0
       or (d->>'discount_type' = 'percentage' and v_num > 100) then
      return jsonb_build_object('ok', false, 'reason', 'invalid_value');
    end if;
    if v_id is null then
      insert into public.discounts (brand_id, name, discount_type, value, requires_approval)
      values (v_brand, left(v_txt, 100), d->>'discount_type', v_num, coalesce(d->>'requires_approval', 'true') = 'true');
    else
      update public.discounts set name = left(v_txt, 100), discount_type = d->>'discount_type', value = v_num,
             requires_approval = coalesce(d->>'requires_approval', 'true') = 'true'
       where id = v_id and brand_id = v_brand;
    end if;

  when 'save_cancel_reason' then
    v_id := public.pos_uuid(d->>'id');
    v_txt := nullif(btrim(coalesce(d->>'reason', '')), '');
    if v_txt is null or coalesce(d->>'reason_type', '') not in ('void_item', 'cancel_order', 'return') then
      return jsonb_build_object('ok', false, 'reason', 'invalid_value');
    end if;
    if v_id is null then
      insert into public.cancel_reasons (brand_id, reason, reason_type) values (v_brand, left(v_txt, 150), d->>'reason_type');
    else
      update public.cancel_reasons set reason = left(v_txt, 150), reason_type = d->>'reason_type' where id = v_id and brand_id = v_brand;
    end if;

  when 'add_area' then
    v_txt := nullif(btrim(coalesce(d->>'name', '')), '');
    if v_txt is null then
      return jsonb_build_object('ok', false, 'reason', 'invalid_name');
    end if;
    insert into public.areas (branch_id, name) values (c.branch_id, left(v_txt, 100)) returning id into v_id;

  when 'set_payment_account' then
    if c.role_name <> 'owner' then
      return jsonb_build_object('ok', false, 'reason', 'not_allowed');
    end if;
    v_txt := d->>'method';
    v_id := public.pos_uuid(d->>'account_id');
    if v_txt is null or v_txt not in ('cash', 'card', 'instapay', 'wallet', 'on_account')
       or not exists (select 1 from public.accounts a where a.id = v_id and a.company_id = c.company_id and a.account_type = 'asset') then
      return jsonb_build_object('ok', false, 'reason', 'invalid_value');
    end if;
    insert into public.payment_method_account_mappings (company_id, payment_method, account_id)
    values (c.company_id, v_txt, v_id)
    on conflict (company_id, payment_method) do update set account_id = excluded.account_id;

  when 'save_tax_flags' then
    v_id := public.pos_uuid(d->>'branch_id');
    if v_id is null or not exists (select 1 from public.branches b where b.id = v_id and b.brand_id = v_brand)
       or coalesce(d->>'is_vat_inclusive', '') not in ('true', 'false') or coalesce(d->>'is_service_taxable', '') not in ('true', 'false') then
      return jsonb_build_object('ok', false, 'reason', 'invalid_value');
    end if;
    update public.branch_tax_settings
       set is_vat_inclusive = (d->>'is_vat_inclusive') = 'true', is_service_taxable = (d->>'is_service_taxable') = 'true'
     where branch_id = v_id;
    if not found then
      insert into public.branch_tax_settings (branch_id, is_vat_inclusive, is_service_taxable)
      values (v_id, (d->>'is_vat_inclusive') = 'true', (d->>'is_service_taxable') = 'true');
    end if;

  else
    return jsonb_build_object('ok', false, 'reason', 'unknown_action');
  end case;

  if p_action not in ('get', 'get_recipe') then
    insert into public.settings_logs (staff_id, action, details) values (c.staff_id, p_action, jsonb_build_object('data', d, 'id', v_id));
  end if;
  return jsonb_build_object('ok', true, 'id', v_id) || v_result;
end;
$$;

create or replace function public.motionpos_version_public()
returns text
language sql
immutable
as $$
  select '043'
$$;

do $grants$
declare
  f record;
begin
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and (p.proname like 'pos\_%' or p.proname like 'trg\_%')
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f.sig);
  end loop;
  for f in
    select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and (p.proname like '%\_secure' or p.proname like '%\_public')
  loop
    execute format('revoke all on function %s from public', f.sig);
    execute format('grant execute on function %s to anon, authenticated, service_role', f.sig);
  end loop;
end;
$grants$;

do $selftest$
declare
  v_co uuid;
  v_br uuid;
  v_wh uuid;
  v_cat uuid;
  v_p1 uuid;
  v_p2 uuid;
  v_a uuid;
  v_b uuid;
  v_tok text;
  v_res jsonb;
begin
  begin
    perform set_config('motionpos.sync_apply', 'on', true);
    insert into public.companies (name) values ('selftest043') returning id into v_co;
    insert into public.branches (name) values ('selftest043') returning id into v_br;
    insert into public.warehouses (name) values ('selftest043') returning id into v_wh;
    insert into public.staff (name, company_id, branch_id, is_active, pin_hash, role_id)
    values ('selftest043', v_co, v_br, true, extensions.crypt('4743', extensions.gen_salt('bf')), (select id from public.roles where name = 'owner' limit 1));
    v_tok := public.staff_login('4743')->>'session_token';
    insert into public.categories (name) values ('selftest043') returning id into v_cat;
    insert into public.products (name, price, category_id) values ('st043 a', 10, v_cat) returning id into v_p1;
    insert into public.products (name, price, category_id) values ('st043 b', 10, v_cat) returning id into v_p2;
    -- a gallon set up as "2500 kg": 1 gallon received = 2500 kg at 0.04 (100 a gallon); the recipe uses 0.02 kg (right)
    insert into public.ingredients (name, unit, pack_unit, pack_size, cost_per_unit) values ('st043 syrup', 'kg', 'gallon', 2500, 0.04) returning id into v_a;
    insert into public.recipes (product_id, ingredient_id, quantity_required) values (v_p1, v_a, 0.02);
    insert into public.stock_movements (warehouse_id, ingredient_id, movement_type, quantity, unit_cost, total_cost)
    values (v_wh, v_a, 'purchase', 2500, 0.04, 100);
    insert into public.warehouse_stock (warehouse_id, ingredient_id, quantity) values (v_wh, v_a, 2500);
    -- fix: stock / costs only (x 0.001), recipe left as it is, gallon = 2.5 kg
    v_res := public.ingredient_fix_unit_secure(v_tok, jsonb_build_object('ingredient_id', v_a, 'unit', 'kg', 'factor', 0.001,
               'convert_stock', true, 'convert_recipes', false, 'pack_unit', 'gallon', 'pack_size', 2.5, 'reason', 'selftest'));
    if not (v_res->>'ok')::boolean then raise exception 'SELFTEST fix %', v_res; end if;
    if (select quantity from public.warehouse_stock where ingredient_id = v_a) <> 2.5
       or (select cost_per_unit from public.ingredients where id = v_a) <> 40
       or (select quantity_required from public.recipes where ingredient_id = v_a) <> 0.02
       or (select total_cost from public.stock_movements where ingredient_id = v_a) <> 100 then
      raise exception 'SELFTEST fix values';
    end if;
    -- kg -> gram for everything
    perform public.ingredient_fix_unit_secure(v_tok, jsonb_build_object('ingredient_id', v_a, 'unit', 'g', 'factor', 1000, 'reason', 'selftest'));
    if (select quantity_required from public.recipes where ingredient_id = v_a) <> 20 or (select cost_per_unit from public.ingredients where id = v_a) <> 0.04 then
      raise exception 'SELFTEST kg to g';
    end if;
    -- merge a duplicate (in kg) into it: recipe of the same product added, stock added, the duplicate gone
    insert into public.ingredients (name, unit, cost_per_unit) values ('st043 syrup 2', 'kg', 50) returning id into v_b;
    insert into public.recipes (product_id, ingredient_id, quantity_required) values (v_p1, v_b, 0.01), (v_p2, v_b, 0.005);
    insert into public.warehouse_stock (warehouse_id, ingredient_id, quantity) values (v_wh, v_b, 1);
    v_res := public.ingredient_merge_secure(v_tok, jsonb_build_object('from_id', v_b, 'into_id', v_a, 'factor', 1000, 'reason', 'selftest'));
    if not (v_res->>'ok')::boolean then raise exception 'SELFTEST merge %', v_res; end if;
    if exists (select 1 from public.ingredients where id = v_b)
       or (select quantity_required from public.recipes where ingredient_id = v_a and product_id = v_p1) <> 30
       or (select quantity_required from public.recipes where ingredient_id = v_a and product_id = v_p2) <> 5
       or (select quantity from public.warehouse_stock where ingredient_id = v_a) <> 3500
       or (select cost_per_unit from public.ingredients where id = v_a) <> round((2500 * 0.04 + 1000 * 0.05) / 3500, 6) then
      raise exception 'SELFTEST merge values';
    end if;
    -- the plain edit can no longer change the unit of a used item
    v_res := public.settings2_secure(v_tok, 'save_ingredient', jsonb_build_object('id', v_a, 'name', 'st043 syrup', 'unit', 'kg'));
    if v_res->>'reason' is distinct from 'ingredient_unit_locked' then raise exception 'SELFTEST unit lock %', v_res; end if;
    if jsonb_typeof(public.ingredients_review_secure(v_tok)->'items') <> 'array' then raise exception 'SELFTEST review'; end if;
    if public.motionpos_version_public() <> '043' then raise exception 'SELFTEST version'; end if;
    raise notice 'MOTIONPOS-043-SELFTEST-OK';
    raise exception using errcode = 'P0099', message = 'selftest_rollback';
  exception when sqlstate 'P0099' then
    null;
  end;
end;
$selftest$;

notify pgrst, 'reload schema';

commit;
