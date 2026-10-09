-- 027_ingredient_packs.sql
-- An ingredient keeps its unit (kilo / liter / piece...) for stock, recipes and cost, and may have a pack it is bought in
-- (gallon, carton...) with how many units are inside. The screens show two linked boxes (pack <-> unit, gram <-> kilo).
-- Rules: begin/commit, preflight, rolled-back self-test, grants loop. Two new columns on a synced table.

begin;

do $preflight$
begin
  if length('إكراميات') <> 8 then
    raise exception 'file_encoding_broken: read the file as UTF-8';
  end if;
  if public.motionpos_version_public() not in ('026', '027') then
    raise exception 'schema_preflight_failed: run 026 first';
  end if;
end;
$preflight$;

alter table public.ingredients add column if not exists pack_unit text;
alter table public.ingredients add column if not exists pack_size numeric;
do $chk$
begin
  if not exists (select 1 from pg_constraint where conname = 'ingredients_pack_size_check') then
    alter table public.ingredients add constraint ingredients_pack_size_check check (pack_size is null or pack_size > 0);
  end if;
end;
$chk$;
select public.pos_sync_attach_all();


-- settings (same as 012) + the pack of an ingredient
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


-- menu screen data (same as 021) + the pack of an ingredient
create or replace function public.pos_menu_admin_data(p_brand uuid)
returns jsonb
language sql
stable
security definer
set search_path = public, extensions
as $$
  select jsonb_build_object(
    'categories', coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'name', x.name, 'station', coalesce(x.station, 'kitchen'),
                                   'sort_order', x.sort_order, 'show_in_menu', x.show_in_menu,
                                   'products', (select count(*) from public.products p where p.category_id = x.id)) order by x.sort_order, x.name)
                              from public.categories x where x.brand_id = p_brand), '[]'::jsonb),
    'products', coalesce((select jsonb_agg(jsonb_build_object(
                     'id', p.id, 'name', p.name, 'price', p.price, 'category_id', p.category_id, 'is_available', coalesce(p.is_available, true),
                     'show_in_menu', p.show_in_menu, 'description', p.description, 'sort_order', p.sort_order,
                     'has_image', coalesce(p.image, '') <> '',
                     'cost', round(public.pos_product_cost(p.id), 2),
                     'sold', exists (select 1 from public.order_items oi where oi.product_id = p.id),
                     'recipe', coalesce((select jsonb_agg(jsonb_build_object('ingredient_id', r.ingredient_id, 'qty', r.quantity_required)
                                                          order by i.name)
                                           from public.recipes r join public.ingredients i on i.id = r.ingredient_id
                                          where r.product_id = p.id), '[]'::jsonb),
                     'group_ids', coalesce((select jsonb_agg(g.group_id) from public.product_modifier_groups g where g.product_id = p.id), '[]'::jsonb))
                   order by p.sort_order, p.name)
                   from public.products p where p.brand_id = p_brand), '[]'::jsonb),
    'ingredients', coalesce((select jsonb_agg(jsonb_build_object('id', i.id, 'name', i.name, 'unit', i.unit, 'cost_per_unit', coalesce(i.cost_per_unit, 0), 'pack_unit', i.pack_unit, 'pack_size', i.pack_size)
                                              order by i.name)
                               from public.ingredients i where i.brand_id is null or i.brand_id = p_brand), '[]'::jsonb),
    'groups', coalesce((select jsonb_agg(jsonb_build_object('id', g.id, 'name', g.name,
                                 'modifiers', (select count(*) from public.modifiers m where m.group_id = g.id)) order by g.name)
                          from public.modifier_groups g where g.brand_id = p_brand), '[]'::jsonb))
$$;


create or replace function public.motionpos_version_public()
returns text
language sql
immutable
as $$
  select '027'
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
  v_company uuid; v_brand uuid; v_branch uuid; v_owner uuid; v_ing uuid;
  v_to text := 'mp-t27-o-' || md5(random()::text || clock_timestamp()::text);
  v_res jsonb;
begin
  begin
    insert into public.companies (name) values ('selftest027') returning id into v_company;
    insert into public.brands (company_id, name) values (v_company, 'selftest027') returning id into v_brand;
    insert into public.branches (name, brand_id) values ('selftest027', v_brand) returning id into v_branch;
    insert into public.staff (name, role_id, branch_id, company_id, is_active)
    values ('selftest027 o', (select id from public.roles where name = 'owner'), v_branch, v_company, true) returning id into v_owner;
    insert into public.staff_sessions (token_hash, staff_id, expires_at)
    values (encode(extensions.digest(v_to, 'sha256'), 'hex'), v_owner, now() + interval '10 minutes');
    v_res := public.settings2_secure(v_to, 'save_ingredient', jsonb_build_object('name', 'selftest027 لبن', 'unit', 'لتر', 'min_stock_alert', '2',
                                                                                'pack_unit', 'جالون', 'pack_size', '3'));
    if not coalesce((v_res->>'ok')::boolean, false) then raise exception 'SELFTEST save with pack: %', v_res; end if;
    select id into v_ing from public.ingredients where name = 'selftest027 لبن';
    if (select pack_unit || '/' || pack_size::text from public.ingredients where id = v_ing) <> 'جالون/3' then raise exception 'SELFTEST pack not saved'; end if;
    v_res := public.settings2_secure(v_to, 'save_ingredient', jsonb_build_object('id', v_ing, 'name', 'selftest027 لبن', 'unit', 'لتر', 'pack_unit', 'جالون', 'pack_size', '0'));
    if coalesce(v_res->>'reason', '') <> 'invalid_value' then raise exception 'SELFTEST pack without size accepted'; end if;
    v_res := public.settings2_secure(v_to, 'save_ingredient', jsonb_build_object('id', v_ing, 'name', 'selftest027 لبن', 'unit', 'لتر', 'pack_unit', '', 'pack_size', ''));
    if (select pack_unit from public.ingredients where id = v_ing) is not null then raise exception 'SELFTEST pack not removed'; end if;
    if not exists (select 1 from jsonb_array_elements(public.pos_menu_admin_data(v_brand)->'ingredients') e where e ? 'pack_unit') then
      raise exception 'SELFTEST menu data without pack';
    end if;
    raise notice 'MOTIONPOS-027-SELFTEST-OK';
    raise exception using errcode = 'P0099', message = 'selftest_rollback';
  exception when sqlstate 'P0099' then
    null;
  end;
end;
$selftest$;

notify pgrst, 'reload schema';

commit;
