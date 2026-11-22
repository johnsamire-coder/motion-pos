-- One-time correction (2026-11-22), Makany: the owner cancels what is left on Yasmin's staff account (older shift
-- shortages: 15/11 125, 16/11 150 and 30 before them = 305), so nothing is taken from her salary.
--   :mode = forgiven (default): the shop takes the loss: Dr 6500 other operating expenses / Cr 1130
--   :mode = returned          : she handed the money back: Dr 1100 main cash / Cr 1130
-- Stops and changes nothing if her balance is not 305 (already cleared, or it changed). All or nothing.
-- Run: sudo bash /opt/motionpos/repo/supabase/ops/clear_yasmin_balance.sh [forgiven|returned]
\set ON_ERROR_STOP 1
\pset footer off
begin;
select set_config('motionpos.fix_mode', :'mode', true);
do $fix$
declare
  v_staff record;
  n int;
  v_bal numeric;
  v_mode text := current_setting('motionpos.fix_mode', true);
  v_code text;
begin
  if v_mode not in ('forgiven', 'returned') then
    raise exception 'STOP: mode must be forgiven or returned, nothing changed';
  end if;
  select count(*) into n from staff where name ilike 'yasmin%';
  if n <> 1 then
    raise exception 'STOP: % staff named Yasmin (expected 1), nothing changed', n;
  end if;
  select * into v_staff from staff where name ilike 'yasmin%';
  select coalesce(sum(amount), 0) into v_bal from staff_ledger where staff_id = v_staff.id;
  if v_bal <> 305 then
    raise exception 'STOP: her balance is % (expected 305), nothing changed', v_bal;
  end if;
  v_code := case when v_mode = 'returned' then '1100' else '6500' end;
  if not exists (select 1 from accounts a where a.company_id = v_staff.company_id and a.code = v_code) then
    raise exception 'STOP: account % is not in the chart, nothing changed', v_code;
  end if;
  v_bal := public.pos_staff_add_ledger(v_staff.company_id, v_staff.id, 'adjustment', -305, null, null,
             case when v_mode = 'returned' then 'إلغاء عجوزات ورديات قديمة (15 و16/11 وقبلهم): المبلغ اترجع'
                  else 'إلغاء عجوزات ورديات قديمة (15 و16/11 وقبلهم) بقرار الإدارة' end, null);
  perform public.pos_post_je(v_staff.company_id, v_staff.branch_id, 'adjustment', 'adjustment', v_staff.id,
    'إلغاء عجوزات ورديات ' || v_staff.name || ' (305)',
    jsonb_build_array(public.pos_je_line(v_code, 305, 0, case when v_mode = 'returned' then 'المبلغ اترجع للخزينة' else 'عجز نقدية اتسامح فيه' end),
                      public.pos_je_line('1130', 0, 305, 'إلغاء العجز على الكاشير')), null);
  raise notice 'DONE (%): % balance now %', v_mode, v_staff.name, v_bal;
end;
$fix$;
\echo '== her staff account (last lines)'
select l.created_at::date as day, l.entry_type, l.amount, l.balance_after, left(l.notes, 60) as notes
  from staff_ledger l join staff st on st.id = l.staff_id where st.name ilike 'yasmin%' order by l.created_at desc limit 3;
commit;
