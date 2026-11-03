-- 036_branch_drawer_for_manager.sql
-- Since 033 a branch has ONE open shift (usually the cashier's). Paying from "the drawer" still looked for a shift opened
-- by the person doing it, so the branch manager could not record an expense, give custody, pay a supplier, pay an advance,
-- pay tips or take a customer's account payment from the drawer ("open a shift first").
-- Now "the drawer" = your own open shift if you have one, else the open shift of your branch. The cash move keeps the
-- name of who did it (staff_id), and counts in that shift's expected cash like before.
-- The shift row is locked while used, so money cannot go into a shift that the cashier is closing at the same moment.
-- Unchanged on purpose: taking order payments / refunds, and opening / closing / moving cash of a shift (the shift owner's job).
-- Functions copied from their latest files (011 source check, 022 custody settle + advance, 012 customer receive,
-- 024 tips) with only the shift lookup changed. No tables changed.
-- Rules: begin/commit, preflight (needs 035), version bump to 036, grants loop, rolled-back self-test.

begin;

do $preflight$
begin
  if length('إكراميات') <> 8 then
    raise exception 'file_encoding_broken: read the file as UTF-8';
  end if;
  if public.motionpos_version_public() not in ('035', '036') then
    raise exception 'schema_preflight_failed: run 035 first';
  end if;
end;
$preflight$;

-- the drawer this person pays from / into: own open shift, else the branch's open shift (locked, null if none)
create or replace function public.pos_drawer_shift(p_staff_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_shift uuid;
begin
  select s.id into v_shift from public.pos_shifts s
   where s.staff_id = p_staff_id and s.status = 'open'
   limit 1 for update;
  if v_shift is null then
    select s.id into v_shift from public.pos_shifts s
     where s.status = 'open' and s.branch_id = (select st.branch_id from public.staff st where st.id = p_staff_id)
     order by s.opened_at
     limit 1 for update;
  end if;
  return v_shift;
end;
$$;

-- Where the money comes from: drawer (the branch's open shift), main_cash or bank. Returns the shift id for the drawer.
create or replace function public.pos_source_check(p_staff_id uuid, p_source text, p_amount numeric)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_shift uuid;
begin
  if coalesce(p_source, '') not in ('drawer', 'main_cash', 'bank') then
    return jsonb_build_object('ok', false, 'reason', 'invalid_destination');
  end if;
  if p_source = 'drawer' then
    v_shift := public.pos_drawer_shift(p_staff_id);
    if v_shift is null then
      return jsonb_build_object('ok', false, 'reason', 'no_open_shift');
    end if;
    if p_amount > public.pos_shift_expected(v_shift) then
      return jsonb_build_object('ok', false, 'reason', 'not_enough_cash');
    end if;
  end if;
  return jsonb_build_object('ok', true, 'shift_id', v_shift);
end;
$$;

-- custody settle back to the drawer (copied from 022)
create or replace function public.custody_settle_secure(
  p_token text, p_staff_id uuid, p_lines jsonb, p_returned_cash numeric, p_return_to text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
  v_bal numeric;
  v_ret numeric := round(coalesce(p_returned_cash, 0), 2);
  v_total numeric := 0;
  l jsonb;
  v_cat public.expense_categories%rowtype;
  v_amt numeric;
  v_shift uuid;
  v_lines jsonb := '[]'::jsonb;
  v_ref uuid := gen_random_uuid();
  v_exp uuid;
begin
  select * into c from public.pos_ctx(p_token, 'expenses');
  if not public.pos_perm_ok(c.role_name, 'exp_custody') then
    return jsonb_build_object('ok', false, 'reason', 'not_allowed', 'perm', 'exp_custody');
  end if;
  select coalesce(sum(x.amount), 0) into v_bal from public.custody_ledger x where x.staff_id = p_staff_id;
  if v_bal <= 0 then
    return jsonb_build_object('ok', false, 'reason', 'no_custody');
  end if;
  if jsonb_typeof(coalesce(p_lines, '[]'::jsonb)) <> 'array' or jsonb_array_length(coalesce(p_lines, '[]'::jsonb)) > 100 then
    return jsonb_build_object('ok', false, 'reason', 'invalid_items');
  end if;
  for l in select e.value from jsonb_array_elements(coalesce(p_lines, '[]'::jsonb)) e(value) loop
    v_amt := public.pos_amount(l->>'amount');
    if v_amt is null or v_amt <= 0
       or not exists (select 1 from public.expense_categories e where e.id = public.pos_uuid(l->>'category_id')
                                                                  and e.company_id = c.company_id and e.is_active is true)
       or nullif(btrim(coalesce(l->>'description', '')), '') is null then
      return jsonb_build_object('ok', false, 'reason', 'invalid_items');
    end if;
    v_total := v_total + round(v_amt, 2);
  end loop;
  if v_ret < 0 or v_total + v_ret <= 0 or v_total + v_ret > v_bal then
    return jsonb_build_object('ok', false, 'reason', 'custody_amount_mismatch', 'balance', v_bal);
  end if;
  if v_ret > 0 then
    if coalesce(p_return_to, '') not in ('main_cash', 'drawer') then
      return jsonb_build_object('ok', false, 'reason', 'invalid_destination');
    end if;
    if p_return_to = 'drawer' then
      v_shift := public.pos_drawer_shift(c.staff_id);
      if v_shift is null then
        return jsonb_build_object('ok', false, 'reason', 'no_open_shift');
      end if;
    end if;
  end if;

  for l in select e.value from jsonb_array_elements(coalesce(p_lines, '[]'::jsonb)) e(value) loop
    select e.* into v_cat from public.expense_categories e where e.id = (l->>'category_id')::uuid;
    v_amt := round((l->>'amount')::numeric, 2);
    insert into public.expenses (company_id, branch_id, expense_account_id, amount, payment_method, description,
                                 created_by, category_id, source, custody_staff_id)
    values (c.company_id, c.branch_id, v_cat.account_id, v_amt, 'cash', left(btrim(l->>'description'), 500),
            c.staff_id, v_cat.id, 'custody', p_staff_id)
    returning id into v_exp;
    v_lines := v_lines || jsonb_build_array(jsonb_build_object('account_id', v_cat.account_id, 'debit', v_amt, 'credit', 0,
                                                               'description', left(btrim(l->>'description'), 200)));
    perform public.pos_custody_add(c.company_id, p_staff_id, 'settle_expense', -v_amt, left(btrim(l->>'description'), 300), c.staff_id);
  end loop;
  if v_ret > 0 then
    perform public.pos_custody_add(c.company_id, p_staff_id, 'return', -v_ret, 'رد باقي العهدة', c.staff_id);
    v_lines := v_lines || jsonb_build_array(public.pos_je_line(case when p_return_to = 'drawer' then '1101' else '1100' end,
                                                               v_ret, 0, 'رد باقي العهدة'));
    if p_return_to = 'drawer' then
      insert into public.pos_cash_moves (shift_id, company_id, branch_id, move_type, amount, source, destination, reason, staff_id)
      values (v_shift, c.company_id, c.branch_id, 'cash_in', v_ret, 'custody', 'drawer', 'رد باقي عهدة', c.staff_id);
    end if;
  end if;
  v_lines := v_lines || jsonb_build_array(public.pos_je_line('1140', 0, v_total + v_ret, 'تسوية عهدة'));
  perform public.pos_post_je(c.company_id, c.branch_id, 'expense', 'custody', v_ref, 'تسوية عهدة موظف', v_lines, c.staff_id);

  return jsonb_build_object('ok', true, 'balance', v_bal - v_total - v_ret);
end;
$$;

-- staff advance from the drawer (copied from 022)
create or replace function public.staff_advance_secure(
  p_token text, p_staff_id uuid, p_amount numeric, p_source text, p_reason text, p_manager_pin text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
  v_amount numeric := round(coalesce(p_amount, 0), 2);
  v_manager uuid;
  v_shift uuid;
  v_ref uuid := gen_random_uuid();
begin
  select * into c from public.pos_ctx(p_token, 'payroll');
  if not public.pos_perm_ok(c.role_name, 'payroll_pay') then
    return jsonb_build_object('ok', false, 'reason', 'not_allowed', 'perm', 'payroll_pay');
  end if;
  if not public.pos_staff_scope_ok(c.role_name, c.branch_id, c.company_id, p_staff_id) and p_staff_id <> c.staff_id then
    return jsonb_build_object('ok', false, 'reason', 'staff_not_found');
  end if;
  if v_amount <= 0 or v_amount > 10000000 then
    return jsonb_build_object('ok', false, 'reason', 'invalid_amount');
  end if;
  if coalesce(p_source, '') not in ('main_cash', 'drawer', 'bank') then
    return jsonb_build_object('ok', false, 'reason', 'invalid_destination');
  end if;
  if p_source = 'drawer' then
    v_shift := public.pos_drawer_shift(c.staff_id);
    if v_shift is null then
      return jsonb_build_object('ok', false, 'reason', 'no_open_shift');
    end if;
    if v_amount > public.pos_shift_expected(v_shift) then
      return jsonb_build_object('ok', false, 'reason', 'not_enough_cash');
    end if;
  end if;
  v_manager := public.verify_manager_pin(p_manager_pin, c.branch_id);
  if v_manager is null then
    return jsonb_build_object('ok', false, 'reason', 'manager_pin');
  end if;

  perform public.pos_staff_add_ledger(c.company_id, p_staff_id, 'advance', v_amount, v_shift, null,
                                      left(coalesce(p_reason, 'سلفة'), 300), c.staff_id);
  insert into public.pos_cash_moves (shift_id, company_id, branch_id, move_type, amount, source, destination, reason, staff_id, approved_by)
  values (v_shift, c.company_id, c.branch_id, 'advance', v_amount, p_source, 'staff', left(coalesce(p_reason, 'سلفة'), 300), c.staff_id, v_manager);
  perform public.pos_post_je(c.company_id, c.branch_id, 'payment', 'advance', v_ref, 'سلفة موظف',
    jsonb_build_array(public.pos_je_line('1130', v_amount, 0, 'سلفة'),
                      public.pos_je_line(public.pos_box_code(p_source), 0, v_amount, 'صرف سلفة')), c.staff_id);
  return jsonb_build_object('ok', true);
end;
$$;

-- customer pays his account into the drawer (copied from 012)
create or replace function public.customer_receive_secure(p_token text, p_customer_id uuid, p_amount numeric, p_source text, p_reference text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
  v_amount numeric := round(coalesce(p_amount, 0), 2);
  v_bal numeric;
  v_shift uuid;
  v_id uuid;
begin
  select * into c from public.pos_ctx(p_token, null);
  if not public.pos_is_manager(c.role_name)
     and not exists (select 1 from public.role_permissions rp where rp.role_name = c.role_name and rp.perm in ('accounting', 'shift')) then
    return jsonb_build_object('ok', false, 'reason', 'not_allowed');
  end if;
  perform 1 from public.customers cu where cu.id = p_customer_id and cu.company_id = c.company_id for update;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'not_found');
  end if;
  select coalesce(sum(l.amount), 0) into v_bal from public.customer_ledger l where l.customer_id = p_customer_id;
  if v_amount <= 0 or v_amount > v_bal then
    return jsonb_build_object('ok', false, 'reason', 'invalid_amount', 'balance', v_bal);
  end if;
  if coalesce(p_source, '') not in ('drawer', 'main_cash', 'bank') then
    return jsonb_build_object('ok', false, 'reason', 'invalid_destination');
  end if;
  if p_source = 'drawer' then
    v_shift := public.pos_drawer_shift(c.staff_id);
    if v_shift is null then
      return jsonb_build_object('ok', false, 'reason', 'no_open_shift');
    end if;
  end if;
  v_id := gen_random_uuid();
  insert into public.customer_ledger (id, company_id, customer_id, transaction_type, amount, payment_method, reference_number,
                                      balance_after, notes, created_by)
  values (v_id, c.company_id, p_customer_id, 'payment_received', -v_amount, case when p_source = 'bank' then 'bank_transfer' else 'cash' end,
          left(coalesce(p_reference, ''), 100), v_bal - v_amount, 'تحصيل', c.staff_id);
  update public.customers set current_balance = v_bal - v_amount where id = p_customer_id;
  if p_source = 'drawer' then
    insert into public.pos_cash_moves (shift_id, company_id, branch_id, move_type, amount, source, destination, reason, staff_id)
    values (v_shift, c.company_id, c.branch_id, 'cash_in', v_amount, 'customer', 'drawer', 'تحصيل من عميل', c.staff_id);
  end if;
  perform public.pos_post_je(c.company_id, c.branch_id, 'receipt', 'payment', v_id, 'تحصيل من عميل',
    jsonb_build_array(public.pos_je_line(public.pos_box_code(p_source), v_amount, 0, 'تحصيل'),
                      public.pos_je_line('1120', 0, v_amount, 'العملاء')), c.staff_id);
  return jsonb_build_object('ok', true, 'balance', v_bal - v_amount);
end;
$$;

-- tips paid from the drawer (copied from 024)
create or replace function public.tips_secure(p_token text, p_action text, p_data jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
  d jsonb := coalesce(p_data, '{}'::jsonb);
  v_pool numeric;
  v_amount numeric;
  v_ids uuid[];
  v_n int;
  v_each numeric;
  v_total numeric;
  v_batch uuid := gen_random_uuid();
  v_shift uuid;
  v_src text := coalesce(d->>'source', 'main_cash');
begin
  select * into c from public.pos_ctx(p_token, 'treasury');
  if not public.pos_perm_ok(c.role_name, 'tips_distribute') then
    return jsonb_build_object('ok', false, 'reason', 'not_allowed', 'perm', 'tips_distribute');
  end if;
  v_pool := round(greatest(0, public.pos_tips_pool(c.company_id, c.branch_id)), 2);

  if coalesce(p_action, '') = 'distribute' then
    if jsonb_typeof(d->'staff_ids') is distinct from 'array' then
      return jsonb_build_object('ok', false, 'reason', 'invalid_value');
    end if;
    select coalesce(array_agg(distinct s.id), '{}'::uuid[]) into v_ids
      from jsonb_array_elements_text(d->'staff_ids') x(v) join public.staff s on s.id = public.pos_uuid(x.v)
     where s.branch_id = c.branch_id and s.is_active is true;
    v_n := coalesce(array_length(v_ids, 1), 0);
    if v_n = 0 then
      return jsonb_build_object('ok', false, 'reason', 'invalid_value');
    end if;
    v_amount := coalesce(public.pos_amount(d->>'amount'), v_pool);
    if v_amount <= 0 or v_amount > v_pool then
      return jsonb_build_object('ok', false, 'reason', 'invalid_amount', 'pool', v_pool);
    end if;
    v_each := floor(v_amount * 100 / v_n) / 100;          -- what does not divide stays in the pot
    if v_each <= 0 then
      return jsonb_build_object('ok', false, 'reason', 'invalid_amount', 'pool', v_pool);
    end if;
    v_total := v_each * v_n;
    if v_src not in ('main_cash', 'drawer') then
      return jsonb_build_object('ok', false, 'reason', 'invalid_value');
    end if;
    if v_src = 'drawer' then
      v_shift := public.pos_drawer_shift(c.staff_id);
      if v_shift is null then
        return jsonb_build_object('ok', false, 'reason', 'no_open_shift');
      end if;
      insert into public.pos_cash_moves (shift_id, company_id, branch_id, move_type, amount, source, destination, reason, staff_id)
      values (v_shift, c.company_id, c.branch_id, 'tips_payout', v_total, 'drawer', 'staff', 'توزيع الإكراميات', c.staff_id);
    end if;
    insert into public.tip_payouts (company_id, branch_id, batch_id, staff_id, amount, source, shift_id, created_by)
    select c.company_id, c.branch_id, v_batch, u.id, v_each, v_src, v_shift, c.staff_id from unnest(v_ids) u(id);
    perform public.pos_post_je(c.company_id, c.branch_id, 'payment', 'adjustment', v_batch, 'توزيع الإكراميات على ' || v_n || ' موظف',
      jsonb_build_array(public.pos_je_line('2400', v_total, 0, 'صندوق الإكراميات'),
                        public.pos_je_line(case when v_src = 'drawer' then '1101' else '1100' end, 0, v_total, 'صرف الإكراميات')), c.staff_id);
    v_pool := round(greatest(0, public.pos_tips_pool(c.company_id, c.branch_id)), 2);
  elsif coalesce(p_action, '') <> 'status' then
    return jsonb_build_object('ok', false, 'reason', 'unknown_action');
  end if;

  return jsonb_build_object('ok', true, 'pool', v_pool, 'each', v_each, 'paid', v_total,
    'collected_today', coalesce((select sum(p.tip_amount) from public.payments p join public.pos_shifts sh on sh.id = p.shift_id
                                  where sh.branch_id = c.branch_id and public.pos_local_date(p.created_at) = public.pos_local_date(now())), 0),
    'covered_shortages_today', coalesce((select sum(sh.shortage_from_tips) from public.pos_shifts sh
                                          where sh.branch_id = c.branch_id and public.pos_local_date(sh.closed_at) = public.pos_local_date(now())), 0),
    'staff', coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name,
                         'came_today', exists (select 1 from public.staff_attendance a where a.staff_id = s.id
                                                 and public.pos_local_date(a.clock_in) = public.pos_local_date(now()))) order by s.name)
                         from public.staff s join public.roles r on r.id = s.role_id
                        where s.branch_id = c.branch_id and s.is_active is true and r.name <> 'owner'), '[]'::jsonb),
    'history', coalesce((select jsonb_agg(jsonb_build_object('at', q.at, 'by', q.by, 'total', q.total, 'each', q.each, 'count', q.cnt,
                                                            'names', q.names, 'source', q.source) order by q.at desc)
                           from (select min(t.created_at) as at, (select s.name from public.staff s where s.id = min(t.created_by::text)::uuid) as by,
                                        sum(t.amount) as total, max(t.amount) as each, count(*) as cnt, string_agg(st.name, '، ' order by st.name) as names,
                                        max(t.source) as source
                                   from public.tip_payouts t join public.staff st on st.id = t.staff_id
                                  where t.branch_id = c.branch_id and t.created_at > now() - interval '60 days'
                                  group by t.batch_id order by min(t.created_at) desc limit 30) q), '[]'::jsonb));
end;
$$;

create or replace function public.motionpos_version_public()
returns text
language sql
immutable
as $$
  select '036'
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
  v_brand uuid;
  v_branch uuid;
  v_other uuid;
  v_cashier uuid;
  v_manager uuid;
  v_far uuid;
  v_shift uuid;
  v_src text;
  f text;
begin
  begin
    perform set_config('motionpos.sync_apply', 'on', true);
    insert into public.companies (name) values ('selftest036') returning id into v_co;
    insert into public.brands (name, company_id) values ('selftest036', v_co) returning id into v_brand;
    insert into public.branches (name, brand_id) values ('selftest036 a', v_brand) returning id into v_branch;
    insert into public.branches (name, brand_id) values ('selftest036 b', v_brand) returning id into v_other;
    insert into public.staff (name, company_id, branch_id, is_active) values ('cashier036', v_co, v_branch, true) returning id into v_cashier;
    insert into public.staff (name, company_id, branch_id, is_active) values ('manager036', v_co, v_branch, true) returning id into v_manager;
    insert into public.staff (name, company_id, branch_id, is_active) values ('other036', v_co, v_other, true) returning id into v_far;
    insert into public.pos_shifts (company_id, branch_id, staff_id, opening_float) values (v_co, v_branch, v_cashier, 0) returning id into v_shift;
    -- the manager (no shift of his own) uses the cashier's open shift of his branch; another branch does not
    if public.pos_drawer_shift(v_manager) is distinct from v_shift then raise exception 'SELFTEST manager drawer'; end if;
    if public.pos_drawer_shift(v_cashier) is distinct from v_shift then raise exception 'SELFTEST own drawer'; end if;
    if public.pos_drawer_shift(v_far) is not null then raise exception 'SELFTEST other branch'; end if;
    if public.pos_source_check(v_manager, 'drawer', 0)->>'shift_id' is distinct from v_shift::text then raise exception 'SELFTEST source check'; end if;
    if public.pos_source_check(v_far, 'drawer', 0)->>'reason' is distinct from 'no_open_shift' then raise exception 'SELFTEST source none'; end if;
    update public.pos_shifts set status = 'closed', closed_at = now() where id = v_shift;
    if public.pos_drawer_shift(v_manager) is not null then raise exception 'SELFTEST closed shift'; end if;
    foreach f in array array['custody_settle_secure', 'staff_advance_secure', 'customer_receive_secure', 'tips_secure'] loop
      select pg_get_functiondef(p.oid) into v_src from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = f;
      if position('pos_drawer_shift' in v_src) = 0 then raise exception 'SELFTEST % not replaced', f; end if;
    end loop;
    if public.motionpos_version_public() <> '036' then raise exception 'SELFTEST version'; end if;
    raise notice 'MOTIONPOS-036-SELFTEST-OK';
    raise exception using errcode = 'P0099', message = 'selftest_rollback';
  exception when sqlstate 'P0099' then
    null;
  end;
end;
$selftest$;

notify pgrst, 'reload schema';

commit;
