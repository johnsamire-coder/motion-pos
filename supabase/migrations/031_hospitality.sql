-- 031_hospitality.sql
-- Hospitality: close an order as hospitality instead of taking payment.
-- No payment rows (drawer, shift and day close untouched). Stock is consumed by recipes as movement type
-- 'hospitality' (not 'sale', so cost of sales and daily profit stay clean). One journal entry at cost:
-- Dr 6600 (owner_guest, staff) / 3300 (family) / 6300 (marketing)  Cr 1200.
-- Owner PIN: any amount. Manager PIN: daily limit per manager on menu value (settings hospitality.manager_daily_limit,
-- empty = owner only). A closed hospitality order cannot be refunded or cancelled (lock trigger).
-- New: table hospitality_orders, function hospitality_close_secure, report 'hospitality', settings section 'hospitality',
-- permission 'hospitality', account 6600, trigger trg_orders_hospitality_lock.
-- Copied verbatim with small edits: pos_settings_defaults, inv_variance_secure, order_print_data_secure, report_secure.
-- Rewritten with one extra condition: pos_rpt_orders, pos_loyalty_spent (exclude hospitality).
-- Rules: begin/commit, preflight (needs 030), version bump to 031, grants loop, rolled-back self-test.

begin;

do $preflight$
begin
  if length('إكراميات') <> 8 then
    raise exception 'file_encoding_broken: read the file as UTF-8';
  end if;
  if public.motionpos_version_public() not in ('030', '031') then
    raise exception 'schema_preflight_failed: run 030 first';
  end if;
end;
$preflight$;

-- 1) new stock movement type
alter table public.stock_movements drop constraint if exists stock_movements_movement_type_check;
alter table public.stock_movements add constraint stock_movements_movement_type_check check (movement_type = any (array[
  'opening_balance', 'purchase', 'sale', 'waste', 'transfer_in', 'transfer_out', 'adjustment', 'hospitality']));

-- 2) account 6600 next to 6300 for every company
insert into public.accounts (company_id, code, name_ar, name_en, account_type, normal_balance, parent_id, is_system_account)
select x.company_id, '6600', 'مصروف ضيافة', 'Hospitality expense', 'expense', 'debit', x.parent_id, true
  from (select distinct on (a.company_id) a.company_id, a.parent_id from public.accounts a where a.code = '6300' order by a.company_id) x
 where not exists (select 1 from public.accounts b where b.code = '6600' and b.company_id is not distinct from x.company_id);

-- 3) hospitality log (one row per order)
create table if not exists public.hospitality_orders (
  order_id uuid primary key references public.orders(id) on delete cascade,
  company_id uuid,
  branch_id uuid,
  category text not null check (category in ('owner_guest', 'family', 'staff', 'marketing')),
  guest_name text,
  note text,
  menu_value numeric(12,2) not null default 0,
  cost numeric(12,2) not null default 0,
  account_code text,
  requested_by uuid,
  approved_by uuid,
  approved_role text,
  created_at timestamptz not null default now()
);
create index if not exists hospitality_orders_company_day_idx on public.hospitality_orders (company_id, created_at);
alter table public.hospitality_orders enable row level security;
revoke all on table public.hospitality_orders from public, anon, authenticated;

-- 4) permission for cashier and branch manager (owner always allowed)
insert into public.role_permissions (role_name, perm)
select v.r, 'hospitality' from (values ('cashier'), ('branch_manager')) v(r)
 where exists (select 1 from public.roles ro where ro.name = v.r)
on conflict do nothing;
-- 5) settings defaults: new section 'hospitality'
create or replace function public.pos_settings_defaults()
returns jsonb
language sql
immutable
as $$
  select jsonb_build_object(
    'general', jsonb_build_object('company_name', 'Motion POS', 'logo', '', 'address', '', 'phone', '', 'tax_number', '',
                                  'commercial_register', '', 'currency', 'ج.م'),
    'receipt', jsonb_build_object('header', '', 'footer', 'شكراً لزيارتكم', 'show_logo', true, 'paper_mm', 80, 'copies', 1,
                                  'auto_print_after_pay', false, 'auto_kitchen_ticket', false, 'show_tax_number', true,
                                  'show_feedback_qr', true),
    'pos', jsonb_build_object('order_types', jsonb_build_array('dine_in', 'takeaway', 'delivery', 'pickup'),
                              'payment_methods', jsonb_build_array('cash', 'card', 'instapay', 'wallet', 'on_account'),
                              'require_waiter', false, 'round_total', false,
                              'quick_notes', jsonb_build_array('بدون بصل', 'بدون طماطم', 'بدون مايونيز', 'حار', 'سكر زيادة',
                                                               'سكر خفيف', 'سكر بره', 'من غير سكر', 'من غير تلج', 'تلج زيادة')),
    'kds', jsonb_build_object('stations', jsonb_build_array('kitchen', 'bar', 'shisha'), 'warn_minutes', 15, 'sound', true,
                              'refresh_seconds', 10, 'warn_kitchen_minutes', 20, 'warn_bar_minutes', 10, 'warn_shisha_minutes', 10,
                              'rush_kitchen_orders', 0, 'rush_kitchen_minutes', 10, 'rush_bar_orders', 0, 'rush_bar_minutes', 5,
                              'rush_shisha_orders', 0, 'rush_shisha_minutes', 5),
    'waiter_qr', jsonb_build_object('qr_enabled', true, 'qr_call_waiter', true, 'qr_request_bill', true, 'qr_show_prices', true,
                                    'qr_ordering', true,
                                    'qr_welcome', 'أهلاً بيك 👋 اختار اللي نفسك فيه، وإحنا نجهّزهولك',
                                    'qr_privacy_note', 'بنسأل عن اسمك ورقمك عشان الويتر يعرفك ويأكد طلبك، وعشان نفتكرك المرة الجاية ونبعتلك عروضنا وهدية عيد ميلادك 🎁 بياناتك أمانة عندنا ومش بنشاركها مع أي حد.'),
    'loyalty', jsonb_build_object('enabled', false, 'min_spent', 1000, 'period_days', 365, 'percent', 5, 'label', 'خصم انتماء'),
    'social', jsonb_build_object('facebook_url', '', 'instagram_url', '', 'feedback_enabled', true, 'links_in_thanks', true,
                                 'feedback_intro', 'رأيك يهمنا جداً 🙏 قولنا إيه اللي عجبك وإيه اللي محتاج يتحسن'),
    'payinfo', jsonb_build_object('instapay', '', 'instapay_link', '', 'wallet', '', 'wallet_name', 'فودافون كاش',
                                  'show_on_receipt', true, 'show_on_menu', true),
    'hospitality', jsonb_build_object('enabled', true, 'manager_daily_limit', 500, 'auto_print', true),
    'shift', jsonb_build_object('default_float', 0, 'drawer_alert_limit', 5000),
    'inventory', jsonb_build_object('allow_negative_stock', true, 'default_min_stock', 5, 'units', '[]'::jsonb),
    'staff', jsonb_build_object('work_start_time', '09:00', 'late_grace_minutes', 15),
    'offline', jsonb_build_object('mode', 'none', 'local_server_url', ''),
    'whatsapp', jsonb_build_object(
      'customer_message', 'أهلاً يا {الاسم} 👋',
      'thanks_enabled', true,
      'thanks_message', 'شكراً يا {الاسم} إنك شرفتنا ونورتنا النهارده 🙏 بنحب نشوفك دايماً في {المحل} ❤️')
  )
$$;

-- 6) sales reports, dashboard and loyalty ignore hospitality
create or replace function public.pos_rpt_orders(p_company_id uuid, p_branch_id uuid, p_from date, p_to date)
returns setof public.orders
language sql
stable
security definer
set search_path = public, extensions
as $$
  select o.* from public.orders o
   where o.company_id = p_company_id and o.status = 'closed'
     and coalesce(o.payment_method, '') <> 'hospitality'
     and (p_branch_id is null or o.branch_id = p_branch_id)
     and (o.created_at at time zone 'Africa/Cairo')::date between p_from and p_to
$$;

create or replace function public.pos_loyalty_spent(p_customer_id uuid, p_company_id uuid, p_exclude uuid)
returns numeric
language sql
stable
security definer
set search_path = public, extensions
as $$
  select coalesce(sum(o.total_amount), 0)
    from public.orders o
   where o.customer_id = p_customer_id and o.company_id = p_company_id and o.status = 'closed'
     and coalesce(o.payment_method, '') <> 'hospitality'
     and o.id is distinct from p_exclude
     and o.created_at > now() - make_interval(days => greatest(1, least(3650,
           coalesce(nullif(public.pos_app_settings(p_company_id) -> 'loyalty' ->> 'period_days', '')::numeric, 365)::int)))
$$;
-- 7) expected-vs-actual counts hospitality as normal use
create or replace function public.inv_variance_secure(p_token text, p_warehouse_id uuid, p_from date, p_to date)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
begin
  select * into c from public.pos_ctx(p_token, 'inventory');
  if not public.pos_warehouse_ok(p_warehouse_id, c.branch_id, c.role_name) then
    return jsonb_build_object('ok', false, 'reason', 'warehouse_not_allowed');
  end if;
  return jsonb_build_object('ok', true, 'rows', coalesce((
    select jsonb_agg(jsonb_build_object(
             'ingredient', q.name, 'unit', q.unit, 'sales_qty', q.sales_qty, 'waste_qty', q.waste_qty,
             'expected_qty', q.sales_qty + q.waste_qty,
             'actual_qty', q.sales_qty + q.waste_qty - q.count_qty,
             'difference_qty', -q.count_qty,
             'difference_value', round(-q.count_qty * q.cost, 2)) order by round(q.count_qty * q.cost, 2))
      from (
        select i.name, i.unit, coalesce(i.cost_per_unit, 0) as cost,
               coalesce(sum(case when sm.movement_type in ('sale', 'hospitality') then -sm.quantity end), 0) as sales_qty,
               coalesce(sum(case when sm.movement_type = 'waste' then -sm.quantity end), 0) as waste_qty,
               coalesce(sum(case when sm.movement_type = 'adjustment' and sm.reference_type = 'stocktake' then sm.quantity end), 0) as count_qty
          from public.stock_movements sm
          join public.ingredients i on i.id = sm.ingredient_id
         where sm.warehouse_id = p_warehouse_id
           and sm.created_at::date between coalesce(p_from, current_date - 30) and coalesce(p_to, current_date)
         group by i.name, i.unit, i.cost_per_unit) q), '[]'::jsonb));
end;
$$;

-- 8) print data knows the order is hospitality
create or replace function public.order_print_data_secure(p_token text, p_order_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
  v jsonb;
begin
  select * into c from public.pos_ctx(p_token, null);
  select jsonb_build_object(
    'order_number', o.order_number, 'order_type', o.order_type, 'status', o.status, 'created_at', o.created_at,
    'table_number', t.table_number, 'waiter', w.name, 'customer', cu.name, 'guest_count', o.guest_count,
    'sub_total', o.sub_total, 'discount_amount', o.discount_amount, 'service_charge_amount', o.service_charge_amount,
    'tax_amount', o.tax_amount, 'total_amount', o.total_amount, 'branch', b.name, 'branch_address', b.address,
    'loyalty_percent', o.loyalty_percent, 'source', o.source, 'feedback_token', b.public_token,
    'loyalty_amount', (public.compute_order_totals(o.id) ->> 'loyalty_discount')::numeric,
    'items', coalesce((select jsonb_agg(jsonb_build_object('name', coalesce(p.name, 'صنف'), 'quantity', oi.quantity,
                                                           'unit_price', oi.unit_price, 'total_price', oi.total_price,
                                                           'notes', oi.item_notes, 'station', public.pos_item_station(oi.product_id),
                                                           'modifiers', coalesce((select jsonb_agg(m.modifier_name)
                                                                                    from public.order_item_modifiers m
                                                                                   where m.order_item_id = oi.id), '[]'::jsonb))
                                        order by p.name)
                         from public.order_items oi left join public.products p on p.id = oi.product_id
                        where oi.order_id = o.id and coalesce(oi.status, 'active') = 'active'), '[]'::jsonb),
    'payments', coalesce((select jsonb_agg(jsonb_build_object('method', p.payment_method, 'amount', p.amount, 'tip', p.tip_amount))
                            from public.payments p where p.order_id = o.id), '[]'::jsonb),
    'hospitality', (select jsonb_build_object('category', h.category, 'guest_name', h.guest_name, 'note', h.note,
                                             'approved_by', ap.name, 'approved_role', h.approved_role, 'value', h.menu_value)
                      from public.hospitality_orders h left join public.staff ap on ap.id = h.approved_by where h.order_id = o.id),
    'cashier', (select st.name from public.payments p join public.pos_shifts sh on sh.id = p.shift_id
                  join public.staff st on st.id = sh.staff_id where p.order_id = o.id limit 1))
    into v
    from public.orders o
    left join public.tables t on t.id = o.table_id
    left join public.staff w on w.id = o.waiter_id
    left join public.customers cu on cu.id = o.customer_id
    left join public.branches b on b.id = o.branch_id
   where o.id = p_order_id and o.branch_id = c.branch_id;
  if v is null then
    return jsonb_build_object('ok', false, 'reason', 'order_not_found');
  end if;
  return jsonb_build_object('ok', true, 'order', v, 'settings', public.pos_app_settings(c.company_id));
end;
$$;

-- 9) reports: new 'hospitality', turnover counts it, approvals label
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
             when 'CHANGE_CHARGES' then 'شيل خدمة/ضريبة' when 'REFUND_ORDER' then 'مرتجع' when 'CANCEL_ORDER' then 'إلغاء طلب' when 'HOSPITALITY' then 'ضيافة'
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
                         and sm.movement_type in ('sale', 'waste', 'hospitality') and (v_branch is null or sm.branch_id = v_branch)
                         and public.pos_local_date(sm.created_at) between v_from and v_to), 0) as used,
             coalesce((select sum(ws.quantity) from public.warehouse_stock ws join public.warehouses w on w.id = ws.warehouse_id
                        where ws.ingredient_id = i.id and (v_branch is null or w.branch_id = v_branch)), 0) as current,
             round(coalesce((select sum(ws.quantity) from public.warehouse_stock ws join public.warehouses w on w.id = ws.warehouse_id
                              where ws.ingredient_id = i.id and (v_branch is null or w.branch_id = v_branch)), 0)
                   / nullif(coalesce((select -sum(sm.quantity) from public.stock_movements sm where sm.ingredient_id = i.id
                         and sm.movement_type in ('sale', 'waste', 'hospitality') and (v_branch is null or sm.branch_id = v_branch)
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

  when 'hospitality' then
    v_title := 'الضيافة';
    v_cols := public.pos_cols(array['at','order_number','category','guest','items','value','cost','account','requested_by','approved_by'],
      array['الوقت','الطلب','النوع','الضيف','عدد الأصناف','القيمة بسعر المنيو','التكلفة','الحساب','طلبها','وافق عليها'], 'ttttnmmttt');
    select coalesce(jsonb_agg(to_jsonb(q) order by q.at desc), '[]') into v_rows from (
      select to_char(h.created_at at time zone 'Africa/Cairo', 'YYYY-MM-DD HH24:MI') as at, o.order_number,
             case h.category when 'owner_guest' then 'ضيف المالك' when 'family' then 'أهل' when 'staff' then 'موظفين'
                             when 'marketing' then 'دعاية' else h.category end as category,
             h.guest_name as guest,
             (select coalesce(sum(oi.quantity), 0) from public.order_items oi
               where oi.order_id = o.id and coalesce(oi.status, 'active') = 'active') as items,
             h.menu_value as value, h.cost, h.account_code as account, rq.name as requested_by, ap.name as approved_by
        from public.hospitality_orders h join public.orders o on o.id = h.order_id
        left join public.staff rq on rq.id = h.requested_by left join public.staff ap on ap.id = h.approved_by
       where h.company_id = c.company_id and (v_branch is null or h.branch_id = v_branch)
         and public.pos_local_date(h.created_at) between v_from and v_to) q;
  else
    return jsonb_build_object('ok', false, 'reason', 'unknown_action');
  end case;

  return jsonb_build_object('ok', true, 'key', p_key, 'title', v_title, 'columns', v_cols, 'rows', coalesce(v_rows, '[]'::jsonb),
    'from', v_from, 'to', v_to,
    'branch', coalesce((select b.name from public.branches b where b.id = v_branch), 'كل الفروع'));
end;
$$;

-- 10) the hospitality close, the lock, version, sync
create or replace function public.hospitality_close_secure(
  p_token text, p_order_id uuid, p_category text, p_guest_name text, p_note text, p_pin text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
  v_order public.orders%rowtype;
  v_set jsonb;
  v_lim text;
  v_limit numeric;
  v_used numeric;
  v_value numeric;
  v_approver uuid;
  v_role text;
  v_code text;
  v_wh uuid;
  v_x record;
  v_unit numeric;
  v_cost numeric := 0;
  v_guest text := left(nullif(btrim(coalesce(p_guest_name, '')), ''), 100);
  v_note text := left(nullif(btrim(coalesce(p_note, '')), ''), 300);
begin
  select * into c from public.pos_ctx(p_token, 'hospitality');

  v_set := coalesce(public.pos_app_settings(c.company_id) -> 'hospitality', '{}'::jsonb);
  if not coalesce((v_set->>'enabled')::boolean, true) then
    return jsonb_build_object('ok', false, 'reason', 'hospitality_disabled');
  end if;

  v_code := case p_category when 'owner_guest' then '6600' when 'staff' then '6600'
                            when 'family' then '3300' when 'marketing' then '6300' end;
  if v_code is null then
    return jsonb_build_object('ok', false, 'reason', 'invalid_value');
  end if;

  select o.* into v_order from public.orders o where o.id = p_order_id and o.branch_id = c.branch_id for update;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'order_not_found');
  end if;
  if coalesce(v_order.status, '') in ('paid', 'closed', 'cancelled') then
    return jsonb_build_object('ok', false, 'reason', 'order_not_open');
  end if;
  if not exists (select 1 from public.order_items oi
                  where oi.order_id = p_order_id and coalesce(oi.status, 'active') = 'active') then
    return jsonb_build_object('ok', false, 'reason', 'empty_order');
  end if;
  if exists (select 1 from public.payments p where p.order_id = p_order_id) then
    return jsonb_build_object('ok', false, 'reason', 'order_has_payments');
  end if;

  perform public.recalc_order_totals(p_order_id);
  select coalesce(o.sub_total, o.total_amount, 0) into v_value from public.orders o where o.id = p_order_id;

  -- approval: manager or owner of this branch, else the company owner
  v_approver := public.verify_manager_pin(p_pin, c.branch_id);
  if v_approver is null then
    v_approver := public.pos_verify_owner_pin(p_pin, c.company_id);
  end if;
  if v_approver is null then
    return jsonb_build_object('ok', false, 'reason', 'manager_pin');
  end if;
  select r.name into v_role from public.staff s join public.roles r on r.id = s.role_id where s.id = v_approver;

  if v_role is distinct from 'owner' then
    v_lim := btrim(coalesce(v_set->>'manager_daily_limit', ''));
    v_limit := case when v_lim ~ '^[0-9]{1,9}(\.[0-9]{1,2})?$' then v_lim::numeric end;
    if coalesce(v_limit, 0) <= 0 then
      return jsonb_build_object('ok', false, 'reason', 'owner_pin_required');
    end if;
    select coalesce(sum(h.menu_value), 0) into v_used
      from public.hospitality_orders h
     where h.approved_by = v_approver and public.pos_local_date(h.created_at) = public.pos_local_date(now());
    if v_used + v_value > v_limit then
      return jsonb_build_object('ok', false, 'reason', 'hospitality_limit', 'used', v_used, 'limit', v_limit, 'value', v_value);
    end if;
  end if;

  -- stock: same recipe consumption as a sale, typed 'hospitality'
  v_wh := public.pos_branch_warehouse(v_order.branch_id);
  for v_x in
    select ci.ingredient_id, sum(ci.qty) as qty
      from public.order_items oi
      cross join lateral public.pos_item_consumption(oi.id, oi.quantity) ci
     where oi.order_id = p_order_id
       and coalesce(oi.status, 'active') = 'active'
     group by ci.ingredient_id
  loop
    if v_x.qty > 0 then
      if v_wh is null then
        raise exception 'no_branch_warehouse';
      end if;
      select coalesce(i.cost_per_unit, 0) into v_unit from public.ingredients i where i.id = v_x.ingredient_id;
      perform public.record_stock_movement(
        v_order.company_id, v_order.brand_id, v_order.branch_id, v_wh, v_x.ingredient_id,
        'hospitality', -v_x.qty, coalesce(v_unit, 0), 'order', p_order_id,
        'ضيافة - طلب ' || coalesce(v_order.order_number, ''), c.staff_id);
      v_cost := v_cost + round(v_x.qty * coalesce(v_unit, 0), 2);
    end if;
  end loop;

  -- one entry at cost: expense (or owner current account) against inventory
  if v_cost > 0 then
    perform public.pos_post_je(v_order.company_id, v_order.branch_id, 'inventory', 'order', p_order_id,
      'قيد ضيافة - طلب ' || coalesce(v_order.order_number, ''),
      jsonb_build_array(public.pos_je_line(v_code, v_cost, 0, 'ضيافة'),
                        public.pos_je_line('1200', 0, v_cost, 'خصم المخزون')), c.staff_id);
  end if;

  update public.orders
     set status = 'closed', is_posted_to_gl = true, payment_method = 'hospitality'
   where id = p_order_id;

  perform public.pos_free_table_if_empty(v_order.table_id);

  insert into public.hospitality_orders (order_id, company_id, branch_id, category, guest_name, note, menu_value, cost,
                                         account_code, requested_by, approved_by, approved_role)
  values (p_order_id, v_order.company_id, v_order.branch_id, p_category, v_guest, v_note, v_value, v_cost,
          v_code, c.staff_id, v_approver, v_role);

  insert into public.order_logs (order_id, user_id, action, details)
  values (p_order_id, c.staff_id, 'HOSPITALITY', jsonb_build_object(
    'category', p_category, 'value', v_value, 'cost', v_cost, 'account', v_code,
    'approved_by_manager_id', v_approver, 'approved_role', v_role, 'guest', v_guest));

  return jsonb_build_object('ok', true, 'order_number', v_order.order_number, 'value', v_value,
                            'cost', v_cost, 'category', p_category);
end;
$$;

create or replace function public.trg_orders_hospitality_lock()
returns trigger
language plpgsql
as $$
begin
  if coalesce(current_setting('motionpos.sync_apply', true), '') = 'on'
     or coalesce(current_setting('motionpos.system_reset', true), '') = 'on' then
    return new;
  end if;
  if coalesce(old.payment_method, '') = 'hospitality' and old.status = 'closed'
     and new.status is distinct from old.status then
    raise exception 'hospitality_locked';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_orders_hospitality_lock on public.orders;
create trigger trg_orders_hospitality_lock before update on public.orders
  for each row execute function public.trg_orders_hospitality_lock();

create or replace function public.motionpos_version_public()
returns text
language sql
immutable
as $$
  select '031'
$$;

-- the new table joins the shop <-> server sync
select public.pos_sync_attach_all();
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
  v_owner uuid;
  v_branch uuid;
  v_company uuid;
  v_brand uuid;
  v_prod uuid;
  v_ing uuid;
  v_order uuid;
  v_res jsonb;
  v_mgr uuid;
  v_role uuid;
begin
  begin
    perform set_config('motionpos.sync_apply', 'on', true);
    select s.id, s.branch_id, s.company_id into v_owner, v_branch, v_company
      from public.staff s join public.roles r on r.id = s.role_id
     where s.is_active is true and s.branch_id is not null and r.name = 'owner'
     limit 1;
    if v_owner is null then
      raise notice 'selftest skipped: no active owner with a branch';
      raise exception using errcode = 'P0099', message = 'selftest_skip';
    end if;
    select b.brand_id into v_brand from public.branches b where b.id = v_branch;

    update public.staff set pin_hash = extensions.crypt('4321', '$2a$06$abcdefghijklmnopqrstuu') where id = v_owner;
    insert into public.staff_sessions (token_hash, staff_id, expires_at)
    values (encode(extensions.digest(v_token, 'sha256'), 'hex'), v_owner, now() + interval '10 minutes');

    select r.product_id, r.ingredient_id into v_prod, v_ing
      from public.recipes r join public.products p on p.id = r.product_id
     where p.brand_id = v_brand and r.ingredient_id is not null and r.quantity_required > 0
     limit 1;
    if v_prod is null then
      raise exception 'SELFTEST no product with a recipe';
    end if;
    update public.ingredients set cost_per_unit = 1000 where id = v_ing;

    -- a) owner, family
    insert into public.orders (company_id, brand_id, branch_id, order_type, status, guest_count)
    values (v_company, v_brand, v_branch, 'takeaway', 'open', 1) returning id into v_order;
    insert into public.order_items (order_id, product_id, quantity, unit_price, total_price, status)
    values (v_order, v_prod, 2, 50, 100, 'active');

    v_res := public.hospitality_close_secure(v_token, v_order, 'bad', null, null, '4321');
    if v_res->>'reason' is distinct from 'invalid_value' then raise exception 'SELFTEST bad category: %', v_res; end if;
    v_res := public.hospitality_close_secure(v_token, v_order, 'family', null, null, 'abcd');
    if v_res->>'reason' is distinct from 'manager_pin' then raise exception 'SELFTEST bad pin: %', v_res; end if;

    v_res := public.hospitality_close_secure(v_token, v_order, 'family', 'ضيف تجربة', 'ملاحظة', '4321');
    if not coalesce((v_res->>'ok')::boolean, false) then raise exception 'SELFTEST family: %', v_res; end if;
    if coalesce((v_res->>'cost')::numeric, 0) <= 0 then raise exception 'SELFTEST no cost: %', v_res; end if;
    if not exists (select 1 from public.orders o where o.id = v_order and o.status = 'closed' and o.payment_method = 'hospitality') then
      raise exception 'SELFTEST order not closed';
    end if;
    if exists (select 1 from public.payments p where p.order_id = v_order) then raise exception 'SELFTEST payment written'; end if;
    if not exists (select 1 from public.hospitality_orders h where h.order_id = v_order and h.account_code = '3300'
                    and h.approved_role = 'owner' and h.cost > 0) then
      raise exception 'SELFTEST log row';
    end if;
    if not exists (select 1 from public.stock_movements m where m.reference_id = v_order and m.movement_type = 'hospitality')
       or exists (select 1 from public.stock_movements m where m.reference_id = v_order and m.movement_type = 'sale') then
      raise exception 'SELFTEST stock type';
    end if;
    if not exists (select 1 from public.journal_entries j where j.reference_type = 'order' and j.reference_id = v_order and j.journal_type = 'inventory')
       or exists (select 1 from public.journal_entries j where j.reference_id = v_order and j.journal_type = 'sales') then
      raise exception 'SELFTEST journal';
    end if;
    if exists (select 1 from public.pos_rpt_orders(v_company, null, current_date - 2, current_date + 2) x where x.id = v_order) then
      raise exception 'SELFTEST shows in sales';
    end if;

    -- b) no second close, no refund / cancel
    v_res := public.hospitality_close_secure(v_token, v_order, 'family', null, null, '4321');
    if v_res->>'reason' is distinct from 'order_not_open' then raise exception 'SELFTEST second close: %', v_res; end if;
    perform set_config('motionpos.sync_apply', '', true);
    begin
      update public.orders set status = 'cancelled' where id = v_order;
      raise exception 'lock_missing';
    exception when others then
      if sqlerrm <> 'hospitality_locked' then raise exception 'SELFTEST lock: %', sqlerrm; end if;
    end;
    perform set_config('motionpos.sync_apply', 'on', true);

    -- c) print data and report
    v_res := public.order_print_data_secure(v_token, v_order);
    if v_res->'order'->'hospitality'->>'category' is distinct from 'family' then raise exception 'SELFTEST print: %', v_res; end if;
    v_res := public.report_secure(v_token, 'hospitality', current_date - 2, current_date + 2, null);
    if not coalesce((v_res->>'ok')::boolean, false) or jsonb_array_length(v_res->'rows') < 1 then
      raise exception 'SELFTEST report: %', v_res;
    end if;

    -- d) owner, marketing -> 6300
    insert into public.orders (company_id, brand_id, branch_id, order_type, status, guest_count)
    values (v_company, v_brand, v_branch, 'takeaway', 'open', 1) returning id into v_order;
    insert into public.order_items (order_id, product_id, quantity, unit_price, total_price, status)
    values (v_order, v_prod, 1, 50, 50, 'active');
    v_res := public.hospitality_close_secure(v_token, v_order, 'marketing', null, null, '4321');
    if not coalesce((v_res->>'ok')::boolean, false)
       or not exists (select 1 from public.hospitality_orders h where h.order_id = v_order and h.account_code = '6300') then
      raise exception 'SELFTEST marketing: %', v_res;
    end if;

    -- e) manager daily limit (only when a test manager can be added)
    select r.id into v_role from public.roles r where r.name = 'branch_manager' limit 1;
    begin
      insert into public.staff (company_id, branch_id, role_id, name, is_active, pin_hash)
      values (v_company, v_branch, v_role, 'مدير تجربة 031', true, extensions.crypt('8642', '$2a$06$abcdefghijklmnopqrstuu'))
      returning id into v_mgr;
    exception when others then
      v_mgr := null;
      raise notice 'manager part skipped: %', sqlerrm;
    end;
    if v_mgr is not null then
      insert into public.orders (company_id, brand_id, branch_id, order_type, status, guest_count)
      values (v_company, v_brand, v_branch, 'takeaway', 'open', 1) returning id into v_order;
      insert into public.order_items (order_id, product_id, quantity, unit_price, total_price, status)
      values (v_order, v_prod, 2, 50, 100, 'active');
      delete from public.app_settings where company_id = v_company and section = 'hospitality';
      insert into public.app_settings (company_id, section, data) values (v_company, 'hospitality', '{"manager_daily_limit": 1}'::jsonb);
      v_res := public.hospitality_close_secure(v_token, v_order, 'staff', null, null, '8642');
      if v_res->>'reason' is distinct from 'hospitality_limit' then raise exception 'SELFTEST limit: %', v_res; end if;
      update public.app_settings set data = '{"manager_daily_limit": ""}'::jsonb where company_id = v_company and section = 'hospitality';
      v_res := public.hospitality_close_secure(v_token, v_order, 'staff', null, null, '8642');
      if v_res->>'reason' is distinct from 'owner_pin_required' then raise exception 'SELFTEST owner only: %', v_res; end if;
      update public.app_settings set data = '{"manager_daily_limit": 999999}'::jsonb where company_id = v_company and section = 'hospitality';
      v_res := public.hospitality_close_secure(v_token, v_order, 'staff', null, null, '8642');
      if not coalesce((v_res->>'ok')::boolean, false)
         or not exists (select 1 from public.hospitality_orders h where h.order_id = v_order and h.account_code = '6600'
                         and h.approved_role = 'branch_manager') then
        raise exception 'SELFTEST manager: %', v_res;
      end if;
    end if;

    raise notice 'MOTIONPOS-031-SELFTEST-OK';
    raise exception using errcode = 'P0099', message = 'selftest_rollback';
  exception when sqlstate 'P0099' then
    null;
  end;
end;
$selftest$;
notify pgrst, 'reload schema';

commit;
