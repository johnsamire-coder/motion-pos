-- 029_order_cancellations_report.sql
-- Adds two reports inside report_secure. The function is copied verbatim from 024 with ONLY the new
-- cases added before the final else; every existing report stays untouched.
--   order_cancellations   : each cancelled order - who/when/why/manager, voided items count and value,
--                           order total, customer, and that customer's previous cancellations
--                           (all time, and within the last 90 days).
--   cancelled_order_items : the items that were inside fully cancelled orders.
-- Rules: begin/commit, preflight (needs 028), version bump to 029, grants loop, rolled-back self-test.

begin;

do $preflight$
begin
  if length('إكراميات') <> 8 then
    raise exception 'file_encoding_broken: read the file as UTF-8';
  end if;
  if public.motionpos_version_public() not in ('028', '029') then
    raise exception 'schema_preflight_failed: run 028 first';
  end if;
end;
$preflight$;

create or replace function public.report_secure(p_token text, p_key text, p_from date, p_to date, p_branch_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
  v_from date := coalesce(p_from, current_date - 30);
  v_to date := coalesce(p_to, current_date);
  v_branch uuid;
  v_title text;
  v_cols jsonb;
  v_rows jsonb;
  v_days int;
  v_set jsonb;
  v_start time;
  v_grace int;
begin
  select * into c from public.pos_ctx(p_token, 'reports');
  v_branch := case when c.role_name = 'owner' then p_branch_id else c.branch_id end;
  if v_to < v_from or v_to - v_from > 731 then
    return jsonb_build_object('ok', false, 'reason', 'invalid_period');
  end if;
  v_days := v_to - v_from + 1;

  case p_key
  -- ---------------------------------------------------------------- sales
  when 'sales_daily' then
    v_title := 'المبيعات اليومية';
    v_cols := public.pos_cols(array['day','orders','guests','gross','discount','service','tax','total','avg_ticket','per_guest'],
      array['اليوم','الطلبات','الضيوف','قبل الخصم','الخصم','الخدمة','الضريبة','الإجمالي','متوسط الفاتورة','متوسط الفرد'], 'dnnmmmmmmm');
    select coalesce(jsonb_agg(to_jsonb(q) order by q.day), '[]') into v_rows from (
      select public.pos_local_date(o.created_at) as day, count(*) as orders, sum(coalesce(o.guest_count, 1)) as guests,
             sum(o.sub_total) as gross, sum(o.discount_amount) as discount, sum(o.service_charge_amount) as service,
             sum(o.tax_amount) as tax, sum(o.total_amount) as total, round(avg(o.total_amount), 2) as avg_ticket,
             round(sum(o.total_amount) / nullif(sum(coalesce(o.guest_count, 1)), 0), 2) as per_guest
        from public.pos_rpt_orders(c.company_id, v_branch, v_from, v_to) o group by 1) q;

  when 'sales_monthly' then
    v_title := 'المبيعات الشهرية';
    v_cols := public.pos_cols(array['month','orders','gross','discount','service','tax','total','avg_ticket'],
      array['الشهر','الطلبات','قبل الخصم','الخصم','الخدمة','الضريبة','الإجمالي','متوسط الفاتورة'], 'tnmmmmmm');
    select coalesce(jsonb_agg(to_jsonb(q) order by q.month), '[]') into v_rows from (
      select to_char(public.pos_local_date(o.created_at), 'YYYY-MM') as month, count(*) as orders, sum(o.sub_total) as gross,
             sum(o.discount_amount) as discount, sum(o.service_charge_amount) as service, sum(o.tax_amount) as tax,
             sum(o.total_amount) as total, round(avg(o.total_amount), 2) as avg_ticket
        from public.pos_rpt_orders(c.company_id, v_branch, v_from, v_to) o group by 1) q;

  when 'sales_hourly' then
    v_title := 'أوقات الذروة (بالساعة)';
    v_cols := public.pos_cols(array['hour','orders','total','avg_per_day'], array['الساعة','الطلبات','الإجمالي','متوسط اليوم'], 'tnmm');
    select coalesce(jsonb_agg(to_jsonb(q) order by q.hour), '[]') into v_rows from (
      select lpad(extract(hour from o.created_at at time zone 'Africa/Cairo')::text, 2, '0') || ':00' as hour,
             count(*) as orders, sum(o.total_amount) as total, round(sum(o.total_amount) / v_days, 2) as avg_per_day
        from public.pos_rpt_orders(c.company_id, v_branch, v_from, v_to) o group by 1) q;

  when 'sales_weekday' then
    v_title := 'المبيعات بأيام الأسبوع';
    v_cols := public.pos_cols(array['weekday','orders','total'], array['اليوم','الطلبات','الإجمالي'], 'tnm');
    select coalesce(jsonb_agg(jsonb_build_object('weekday', (array['الأحد','الاثنين','الثلاثاء','الأربعاء','الخميس','الجمعة','السبت'])[q.d + 1],
                                                 'orders', q.orders, 'total', q.total) order by q.d), '[]') into v_rows from (
      select extract(dow from o.created_at at time zone 'Africa/Cairo')::int as d, count(*) as orders, sum(o.total_amount) as total
        from public.pos_rpt_orders(c.company_id, v_branch, v_from, v_to) o group by 1) q;

  when 'sales_payment_method' then
    v_title := 'المبيعات بطريقة الدفع';
    v_cols := public.pos_cols(array['method','count','amount','tips'], array['طريقة الدفع','العدد','المبلغ','الإكراميات'], 'tnmm');
    select coalesce(jsonb_agg(to_jsonb(q) order by q.amount desc), '[]') into v_rows from (
      select p.payment_method as method, count(*) as count, sum(p.amount) as amount, sum(coalesce(p.tip_amount, 0)) as tips
        from public.payments p join public.orders o on o.id = p.order_id
       where o.company_id = c.company_id and (v_branch is null or o.branch_id = v_branch)
         and public.pos_local_date(p.created_at) between v_from and v_to group by 1) q;

  when 'sales_order_type' then
    v_title := 'المبيعات بنوع الطلب';
    v_cols := public.pos_cols(array['order_type','orders','total','avg_ticket'], array['النوع','الطلبات','الإجمالي','متوسط الفاتورة'], 'tnmm');
    select coalesce(jsonb_agg(to_jsonb(q) order by q.total desc), '[]') into v_rows from (
      select o.order_type, count(*) as orders, sum(o.total_amount) as total, round(avg(o.total_amount), 2) as avg_ticket
        from public.pos_rpt_orders(c.company_id, v_branch, v_from, v_to) o group by 1) q;

  when 'sales_category' then
    v_title := 'المبيعات بالقسم';
    v_cols := public.pos_cols(array['category','qty','amount','share'], array['القسم','الكمية','المبلغ','النسبة'], 'tnmp');
    select coalesce(jsonb_agg(to_jsonb(q) order by q.amount desc), '[]') into v_rows from (
      select coalesce(cat.name, '-') as category, sum(oi.quantity) as qty, sum(oi.total_price) as amount,
             round(100 * sum(oi.total_price) / nullif(sum(sum(oi.total_price)) over (), 0), 1) as share
        from public.pos_rpt_orders(c.company_id, v_branch, v_from, v_to) o
        join public.order_items oi on oi.order_id = o.id and coalesce(oi.status, 'active') = 'active'
        left join public.products p on p.id = oi.product_id left join public.categories cat on cat.id = p.category_id
       group by 1) q;

  when 'sales_item' then
    v_title := 'المبيعات بالصنف';
    v_cols := public.pos_cols(array['product','category','qty','amount','avg_price','share'],
      array['الصنف','القسم','الكمية','المبلغ','متوسط السعر','النسبة'], 'ttnmmp');
    select coalesce(jsonb_agg(to_jsonb(q) order by q.amount desc), '[]') into v_rows from (
      select coalesce(p.name, '-') as product, coalesce(cat.name, '-') as category, sum(oi.quantity) as qty,
             sum(oi.total_price) as amount, round(sum(oi.total_price) / nullif(sum(oi.quantity), 0), 2) as avg_price,
             round(100 * sum(oi.total_price) / nullif(sum(sum(oi.total_price)) over (), 0), 1) as share
        from public.pos_rpt_orders(c.company_id, v_branch, v_from, v_to) o
        join public.order_items oi on oi.order_id = o.id and coalesce(oi.status, 'active') = 'active'
        left join public.products p on p.id = oi.product_id left join public.categories cat on cat.id = p.category_id
       group by 1, 2) q;

  when 'sales_modifiers' then
    v_title := 'أكتر الإضافات طلباً';
    v_cols := public.pos_cols(array['modifier','count','amount'], array['الإضافة','العدد','المبلغ'], 'tnm');
    select coalesce(jsonb_agg(to_jsonb(q) order by q.count desc), '[]') into v_rows from (
      select m.modifier_name as modifier, sum(oi.quantity) as count, sum(coalesce(m.unit_price, 0) * oi.quantity) as amount
        from public.pos_rpt_orders(c.company_id, v_branch, v_from, v_to) o
        join public.order_items oi on oi.order_id = o.id and coalesce(oi.status, 'active') = 'active'
        join public.order_item_modifiers m on m.order_item_id = oi.id group by 1) q;

  when 'sales_waiter' then
    v_title := 'المبيعات بالويتر';
    v_cols := public.pos_cols(array['waiter','orders','total','avg_ticket','guests'], array['الويتر','الطلبات','الإجمالي','متوسط الفاتورة','الضيوف'], 'tnmmn');
    select coalesce(jsonb_agg(to_jsonb(q) order by q.total desc), '[]') into v_rows from (
      select coalesce(w.name, 'بدون ويتر') as waiter, count(*) as orders, sum(o.total_amount) as total,
             round(avg(o.total_amount), 2) as avg_ticket, sum(coalesce(o.guest_count, 1)) as guests
        from public.pos_rpt_orders(c.company_id, v_branch, v_from, v_to) o left join public.staff w on w.id = o.waiter_id group by 1) q;

  when 'sales_cashier' then
    v_title := 'المقبوض بالكاشير';
    v_cols := public.pos_cols(array['cashier','orders','cash','other','total'], array['الكاشير','الطلبات','كاش','طرق تانية','الإجمالي'], 'tnmmm');
    select coalesce(jsonb_agg(to_jsonb(q) order by q.total desc), '[]') into v_rows from (
      select st.name as cashier, count(distinct p.order_id) as orders,
             sum(case when p.payment_method = 'cash' then p.amount else 0 end) as cash,
             sum(case when p.payment_method <> 'cash' then p.amount else 0 end) as other, sum(p.amount) as total
        from public.payments p join public.pos_shifts sh on sh.id = p.shift_id join public.staff st on st.id = sh.staff_id
       where sh.company_id = c.company_id and (v_branch is null or sh.branch_id = v_branch)
         and public.pos_local_date(p.created_at) between v_from and v_to group by 1) q;

  when 'sales_compare' then
    v_title := 'مقارنة الفترة بالفترة اللي قبلها';
    v_cols := public.pos_cols(array['metric','current','previous','change'], array['البند','الفترة دي','الفترة اللي قبلها','التغيير %'], 'tmmp');
    with cur as (select count(*) n, coalesce(sum(total_amount), 0) t, coalesce(avg(total_amount), 0) a, coalesce(sum(discount_amount), 0) d
                   from public.pos_rpt_orders(c.company_id, v_branch, v_from, v_to)),
         prv as (select count(*) n, coalesce(sum(total_amount), 0) t, coalesce(avg(total_amount), 0) a, coalesce(sum(discount_amount), 0) d
                   from public.pos_rpt_orders(c.company_id, v_branch, v_from - v_days, v_from - 1))
    select jsonb_build_array(
      jsonb_build_object('metric', 'عدد الطلبات', 'current', cur.n, 'previous', prv.n, 'change', round(100.0 * (cur.n - prv.n) / nullif(prv.n, 0), 1)),
      jsonb_build_object('metric', 'إجمالي المبيعات', 'current', cur.t, 'previous', prv.t, 'change', round(100 * (cur.t - prv.t) / nullif(prv.t, 0), 1)),
      jsonb_build_object('metric', 'متوسط الفاتورة', 'current', round(cur.a, 2), 'previous', round(prv.a, 2), 'change', round(100 * (cur.a - prv.a) / nullif(prv.a, 0), 1)),
      jsonb_build_object('metric', 'الخصومات', 'current', cur.d, 'previous', prv.d, 'change', round(100 * (cur.d - prv.d) / nullif(prv.d, 0), 1)))
      into v_rows from cur, prv;

  -- ---------------------------------------------------------------- profit
  when 'item_profit' then
    v_title := 'ربحية الأصناف وتصنيف المنيو';
    v_cols := public.pos_cols(array['product','qty','revenue','unit_cost','cost','profit','cost_pct','class'],
      array['الصنف','الكمية','الإيراد','تكلفة الوحدة','التكلفة','الربح','نسبة التكلفة','التصنيف'], 'tnmmmmpt');
    select coalesce(jsonb_agg(jsonb_build_object('product', q.product, 'qty', q.qty, 'revenue', q.revenue, 'unit_cost', q.unit_cost,
             'cost', q.cost, 'profit', q.revenue - q.cost, 'cost_pct', round(100 * q.cost / nullif(q.revenue, 0), 1),
             'class', case when q.qty >= 0.7 * q.avg_qty and q.margin >= q.avg_margin then 'نجم (مربح ومطلوب)'
                           when q.qty >= 0.7 * q.avg_qty then 'حصان (مطلوب وربحه قليل)'
                           when q.margin >= q.avg_margin then 'لغز (مربح ومش مطلوب)'
                           else 'ضعيف (لا ده ولا ده)' end) order by q.revenue - q.cost desc), '[]') into v_rows from (
      select x.*, avg(x.qty) over () as avg_qty, avg(x.margin) over () as avg_margin from (
        select coalesce(p.name, '-') as product, sum(oi.quantity) as qty, sum(oi.total_price) as revenue,
               round(public.pos_product_cost(oi.product_id), 2) as unit_cost,
               round(public.pos_product_cost(oi.product_id) * sum(oi.quantity), 2) as cost,
               sum(oi.total_price) / nullif(sum(oi.quantity), 0) - public.pos_product_cost(oi.product_id) as margin
          from public.pos_rpt_orders(c.company_id, v_branch, v_from, v_to) o
          join public.order_items oi on oi.order_id = o.id and coalesce(oi.status, 'active') = 'active'
          left join public.products p on p.id = oi.product_id
         group by p.name, oi.product_id) x) q;

  when 'category_profit' then
    v_title := 'ربحية الأقسام';
    v_cols := public.pos_cols(array['category','revenue','cost','profit','cost_pct'], array['القسم','الإيراد','التكلفة','الربح','نسبة التكلفة'], 'tmmmp');
    select coalesce(jsonb_agg(jsonb_build_object('category', q.category, 'revenue', q.revenue, 'cost', q.cost, 'profit', q.revenue - q.cost,
             'cost_pct', round(100 * q.cost / nullif(q.revenue, 0), 1)) order by q.revenue - q.cost desc), '[]') into v_rows from (
      select coalesce(cat.name, '-') as category, sum(oi.total_price) as revenue,
             round(sum(public.pos_product_cost(oi.product_id) * oi.quantity), 2) as cost
        from public.pos_rpt_orders(c.company_id, v_branch, v_from, v_to) o
        join public.order_items oi on oi.order_id = o.id and coalesce(oi.status, 'active') = 'active'
        left join public.products p on p.id = oi.product_id left join public.categories cat on cat.id = p.category_id
       group by 1) q;

  when 'daily_profit' then
    v_title := 'الربح اليومي (قبل المصروفات)';
    v_cols := public.pos_cols(array['day','revenue','cogs','waste','gross_profit','margin'],
      array['اليوم','الإيراد بدون ضريبة','تكلفة المبيعات','الهالك','مجمل الربح','نسبة الربح'], 'dmmmmp');
    select coalesce(jsonb_agg(jsonb_build_object('day', d.day, 'revenue', d.revenue, 'cogs', d.cogs, 'waste', d.waste,
             'gross_profit', d.revenue - d.cogs - d.waste, 'margin', round(100 * (d.revenue - d.cogs - d.waste) / nullif(d.revenue, 0), 1))
             order by d.day), '[]') into v_rows from (
      select g.day::date as day,
             coalesce((select sum(o.total_amount - o.tax_amount) from public.pos_rpt_orders(c.company_id, v_branch, g.day::date, g.day::date) o), 0) as revenue,
             coalesce((select sum(sm.total_cost) from public.stock_movements sm where sm.company_id = c.company_id and sm.movement_type = 'sale'
                         and (v_branch is null or sm.branch_id = v_branch) and public.pos_local_date(sm.created_at) = g.day::date), 0) as cogs,
             coalesce((select sum(sm.total_cost) from public.stock_movements sm where sm.company_id = c.company_id and sm.movement_type = 'waste'
                         and (v_branch is null or sm.branch_id = v_branch) and public.pos_local_date(sm.created_at) = g.day::date), 0) as waste
        from generate_series(v_from, v_to, interval '1 day') g(day)) d;

  -- ---------------------------------------------------------------- discounts / voids / refunds
  when 'discounts_detail' then
    v_title := 'الخصومات بالتفصيل';
    v_cols := public.pos_cols(array['at','order_number','kind','percent','amount','total_before','cashier','manager'],
      array['الوقت','الطلب','النوع','النسبة','المبلغ','الإجمالي قبلها','الكاشير','المدير الموافق'], 'ttnnmmtt');
    select coalesce(jsonb_agg(to_jsonb(q) order by q.at desc), '[]') into v_rows from (
      select to_char(l.created_at at time zone 'Africa/Cairo', 'YYYY-MM-DD HH24:MI') as at, o.order_number,
             case l.details->>'kind' when 'manual' then 'يدوي' when 'list' then 'من القايمة' else l.details->>'kind' end as kind,
             (l.details->>'percent')::numeric as percent, (l.details->>'amount')::numeric as amount,
             (l.details->>'total_before')::numeric as total_before, s.name as cashier, m.name as manager
        from public.order_logs l join public.orders o on o.id = l.order_id
        left join public.staff s on s.id = l.user_id left join public.staff m on m.id = public.pos_uuid(l.details->>'approved_by_manager_id')
       where l.action = 'APPLY_DISCOUNT' and o.company_id = c.company_id and (v_branch is null or o.branch_id = v_branch)
         and public.pos_local_date(l.created_at) between v_from and v_to) q;

  when 'voids_detail' then
    v_title := 'الإلغاءات بالتفصيل';
    v_cols := public.pos_cols(array['at','order_number','product','qty','value','reason','after_prep','waste_cost','cashier','manager'],
      array['الوقت','الطلب','الصنف','الكمية','القيمة','السبب','بعد التحضير','تكلفة الهالك','الكاشير','المدير الموافق'], 'tttnmttmtt');
    select coalesce(jsonb_agg(to_jsonb(q) order by q.at desc), '[]') into v_rows from (
      select to_char(l.created_at at time zone 'Africa/Cairo', 'YYYY-MM-DD HH24:MI') as at, o.order_number, l.details->>'product' as product,
             (l.details->>'qty_voided')::numeric as qty,
             round((l.details->>'qty_voided')::numeric * coalesce((l.details->>'unit_price')::numeric, 0), 2) as value,
             cr.reason, case when (l.details->>'recorded_as_waste')::boolean then 'نعم' else 'لا' end as after_prep,
             coalesce((l.details->>'waste_cost')::numeric, 0) as waste_cost, s.name as cashier, m.name as manager
        from public.order_logs l join public.orders o on o.id = l.order_id
        left join public.staff s on s.id = l.user_id left join public.staff m on m.id = public.pos_uuid(l.details->>'approved_by_manager_id')
        left join public.cancel_reasons cr on cr.id = public.pos_uuid(l.details->>'reason_id')
       where l.action like 'VOID_ITEM%' and o.company_id = c.company_id and (v_branch is null or o.branch_id = v_branch)
         and public.pos_local_date(l.created_at) between v_from and v_to) q;

  when 'refunds_detail' then
    v_title := 'المرتجعات والطلبات الملغية';
    v_cols := public.pos_cols(array['at','order_number','action','total','reason','by_staff','manager'],
      array['الوقت','الطلب','العملية','الإجمالي','السبب','بواسطة','المدير الموافق'], 'tttmttt');
    select coalesce(jsonb_agg(to_jsonb(q) order by q.at desc), '[]') into v_rows from (
      select to_char(l.created_at at time zone 'Africa/Cairo', 'YYYY-MM-DD HH24:MI') as at, o.order_number,
             case l.action when 'REFUND_ORDER' then 'مرتجع بعد الدفع' else 'إلغاء طلب' end as action,
             coalesce((l.details->>'total')::numeric, (l.details->>'total_before')::numeric) as total, cr.reason, s.name as by_staff, m.name as manager
        from public.order_logs l join public.orders o on o.id = l.order_id
        left join public.staff s on s.id = l.user_id left join public.staff m on m.id = public.pos_uuid(l.details->>'approved_by_manager_id')
        left join public.cancel_reasons cr on cr.id = public.pos_uuid(l.details->>'reason_id')
       where l.action in ('REFUND_ORDER', 'CANCEL_ORDER') and o.company_id = c.company_id and (v_branch is null or o.branch_id = v_branch)
         and public.pos_local_date(l.created_at) between v_from and v_to) q;

  -- ---------------------------------------------------------------- theft indicators
  when 'theft_indicators' then
    v_title := 'مؤشرات السرقة لكل موظف';
    v_cols := public.pos_cols(array['staff','voids','voids_value','voids_after_prep','manual_discounts','discounts_value','charges_removed',
                                    'refunds','cancelled_orders','shortage_count','shortage_total','night_actions','approvals_given'],
      array['الموظف','إلغاءات','قيمتها','بعد التحضير','خصم يدوي','قيمة الخصومات','شيل خدمة/ضريبة','مرتجعات','طلبات ملغية',
            'مرات العجز','إجمالي العجز','عمليات بعد ١٢ بالليل','موافقات أعطاها كمدير'], 'tnmnnmnnnnmnn');
    select coalesce(jsonb_agg(to_jsonb(q) order by q.voids_value + q.discounts_value + q.shortage_total desc), '[]') into v_rows from (
      select s.name as staff,
        count(*) filter (where l.action like 'VOID_ITEM%') as voids,
        coalesce(sum(round((l.details->>'qty_voided')::numeric * coalesce((l.details->>'unit_price')::numeric, 0), 2))
                   filter (where l.action like 'VOID_ITEM%'), 0) as voids_value,
        count(*) filter (where l.action like 'VOID_ITEM%' and (l.details->>'recorded_as_waste')::boolean) as voids_after_prep,
        count(*) filter (where l.action = 'APPLY_DISCOUNT' and l.details->>'kind' = 'manual') as manual_discounts,
        coalesce(sum((l.details->>'amount')::numeric) filter (where l.action = 'APPLY_DISCOUNT'), 0) as discounts_value,
        count(*) filter (where l.action = 'CHANGE_CHARGES' and ((l.details->>'vat_after')::boolean is false or (l.details->>'service_after')::boolean is false)) as charges_removed,
        count(*) filter (where l.action = 'REFUND_ORDER') as refunds,
        count(*) filter (where l.action = 'CANCEL_ORDER') as cancelled_orders,
        (select count(*) from public.pos_shifts sh where sh.staff_id = s.id and sh.difference < 0
            and public.pos_local_date(sh.opened_at) between v_from and v_to) as shortage_count,
        coalesce((select -sum(sh.difference) from public.pos_shifts sh where sh.staff_id = s.id and sh.difference < 0
            and public.pos_local_date(sh.opened_at) between v_from and v_to), 0) as shortage_total,
        count(*) filter (where extract(hour from l.created_at at time zone 'Africa/Cairo') between 0 and 5
                           and l.action in ('VOID_ITEM', 'APPLY_DISCOUNT', 'REFUND_ORDER', 'CANCEL_ORDER', 'CHANGE_CHARGES')) as night_actions,
        (select count(*) from public.order_logs l2 where public.pos_uuid(l2.details->>'approved_by_manager_id') = s.id
            and public.pos_local_date(l2.created_at) between v_from and v_to) as approvals_given
        from public.staff s
        left join public.order_logs l on l.user_id = s.id and public.pos_local_date(l.created_at) between v_from and v_to
       where s.company_id = c.company_id and (v_branch is null or s.branch_id = v_branch)
       group by s.id, s.name) q;

  when 'long_open_orders' then
    v_title := 'طلبات مفتوحة من وقت طويل (أكتر من ساعتين)';
    v_cols := public.pos_cols(array['order_number','opened','hours','table_number','waiter','total'],
      array['الطلب','اتفتح','ساعات','الطاولة','الويتر','الإجمالي'], 'ttnttm');
    select coalesce(jsonb_agg(to_jsonb(q) order by q.hours desc), '[]') into v_rows from (
      select o.order_number, to_char(o.created_at at time zone 'Africa/Cairo', 'YYYY-MM-DD HH24:MI') as opened,
             round(extract(epoch from now() - o.created_at) / 3600, 1) as hours, t.table_number, w.name as waiter, o.total_amount as total
        from public.orders o left join public.tables t on t.id = o.table_id left join public.staff w on w.id = o.waiter_id
       where o.company_id = c.company_id and (v_branch is null or o.branch_id = v_branch)
         and coalesce(o.status, '') not in ('paid', 'closed', 'cancelled') and o.created_at < now() - interval '2 hours') q;

  when 'manager_approvals' then
    v_title := 'موافقات المديرين';
    v_cols := public.pos_cols(array['manager','action','count'], array['المدير','العملية','العدد'], 'ttn');
    select coalesce(jsonb_agg(to_jsonb(q) order by q.count desc), '[]') into v_rows from (
      select m.name as manager, case l.action when 'VOID_ITEM' then 'إلغاء صنف' when 'APPLY_DISCOUNT' then 'خصم'
             when 'CHANGE_CHARGES' then 'شيل خدمة/ضريبة' when 'REFUND_ORDER' then 'مرتجع' when 'CANCEL_ORDER' then 'إلغاء طلب'
             else l.action end as action, count(*) as count
        from public.order_logs l join public.staff m on m.id = public.pos_uuid(l.details->>'approved_by_manager_id')
       where m.company_id = c.company_id and (v_branch is null or m.branch_id = v_branch)
         and public.pos_local_date(l.created_at) between v_from and v_to group by 1, 2) q;

  -- ---------------------------------------------------------------- inventory
  when 'stock_valuation' then
    v_title := 'تقييم المخزون (دلوقتي)';
    v_cols := public.pos_cols(array['warehouse','ingredient','unit','qty','unit_cost','value'],
      array['المخزن','الخامة','الوحدة','الكمية','تكلفة الوحدة','القيمة'], 'tttnmm');
    select coalesce(jsonb_agg(to_jsonb(q) order by q.warehouse, q.value desc), '[]') into v_rows from (
      select w.name as warehouse, i.name as ingredient, i.unit, ws.quantity as qty, i.cost_per_unit as unit_cost,
             round(ws.quantity * i.cost_per_unit, 2) as value
        from public.warehouse_stock ws join public.warehouses w on w.id = ws.warehouse_id join public.ingredients i on i.id = ws.ingredient_id
       where (v_branch is null or w.branch_id = v_branch or w.branch_id is null) and ws.quantity <> 0) q;

  when 'waste_by_reason' then
    v_title := 'الهالك بالسبب';
    v_cols := public.pos_cols(array['reason','ingredient','qty','cost'], array['السبب','الخامة','الكمية','التكلفة'], 'ttnm');
    select coalesce(jsonb_agg(to_jsonb(q) order by q.cost desc), '[]') into v_rows from (
      select split_part(wl.reason, ':', 1) as reason, i.name as ingredient, sum(wl.quantity) as qty, sum(wl.cost_loss) as cost
        from public.waste_logs wl join public.warehouses w on w.id = wl.warehouse_id join public.ingredients i on i.id = wl.ingredient_id
       where (v_branch is null or w.branch_id = v_branch or w.branch_id is null)
         and public.pos_local_date(wl.created_at) between v_from and v_to group by 1, 2) q;

  when 'count_variances' then
    v_title := 'فروقات الجرد';
    v_cols := public.pos_cols(array['at','warehouse','ingredient','system_qty','actual_qty','variance','value'],
      array['التاريخ','المخزن','الخامة','على السيستم','المعدود','الفرق','قيمة الفرق'], 'tttnnnm');
    select coalesce(jsonb_agg(to_jsonb(q) order by q.at desc), '[]') into v_rows from (
      select to_char(st.created_at at time zone 'Africa/Cairo', 'YYYY-MM-DD') as at, w.name as warehouse, i.name as ingredient,
             st.theoretical_qty as system_qty, st.actual_qty, st.variance_qty as variance, st.variance_cost as value
        from public.stock_takes st join public.warehouses w on w.id = st.warehouse_id join public.ingredients i on i.id = st.ingredient_id
       where (v_branch is null or w.branch_id = v_branch or w.branch_id is null) and st.variance_qty <> 0
         and public.pos_local_date(st.created_at) between v_from and v_to) q;

  when 'low_stock' then
    v_title := 'خامات تحت الحد الأدنى';
    v_cols := public.pos_cols(array['warehouse','ingredient','unit','qty','min'], array['المخزن','الخامة','الوحدة','الرصيد','الحد الأدنى'], 'tttnn');
    select coalesce(jsonb_agg(to_jsonb(q) order by q.warehouse, q.ingredient), '[]') into v_rows from (
      select w.name as warehouse, i.name as ingredient, i.unit, coalesce(ws.quantity, 0) as qty, i.min_stock_alert as min
        from public.warehouses w cross join public.ingredients i
        left join public.warehouse_stock ws on ws.warehouse_id = w.id and ws.ingredient_id = i.id
       where (v_branch is null or w.branch_id = v_branch) and coalesce(ws.quantity, 0) <= coalesce(i.min_stock_alert, 0)) q;

  when 'stock_turnover' then
    v_title := 'دوران المخزون';
    v_cols := public.pos_cols(array['ingredient','unit','used','current','days_left'], array['الخامة','الوحدة','المستهلك في الفترة','الرصيد الحالي','يكفي كام يوم'], 'ttnnn');
    select coalesce(jsonb_agg(to_jsonb(q) order by q.days_left nulls last), '[]') into v_rows from (
      select i.name as ingredient, i.unit,
             coalesce((select -sum(sm.quantity) from public.stock_movements sm where sm.ingredient_id = i.id
                         and sm.movement_type in ('sale', 'waste') and (v_branch is null or sm.branch_id = v_branch)
                         and public.pos_local_date(sm.created_at) between v_from and v_to), 0) as used,
             coalesce((select sum(ws.quantity) from public.warehouse_stock ws join public.warehouses w on w.id = ws.warehouse_id
                        where ws.ingredient_id = i.id and (v_branch is null or w.branch_id = v_branch)), 0) as current,
             round(coalesce((select sum(ws.quantity) from public.warehouse_stock ws join public.warehouses w on w.id = ws.warehouse_id
                              where ws.ingredient_id = i.id and (v_branch is null or w.branch_id = v_branch)), 0)
                   / nullif(coalesce((select -sum(sm.quantity) from public.stock_movements sm where sm.ingredient_id = i.id
                         and sm.movement_type in ('sale', 'waste') and (v_branch is null or sm.branch_id = v_branch)
                         and public.pos_local_date(sm.created_at) between v_from and v_to), 0) / v_days, 0), 1) as days_left
        from public.ingredients i) q;

  when 'transfers' then
    v_title := 'التحويلات بين المخازن';
    v_cols := public.pos_cols(array['at','number','from_wh','to_wh','status','ingredient','requested','shipped','received'],
      array['التاريخ','الرقم','من','إلى','الحالة','الخامة','المطلوب','المشحون','المستلم'], 'tttttnnnn');
    select coalesce(jsonb_agg(to_jsonb(q) order by q.at desc), '[]') into v_rows from (
      select to_char(t.created_at at time zone 'Africa/Cairo', 'YYYY-MM-DD') as at, t.transfer_number as number, wf.name as from_wh,
             wt.name as to_wh, t.status, i.name as ingredient, l.qty_requested as requested, l.qty_shipped as shipped, l.qty_received as received
        from public.inv_transfers t join public.inv_transfer_lines l on l.transfer_id = t.id join public.ingredients i on i.id = l.ingredient_id
        join public.warehouses wf on wf.id = t.from_warehouse_id join public.warehouses wt on wt.id = t.to_warehouse_id
       where t.company_id = c.company_id and public.pos_local_date(t.created_at) between v_from and v_to
         and (v_branch is null or wf.branch_id = v_branch or wt.branch_id = v_branch)) q;

  -- ---------------------------------------------------------------- purchasing
  when 'purchases_by_supplier' then
    v_title := 'المشتريات بالمورد';
    v_cols := public.pos_cols(array['supplier','received','invoiced','paid','balance'], array['المورد','المستلم','الفواتير','المدفوع','الرصيد الحالي'], 'tmmmm');
    select coalesce(jsonb_agg(to_jsonb(q) order by q.received desc), '[]') into v_rows from (
      select s.name as supplier,
             coalesce((select sum(gi.total_cost) from public.goods_receipt_items gi join public.goods_receipts g on g.id = gi.goods_receipt_id
                        join public.purchase_orders po on po.id = g.purchase_order_id
                       where po.supplier_id = s.id and public.pos_local_date(g.received_at) between v_from and v_to), 0) as received,
             coalesce((select sum(i.amount + i.tax_amount) from public.supplier_invoices i where i.supplier_id = s.id
                         and i.invoice_date between v_from and v_to), 0) as invoiced,
             coalesce((select sum(p.amount) from public.supplier_payments p where p.supplier_id = s.id
                         and public.pos_local_date(p.created_at) between v_from and v_to), 0) as paid,
             coalesce((select sum(l.amount) from public.supplier_ledger l where l.supplier_id = s.id), 0) as balance
        from public.suppliers s where s.company_id = c.company_id) q;

  when 'purchases_by_ingredient' then
    v_title := 'المشتريات بالخامة';
    v_cols := public.pos_cols(array['ingredient','unit','qty','value','avg_cost','min_cost','max_cost'],
      array['الخامة','الوحدة','الكمية','القيمة','متوسط السعر','أقل سعر','أعلى سعر'], 'ttnmmmm');
    select coalesce(jsonb_agg(to_jsonb(q) order by q.value desc), '[]') into v_rows from (
      select i.name as ingredient, i.unit, sum(gi.received_qty) as qty, sum(gi.total_cost) as value,
             round(sum(gi.total_cost) / nullif(sum(gi.received_qty), 0), 4) as avg_cost, min(gi.unit_cost) as min_cost, max(gi.unit_cost) as max_cost
        from public.goods_receipt_items gi join public.goods_receipts g on g.id = gi.goods_receipt_id
        join public.purchase_orders po on po.id = g.purchase_order_id join public.ingredients i on i.id = gi.ingredient_id
       where po.company_id = c.company_id and public.pos_local_date(g.received_at) between v_from and v_to group by 1, 2) q;

  when 'price_changes' then
    v_title := 'تغيّر أسعار الخامات';
    v_cols := public.pos_cols(array['at','ingredient','old_cost','new_cost','change'], array['التاريخ','الخامة','السعر القديم','السعر الجديد','التغيير %'], 'ttmmp');
    select coalesce(jsonb_agg(to_jsonb(q) order by q.at desc), '[]') into v_rows from (
      select to_char(h.created_at at time zone 'Africa/Cairo', 'YYYY-MM-DD') as at, i.name as ingredient, h.old_cost, h.new_cost,
             round(100 * (h.new_cost - h.old_cost) / nullif(h.old_cost, 0), 1) as change
        from public.ingredient_cost_history h join public.ingredients i on i.id = h.ingredient_id
       where public.pos_local_date(h.created_at) between v_from and v_to) q;

  when 'unmatched_invoices' then
    v_title := 'فواتير موردين مش مطابقة للاستلام';
    v_cols := public.pos_cols(array['date','supplier','invoice','received','amount','difference'],
      array['التاريخ','المورد','رقم الفاتورة','قيمة المستلم','قيمة الفاتورة','الفرق'], 'tttmmm');
    select coalesce(jsonb_agg(to_jsonb(q) order by q.date desc), '[]') into v_rows from (
      select i.invoice_date::text as date, s.name as supplier, i.invoice_number as invoice, i.received_value as received,
             i.amount, i.difference
        from public.supplier_invoices i join public.suppliers s on s.id = i.supplier_id
       where i.company_id = c.company_id and not i.matched and i.invoice_date between v_from and v_to) q;

  when 'supplier_aging' then
    v_title := 'أعمار ديون الموردين';
    v_cols := public.pos_cols(array['supplier','balance','last_invoice','last_payment','days_since_payment'],
      array['المورد','الرصيد','آخر فاتورة','آخر سداد','أيام من آخر سداد'], 'tmttn');
    select coalesce(jsonb_agg(to_jsonb(q) order by q.balance desc), '[]') into v_rows from (
      select s.name as supplier, coalesce(sum(l.amount), 0) as balance,
             max(l.created_at) filter (where l.entry_type = 'invoice')::date::text as last_invoice,
             max(l.created_at) filter (where l.entry_type = 'payment')::date::text as last_payment,
             current_date - max(l.created_at) filter (where l.entry_type = 'payment')::date as days_since_payment
        from public.suppliers s left join public.supplier_ledger l on l.supplier_id = s.id
       where s.company_id = c.company_id group by s.id, s.name having coalesce(sum(l.amount), 0) <> 0) q;

  -- ---------------------------------------------------------------- treasury
  when 'cash_movements' then
    v_title := 'حركة النقدية';
    v_cols := public.pos_cols(array['at','type','amount','source','destination','reason','staff'],
      array['الوقت','النوع','المبلغ','من','إلى','السبب','الموظف'], 'ttmtttt');
    select coalesce(jsonb_agg(to_jsonb(q) order by q.at desc), '[]') into v_rows from (
      select to_char(m.created_at at time zone 'Africa/Cairo', 'YYYY-MM-DD HH24:MI') as at, m.move_type as type, m.amount,
             m.source, m.destination, m.reason, s.name as staff
        from public.pos_cash_moves m left join public.staff s on s.id = m.staff_id
       where m.company_id = c.company_id and (v_branch is null or m.branch_id = v_branch)
         and public.pos_local_date(m.created_at) between v_from and v_to) q;

  when 'shifts' then
    v_title := 'الورديات وفروقها';
    v_cols := public.pos_cols(array['opened','closed','staff','float','expected','counted','difference','tips'],
      array['فتح','قفل','الموظف','العهدة','المفروض','المعدود','الفرق','الإكراميات'], 'tttmmmmm');
    select coalesce(jsonb_agg(to_jsonb(q) order by q.opened desc), '[]') into v_rows from (
      select to_char(sh.opened_at at time zone 'Africa/Cairo', 'YYYY-MM-DD HH24:MI') as opened,
             to_char(sh.closed_at at time zone 'Africa/Cairo', 'YYYY-MM-DD HH24:MI') as closed, s.name as staff,
             sh.opening_float as float, sh.expected_cash as expected, sh.counted_cash as counted, sh.difference, sh.tips_paid as tips
        from public.pos_shifts sh join public.staff s on s.id = sh.staff_id
       where sh.company_id = c.company_id and (v_branch is null or sh.branch_id = v_branch)
         and public.pos_local_date(sh.opened_at) between v_from and v_to) q;

  when 'expenses_by_category' then
    v_title := 'المصروفات بالبند';
    v_cols := public.pos_cols(array['category','count','total','share'], array['البند','العدد','الإجمالي','النسبة'], 'tnmp');
    select coalesce(jsonb_agg(to_jsonb(q) order by q.total desc), '[]') into v_rows from (
      select coalesce(ec.name, a.name_ar) as category, count(*) as count, sum(x.amount) as total,
             round(100 * sum(x.amount) / nullif(sum(sum(x.amount)) over (), 0), 1) as share
        from public.expenses x left join public.expense_categories ec on ec.id = x.category_id left join public.accounts a on a.id = x.expense_account_id
       where x.company_id = c.company_id and (v_branch is null or x.branch_id = v_branch)
         and public.pos_local_date(x.created_at) between v_from and v_to group by 1) q;

  -- ---------------------------------------------------------------- customers
  when 'customer_balances' then
    v_title := 'أرصدة العملاء الآجل';
    v_cols := public.pos_cols(array['customer','phone','balance','credit_limit','last_sale','last_payment','days_since_payment'],
      array['العميل','التليفون','الرصيد','الحد','آخر بيع','آخر تحصيل','أيام من آخر تحصيل'], 'ttmmttn');
    select coalesce(jsonb_agg(to_jsonb(q) order by q.balance desc), '[]') into v_rows from (
      select cu.name as customer, cu.phone, coalesce(sum(l.amount), 0) as balance, cu.credit_limit,
             max(l.created_at) filter (where l.transaction_type = 'credit_sale')::date::text as last_sale,
             max(l.created_at) filter (where l.transaction_type = 'payment_received')::date::text as last_payment,
             current_date - coalesce(max(l.created_at) filter (where l.transaction_type = 'payment_received'),
                                     min(l.created_at))::date as days_since_payment
        from public.customers cu left join public.customer_ledger l on l.customer_id = cu.id
       where cu.company_id = c.company_id group by cu.id, cu.name, cu.phone, cu.credit_limit
      having coalesce(sum(l.amount), 0) <> 0) q;

  when 'top_customers' then
    v_title := 'أكتر العملاء شراء';
    v_cols := public.pos_cols(array['customer','orders','total','avg_ticket'], array['العميل','الطلبات','الإجمالي','متوسط الفاتورة'], 'tnmm');
    select coalesce(jsonb_agg(to_jsonb(q) order by q.total desc), '[]') into v_rows from (
      select cu.name as customer, count(*) as orders, sum(o.total_amount) as total, round(avg(o.total_amount), 2) as avg_ticket
        from public.pos_rpt_orders(c.company_id, v_branch, v_from, v_to) o join public.customers cu on cu.id = o.customer_id group by 1) q;

  -- ---------------------------------------------------------------- staff
  when 'attendance' then
    v_set := public.pos_app_settings(c.company_id) -> 'staff';
    v_start := coalesce(nullif(v_set->>'work_start_time', ''), '09:00')::time;
    v_grace := coalesce((v_set->>'late_grace_minutes')::int, 15);
    v_title := 'الحضور والتأخير';
    v_cols := public.pos_cols(array['staff','days','hours','late_days','late_minutes'], array['الموظف','أيام الحضور','الساعات','أيام التأخير','دقايق التأخير'], 'tnnnn');
    select coalesce(jsonb_agg(to_jsonb(q) order by q.staff), '[]') into v_rows from (
      select s.name as staff, count(*) as days, round(sum(d.minutes) / 60.0, 1) as hours,
             count(*) filter (where d.first_in > v_start + make_interval(mins => v_grace)) as late_days,
             coalesce(sum(greatest(0, extract(epoch from (d.first_in - v_start)) / 60)::int)
                        filter (where d.first_in > v_start + make_interval(mins => v_grace)), 0) as late_minutes
        from (select a.staff_id, public.pos_local_date(a.clock_in) as day, min((a.clock_in at time zone 'Africa/Cairo')::time) as first_in,
                     coalesce(sum(a.minutes), 0) as minutes
                from public.staff_attendance a
               where a.company_id = c.company_id and (v_branch is null or a.branch_id = v_branch)
                 and public.pos_local_date(a.clock_in) between v_from and v_to group by 1, 2) d
        join public.staff s on s.id = d.staff_id group by s.name) q;

  when 'tips_by_staff' then
    v_title := 'الإكراميات لكل موظف';
    v_cols := public.pos_cols(array['staff','count','tips'], array['الموظف','العدد','الإجمالي'], 'tnm');
    select coalesce(jsonb_agg(to_jsonb(q) order by q.tips desc), '[]') into v_rows from (
      select s.name as staff, count(*) as count, sum(x.amount) as tips
        from (select p.tip_staff_id as staff_id, p.tip_amount as amount, p.created_at from public.payments p
               where p.tip_staff_id is not null and p.tip_amount > 0
              union all
              select t.staff_id, t.amount, t.created_at from public.tip_payouts t) x
        join public.staff s on s.id = x.staff_id
       where s.company_id = c.company_id and (v_branch is null or s.branch_id = v_branch)
         and public.pos_local_date(x.created_at) between v_from and v_to group by 1) q;

  when 'staff_balances' then
    v_title := 'أرصدة الموظفين (عجز وسلف)';
    v_cols := public.pos_cols(array['staff','shortages','advances','deducted','balance'], array['الموظف','العجز','السلف','اتخصم','الرصيد عليه'], 'tmmmm');
    select coalesce(jsonb_agg(to_jsonb(q) order by q.balance desc), '[]') into v_rows from (
      select s.name as staff,
             coalesce(sum(l.amount) filter (where l.entry_type = 'shortage'), 0) as shortages,
             coalesce(sum(l.amount) filter (where l.entry_type = 'advance'), 0) as advances,
             coalesce(-sum(l.amount) filter (where l.entry_type in ('deduction', 'repayment')), 0) as deducted,
             coalesce(sum(l.amount), 0) as balance
        from public.staff s join public.staff_ledger l on l.staff_id = s.id
       where s.company_id = c.company_id and (v_branch is null or s.branch_id = v_branch) group by s.name) q;

  -- ---------------------------------------------------------------- tax
  when 'vat_monthly' then
    v_title := 'ضريبة القيمة المضافة الشهرية';
    v_cols := public.pos_cols(array['month','sales_base','output_vat','purchases_base','input_vat','net_vat'],
      array['الشهر','المبيعات الخاضعة','ضريبة المبيعات','المشتريات الخاضعة','ضريبة المدخلات','الصافي المستحق'], 'tmmmmm');
    select coalesce(jsonb_agg(jsonb_build_object('month', m.month, 'sales_base', m.sales_base, 'output_vat', m.output_vat,
             'purchases_base', m.purchases_base, 'input_vat', m.input_vat, 'net_vat', m.output_vat - m.input_vat) order by m.month), '[]')
      into v_rows from (
      select g.month,
             coalesce((select sum(o.total_amount - o.tax_amount) from public.pos_rpt_orders(c.company_id, v_branch, v_from, v_to) o
                        where to_char(public.pos_local_date(o.created_at), 'YYYY-MM') = g.month), 0) as sales_base,
             coalesce((select sum(o.tax_amount) from public.pos_rpt_orders(c.company_id, v_branch, v_from, v_to) o
                        where to_char(public.pos_local_date(o.created_at), 'YYYY-MM') = g.month), 0) as output_vat,
             coalesce((select sum(i.amount) from public.supplier_invoices i where i.company_id = c.company_id
                         and to_char(i.invoice_date, 'YYYY-MM') = g.month), 0) as purchases_base,
             coalesce((select sum(i.tax_amount) from public.supplier_invoices i where i.company_id = c.company_id
                         and to_char(i.invoice_date, 'YYYY-MM') = g.month), 0) as input_vat
        from (select distinct to_char(d::date, 'YYYY-MM') as month from generate_series(v_from, v_to, interval '1 day') d) g) m;

  when 'order_cancellations' then
    v_title := 'الطلبات الملغية (تفاصيل كاملة)';
    v_cols := public.pos_cols(array['at','order_number','order_type','table_number','waiter','by_staff','manager','reason','items_voided','voided_value','total','customer','cust_prior','cust_90d'],
      array['الوقت','الطلب','النوع','الطاولة','الويتر','مين ألغاه','المدير الموافق','السبب','عدد الأصناف الملغية','قيمة الأصناف الملغية','إجمالي الطلب','العميل','إلغاءات سابقة للعميل','منها آخر ٩٠ يوم'], 'ttttttttnmmttt');
    select coalesce(jsonb_agg(to_jsonb(q) order by q.at desc), '[]') into v_rows from (
      select to_char(l.created_at at time zone 'Africa/Cairo', 'YYYY-MM-DD HH24:MI') as at, o.order_number,
             case o.order_type when 'dine_in' then 'صالة' when 'takeaway' then 'تيك أواي' when 'delivery' then 'توصيل' when 'pickup' then 'استلام' else o.order_type end as order_type,
             o.table_number, w.name as waiter, s.name as by_staff, m.name as manager, cr.reason,
             coalesce((l.details->>'items_voided')::numeric, 0) as items_voided,
             (select round(sum((vi.details->>'qty_voided')::numeric * coalesce((vi.details->>'unit_price')::numeric, 0)), 2)
                from public.order_logs vi where vi.order_id = l.order_id and vi.action = 'VOID_ITEM_CANCEL_ORDER') as voided_value,
             coalesce((l.details->>'total_before')::numeric, 0) as total,
             coalesce(cu.name, 'زائر') as customer,
             case when o.customer_id is null then null else
               (select count(*) from public.order_logs l2 join public.orders o2 on o2.id = l2.order_id
                 where l2.action = 'CANCEL_ORDER' and o2.company_id = o.company_id and o2.customer_id = o.customer_id
                   and l2.created_at < l.created_at) end as cust_prior,
             case when o.customer_id is null then null else
               (select count(*) from public.order_logs l2 join public.orders o2 on o2.id = l2.order_id
                 where l2.action = 'CANCEL_ORDER' and o2.company_id = o.company_id and o2.customer_id = o.customer_id
                   and l2.created_at >= l.created_at - interval '90 days' and l2.created_at < l.created_at) end as cust_90d
        from public.order_logs l
        join public.orders o on o.id = l.order_id
        left join public.staff w on w.id = o.waiter_id
        left join public.staff s on s.id = l.user_id
        left join public.staff m on m.id = public.pos_uuid(l.details->>'approved_by_manager_id')
        left join public.cancel_reasons cr on cr.id = public.pos_uuid(l.details->>'reason_id')
        left join public.customers cu on cu.id = o.customer_id
       where l.action = 'CANCEL_ORDER' and o.company_id = c.company_id and (v_branch is null or o.branch_id = v_branch)
         and public.pos_local_date(l.created_at) between v_from and v_to) q;

  when 'cancelled_order_items' then
    v_title := 'أصناف الطلبات الملغية';
    v_cols := public.pos_cols(array['at','order_number','product','qty','unit_price','value','reason','by_staff','manager','customer'],
      array['الوقت','الطلب','الصنف','الكمية','السعر','القيمة','السبب','ألغاه','المدير الموافق','العميل'], 'tttnmmtttt');
    select coalesce(jsonb_agg(to_jsonb(q) order by q.at desc), '[]') into v_rows from (
      select to_char(vi.created_at at time zone 'Africa/Cairo', 'YYYY-MM-DD HH24:MI') as at, o.order_number,
             vi.details->>'product' as product, (vi.details->>'qty_voided')::numeric as qty,
             coalesce((vi.details->>'unit_price')::numeric, 0) as unit_price,
             round((vi.details->>'qty_voided')::numeric * coalesce((vi.details->>'unit_price')::numeric, 0), 2) as value,
             cr.reason, s.name as by_staff, m.name as manager, coalesce(cu.name, 'زائر') as customer
        from public.order_logs vi
        join public.orders o on o.id = vi.order_id
        join public.order_logs cl on cl.order_id = vi.order_id and cl.action = 'CANCEL_ORDER'
        left join public.staff s on s.id = vi.user_id
        left join public.staff m on m.id = public.pos_uuid(vi.details->>'approved_by_manager_id')
        left join public.cancel_reasons cr on cr.id = public.pos_uuid(vi.details->>'reason_id')
        left join public.customers cu on cu.id = o.customer_id
       where vi.action = 'VOID_ITEM_CANCEL_ORDER' and o.company_id = c.company_id and (v_branch is null or o.branch_id = v_branch)
         and public.pos_local_date(vi.created_at) between v_from and v_to) q;

  else
    return jsonb_build_object('ok', false, 'reason', 'unknown_action');
  end case;

  return jsonb_build_object('ok', true, 'key', p_key, 'title', v_title, 'columns', v_cols, 'rows', coalesce(v_rows, '[]'::jsonb),
    'from', v_from, 'to', v_to,
    'branch', coalesce((select b.name from public.branches b where b.id = v_branch), 'كل الفروع'));
end;
$$;

create or replace function public.motionpos_version_public()
returns text
language sql
immutable
as $$
  select '029'
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
  v_token text := 'motionpos-selftest-' || md5(random()::text || clock_timestamp()::text);
  v_staff uuid;
  v_res jsonb;
  v_cols int;
begin
  begin
    select s.id into v_staff
      from public.staff s join public.roles r on r.id = s.role_id
     where s.is_active is true and r.name = 'owner'
     limit 1;
    if v_staff is null then
      raise notice 'selftest skipped: no active owner';
      raise exception using errcode = 'P0099', message = 'selftest_skip';
    end if;

    insert into public.staff_sessions (token_hash, staff_id, expires_at)
    values (encode(extensions.digest(v_token, 'sha256'), 'hex'), v_staff, now() + interval '10 minutes');

    v_res := public.report_secure(v_token, 'order_cancellations', current_date - 30, current_date, null);
    if not coalesce((v_res->>'ok')::boolean, false) then raise exception 'SELFTEST order_cancellations: %', v_res; end if;
    v_cols := jsonb_array_length(coalesce(v_res->'columns', '[]'::jsonb));
    if v_cols <> 14 then raise exception 'SELFTEST order_cancellations columns: %', v_cols; end if;

    v_res := public.report_secure(v_token, 'cancelled_order_items', current_date - 30, current_date, null);
    if not coalesce((v_res->>'ok')::boolean, false) then raise exception 'SELFTEST cancelled_order_items: %', v_res; end if;
    v_cols := jsonb_array_length(coalesce(v_res->'columns', '[]'::jsonb));
    if v_cols <> 10 then raise exception 'SELFTEST cancelled_order_items columns: %', v_cols; end if;

    v_res := public.report_secure(v_token, 'voids_detail', current_date - 30, current_date, null);
    if not coalesce((v_res->>'ok')::boolean, false) then raise exception 'SELFTEST voids_detail broken: %', v_res; end if;

    raise notice 'MOTIONPOS-029-SELFTEST-OK';
    raise exception using errcode = 'P0099', message = 'selftest_rollback';
  exception when sqlstate 'P0099' then
    null;
  end;
end;
$selftest$;

notify pgrst, 'reload schema';

commit;

