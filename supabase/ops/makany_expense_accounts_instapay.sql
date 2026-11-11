-- One-time data change (2026-11-11), Makany:
-- 1) expense items the client asked for, each with its own expense account in the chart of accounts
--    (a new 6xxx code after the existing ones). Anything that already exists with the same name is kept, not doubled.
--    "مسحوبات شخصية" is the owner taking money: it goes to 3300 (owner's current account), not to an expense.
-- 2) InstaPay number on the receipt: settings > receipt > payment numbers.
-- All or nothing. Run: sudo bash /opt/motionpos/repo/supabase/ops/makany_expense_accounts_instapay.sh
\set ON_ERROR_STOP 1
\pset footer off
begin;

do $fix$
declare
  v_co uuid;
  v_parent uuid;
  v_acc uuid;
  v_code int;
  v_owner uuid;
  r record;
  n_acc int := 0;
  n_cat int := 0;
begin
  if (select count(*) from companies) <> 1 then
    raise exception 'STOP: more than one company here, nothing changed';
  end if;
  select id into v_co from companies;

  -- the expenses group the 6xxx accounts hang under (if the chart has one)
  select a.parent_id into v_parent from accounts a
   where a.company_id = v_co and a.account_type = 'expense' and a.code ~ '^6[0-9]{3}$' and a.parent_id is not null
   group by a.parent_id order by count(*) desc limit 1;

  for r in
    select * from (values
      (1, 'صيانة', 'صيانة', 'Maintenance'),
      (2, 'نظافة', 'نظافة', 'Cleaning'),
      (3, 'انتقالات', 'انتقالات', 'Transportation'),
      (4, 'رسوم واشتراكات', 'رسوم واشتراكات', 'Fees and subscriptions'),
      (5, 'مياه', 'مياه', 'Water'),
      (6, 'كهرباء', 'كهرباء', 'Electricity'),
      (7, 'غاز', 'غاز', 'Gas'),
      (8, 'إكراميات', 'مصروف إكراميات', 'Tips expense'),
      (9, 'رسوم حكومية', 'رسوم حكومية', 'Government fees'),
      (10, 'أدوات مكتبية', 'أدوات مكتبية', 'Stationery')) x(ord, cat, acc, en)
    order by ord
  loop
    -- same name already there (spelling differences of ة/ه, أ/ا, ى/ي and spaces ignored) = keep it
    if exists (select 1 from expense_categories e where e.company_id = v_co
                and translate(replace(e.name, ' ', ''), 'ةأإآى', 'هاااي') = translate(replace(r.cat, ' ', ''), 'ةأإآى', 'هاااي')) then
      raise notice 'kept (already there): %', r.cat;
      continue;
    end if;
    select a.id into v_acc from accounts a
     where a.company_id = v_co and a.account_type = 'expense'
       and translate(replace(a.name_ar, ' ', ''), 'ةأإآى', 'هاااي') in (translate(replace(r.acc, ' ', ''), 'ةأإآى', 'هاااي'),
                                                                     translate(replace(r.cat, ' ', ''), 'ةأإآى', 'هاااي'))
     limit 1;
    if v_acc is null then
      select coalesce(max(a.code::int), 6000) into v_code from accounts a where a.company_id = v_co and a.code ~ '^6[0-9]{3}$';
      v_code := (v_code / 10 + 1) * 10;
      while exists (select 1 from accounts a where a.company_id = v_co and a.code = v_code::text) loop
        v_code := v_code + 10;
      end loop;
      if v_code > 6990 then
        raise exception 'STOP: no free 6xxx code left, nothing changed';
      end if;
      insert into accounts (company_id, code, name_ar, name_en, account_type, normal_balance, parent_id, is_system_account, is_active)
      values (v_co, v_code::text, r.acc, r.en, 'expense', 'debit', v_parent, false, true)
      returning id into v_acc;
      n_acc := n_acc + 1;
      raise notice 'account % - %', v_code, r.acc;
    end if;
    insert into expense_categories (company_id, name, account_id, is_active) values (v_co, r.cat, v_acc, true);
    n_cat := n_cat + 1;
  end loop;

  -- owner's personal withdrawals: on the owner's current account 3300
  select a.id into v_owner from accounts a where a.company_id = v_co and a.code = '3300';
  if v_owner is null then
    raise notice 'skipped مسحوبات شخصية: account 3300 is not in the chart';
  elsif exists (select 1 from expense_categories e where e.company_id = v_co
                 and translate(replace(e.name, ' ', ''), 'ةأإآى', 'هاااي') like 'مسحوباتشخصيه%') then
    raise notice 'kept (already there): مسحوبات شخصية';
  else
    insert into expense_categories (company_id, name, account_id, is_active) values (v_co, 'مسحوبات شخصية (صاحب المحل)', v_owner, true);
    n_cat := n_cat + 1;
  end if;

  -- InstaPay number on the receipt
  insert into app_settings (company_id, section, data)
  values (v_co, 'payinfo', '{"instapay": "01065449443", "show_on_receipt": true}'::jsonb)
  on conflict (company_id, section)
  do update set data = app_settings.data || excluded.data, updated_at = now();

  raise notice 'new accounts: %, new expense items: %, InstaPay 01065449443 on the receipt', n_acc, n_cat;
end;
$fix$;

\echo '== expense items now'
select e.name as item, a.code, a.name_ar as account from expense_categories e join accounts a on a.id = e.account_id
 where e.is_active order by a.code, e.name;
\echo '== payment numbers on the receipt'
select data->>'instapay' as instapay, data->>'show_on_receipt' as on_receipt from app_settings where section = 'payinfo';
commit;
