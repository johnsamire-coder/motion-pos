-- 045_audit_log.sql
-- Who did what: every insert / change / delete in the program's main tables is written to audit_log with the person
-- logged in, the time, the table, the record and, for a change, each field from old to new. Secrets (PINs, tokens,
-- hashes) are never written. The owner reads it in staff > activity log, with filters.
--   * require_session (copied from 003) also keeps the logged-in person for the rest of the request
--     (set_config motionpos.staff_id, local to the transaction), so one trigger knows who it is;
--   * pos_audit_row: one trigger function on 57 tables (orders, payments, menu, stock items, purchases, expenses,
--     staff, settings, accounts, shifts ...); copies coming from the sync and the program reset are not logged;
--   * audit_log_secure: owner only, by period / person / area / action / text, newest first (500 a page).
-- Logins / logouts (staff_sessions) are logged too. Changes that only touch updated_at are skipped.
-- Rules: begin/commit, preflight (needs 044), version bump to 045, grants loop, rolled-back self-test.

begin;

do $preflight$
begin
  if length('إكراميات') <> 8 then
    raise exception 'file_encoding_broken: read the file as UTF-8';
  end if;
  if public.motionpos_version_public() not in ('044', '045') then
    raise exception 'schema_preflight_failed: run 044 first';
  end if;
end;
$preflight$;

-- ---------------------------------------------------------------- 1) the log
create table if not exists public.audit_log (
  id bigserial primary key,
  at timestamptz not null default now(),
  staff_id uuid,
  table_name text not null,
  action text not null check (action in ('insert', 'update', 'delete')),
  row_id text,
  label text,
  changes jsonb
);
alter table public.audit_log enable row level security;
create index if not exists audit_log_at_idx on public.audit_log (at desc);
create index if not exists audit_log_staff_idx on public.audit_log (staff_id, at desc);
create index if not exists audit_log_table_idx on public.audit_log (table_name, at desc);
create index if not exists audit_log_row_idx on public.audit_log (row_id);

-- ---------------------------------------------------------------- 2) who is logged in (copied from 003 + one line)
create or replace function public.require_session(p_token text)
returns table (staff_id uuid, company_id uuid, branch_id uuid, role_name text)
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  return query
    select st.id, st.company_id, st.branch_id, coalesce(r.name, 'cashier')::text
      from public.staff_sessions ss
      join public.staff st on st.id = ss.staff_id
      left join public.roles r on r.id = st.role_id
     where ss.token_hash = encode(extensions.digest(coalesce(p_token, ''), 'sha256'), 'hex')
       and ss.revoked_at is null
       and ss.expires_at > now()
       and st.is_active = true;
  if not found then
    raise exception 'session_invalid' using errcode = '28000';
  end if;
  -- who is doing this, for the audit log (045): kept until the end of this request only
  perform set_config('motionpos.staff_id',
    (select st.id::text from public.staff_sessions ss join public.staff st on st.id = ss.staff_id
      where ss.token_hash = encode(extensions.digest(coalesce(p_token, ''), 'sha256'), 'hex') limit 1), true);
end;
$$;

-- ---------------------------------------------------------------- 3) the trigger
create or replace function public.pos_audit_mask(p jsonb)
returns jsonb
language sql
immutable
as $$
  select coalesce(jsonb_object_agg(e.key, case when e.key ~ '(pin|token|hash|password|secret)' then to_jsonb('***'::text) else e.value end), '{}'::jsonb)
    from jsonb_each(coalesce(p, '{}'::jsonb)) e
$$;

create or replace function public.pos_audit_row()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_old jsonb;
  v_new jsonb;
  v_row jsonb;
  v_changes jsonb;
  v_staff uuid;
begin
  if coalesce(current_setting('motionpos.sync_apply', true), '') = 'on' or coalesce(current_setting('motionpos.system_reset', true), '') = 'on' then
    return null;
  end if;
  begin
    v_staff := nullif(current_setting('motionpos.staff_id', true), '')::uuid;
  exception when others then
    v_staff := null;
  end;
  if tg_op <> 'INSERT' then v_old := to_jsonb(old); end if;
  if tg_op <> 'DELETE' then v_new := to_jsonb(new); end if;
  v_row := coalesce(v_new, v_old);
  -- logins / logouts: the person is the one in the row
  if tg_table_name = 'staff_sessions' then
    v_staff := coalesce(v_staff, public.pos_uuid(v_row ->> 'staff_id'));
  end if;
  if tg_op = 'UPDATE' then
    -- compared before hiding secrets, so "the PIN was changed" is logged without the PIN
    select jsonb_object_agg(k, case when k ~ '(pin|token|hash|password|secret)' then jsonb_build_array('***', 'تم التغيير')
                                    else jsonb_build_array(v_old -> k, v_new -> k) end) into v_changes
      from jsonb_object_keys(v_new) k
     where (v_old -> k) is distinct from (v_new -> k) and k not in ('updated_at', 'last_seen_at');
    if v_changes is null then
      return null;
    end if;
  else
    v_changes := public.pos_audit_mask(v_row);
  end if;
  insert into public.audit_log (staff_id, table_name, action, row_id, label, changes)
  values (v_staff, tg_table_name, lower(tg_op), v_row ->> 'id',
          left(coalesce(v_row ->> 'order_number', v_row ->> 'po_number', v_row ->> 'entry_number', v_row ->> 'grn_number',
                        v_row ->> 'name', v_row ->> 'name_ar', v_row ->> 'table_number', v_row ->> 'customer_name',
                        v_row ->> 'reason', v_row ->> 'description', v_row ->> 'section', v_row ->> 'key', v_row ->> 'perm',
                        case when tg_table_name = 'staff_sessions' then case when tg_op = 'INSERT' then 'دخول' else 'خروج' end end), 120),
          v_changes);
  return null;
end;
$$;

do $attach$
declare
  t text;
begin
  foreach t in array array['staff_sessions', 'orders', 'order_items', 'payments', 'order_splits', 'hospitality_orders', 'qr_orders', 'products', 'categories', 'recipes', 'modifiers', 'modifier_groups', 'product_modifier_groups', 'ingredients', 'discounts', 'cancel_reasons', 'tables', 'areas', 'branches', 'warehouses', 'staff', 'roles', 'role_permissions', 'app_settings', 'pos_settings', 'branch_tax_settings', 'suppliers', 'purchase_orders', 'purchase_order_items', 'goods_receipts', 'supplier_invoices', 'supplier_payments', 'expenses', 'expense_categories', 'expense_recurring', 'custody_ledger', 'customers', 'customer_ledger', 'customer_followups', 'customer_feedback', 'journal_entries', 'accounts', 'fiscal_periods', 'pos_shifts', 'pos_cash_moves', 'pos_days', 'waste_logs', 'stock_takes', 'inv_counts', 'inv_transfers', 'staff_attendance', 'staff_ledger', 'payroll_runs', 'payroll_lines', 'tip_payouts', 'companies', 'cash_bank_accounts', 'payment_method_account_mappings'] loop
    if to_regclass('public.' || t) is not null then
      execute format('drop trigger if exists trg_audit on public.%I', t);
      execute format('create trigger trg_audit after insert or update or delete on public.%I for each row execute function public.pos_audit_row()', t);
    end if;
  end loop;
end;
$attach$;

-- ---------------------------------------------------------------- 4) the owner reads it
-- p_filters: staff_id, table, action, search (record / any changed value)
create or replace function public.audit_log_secure(p_token text, p_from date, p_to date, p_filters jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
declare
  c record;
  f jsonb := coalesce(p_filters, '{}'::jsonb);
  v_from date := coalesce(p_from, public.pos_local_date(now()));
  v_to date := coalesce(p_to, public.pos_local_date(now()));
  v_staff uuid := public.pos_uuid(f->>'staff_id');
  v_table text := nullif(f->>'table', '');
  v_action text := nullif(f->>'action', '');
  v_search text := nullif(btrim(coalesce(f->>'search', '')), '');
  v_before bigint := public.pos_num(f->>'before_id')::bigint;
begin
  select * into c from public.pos_ctx(p_token, null);
  if c.role_name <> 'owner' then
    return jsonb_build_object('ok', false, 'reason', 'owner_only');
  end if;
  if v_to < v_from or v_to - v_from > 366 then
    return jsonb_build_object('ok', false, 'reason', 'invalid_period');
  end if;
  return jsonb_build_object('ok', true, 'from', v_from, 'to', v_to,
    'staff', coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name) order by s.name)
                         from public.staff s where s.company_id = c.company_id), '[]'::jsonb),
    'rows', coalesce((
      select jsonb_agg(jsonb_build_object('id', q.id, 'at', q.at, 'staff', q.staff, 'table', q.table_name, 'action', q.action,
                                          'row_id', q.row_id, 'label', q.label, 'changes', q.changes) order by q.id desc)
        from (select a.*, s.name as staff
                from public.audit_log a left join public.staff s on s.id = a.staff_id
               where public.pos_local_date(a.at) between v_from and v_to
                 and (a.staff_id is null or s.company_id = c.company_id)
                 and (v_staff is null or a.staff_id = v_staff)
                 and (v_table is null or a.table_name = v_table)
                 and (v_action is null or a.action = v_action)
                 and (v_before is null or a.id < v_before)
                 and (v_search is null or a.label ilike '%' || v_search || '%' or a.changes::text ilike '%' || v_search || '%')
               order by a.id desc
               limit 500) q), '[]'::jsonb));
end;
$$;

create or replace function public.motionpos_version_public()
returns text
language sql
immutable
as $$
  select '045'
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
  v_sid uuid;
  v_tok text;
  v_cat uuid;
  v_res jsonb;
  v_n int;
begin
  begin
    perform set_config('motionpos.sync_apply', 'off', true);
    insert into public.companies (name) values ('selftest045') returning id into v_co;
    insert into public.branches (name) values ('selftest045') returning id into v_br;
    insert into public.staff (name, company_id, branch_id, is_active, pin_hash, role_id)
    values ('selftest045', v_co, v_br, true, extensions.crypt('4745', extensions.gen_salt('bf')), (select id from public.roles where name = 'owner' limit 1))
    returning id into v_sid;
    v_tok := public.staff_login('4745')->>'session_token';
    perform public.require_session(v_tok);
    insert into public.categories (name) values ('st045 drinks') returning id into v_cat;
    update public.categories set name = 'st045 cold drinks' where id = v_cat;
    update public.staff set pin_hash = extensions.crypt('4746', extensions.gen_salt('bf')) where id = v_sid;
    -- the change is logged with the person, old -> new; the PIN never shows
    select count(*) into v_n from public.audit_log where row_id = v_cat::text and staff_id = v_sid;
    if v_n <> 2 then raise exception 'SELFTEST logged %', v_n; end if;
    if (select changes -> 'name' ->> 1 from public.audit_log where row_id = v_cat::text and action = 'update') <> 'st045 cold drinks' then
      raise exception 'SELFTEST old -> new';
    end if;
    if exists (select 1 from public.audit_log where row_id = v_sid::text and changes::text like '%$2%') then
      raise exception 'SELFTEST pin written';
    end if;
    if not exists (select 1 from public.audit_log where row_id = v_sid::text and action = 'update' and changes ? 'pin_hash') then
      raise exception 'SELFTEST pin change not logged';
    end if;
    if not exists (select 1 from public.audit_log where table_name = 'staff_sessions' and staff_id = v_sid and label = 'دخول') then
      raise exception 'SELFTEST login not logged';
    end if;
    v_res := public.audit_log_secure(v_tok, null, null, jsonb_build_object('search', 'cold drinks'));
    if jsonb_array_length(v_res->'rows') <> 1 then raise exception 'SELFTEST read %', v_res; end if;
    if public.motionpos_version_public() <> '045' then raise exception 'SELFTEST version'; end if;
    raise notice 'MOTIONPOS-045-SELFTEST-OK';
    raise exception using errcode = 'P0099', message = 'selftest_rollback';
  exception when sqlstate 'P0099' then
    null;
  end;
end;
$selftest$;

notify pgrst, 'reload schema';

commit;
