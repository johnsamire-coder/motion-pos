-- 041_journal_by_account.sql
-- Journal list: show only the entries that touch one account (e.g. 1130 staff receivables, 2100 suppliers), with what
-- each entry did to it (debit / credit). Used by the quick buttons on the journal tab and by clicking an account in
-- the balance sheet / trial balance. journal_list_secure gets p_account_id (default null = all, as before); the old
-- 6-argument version is dropped so the API has one function. Copied from 038 with only this added. No tables changed.
-- Rules: begin/commit, preflight (needs 040), version bump to 041, grants loop, rolled-back self-test.

begin;

do $preflight$
begin
  if length('إكراميات') <> 8 then
    raise exception 'file_encoding_broken: read the file as UTF-8';
  end if;
  if public.motionpos_version_public() not in ('040', '041') then
    raise exception 'schema_preflight_failed: run 040 first';
  end if;
end;
$preflight$;

drop function if exists public.journal_list_secure(text, date, date, uuid, text, text);

-- copied from 038 + the account filter
create or replace function public.journal_list_secure(p_token text, p_from date, p_to date, p_branch_id uuid, p_type text, p_search text,
                                               p_account_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_lim date;
  c record;
  v_branch uuid;
begin
  select * into c from public.pos_ctx(p_token, 'accounting');
  -- the period this role may look at (settings > staff > permissions); null = everything
  v_lim := public.pos_view_min(c.company_id, c.role_name, 'accounting');
  if v_lim is not null then
    if coalesce(p_to, public.pos_local_date(now())) < v_lim then
      return public.pos_view_refusal(c.company_id, c.role_name, 'accounting');
    end if;
    p_from := greatest(coalesce(p_from, v_lim), v_lim);
  end if;
  v_branch := case when c.role_name = 'owner' then p_branch_id else c.branch_id end;
  return jsonb_build_object('ok', true, 'entries', coalesce((
    select jsonb_agg(to_jsonb(q) order by q.entry_date desc, q.entry_number desc) from (
      select je.id, je.entry_number, je.entry_date, je.journal_type, je.reference_type, je.description, je.status,
             b.name as branch, st.name as created_by,
             (select sum(l.debit) from public.journal_entry_lines l where l.journal_entry_id = je.id) as total,
             -- with an account chosen: what this entry did to that account
             (select sum(l.debit) from public.journal_entry_lines l where l.journal_entry_id = je.id and l.account_id = p_account_id) as account_debit,
             (select sum(l.credit) from public.journal_entry_lines l where l.journal_entry_id = je.id and l.account_id = p_account_id) as account_credit
        from public.journal_entries je
        left join public.branches b on b.id = je.branch_id
        left join public.staff st on st.id = je.created_by
       where je.company_id = c.company_id
         and je.entry_date between coalesce(p_from, current_date - 30) and coalesce(p_to, current_date)
         and (v_branch is null or je.branch_id = v_branch)
         and (p_type is null or p_type = '' or je.journal_type = p_type)
         and (p_account_id is null or exists (select 1 from public.journal_entry_lines l where l.journal_entry_id = je.id and l.account_id = p_account_id))
         and (p_search is null or p_search = '' or je.description ilike '%' || p_search || '%' or je.entry_number ilike '%' || p_search || '%')
       order by je.entry_date desc, je.entry_number desc
       limit 500) q), '[]'::jsonb));
end;
$$;

create or replace function public.motionpos_version_public()
returns text
language sql
immutable
as $$
  select '041'
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
  v_tok text;
  v_a uuid;
  v_b uuid;
  v_c uuid;
  v_je uuid;
  v_res jsonb;
begin
  begin
    perform set_config('motionpos.sync_apply', 'on', true);
    insert into public.companies (name) values ('selftest041') returning id into v_co;
    insert into public.branches (name) values ('selftest041') returning id into v_br;
    insert into public.staff (name, company_id, branch_id, is_active, pin_hash, role_id)
    values ('selftest041', v_co, v_br, true, extensions.crypt('4741', extensions.gen_salt('bf')), (select id from public.roles where name = 'owner' limit 1));
    v_tok := public.staff_login('4741')->>'session_token';
    insert into public.accounts (company_id, code, name_ar, account_type, normal_balance) values (v_co, '9101', 'a', 'asset', 'debit') returning id into v_a;
    insert into public.accounts (company_id, code, name_ar, account_type, normal_balance) values (v_co, '9102', 'b', 'asset', 'debit') returning id into v_b;
    insert into public.accounts (company_id, code, name_ar, account_type, normal_balance) values (v_co, '9103', 'c', 'asset', 'debit') returning id into v_c;
    insert into public.journal_entries (company_id, branch_id, entry_number, entry_date, journal_type, description, status)
    values (v_co, v_br, 'ST41-1', public.pos_local_date(now()), 'manual', 'x', 'posted') returning id into v_je;
    insert into public.journal_entry_lines (journal_entry_id, account_id, debit, credit) values (v_je, v_a, 70, 0), (v_je, v_b, 0, 70);
    v_res := public.journal_list_secure(v_tok, null, null, null, null, null, v_a);
    if jsonb_array_length(v_res->'entries') <> 1 or (v_res->'entries'->0->>'account_debit')::numeric <> 70 then raise exception 'SELFTEST account a %', v_res; end if;
    if jsonb_array_length(public.journal_list_secure(v_tok, null, null, null, null, null, v_c)->'entries') <> 0 then raise exception 'SELFTEST account c'; end if;
    if jsonb_array_length(public.journal_list_secure(v_tok, null, null, null, null, null)->'entries') <> 1 then raise exception 'SELFTEST no account'; end if;
    if to_regprocedure('public.journal_list_secure(text,date,date,uuid,text,text)') is not null then raise exception 'SELFTEST old one still there'; end if;
    if public.motionpos_version_public() <> '041' then raise exception 'SELFTEST version'; end if;
    raise notice 'MOTIONPOS-041-SELFTEST-OK';
    raise exception using errcode = 'P0099', message = 'selftest_rollback';
  exception when sqlstate 'P0099' then
    null;
  end;
end;
$selftest$;

notify pgrst, 'reload schema';

commit;
