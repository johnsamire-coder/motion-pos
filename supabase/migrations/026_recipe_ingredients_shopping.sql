-- 026_recipe_ingredients_shopping.sql
-- 1) A recipe line can have quantity 0 = "the ingredient is known, the amount not yet". Such lines take nothing from
--    the stores and cost nothing; the menu screen shows the product as "missing amounts".
-- 2) Shopping list: ingredients used in the menu with no stock in the store (or below the minimum), with the products
--    that use them, so the manager turns them into a purchase order.
-- Rules: begin/commit, preflight, rolled-back self-test, grants loop.

begin;

do $preflight$
begin
  if length('إكراميات') <> 8 then
    raise exception 'file_encoding_broken: read the file as UTF-8';
  end if;
  if public.motionpos_version_public() not in ('025', '026') then
    raise exception 'schema_preflight_failed: run 025 first';
  end if;
end;
$preflight$;


-- stock taken by a sold item (same as 010) + lines with quantity 0 take nothing
create or replace function public.pos_item_consumption(p_order_item_id uuid, p_qty numeric)
returns table (ingredient_id uuid, qty numeric)
language sql
stable
security definer
set search_path = public, extensions
as $$
  select r.ingredient_id, (r.quantity_required * p_qty)::numeric
    from public.order_items oi
    join public.recipes r on r.product_id = oi.product_id
   where oi.id = p_order_item_id
     and r.ingredient_id is not null
     and r.quantity_required > 0
  union all
  select m.ingredient_id, (coalesce(m.ingredient_quantity, 0) * p_qty)::numeric
    from public.order_item_modifiers oim
    join public.modifiers m on m.id = oim.modifier_id
   where oim.order_item_id = p_order_item_id
     and m.ingredient_id is not null
     and coalesce(m.ingredient_quantity, 0) > 0
$$;


-- menu screen (same as 025): a recipe line may have quantity 0 (amount not known yet)
create or replace function public.menu_admin_secure(p_token text, p_action text, p_data jsonb)
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
  v_cat uuid;
  v_name text;
  v_num numeric;
  v_old record;
  l jsonb;
  r jsonb;
  v_created int := 0;
  v_updated int := 0;
  v_extra jsonb := '{}'::jsonb;
begin
  select * into c from public.pos_ctx(p_token, 'settings');
  if coalesce(p_action, '') not in ('get', 'get_image') and not public.pos_perm_ok(c.role_name, 'settings_menu') then
    return jsonb_build_object('ok', false, 'reason', 'not_allowed', 'perm', 'settings_menu');
  end if;
  if not public.pos_perm_ok(c.role_name, 'settings_menu') then
    return jsonb_build_object('ok', false, 'reason', 'not_allowed');
  end if;
  select b.brand_id into v_brand from public.branches b where b.id = c.branch_id;
  if v_brand is null then
    return jsonb_build_object('ok', false, 'reason', 'branch_brand_not_configured');
  end if;

  case coalesce(p_action, '')
  when 'get' then
    null;

  when 'save_category' then
    v_id := public.pos_uuid(d->>'id');
    v_name := nullif(btrim(coalesce(d->>'name', '')), '');
    if v_name is null or length(v_name) > 100 then
      return jsonb_build_object('ok', false, 'reason', 'invalid_name');
    end if;
    if coalesce(d->>'station', 'kitchen') not in ('kitchen', 'bar', 'shisha') then
      return jsonb_build_object('ok', false, 'reason', 'invalid_value');
    end if;
    if exists (select 1 from public.categories x where x.brand_id = v_brand and btrim(x.name) = v_name and x.id is distinct from v_id) then
      return jsonb_build_object('ok', false, 'reason', 'name_taken');
    end if;
    if v_id is null then
      insert into public.categories (brand_id, name, station, sort_order, show_in_menu)
      values (v_brand, v_name, coalesce(d->>'station', 'kitchen'),
              coalesce((select max(x.sort_order) + 1 from public.categories x where x.brand_id = v_brand), 0),
              coalesce((d->>'show_in_menu')::boolean, true))
      returning id into v_id;
    else
      update public.categories
         set name = v_name, station = coalesce(d->>'station', station),
             sort_order = coalesce(nullif(d->>'sort_order', '')::int, sort_order),
             show_in_menu = coalesce((d->>'show_in_menu')::boolean, show_in_menu)
       where id = v_id and brand_id = v_brand;
      if not found then
        return jsonb_build_object('ok', false, 'reason', 'invalid_category');
      end if;
    end if;
    v_extra := jsonb_build_object('id', v_id);

  when 'delete_category' then
    v_id := public.pos_uuid(d->>'id');
    if exists (select 1 from public.products p where p.category_id = v_id) then
      return jsonb_build_object('ok', false, 'reason', 'category_not_empty');
    end if;
    delete from public.categories where id = v_id and brand_id = v_brand;

  when 'save_product' then
    v_id := public.pos_uuid(d->>'id');
    v_name := nullif(btrim(coalesce(d->>'name', '')), '');
    v_num := public.pos_amount(d->>'price');
    v_cat := public.pos_uuid(d->>'category_id');
    if v_name is null or length(v_name) > 150 then
      return jsonb_build_object('ok', false, 'reason', 'invalid_name');
    end if;
    if v_num is null or v_num > 999999 then
      return jsonb_build_object('ok', false, 'reason', 'invalid_price');
    end if;
    if v_cat is null or not exists (select 1 from public.categories x where x.id = v_cat and x.brand_id = v_brand) then
      return jsonb_build_object('ok', false, 'reason', 'invalid_category');
    end if;
    if length(coalesce(d->>'description', '')) > 500 then
      return jsonb_build_object('ok', false, 'reason', 'value_too_long');
    end if;
    if exists (select 1 from public.products p where p.brand_id = v_brand and btrim(p.name) = v_name and p.id is distinct from v_id) then
      return jsonb_build_object('ok', false, 'reason', 'name_taken');
    end if;
    if jsonb_typeof(d->'recipe') = 'array' then
      if jsonb_array_length(d->'recipe') > 50 then
        return jsonb_build_object('ok', false, 'reason', 'invalid_items');
      end if;
      for l in select e.value from jsonb_array_elements(d->'recipe') e(value) loop
        if not exists (select 1 from public.ingredients i where i.id = public.pos_uuid(l->>'ingredient_id'))
           or public.pos_amount(l->>'qty') is null then
          return jsonb_build_object('ok', false, 'reason', 'invalid_items');
        end if;
      end loop;
    end if;
    if jsonb_typeof(d->'group_ids') = 'array'
       and exists (select 1 from jsonb_array_elements_text(d->'group_ids') g(v)
                    where not exists (select 1 from public.modifier_groups mg where mg.id = public.pos_uuid(g.v) and mg.brand_id = v_brand)) then
      return jsonb_build_object('ok', false, 'reason', 'group_not_found');
    end if;
    if v_id is null then
      insert into public.products (brand_id, category_id, name, price, is_available, description, show_in_menu, sort_order)
      values (v_brand, v_cat, v_name, round(v_num, 2), coalesce((d->>'is_available')::boolean, true),
              nullif(btrim(coalesce(d->>'description', '')), ''), coalesce((d->>'show_in_menu')::boolean, true),
              coalesce(nullif(d->>'sort_order', '')::int, 0))
      returning id into v_id;
      insert into public.settings_logs (staff_id, action, details)
      values (c.staff_id, 'add_product', jsonb_build_object('product_id', v_id, 'name', v_name, 'price', round(v_num, 2)));
    else
      select p.price, p.name, p.is_available into v_old from public.products p where p.id = v_id and p.brand_id = v_brand for update;
      if not found then
        return jsonb_build_object('ok', false, 'reason', 'product_not_found');
      end if;
      update public.products
         set name = v_name, price = round(v_num, 2), category_id = v_cat,
             is_available = coalesce((d->>'is_available')::boolean, is_available),
             description = nullif(btrim(coalesce(d->>'description', '')), ''),
             show_in_menu = coalesce((d->>'show_in_menu')::boolean, show_in_menu),
             sort_order = coalesce(nullif(d->>'sort_order', '')::int, sort_order)
       where id = v_id;
      if v_old.price is distinct from round(v_num, 2) then
        insert into public.settings_logs (staff_id, action, details)
        values (c.staff_id, 'set_product_price', jsonb_build_object('product_id', v_id, 'name', v_name, 'old_price', v_old.price,
                                                                    'new_price', round(v_num, 2)));
      end if;
    end if;
    if jsonb_typeof(d->'recipe') = 'array' then
      delete from public.recipes where product_id = v_id;
      insert into public.recipes (product_id, ingredient_id, quantity_required)
      select v_id, (e.value->>'ingredient_id')::uuid, sum((e.value->>'qty')::numeric)
        from jsonb_array_elements(d->'recipe') e(value) group by 2;
    end if;
    if jsonb_typeof(d->'group_ids') = 'array' then
      delete from public.product_modifier_groups where product_id = v_id
         and group_id not in (select public.pos_uuid(g.v) from jsonb_array_elements_text(d->'group_ids') g(v));
      insert into public.product_modifier_groups (product_id, group_id)
      select v_id, public.pos_uuid(g.v) from jsonb_array_elements_text(d->'group_ids') g(v)
       where not exists (select 1 from public.product_modifier_groups x where x.product_id = v_id and x.group_id = public.pos_uuid(g.v));
    end if;
    v_extra := jsonb_build_object('id', v_id);

  when 'set_image' then
    v_id := public.pos_uuid(d->>'id');
    if coalesce(d->>'image', '') <> ''
       and ((d->>'image') !~ '^data:image/(png|jpeg|jpg|webp);base64,' or length(d->>'image') > 350000) then
      return jsonb_build_object('ok', false, 'reason', 'invalid_image');
    end if;
    update public.products set image = nullif(d->>'image', '') where id = v_id and brand_id = v_brand;
    if not found then
      return jsonb_build_object('ok', false, 'reason', 'product_not_found');
    end if;

  when 'get_image' then
    return jsonb_build_object('ok', true, 'image', (select p.image from public.products p where p.id = public.pos_uuid(d->>'id') and p.brand_id = v_brand));

  when 'delete_product' then
    v_id := public.pos_uuid(d->>'id');
    if not exists (select 1 from public.products p where p.id = v_id and p.brand_id = v_brand) then
      return jsonb_build_object('ok', false, 'reason', 'product_not_found');
    end if;
    if exists (select 1 from public.order_items oi where oi.product_id = v_id) then
      -- sold before: kept for the old bills and reports, but stopped and hidden
      update public.products set is_available = false, show_in_menu = false where id = v_id;
      v_extra := jsonb_build_object('archived', true);
    else
      delete from public.product_modifier_groups where product_id = v_id;
      delete from public.recipes where product_id = v_id;
      delete from public.products where id = v_id;
    end if;
    insert into public.settings_logs (staff_id, action, details)
    values (c.staff_id, 'delete_product', jsonb_build_object('product_id', v_id, 'archived', v_extra ? 'archived'));

  when 'add_ingredient' then
    v_name := nullif(btrim(coalesce(d->>'name', '')), '');
    if v_name is null or length(v_name) > 100 or nullif(btrim(coalesce(d->>'unit', '')), '') is null then
      return jsonb_build_object('ok', false, 'reason', 'invalid_name');
    end if;
    select i.id into v_id from public.ingredients i where btrim(i.name) = v_name and (i.brand_id is null or i.brand_id = v_brand) limit 1;
    if v_id is null then
      insert into public.ingredients (name, unit, cost_per_unit, min_stock_alert, brand_id)
      values (v_name, left(btrim(d->>'unit'), 20), coalesce(public.pos_amount(d->>'cost_per_unit'), 0),
              coalesce(nullif((public.pos_app_settings(c.company_id) -> 'inventory' ->> 'default_min_stock'), '')::numeric, 0), v_brand)
      returning id into v_id;
      v_extra := jsonb_build_object('id', v_id, 'existing', false);
    else
      v_extra := jsonb_build_object('id', v_id, 'existing', true);
    end if;

  when 'import' then
    -- the whole menu at once: [{category, name, price, description, station}]. Same name = price/category updated.
    if jsonb_typeof(d->'rows') is distinct from 'array' or jsonb_array_length(d->'rows') > 1000 then
      return jsonb_build_object('ok', false, 'reason', 'invalid_items');
    end if;
    for r in select e.value from jsonb_array_elements(d->'rows') e(value) loop
      v_name := nullif(btrim(coalesce(r->>'name', '')), '');
      v_num := public.pos_amount(r->>'price');
      if v_name is null or length(v_name) > 150 or v_num is null or nullif(btrim(coalesce(r->>'category', '')), '') is null
         or coalesce(r->>'station', 'kitchen') not in ('kitchen', 'bar', 'shisha') then
        return jsonb_build_object('ok', false, 'reason', 'invalid_items', 'row', r);
      end if;
      select x.id into v_cat from public.categories x where x.brand_id = v_brand and btrim(x.name) = btrim(r->>'category') limit 1;
      if v_cat is null then
        insert into public.categories (brand_id, name, station, sort_order)
        values (v_brand, left(btrim(r->>'category'), 100), coalesce(r->>'station', 'kitchen'),
                coalesce((select max(x.sort_order) + 1 from public.categories x where x.brand_id = v_brand), 0))
        returning id into v_cat;
      end if;
      select p.id into v_id from public.products p where p.brand_id = v_brand and btrim(p.name) = v_name limit 1;
      if v_id is null then
        insert into public.products (brand_id, category_id, name, price, is_available, description, sort_order)
        values (v_brand, v_cat, v_name, round(v_num, 2), true, nullif(btrim(coalesce(r->>'description', '')), ''),
                coalesce((select max(p.sort_order) + 1 from public.products p where p.category_id = v_cat), 0));
        v_created := v_created + 1;
      else
        update public.products set price = round(v_num, 2), category_id = v_cat,
               description = coalesce(nullif(btrim(coalesce(r->>'description', '')), ''), description)
         where id = v_id;
        v_updated := v_updated + 1;
      end if;
    end loop;
    insert into public.settings_logs (staff_id, action, details)
    values (c.staff_id, 'menu_import', jsonb_build_object('created', v_created, 'updated', v_updated));
    v_extra := jsonb_build_object('created', v_created, 'updated', v_updated);

  when 'import_recipes' then
    -- [{product, ingredient, unit, qty}] grouped by product. A product that already has a recipe is kept
    -- (unless overwrite = true). Missing ingredients are created with cost 0 (purchases set the cost later).
    if jsonb_typeof(d->'rows') is distinct from 'array' or jsonb_array_length(d->'rows') > 3000 then
      return jsonb_build_object('ok', false, 'reason', 'invalid_items');
    end if;
    for r in select e.value from jsonb_array_elements(d->'rows') e(value) loop
      v_name := nullif(btrim(coalesce(r->>'ingredient', '')), '');
      v_num := public.pos_amount(r->>'qty');
      if v_name is null or length(v_name) > 100 or v_num is null or nullif(btrim(coalesce(r->>'unit', '')), '') is null
         or nullif(btrim(coalesce(r->>'product', '')), '') is null then
        return jsonb_build_object('ok', false, 'reason', 'invalid_items', 'row', r);
      end if;
    end loop;
    drop table if exists pg_temp.mp_rec;
    create temporary table mp_rec (product_id uuid, ingredient_id uuid, qty numeric) on commit drop;
    for r in select e.value from jsonb_array_elements(d->'rows') e(value) loop
      select p.id into v_id from public.products p where p.brand_id = v_brand and btrim(p.name) = btrim(r->>'product') limit 1;
      if v_id is null then
        v_extra := jsonb_set(v_extra, '{missing}', coalesce(v_extra->'missing', '[]'::jsonb) || to_jsonb(btrim(r->>'product')));
        continue;
      end if;
      select i.id into v_cat from public.ingredients i where btrim(i.name) = btrim(r->>'ingredient') and (i.brand_id is null or i.brand_id = v_brand) limit 1;
      if v_cat is null then
        insert into public.ingredients (name, unit, cost_per_unit, min_stock_alert, brand_id)
        values (left(btrim(r->>'ingredient'), 100), left(btrim(r->>'unit'), 20), 0, 0, v_brand) returning id into v_cat;
        v_created := v_created + 1;
      end if;
      insert into pg_temp.mp_rec values (v_id, v_cat, public.pos_amount(r->>'qty'));
    end loop;
    select count(distinct x.product_id) into v_updated from pg_temp.mp_rec x
     where coalesce((d->>'overwrite')::boolean, false) or not exists (select 1 from public.recipes rr where rr.product_id = x.product_id);
    v_extra := v_extra || jsonb_build_object('skipped', (select count(distinct x.product_id) from pg_temp.mp_rec x
       where not coalesce((d->>'overwrite')::boolean, false) and exists (select 1 from public.recipes rr where rr.product_id = x.product_id)));
    delete from public.recipes rr using (select distinct product_id from pg_temp.mp_rec) x
     where rr.product_id = x.product_id and coalesce((d->>'overwrite')::boolean, false);
    insert into public.recipes (product_id, ingredient_id, quantity_required)
    select x.product_id, x.ingredient_id, sum(x.qty) from pg_temp.mp_rec x
     where not exists (select 1 from public.recipes rr where rr.product_id = x.product_id)
     group by 1, 2;
    insert into public.settings_logs (staff_id, action, details)
    values (c.staff_id, 'recipes_import', jsonb_build_object('products', v_updated, 'new_ingredients', v_created));
    v_extra := v_extra || jsonb_build_object('imported', v_updated, 'new_ingredients', v_created);

  else
    return jsonb_build_object('ok', false, 'reason', 'unknown_action');
  end case;

  return jsonb_build_object('ok', true) || v_extra || public.pos_menu_admin_data(v_brand);
end;
$$;


-- what we need to buy: ingredients used in the menu with nothing in this store, or at/below their minimum
create or replace function public.inv_shopping_secure(p_token text, p_warehouse_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
  v_brand uuid;
begin
  select * into c from public.pos_ctx(p_token, 'inventory');
  if not public.pos_warehouse_ok(p_warehouse_id, c.branch_id, c.role_name) then
    return jsonb_build_object('ok', false, 'reason', 'warehouse_not_allowed');
  end if;
  select b.brand_id into v_brand from public.branches b where b.id = c.branch_id;
  return jsonb_build_object('ok', true, 'items', coalesce((
    select jsonb_agg(jsonb_build_object(
             'ingredient_id', q.id, 'name', q.name, 'unit', q.unit, 'quantity', q.qty, 'min_stock_alert', q.min_qty,
             'cost_per_unit', q.cost, 'used_in', q.used_in, 'products', q.products, 'no_amounts', q.no_amounts,
             'reason', case when q.qty <= 0 then 'none' else 'low' end) order by q.qty > 0, q.used_in desc, q.name)
      from (select i.id, i.name, i.unit, coalesce(ws.quantity, 0) as qty, coalesce(i.min_stock_alert, 0) as min_qty,
                   coalesce(i.cost_per_unit, 0) as cost,
                   (select count(distinct r.product_id) from public.recipes r join public.products p on p.id = r.product_id
                     where r.ingredient_id = i.id and p.is_available is not false) as used_in,
                   (select string_agg(x.name, '، ' order by x.name) from (
                      select distinct p.name from public.recipes r join public.products p on p.id = r.product_id
                       where r.ingredient_id = i.id and p.is_available is not false order by p.name limit 6) x) as products,
                   (select count(*) from public.recipes r where r.ingredient_id = i.id and r.quantity_required = 0) as no_amounts
              from public.ingredients i
              left join public.warehouse_stock ws on ws.ingredient_id = i.id and ws.warehouse_id = p_warehouse_id
             where (i.brand_id is null or v_brand is null or i.brand_id = v_brand)) q
     where (q.used_in > 0 and q.qty <= 0) or (q.min_qty > 0 and q.qty <= q.min_qty)), '[]'::jsonb));
end;
$$;

create or replace function public.motionpos_version_public()
returns text
language sql
immutable
as $$
  select '026'
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
  v_company uuid; v_brand uuid; v_branch uuid; v_wh uuid; v_owner uuid; v_prod uuid; v_cat uuid;
  v_to text := 'mp-t26-o-' || md5(random()::text || clock_timestamp()::text);
  v_res jsonb;
begin
  begin
    insert into public.companies (name) values ('selftest026') returning id into v_company;
    insert into public.brands (company_id, name) values (v_company, 'selftest026') returning id into v_brand;
    insert into public.branches (name, brand_id) values ('selftest026', v_brand) returning id into v_branch;
    insert into public.warehouses (name, branch_id, is_main) values ('selftest026', v_branch, true) returning id into v_wh;
    insert into public.staff (name, role_id, branch_id, company_id, is_active)
    values ('selftest026 o', (select id from public.roles where name = 'owner'), v_branch, v_company, true) returning id into v_owner;
    insert into public.staff_sessions (token_hash, staff_id, expires_at)
    values (encode(extensions.digest(v_to, 'sha256'), 'hex'), v_owner, now() + interval '10 minutes');
    insert into public.categories (brand_id, name) values (v_brand, 'selftest026') returning id into v_cat;
    insert into public.products (brand_id, category_id, name, price, is_available) values (v_brand, v_cat, 'selftest026 عصير', 50, true) returning id into v_prod;
    -- quantity 0 is accepted (amount not known yet)
    v_res := public.menu_admin_secure(v_to, 'import_recipes', jsonb_build_object('rows', jsonb_build_array(
      jsonb_build_object('product', 'selftest026 عصير', 'ingredient', 'selftest026 مانجو', 'unit', 'كيلو', 'qty', '0'),
      jsonb_build_object('product', 'selftest026 عصير', 'ingredient', 'selftest026 سكر', 'unit', 'كيلو', 'qty', '0.04'))));
    if not coalesce((v_res->>'ok')::boolean, false) or (v_res->>'imported')::int <> 1 then
      raise exception 'SELFTEST zero amount refused: %', v_res - 'products' - 'categories' - 'ingredients';
    end if;
    -- a line with 0 takes nothing from the store
    if (select count(*) from public.recipes r where r.product_id = v_prod) <> 2 then raise exception 'SELFTEST recipe lines missing'; end if;
    -- both ingredients show in the shopping list (used in the menu, nothing in the store)
    v_res := public.inv_shopping_secure(v_to, v_wh);
    if not coalesce((v_res->>'ok')::boolean, false)
       or (select count(*) from jsonb_array_elements(v_res->'items') e where e->>'name' like 'selftest026%') <> 2 then
      raise exception 'SELFTEST shopping list wrong: %', v_res;
    end if;
    -- saving the product keeps the 0 line
    v_res := public.menu_admin_secure(v_to, 'save_product', jsonb_build_object('id', v_prod, 'name', 'selftest026 عصير', 'price', '50', 'category_id', v_cat,
      'recipe', jsonb_build_array(jsonb_build_object('ingredient_id', (select id from public.ingredients where name = 'selftest026 مانجو'), 'qty', '0'))));
    if not coalesce((v_res->>'ok')::boolean, false) then raise exception 'SELFTEST save with 0 refused: %', v_res->>'reason'; end if;
    raise notice 'MOTIONPOS-026-SELFTEST-OK';
    raise exception using errcode = 'P0099', message = 'selftest_rollback';
  exception when sqlstate 'P0099' then
    null;
  end;
end;
$selftest$;

notify pgrst, 'reload schema';

commit;
