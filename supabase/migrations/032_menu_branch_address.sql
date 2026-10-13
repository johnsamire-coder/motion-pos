-- 032_menu_branch_address.sql
-- QR menu: also return the branch address (branches.address) so the menu shows it under the branch name, for every branch.
-- One function changed: qr_menu_public (copied verbatim from the server + one key 'branch_address'). No tables changed.
-- Rules: begin/commit, preflight (needs 031), version bump to 032, grants loop, rolled-back self-test.

begin;

do $preflight$
begin
  if length('إكراميات') <> 8 then
    raise exception 'file_encoding_broken: read the file as UTF-8';
  end if;
  if public.motionpos_version_public() not in ('031', '032') then
    raise exception 'schema_preflight_failed: run 031 first';
  end if;
end;
$preflight$;

CREATE OR REPLACE FUNCTION public.qr_menu_public(p_qr text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
declare
  t record;
  s jsonb;
  tx record;
begin
  select * into t from public.pos_qr_table(p_qr);
  if t.table_id is null then
    return jsonb_build_object('ok', false, 'reason', 'not_found');
  end if;
  s := public.pos_app_settings(t.company_id);
  if not coalesce((s->'waiter_qr'->>'qr_enabled')::boolean, true) then
    return jsonb_build_object('ok', false, 'reason', 'qr_disabled');
  end if;
  select x.vat_percentage, x.service_charge_percentage, x.is_vat_inclusive into tx
    from public.branch_tax_settings x where x.branch_id = t.branch_id limit 1;
  return jsonb_build_object('ok', true,
    'company_name', s->'general'->>'company_name', 'logo', s->'general'->>'logo', 'currency', s->'general'->>'currency',
    'phone', s->'general'->>'phone', 'address', s->'general'->>'address',
    'branch', t.branch_name,
    'branch_address', (select nullif(btrim(b.address), '') from public.branches b where b.id = t.branch_id),
    'table_number', t.table_number,
    'call_waiter', coalesce((s->'waiter_qr'->>'qr_call_waiter')::boolean, true),
    'request_bill', coalesce((s->'waiter_qr'->>'qr_request_bill')::boolean, true),
    'show_prices', coalesce((s->'waiter_qr'->>'qr_show_prices')::boolean, true),
    'ordering', coalesce((s->'waiter_qr'->>'qr_ordering')::boolean, true),
    'welcome', s->'waiter_qr'->>'qr_welcome', 'privacy_note', s->'waiter_qr'->>'qr_privacy_note',
    'facebook_url', s->'social'->>'facebook_url', 'instagram_url', s->'social'->>'instagram_url',
    'feedback_token', case when coalesce((s->'social'->>'feedback_enabled')::boolean, true)
                           then (select b.public_token from public.branches b where b.id = t.branch_id) end,
    'store_offline', public.pos_qr_store_offline(t.branch_id),
    'payinfo', case when coalesce((s->'payinfo'->>'show_on_menu')::boolean, true) then s->'payinfo' end,
    'vat_percentage', coalesce(tx.vat_percentage, 0), 'service_percentage', coalesce(tx.service_charge_percentage, 0),
    'vat_inclusive', coalesce(tx.is_vat_inclusive, false),
    'categories', coalesce((
      select jsonb_agg(jsonb_build_object('id', cat.id, 'name', cat.name,
               'products', (select jsonb_agg(jsonb_build_object(
                                 'id', p.id, 'name', p.name, 'price', p.price, 'description', p.description,
                                 'has_image', coalesce(p.image, '') <> '',
                                 'groups', coalesce((
                                   select jsonb_agg(jsonb_build_object('id', g.id, 'name', g.name,
                                            'min', greatest(coalesce(g.min_selection, 0), case when coalesce(g.is_required, false) then 1 else 0 end),
                                            'max', coalesce(g.max_selection, 0),
                                            'modifiers', coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'name', m.name, 'price', m.price)
                                                                                    order by m.price, m.name)
                                                                     from public.modifiers m where m.group_id = g.id), '[]'::jsonb)) order by g.name)
                                     from public.product_modifier_groups pg join public.modifier_groups g on g.id = pg.group_id
                                    where pg.product_id = p.id
                                      and exists (select 1 from public.modifiers m where m.group_id = g.id)), '[]'::jsonb))
                               order by p.sort_order, p.name)
                              from public.products p
                             where p.category_id = cat.id and p.is_available is true and p.show_in_menu is true))
             order by cat.sort_order, cat.name)
        from public.categories cat
       where cat.brand_id = t.brand_id and cat.show_in_menu is true
         and exists (select 1 from public.products p where p.category_id = cat.id and p.is_available is true and p.show_in_menu is true)),
      '[]'::jsonb));
end;
$function$;

create or replace function public.motionpos_version_public()
returns text
language sql
immutable
as $$
  select '032'
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
  v_res jsonb;
begin
  begin
    v_res := public.qr_menu_public('motionpos-selftest-no-such-table');
    if v_res->>'reason' is distinct from 'not_found' then
      raise exception 'SELFTEST unknown table: %', v_res;
    end if;
    raise notice 'MOTIONPOS-032-SELFTEST-OK';
    raise exception using errcode = 'P0099', message = 'selftest_rollback';
  exception when sqlstate 'P0099' then
    null;
  end;
end;
$selftest$;

notify pgrst, 'reload schema';

commit;