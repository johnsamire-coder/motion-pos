-- One-time correction (2026-11-22), Makany: Yasmin's shift of 21/11 (08:06 -> 22/11 02:57) closed with "counted 2380"
-- (the sales screen figure of the day, not a count) against 3205 expected: a false shortage of 825 put on her.
-- The 825 (a table that came at 03:00 and paid at 09:00 in her shift) was handed back. So:
--   * her staff account: -825 (the shortage is cancelled, nothing taken from her salary);
--   * entry: Dr 1100 main cash / Cr 1130 staff receivables 825 (the money is in the main cash box);
--   * a note on the shift. The shift's own figures stay as they were closed.
-- Stops and changes nothing if the shift is not found exactly once or was already corrected. All or nothing.
-- Run: sudo bash /opt/motionpos/repo/supabase/ops/fix_yasmin_shortage_825.sh
\set ON_ERROR_STOP 1
\pset footer off
begin;
do $fix$
declare
  s record;
  n int;
  v_co uuid;
  v_bal numeric;
begin
  select count(*) into n from pos_shifts x join staff st on st.id = x.staff_id
   where st.name ilike 'yasmin%' and x.status = 'closed' and x.difference = -825 and coalesce(x.shortage_from_tips, 0) = 0
     and x.opened_at between timestamptz '2026-11-21 06:00+02' and timestamptz '2026-11-21 11:00+02';
  if n <> 1 then
    raise exception 'STOP: found % matching shifts (expected 1), nothing changed', n;
  end if;
  select x.*, st.name as staff_name, st.company_id as co into s from pos_shifts x join staff st on st.id = x.staff_id
   where st.name ilike 'yasmin%' and x.status = 'closed' and x.difference = -825 and coalesce(x.shortage_from_tips, 0) = 0
     and x.opened_at between timestamptz '2026-11-21 06:00+02' and timestamptz '2026-11-21 11:00+02';
  if exists (select 1 from staff_ledger l where l.shift_id = s.id and l.entry_type = 'adjustment' and l.amount = -825) then
    raise exception 'STOP: already corrected, nothing changed';
  end if;
  v_co := coalesce(s.company_id, s.co);
  v_bal := public.pos_staff_add_ledger(v_co, s.staff_id, 'adjustment', -825, s.id, null,
                                       'إلغاء عجز وردية 21/11: الـ 825 اترجعت (الرقم المكتوب كان رقم شاشة المبيعات مش عدّ الدرج)', null);
  perform public.pos_post_je(v_co, s.branch_id, 'adjustment', 'shift', s.id, 'إلغاء عجز وردية ' || s.staff_name || ' 21/11: الـ 825 اترجعت',
    jsonb_build_array(public.pos_je_line('1100', 825, 0, 'المبلغ اترجع للخزينة'),
                      public.pos_je_line('1130', 0, 825, 'إلغاء العجز على الكاشير')), null);
  update pos_shifts set notes = left(coalesce(nullif(notes, '') || ' | ', '') || 'تصحيح 22/11: عجز الـ 825 اتلغى، المبلغ اترجع للخزينة', 500)
   where id = s.id;
  raise notice 'DONE: % shortage 825 cancelled, her staff balance now %', s.staff_name, v_bal;
end;
$fix$;
\echo '== her staff account (last lines)'
select l.created_at::date as day, l.entry_type, l.amount, l.balance_after, left(l.notes, 70) as notes
  from staff_ledger l join staff st on st.id = l.staff_id where st.name ilike 'yasmin%' order by l.created_at desc limit 4;
commit;
