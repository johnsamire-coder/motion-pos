-- 042_journal_number_fix.sql
-- URGENT FIX: closing an order failed with "duplicate key value violates unique constraint
-- journal_entries_company_id_entry_number_key", and kept failing on every try.
-- Cause: generate_journal_entry_number gave "how many entries this year + 1". After entries were deleted (the invoice
-- wipe, the system reset) that count is below the last number, so the next number already exists and every new entry
-- (sale, cost, expense, purchase) is refused. The shop PC and the server also number on their own, so both could
-- make the same number for different entries and then clash when they sync.
-- Now: last number + 1 (not the count), one at a time per company (a lock, so two cashiers never get the same number),
-- and the shop PC copy uses its own series JE-YYYY-S000001 so it can never clash with the server's JE-YYYY-000001.
-- Old numbers stay as they are. Same function name and arguments, so nothing else changes.
-- Rules: begin/commit, preflight (needs 041), version bump to 042, rolled-back self-test. No Arabic in this file on purpose
-- (it can be pasted straight into the server screen).

begin;

do $preflight$
begin
  if public.motionpos_version_public() not in ('041', '042') then
    raise exception 'schema_preflight_failed: run 041 first';
  end if;
end;
$preflight$;

create or replace function public.generate_journal_entry_number(p_company_id uuid)
returns text
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_year text := to_char(current_date, 'YYYY');
  v_prefix text;
  v_last integer;
begin
  -- one number at a time per company (released at the end of the transaction)
  perform pg_advisory_xact_lock(hashtextextended('motionpos_je_number:' || coalesce(p_company_id::text, ''), 0));
  v_prefix := 'JE-' || v_year || '-'
              || case when coalesce((select n.node from public.sync_node n limit 1), 'cloud') = 'store' then 'S' else '' end;
  select max(substring(je.entry_number from length(v_prefix) + 1)::integer) into v_last
    from public.journal_entries je
   where je.company_id = p_company_id
     and left(je.entry_number, length(v_prefix)) = v_prefix
     and substring(je.entry_number from length(v_prefix) + 1) ~ '^[0-9]{1,9}$';
  return v_prefix || lpad((coalesce(v_last, 0) + 1)::text, 6, '0');
end;
$$;

revoke all on function public.generate_journal_entry_number(uuid) from public, anon, authenticated;

create or replace function public.motionpos_version_public()
returns text
language sql
immutable
as $$
  select '042'
$$;

do $selftest$
declare
  v_co uuid;
  v_y text := to_char(current_date, 'YYYY');
  v_n text;
  v_node text;
begin
  begin
    perform set_config('motionpos.sync_apply', 'on', true);
    select node into v_node from public.sync_node limit 1;
    update public.sync_node set node = 'cloud';
    insert into public.companies (name) values ('selftest042') returning id into v_co;
    -- the broken case: 2 entries left but the last number is 5 (entries 3 and 4 were deleted, so count + 1 = 3 ... and 5 exists)
    insert into public.journal_entries (company_id, entry_number, entry_date, journal_type, description, status)
    values (v_co, 'JE-' || v_y || '-000001', current_date, 'manual', 'x', 'draft'),
           (v_co, 'JE-' || v_y || '-000005', current_date, 'manual', 'x', 'draft'),
           (v_co, 'JE-' || v_y || '-S000009', current_date, 'manual', 'x', 'draft');
    v_n := public.generate_journal_entry_number(v_co);
    if v_n <> 'JE-' || v_y || '-000006' then raise exception 'SELFTEST cloud number %', v_n; end if;
    insert into public.journal_entries (company_id, entry_number, entry_date, journal_type, description, status)
    values (v_co, v_n, current_date, 'manual', 'x', 'draft');
    if public.generate_journal_entry_number(v_co) <> 'JE-' || v_y || '-000007' then raise exception 'SELFTEST cloud next'; end if;
    update public.sync_node set node = 'store';
    v_n := public.generate_journal_entry_number(v_co);
    if v_n <> 'JE-' || v_y || '-S000010' then raise exception 'SELFTEST store number %', v_n; end if;
    update public.sync_node set node = 'cloud';
    if public.generate_journal_entry_number(gen_random_uuid()) <> 'JE-' || v_y || '-000001' then raise exception 'SELFTEST new company'; end if;
    if public.motionpos_version_public() <> '042' then raise exception 'SELFTEST version'; end if;
    update public.sync_node set node = coalesce(v_node, 'cloud');
    raise notice 'MOTIONPOS-042-SELFTEST-OK';
    raise exception using errcode = 'P0099', message = 'selftest_rollback';
  exception when sqlstate 'P0099' then
    null;
  end;
end;
$selftest$;

notify pgrst, 'reload schema';

commit;
