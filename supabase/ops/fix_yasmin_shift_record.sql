-- One-time correction (2026-11-24), Makany: Yasmin's shift of 21/11 still SHOWED "counted 2380, shortage 825" after the
-- 825 was cancelled (fix_yasmin_shortage_825). The real cash was 3205, so the shift record now says so:
--   counted 3205, difference 0; the drawer move "shortage 825" keeps its line with the reason "cancelled".
-- Display only: balances come from the journal, already corrected (Dr 1100 / Cr 1130 825). All or nothing.
-- Shows the shift report before and after.
-- Run: sudo bash /opt/motionpos/repo/supabase/ops/fix_yasmin_shift_record.sh
\set ON_ERROR_STOP 1
\pset footer off
begin;
\echo '== before'
select r->>'staff' as staff, r->>'expected_cash' as expected, r->>'counted_cash' as counted, r->>'difference' as difference,
       r->>'shortage_on_cashier' as on_cashier, r->>'sales_total' as sales, r->>'orders_paid' as orders
  from (select public.pos_shift_report(x.id) r from pos_shifts x join staff st on st.id = x.staff_id
         where st.name ilike 'yasmin%' and x.opened_at between timestamptz '2026-11-21 06:00+02' and timestamptz '2026-11-21 11:00+02') q;
do $fix$
declare
  v_id uuid;
  n int;
begin
  select count(*) into n from pos_shifts x join staff st on st.id = x.staff_id
   where st.name ilike 'yasmin%' and x.status = 'closed' and x.difference = -825 and x.counted_cash = 2380
     and x.opened_at between timestamptz '2026-11-21 06:00+02' and timestamptz '2026-11-21 11:00+02';
  if n <> 1 then
    raise exception 'STOP: found % shifts as expected (counted 2380, difference -825), nothing changed', n;
  end if;
  if not exists (select 1 from staff_ledger l join pos_shifts x on x.id = l.shift_id join staff st on st.id = x.staff_id
                  where st.name ilike 'yasmin%' and l.entry_type = 'adjustment' and l.amount = -825) then
    raise exception 'STOP: the 825 was not cancelled first (fix_yasmin_shortage_825), nothing changed';
  end if;
  select x.id into v_id from pos_shifts x join staff st on st.id = x.staff_id
   where st.name ilike 'yasmin%' and x.status = 'closed' and x.difference = -825 and x.counted_cash = 2380
     and x.opened_at between timestamptz '2026-11-21 06:00+02' and timestamptz '2026-11-21 11:00+02';
  update pos_shifts set counted_cash = 3205, difference = 0,
         notes = left(coalesce(nullif(notes, '') || ' | ', '') || 'تصحيح 24/11: الدرج كان فيه 3205 (2380 كان رقم شاشة المبيعات)، مفيش عجز', 500)
   where id = v_id;
  update pos_cash_moves set reason = 'عجز اتلغى: الدرج كان فيه 3205، والـ 825 اترجعت للخزينة'
   where shift_id = v_id and move_type = 'shortage' and amount = 825;
  raise notice 'DONE: shift record corrected';
end;
$fix$;
\echo '== after'
select r->>'staff' as staff, r->>'expected_cash' as expected, r->>'counted_cash' as counted, r->>'difference' as difference,
       r->>'shortage_on_cashier' as on_cashier, r->>'sales_total' as sales, r->>'orders_paid' as orders
  from (select public.pos_shift_report(x.id) r from pos_shifts x join staff st on st.id = x.staff_id
         where st.name ilike 'yasmin%' and x.opened_at between timestamptz '2026-11-21 06:00+02' and timestamptz '2026-11-21 11:00+02') q;
commit;
