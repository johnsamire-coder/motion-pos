-- 023_setup_edit.sql
-- Settings: edit / delete branches, warehouses, areas and tables (until now they could only be added).
--   * Branches: owner only. A branch with any history (orders, staff, shifts, expenses, purchases, stock, journal) is
--     never deleted, the reason comes back instead; the last branch is never deleted.
--   * Warehouses: deleted only if nothing ever moved in them. Areas: with their tables, if no table has orders.
--   * Tables: number + chairs editable (same number twice in one area refused).
-- Rules: begin/commit, preflight, rolled-back self-test, grants loop.

begin;

do $preflight$
begin
  if length('إكراميات') <> 8 then
    raise exception 'file_encoding_broken: read the file as UTF-8';
  end if;
  if public.motionpos_version_public() not in ('022', '023') then
    raise exception 'schema_preflight_failed: run 022 first';
  end if;
end;
$preflight$;

create or replace function public.setup_admin_secure(p_token text, p_action text, p_data jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
  d jsonb := coalesce(p_data, '{}'::jsonb);
  v_brand uuid;
  v_id uuid := public.pos_uuid(d->>'id');
  v_name text := nullif(btrim(coalesce(d->>'name', '')), '');
  v_n int;
  v_used text;
begin
  select * into c from public.pos_ctx(p_token, 'settings');
  if not public.pos_perm_ok(c.role_name, 'settings') then
    return jsonb_build_object('ok', false, 'reason', 'not_allowed');
  end if;
  select b.brand_id into v_brand from public.branches b where b.id = c.branch_id;

  if p_action in ('edit_branch', 'delete_branch') then
    if c.role_name <> 'owner' then
      return jsonb_build_object('ok', false, 'reason', 'owner_only');
    end if;
    if v_id is null or not exists (select 1 from public.branches b where b.id = v_id and b.brand_id = v_brand) then
      return jsonb_build_object('ok', false, 'reason', 'invalid_branch');
    end if;
  end if;

  if p_action = 'edit_branch' then
    if v_name is null or length(v_name) > 100 then
      return jsonb_build_object('ok', false, 'reason', 'invalid_name');
    end if;
    update public.branches set name = v_name, address = left(coalesce(btrim(d->>'address'), ''), 300),
           has_tables = coalesce((d->>'has_tables')::boolean, has_tables)
     where id = v_id;

  elsif p_action = 'delete_branch' then
    if (select count(*) from public.branches b where b.brand_id = v_brand) <= 1 then
      return jsonb_build_object('ok', false, 'reason', 'last_branch');
    end if;
    v_used := concat_ws('، ',
      case when exists (select 1 from public.orders o where o.branch_id = v_id) then 'طلبات' end,
      case when exists (select 1 from public.staff s where s.branch_id = v_id) then 'موظفين' end,
      case when exists (select 1 from public.pos_shifts s where s.branch_id = v_id) then 'ورديات' end,
      case when exists (select 1 from public.expenses e where e.branch_id = v_id) then 'مصروفات' end,
      case when exists (select 1 from public.purchase_orders p where p.branch_id = v_id) then 'مشتريات' end,
      case when exists (select 1 from public.stock_movements m where m.branch_id = v_id) then 'حركات مخزن' end,
      case when exists (select 1 from public.journal_entries j where j.branch_id = v_id) then 'قيود' end);
    if v_used <> '' then
      return jsonb_build_object('ok', false, 'reason', 'branch_in_use', 'used', v_used);
    end if;
    begin
      delete from public.tables t using public.areas a where a.id = t.area_id and a.branch_id = v_id;
      delete from public.areas where branch_id = v_id;
      delete from public.warehouse_stock ws using public.warehouses w where w.id = ws.warehouse_id and w.branch_id = v_id;
      delete from public.warehouses where branch_id = v_id;
      delete from public.branch_tax_settings where branch_id = v_id;
      delete from public.branches where id = v_id;
    exception when foreign_key_violation then
      return jsonb_build_object('ok', false, 'reason', 'branch_in_use', 'used', 'بيانات مربوطة بيه');
    end;

  elsif p_action in ('edit_warehouse', 'delete_warehouse') then
    if v_id is null or not exists (select 1 from public.warehouses w left join public.branches b on b.id = w.branch_id
                                    where w.id = v_id and (w.branch_id is null or b.brand_id = v_brand)
                                      and (c.role_name = 'owner' or w.branch_id = c.branch_id)) then
      return jsonb_build_object('ok', false, 'reason', 'warehouse_not_allowed');
    end if;
    if p_action = 'edit_warehouse' then
      if v_name is null or length(v_name) > 100 then
        return jsonb_build_object('ok', false, 'reason', 'invalid_name');
      end if;
      update public.warehouses set name = v_name where id = v_id;
    else
      if exists (select 1 from public.stock_movements m where m.warehouse_id = v_id)
         or exists (select 1 from public.purchase_orders p where p.warehouse_id = v_id)
         or exists (select 1 from public.warehouse_stock ws where ws.warehouse_id = v_id and ws.quantity <> 0) then
        return jsonb_build_object('ok', false, 'reason', 'warehouse_in_use');
      end if;
      begin
        delete from public.warehouse_stock where warehouse_id = v_id;
        delete from public.warehouses where id = v_id;
      exception when foreign_key_violation then
        return jsonb_build_object('ok', false, 'reason', 'warehouse_in_use');
      end;
    end if;

  elsif p_action in ('rename_area', 'delete_area') then
    if v_id is null or not exists (select 1 from public.areas a join public.branches b on b.id = a.branch_id
                                    where a.id = v_id and b.brand_id = v_brand and (c.role_name = 'owner' or a.branch_id = c.branch_id)) then
      return jsonb_build_object('ok', false, 'reason', 'area_not_found');
    end if;
    if p_action = 'rename_area' then
      if v_name is null or length(v_name) > 100 then
        return jsonb_build_object('ok', false, 'reason', 'invalid_name');
      end if;
      update public.areas set name = v_name where id = v_id;
    else
      if exists (select 1 from public.orders o join public.tables t on t.id = o.table_id where t.area_id = v_id)
         or exists (select 1 from public.orders o where o.area_id = v_id) then
        return jsonb_build_object('ok', false, 'reason', 'table_has_orders');
      end if;
      begin
        delete from public.tables where area_id = v_id;
        delete from public.areas where id = v_id;
      exception when foreign_key_violation then
        return jsonb_build_object('ok', false, 'reason', 'table_has_orders');
      end;
    end if;

  elsif p_action = 'edit_table' then
    if v_id is null or not exists (select 1 from public.tables t join public.areas a on a.id = t.area_id join public.branches b on b.id = a.branch_id
                                    where t.id = v_id and b.brand_id = v_brand and (c.role_name = 'owner' or a.branch_id = c.branch_id)) then
      return jsonb_build_object('ok', false, 'reason', 'table_not_found');
    end if;
    if nullif(btrim(coalesce(d->>'table_number', '')), '') is null or length(btrim(d->>'table_number')) > 20 then
      return jsonb_build_object('ok', false, 'reason', 'invalid_table_number');
    end if;
    if coalesce(d->>'capacity', '') !~ '^[1-9][0-9]{0,2}$' then
      return jsonb_build_object('ok', false, 'reason', 'invalid_capacity');
    end if;
    if exists (select 1 from public.tables x where x.area_id = (select t.area_id from public.tables t where t.id = v_id)
                 and btrim(x.table_number) = btrim(d->>'table_number') and x.id <> v_id) then
      return jsonb_build_object('ok', false, 'reason', 'table_number_taken');
    end if;
    update public.tables set table_number = btrim(d->>'table_number'), capacity = (d->>'capacity')::int where id = v_id;

  else
    return jsonb_build_object('ok', false, 'reason', 'unknown_action');
  end if;

  insert into public.settings_logs (staff_id, action, details) values (c.staff_id, p_action, d - 'image');
  return jsonb_build_object('ok', true);
end;
$$;

-- the same table number twice in one area is refused (also for "add table")
create or replace function public.trg_tables_unique_number()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if coalesce(current_setting('motionpos.sync_apply', true), '') = 'on' then
    return new;
  end if;
  if exists (select 1 from public.tables x where x.area_id = new.area_id and btrim(x.table_number) = btrim(new.table_number) and x.id <> new.id) then
    raise exception 'table_number_taken';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_tables_unique_number on public.tables;
create trigger trg_tables_unique_number
before insert on public.tables
for each row execute function public.trg_tables_unique_number();

create or replace function public.motionpos_version_public()
returns text
language sql
immutable
as $$
  select '023'
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
  v_company uuid; v_brand uuid; v_b1 uuid; v_b2 uuid; v_area uuid; v_t1 uuid; v_t2 uuid; v_wh uuid; v_owner uuid;
  v_tok text := 'mp-t23-o-' || md5(random()::text || clock_timestamp()::text);
  v_res jsonb;
begin
  begin
    insert into public.companies (name) values ('selftest023') returning id into v_company;
    insert into public.brands (company_id, name) values (v_company, 'selftest023') returning id into v_brand;
    insert into public.branches (name, brand_id) values ('st023 a', v_brand) returning id into v_b1;
    insert into public.branches (name, brand_id) values ('st023 b', v_brand) returning id into v_b2;
    insert into public.areas (branch_id, name) values (v_b2, 'st') returning id into v_area;
    insert into public.tables (area_id, table_number, capacity) values (v_area, '1', 4) returning id into v_t1;
    insert into public.tables (area_id, table_number, capacity) values (v_area, '2', 4) returning id into v_t2;
    insert into public.warehouses (name, branch_id) values ('st023', v_b2) returning id into v_wh;
    insert into public.staff (name, role_id, branch_id, company_id, is_active)
    values ('selftest023', (select id from public.roles where name = 'owner'), v_b1, v_company, true) returning id into v_owner;
    insert into public.staff_sessions (token_hash, staff_id, expires_at)
    values (encode(extensions.digest(v_tok, 'sha256'), 'hex'), v_owner, now() + interval '10 minutes');

    v_res := public.setup_admin_secure(v_tok, 'edit_table', jsonb_build_object('id', v_t2, 'table_number', '1', 'capacity', '6'));
    if coalesce(v_res->>'reason', '') <> 'table_number_taken' then raise exception 'SELFTEST duplicate table number accepted: %', v_res; end if;
    v_res := public.setup_admin_secure(v_tok, 'edit_table', jsonb_build_object('id', v_t2, 'table_number', '7', 'capacity', '6'));
    if (select table_number || '/' || capacity from public.tables where id = v_t2) <> '7/6' then raise exception 'SELFTEST table not edited'; end if;
    begin
      insert into public.tables (area_id, table_number, capacity) values (v_area, '1', 4);
      raise exception 'SELFTEST duplicate table added';
    exception when raise_exception then
      if sqlerrm <> 'table_number_taken' then raise; end if;
    end;
    v_res := public.setup_admin_secure(v_tok, 'edit_branch', jsonb_build_object('id', v_b2, 'name', 'فرع جديد', 'address', 'x', 'has_tables', false));
    if (select name from public.branches where id = v_b2) <> 'فرع جديد' then raise exception 'SELFTEST branch not edited: %', v_res; end if;
    v_res := public.setup_admin_secure(v_tok, 'delete_branch', jsonb_build_object('id', v_b1));
    if coalesce(v_res->>'reason', '') <> 'branch_in_use' then raise exception 'SELFTEST branch with staff deleted: %', v_res; end if;
    v_res := public.setup_admin_secure(v_tok, 'delete_branch', jsonb_build_object('id', v_b2));
    if not coalesce((v_res->>'ok')::boolean, false) or exists (select 1 from public.warehouses where id = v_wh) then
      raise exception 'SELFTEST empty branch not deleted: %', v_res;
    end if;
    v_res := public.setup_admin_secure(v_tok, 'delete_branch', jsonb_build_object('id', v_b1));
    if coalesce(v_res->>'reason', '') not in ('last_branch', 'branch_in_use') then raise exception 'SELFTEST last branch deleted'; end if;

    raise notice 'MOTIONPOS-023-SELFTEST-OK';
    raise exception using errcode = 'P0099', message = 'selftest_rollback';
  exception when sqlstate 'P0099' then
    null;
  end;
end;
$selftest$;

notify pgrst, 'reload schema';

commit;
