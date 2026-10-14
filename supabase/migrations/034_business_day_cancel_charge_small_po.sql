-- 034_business_day_cancel_charge_small_po.sql
-- 1) Business day: the shop works 8 in the morning to 7 the next morning, so reports count a "day" from a set hour
--    (settings > general > day_start_hour, 0 = midnight). pos_local_date (used by all reports and the dashboard)
--    now shifts by that hour, and pos_rpt_orders uses it too.
-- 2) Two new reports: staff_activity (every action of every user, with time) and staff_summary (per user).
-- 3) Cancelling an order because of an employee's mistake: what was made is recorded as waste and the employee is charged
--    its COST (not the menu price): staff ledger 'shortage' + entry Dr 1130 / Cr 5100. cancel_order_secure gets p_charge_staff_id.
-- 4) Purchasing: the branch manager's own purchase order is approved at once (no owner approval) when it is within
--    settings > purchasing > manager_limit (200), counting all such orders of the business day; he can also post its receipts.
--    The limit is owner-only to change.
-- Functions copied from their latest files (031 defaults/report, 024 settings save, 010 cancel, 022 purchasing) with only these changes.
-- No tables changed. Rules: begin/commit, preflight (needs 033), version bump to 034, grants loop, rolled-back self-test.

begin;

do $preflight$
begin
  if length('إكراميات') <> 8 then
    raise exception 'file_encoding_broken: read the file as UTF-8';
  end if;
  if public.motionpos_version_public() not in ('033', '034') then
    raise exception 'schema_preflight_failed: run 033 first';
  end if;
end;
$preflight$;

-- ---------------------------------------------------------------- business day
create or replace function public.pos_num(p text)
returns numeric
language sql
immutable
as $$
  select case when p ~ '^-?[0-9]{1,12}(\.[0-9]{1,6})?$' then p::numeric end
$$;

create or replace function public.pos_day_start_hour()
returns int
language sql
stable
security definer
set search_path = public, extensions
as $$
  select coalesce((select greatest(0, least(12, floor(public.pos_num(s.data->>'day_start_hour'))))::int
                     from public.app_settings s
                    where s.section = 'general' and s.data ? 'day_start_hour'
                    order by s.updated_at desc nulls last limit 1), 0)
$$;

-- the "day" a moment belongs to: Cairo time minus the day start hour
create or replace function public.pos_local_date(ts timestamptz)
returns date
language sql
stable
as $$ select ((ts at time zone 'Africa/Cairo') - make_interval(hours => (select public.pos_day_start_hour())))::date $$;

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
     and public.pos_local_date(o.created_at) between p_from and p_to
$$;

-- ---------------------------------------------------------------- small purchase orders
create or replace function public.pos_po_manager_limit(p_company_id uuid)
returns numeric
language sql
stable
security definer
set search_path = public, extensions
as $$
  select greatest(0, coalesce(public.pos_num(public.pos_app_settings(p_company_id) -> 'purchasing' ->> 'manager_limit'), 200))
$$;

-- within the manager's limit: this order plus the other orders he/they approved without the owner in the same business day
create or replace function public.pos_po_small_ok(p_company_id uuid, p_branch_id uuid, p_amount numeric, p_exclude uuid)
returns boolean
language sql
stable
security definer
set search_path = public, extensions
as $$
  with lim as (select public.pos_po_manager_limit(p_company_id) as v)
  select coalesce(p_amount, 0) > 0 and (select v from lim) > 0 and coalesce(p_amount, 0) <= (select v from lim)
     and coalesce(p_amount, 0) + coalesce((
           select sum(po.total_amount) from public.purchase_orders po
             join public.staff s on s.id = po.approved_by left join public.roles r on r.id = s.role_id
            where po.company_id = p_company_id and po.branch_id is not distinct from p_branch_id
              and po.id is distinct from p_exclude and po.status <> 'cancelled' and po.approved_at is not null
              and coalesce(r.name, '') <> 'owner'
              and public.pos_local_date(po.approved_at) = public.pos_local_date(now())), 0) <= (select v from lim)
$$;

-- a receipt of a small order approved without the owner (the branch manager can post it)
create or replace function public.pos_gr_small(p_grn_id uuid, p_company_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, extensions
as $$
  select exists (
    select 1 from public.goods_receipts g
      join public.purchase_orders po on po.id = g.purchase_order_id
      join public.staff s on s.id = po.approved_by left join public.roles r on r.id = s.role_id
     where g.id = p_grn_id and po.company_id = p_company_id and coalesce(r.name, '') <> 'owner'
       and po.total_amount <= public.pos_po_manager_limit(p_company_id))
$$;

-- ---------------------------------------------------------------- settings
create or replace function public.pos_settings_defaults()
returns jsonb
language sql
immutable
as $$
  select jsonb_build_object(
    'general', jsonb_build_object('company_name', 'Motion POS', 'logo', '', 'address', '', 'phone', '', 'tax_number', '',
                                  'commercial_register', '', 'currency', 'ج.م', 'day_start_hour', 0),
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
    'purchasing', jsonb_build_object('manager_limit', 200),
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

create or replace function public.app_settings_save_secure(p_token text, p_section text, p_data jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
  v_def jsonb := public.pos_settings_defaults() -> p_section;
  v_clean jsonb := '{}'::jsonb;
  k text;
  v jsonb;
  v_max int;
  v_num numeric;
begin
  select * into c from public.pos_ctx(p_token, 'settings');
  if v_def is null then
    return jsonb_build_object('ok', false, 'reason', 'unknown_action');
  end if;
  if p_section in ('general', 'offline', 'purchasing') and c.role_name <> 'owner' then
    return jsonb_build_object('ok', false, 'reason', 'owner_only');
  end if;
  if jsonb_typeof(p_data) is distinct from 'object' then
    return jsonb_build_object('ok', false, 'reason', 'invalid_value');
  end if;
  for k, v in select e.key, e.value from jsonb_each(p_data) e loop
    if v_def ? k then
      if jsonb_typeof(v) <> jsonb_typeof(v_def -> k) then
        return jsonb_build_object('ok', false, 'reason', 'invalid_value', 'key', k);
      end if;
      v_max := 1000;
      if k = 'logo' then
        v_max := 400000;
      end if;
      if jsonb_typeof(v) = 'string' and length(v #>> '{}') > v_max then
        return jsonb_build_object('ok', false, 'reason', 'value_too_long', 'key', k);
      end if;
      if k = 'logo' and (v #>> '{}') <> '' and (v #>> '{}') !~ '^data:image/(png|jpeg|jpg|webp|svg\+xml);base64,' then
        return jsonb_build_object('ok', false, 'reason', 'invalid_logo');
      end if;
      if jsonb_typeof(v) = 'array' then
        if jsonb_array_length(v) > 50
           or exists (select 1 from jsonb_array_elements(v) x(e)
                       where jsonb_typeof(x.e) <> 'string' or length(x.e #>> '{}') > 60 or btrim(x.e #>> '{}') = '') then
          return jsonb_build_object('ok', false, 'reason', 'invalid_value', 'key', k);
        end if;
      end if;
      if k like 'warn\_%' and jsonb_typeof(v) = 'number' then
        v_num := (v #>> '{}')::numeric;
        if v_num < 1 or v_num > 240 then
          return jsonb_build_object('ok', false, 'reason', 'invalid_value', 'key', k);
        end if;
      end if;
      v_clean := v_clean || jsonb_build_object(k, v);
    end if;
  end loop;
  if p_section = 'offline' and coalesce(v_clean->>'mode', 'none') not in ('none', 'cashier', 'branch') then
    return jsonb_build_object('ok', false, 'reason', 'invalid_value', 'key', 'mode');
  end if;
  if p_section = 'general' and v_clean ? 'day_start_hour'
     and ((v_clean->>'day_start_hour')::numeric < 0 or (v_clean->>'day_start_hour')::numeric > 12) then
    return jsonb_build_object('ok', false, 'reason', 'invalid_value', 'key', 'day_start_hour');
  end if;
  if p_section = 'purchasing' and coalesce((v_clean->>'manager_limit')::numeric, 0) not between 0 and 1000000 then
    return jsonb_build_object('ok', false, 'reason', 'invalid_value', 'key', 'manager_limit');
  end if;
  if p_section = 'receipt' and coalesce((v_clean->>'paper_mm')::int, 80) not in (58, 80) then
    return jsonb_build_object('ok', false, 'reason', 'invalid_value', 'key', 'paper_mm');
  end if;

  if p_section = 'loyalty' and (coalesce((v_clean->>'percent')::numeric, 0) < 0 or coalesce((v_clean->>'percent')::numeric, 0) > 100
                                 or coalesce((v_clean->>'period_days')::numeric, 365) < 1 or coalesce((v_clean->>'period_days')::numeric, 365) > 3650
                                 or coalesce((v_clean->>'min_spent')::numeric, 0) < 0) then
    return jsonb_build_object('ok', false, 'reason', 'invalid_value', 'key', 'loyalty');
  end if;
  if p_section = 'kds' and exists (select 1 from jsonb_each(v_clean) e
                                    where e.key like 'rush\_%' and ((e.value #>> '{}')::numeric < 0 or (e.value #>> '{}')::numeric > 240)) then
    return jsonb_build_object('ok', false, 'reason', 'invalid_value', 'key', 'rush');
  end if;
  if p_section = 'payinfo' and coalesce(v_clean->>'instapay_link', '') !~ '^(https?://[^ <>"]+)?$' then
    return jsonb_build_object('ok', false, 'reason', 'invalid_url');
  end if;
  if p_section = 'social' and (coalesce(v_clean->>'facebook_url', '') !~ '^(https?://[^ <>"]+)?$'
                               or coalesce(v_clean->>'instagram_url', '') !~ '^(https?://[^ <>"]+)?$') then
    return jsonb_build_object('ok', false, 'reason', 'invalid_url');
  end if;

  insert into public.app_settings (company_id, section, data, updated_by)
  values (c.company_id, p_section, v_clean, c.staff_id)
  on conflict (company_id, section)
  do update set data = public.app_settings.data || excluded.data, updated_at = now(), updated_by = excluded.updated_by;

  insert into public.settings_logs (staff_id, action, details)
  values (c.staff_id, 'app_settings', jsonb_build_object('section', p_section, 'keys',
          (select jsonb_agg(x) from jsonb_object_keys(v_clean) x)));
  return jsonb_build_object('ok', true, 'settings', public.pos_app_settings(c.company_id));
end;
$$;

-- ---------------------------------------------------------------- cancel on an employee (the old 4-argument version is replaced)
drop function if exists public.cancel_order_secure(text, uuid, uuid, text);

create or replace function public.cancel_order_secure(
  p_token text, p_order_id uuid, p_reason_id uuid, p_manager_pin text, p_charge_staff_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_staff uuid;
  v_branch uuid;
  v_order public.orders%rowtype;
  v_active int;
  v_manager uuid;
  v_item record;
  v_cost numeric := 0;
  v_charge_name text;
begin
  select rs.staff_id, rs.branch_id into v_staff, v_branch from public.require_session(p_token) rs;

  select o.* into v_order from public.orders o where o.id = p_order_id and o.branch_id = v_branch for update;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'order_not_found');
  end if;
  if coalesce(v_order.status, '') in ('paid', 'closed', 'cancelled') then
    return jsonb_build_object('ok', false, 'reason', 'order_not_open');
  end if;
  if exists (select 1 from public.payments p where p.order_id = p_order_id) then
    return jsonb_build_object('ok', false, 'reason', 'order_has_payments');
  end if;

  select count(*) into v_active
    from public.order_items oi
   where oi.order_id = p_order_id and coalesce(oi.status, 'active') = 'active';

  if v_active > 0 then
    if p_reason_id is null or not exists (select 1 from public.cancel_reasons c where c.id = p_reason_id) then
      return jsonb_build_object('ok', false, 'reason', 'bad_reason');
    end if;
    v_manager := public.verify_manager_pin(p_manager_pin, v_branch);
    if v_manager is null then
      return jsonb_build_object('ok', false, 'reason', 'manager_pin');
    end if;
    -- the cancel is the employee's mistake: what was made is lost (waste), and he pays its cost (not the menu price)
    if p_charge_staff_id is not null then
      select s.name into v_charge_name from public.staff s
       where s.id = p_charge_staff_id and s.branch_id = v_branch and s.is_active is not false;
      if v_charge_name is null then
        return jsonb_build_object('ok', false, 'reason', 'staff_not_found');
      end if;
      if coalesce(v_order.kitchen_status, 'pending') not in ('preparing', 'ready') then
        update public.orders set kitchen_status = 'ready' where id = p_order_id;
      end if;
    end if;
    for v_item in
      select oi.id from public.order_items oi
       where oi.order_id = p_order_id and coalesce(oi.status, 'active') = 'active'
    loop
      v_cost := v_cost + coalesce(public.pos_void_item_internal(v_item.id, p_reason_id, v_staff, v_manager, 'VOID_ITEM_CANCEL_ORDER'), 0);
    end loop;
  end if;

  update public.orders
     set status = 'cancelled',
         notes = left(coalesce(v_order.notes || ' | ', '') || 'ملغي', 500)
   where id = p_order_id;

  perform public.pos_free_table_if_empty(v_order.table_id);

  insert into public.order_logs (order_id, user_id, action, details)
  values (p_order_id, v_staff, 'CANCEL_ORDER', jsonb_build_object(
    'reason_id', p_reason_id, 'approved_by_manager_id', v_manager, 'items_voided', v_active,
    'total_before', v_order.total_amount, 'charged_staff_id', p_charge_staff_id, 'charged_cost', case when v_charge_name is not null then v_cost end));

  if v_charge_name is not null and v_cost > 0 then
    perform public.pos_staff_add_ledger(v_order.company_id, p_charge_staff_id, 'shortage', v_cost, null, null,
      left('تكلفة طلب ملغي بسببه ' || coalesce(v_order.order_number, ''), 300), v_staff);
    perform public.pos_post_je(v_order.company_id, v_order.branch_id, 'inventory', 'order', p_order_id,
      'تحميل تكلفة طلب ملغي على موظف - ' || coalesce(v_order.order_number, ''),
      jsonb_build_array(public.pos_je_line('1130', v_cost, 0, 'على الموظف: ' || v_charge_name),
                        public.pos_je_line('5100', 0, v_cost, 'تخفيض تكلفة الهالك')), v_staff);
  end if;

  return jsonb_build_object('ok', true, 'charged_staff', v_charge_name, 'charged_cost', case when v_charge_name is not null then v_cost end);
end;
$$;

-- ---------------------------------------------------------------- purchasing
create or replace function public.po_create_secure(
  p_token text, p_supplier_id uuid, p_warehouse_id uuid, p_lines jsonb, p_notes text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
  v_id uuid;
  v_num text;
  l jsonb;
  v_total numeric := 0;
  v_n int;
  v_d int;
  v_auto boolean := false;
begin
  select * into c from public.pos_ctx(p_token, 'purchasing');
  if not public.pos_perm_ok(c.role_name, 'po_create') then
    return jsonb_build_object('ok', false, 'reason', 'not_allowed', 'perm', 'po_create');
  end if;
  if not exists (select 1 from public.suppliers s where s.id = p_supplier_id and s.company_id = c.company_id and s.is_active is not false) then
    return jsonb_build_object('ok', false, 'reason', 'supplier_not_found');
  end if;
  if not public.pos_warehouse_ok(p_warehouse_id, c.branch_id, c.role_name) then
    return jsonb_build_object('ok', false, 'reason', 'warehouse_not_allowed');
  end if;
  if jsonb_typeof(p_lines) is distinct from 'array' or jsonb_array_length(p_lines) < 1 or jsonb_array_length(p_lines) > 200 then
    return jsonb_build_object('ok', false, 'reason', 'invalid_items');
  end if;
  select count(*), count(distinct e.value->>'ingredient_id') into v_n, v_d from jsonb_array_elements(p_lines) e(value);
  if v_n <> v_d then
    return jsonb_build_object('ok', false, 'reason', 'duplicate_item');
  end if;
  for l in select e.value from jsonb_array_elements(p_lines) e(value) loop
    if not exists (select 1 from public.ingredients i where i.id = public.pos_uuid(l->>'ingredient_id'))
       or coalesce(public.pos_amount(l->>'qty'), 0) <= 0 or public.pos_amount(l->>'unit_price') is null then
      return jsonb_build_object('ok', false, 'reason', 'invalid_items');
    end if;
    v_total := v_total + round((l->>'qty')::numeric * (l->>'unit_price')::numeric, 2);
  end loop;

  v_num := 'PO-' || to_char(now(), 'YYYY') || '-' || lpad(((select count(*) from public.purchase_orders) + 1)::text, 5, '0');
  insert into public.purchase_orders (supplier_id, warehouse_id, total_amount, status, po_number, notes, company_id, branch_id, created_by)
  values (p_supplier_id, p_warehouse_id, v_total, 'draft', v_num, left(coalesce(p_notes, ''), 500), c.company_id, c.branch_id, c.staff_id)
  returning id into v_id;
  insert into public.purchase_order_items (purchase_order_id, ingredient_id, quantity, unit_price, total_price)
  select v_id, (e.value->>'ingredient_id')::uuid, (e.value->>'qty')::numeric, (e.value->>'unit_price')::numeric,
         round((e.value->>'qty')::numeric * (e.value->>'unit_price')::numeric, 2)
    from jsonb_array_elements(p_lines) e(value);
  if c.role_name = 'branch_manager' then
    perform pg_advisory_xact_lock(hashtext('motionpos_po_small:' || coalesce(c.branch_id::text, '')));
    if public.pos_po_small_ok(c.company_id, c.branch_id, v_total, v_id) then
      update public.purchase_orders set status = 'approved', approved_by = c.staff_id, approved_at = now() where id = v_id;
      v_auto := true;
    end if;
  end if;
  return jsonb_build_object('ok', true, 'id', v_id, 'po_number', v_num, 'total', v_total, 'auto_approved', v_auto,
                            'manager_limit', public.pos_po_manager_limit(c.company_id));
end;
$$;

create or replace function public.po_action_secure(p_token text, p_po_id uuid, p_action text, p_manager_pin text, p_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
  po public.purchase_orders%rowtype;
  v_manager uuid;
begin
  select * into c from public.pos_ctx(p_token, 'purchasing');
  if p_action in ('approve', 'reject') and not public.pos_perm_ok(c.role_name, 'po_approve')
     and not (c.role_name = 'branch_manager' and exists (
              select 1 from public.purchase_orders x where x.id = p_po_id and x.company_id = c.company_id
                 and public.pos_po_small_ok(c.company_id, c.branch_id, x.total_amount, x.id))) then
    return jsonb_build_object('ok', false, 'reason', 'not_allowed', 'perm', 'po_approve');
  end if;
  if p_action in ('cancel', 'close') and not public.pos_perm_ok(c.role_name, 'po_create') then
    return jsonb_build_object('ok', false, 'reason', 'not_allowed', 'perm', 'po_create');
  end if;
  select x.* into po from public.purchase_orders x where x.id = p_po_id and x.company_id = c.company_id for update;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'po_not_found');
  end if;
  if p_action = 'approve' then
    if po.status <> 'draft' then return jsonb_build_object('ok', false, 'reason', 'wrong_po_status'); end if;
    v_manager := public.verify_manager_pin(p_manager_pin, c.branch_id);
    if v_manager is null then return jsonb_build_object('ok', false, 'reason', 'manager_pin'); end if;
    update public.purchase_orders set status = 'approved', approved_by = v_manager, approved_at = now() where id = po.id;
  elsif p_action = 'reject' then
    if po.status <> 'draft' then return jsonb_build_object('ok', false, 'reason', 'wrong_po_status'); end if;
    if nullif(btrim(coalesce(p_reason, '')), '') is null then return jsonb_build_object('ok', false, 'reason', 'reason_required'); end if;
    v_manager := public.verify_manager_pin(p_manager_pin, c.branch_id);
    if v_manager is null then return jsonb_build_object('ok', false, 'reason', 'manager_pin'); end if;
    update public.purchase_orders
       set status = 'cancelled', notes = left('مرفوض: ' || btrim(p_reason) || coalesce(' | ' || nullif(notes, ''), ''), 500)
     where id = po.id;
  elsif p_action = 'cancel' then
    if po.status not in ('draft', 'approved') then return jsonb_build_object('ok', false, 'reason', 'wrong_po_status'); end if;
    update public.purchase_orders set status = 'cancelled' where id = po.id;
  elsif p_action = 'close' then
    if po.status not in ('partially_received', 'fully_received') then return jsonb_build_object('ok', false, 'reason', 'wrong_po_status'); end if;
    update public.purchase_orders set status = 'closed' where id = po.id;
  else
    return jsonb_build_object('ok', false, 'reason', 'unknown_action');
  end if;
  return jsonb_build_object('ok', true);
end;
$$;

create or replace function public.gr_action_secure(p_token text, p_grn_id uuid, p_action text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
begin
  select * into c from public.pos_ctx(p_token, 'purchasing');
  if p_action = 'post' and not public.pos_perm_ok(c.role_name, 'po_post')
     and not (c.role_name = 'branch_manager' and public.pos_gr_small(p_grn_id, c.company_id)) then
    return jsonb_build_object('ok', false, 'reason', 'not_allowed', 'perm', 'po_post');
  end if;
  if p_action = 'void' and not public.pos_perm_ok(c.role_name, 'po_receive') then
    return jsonb_build_object('ok', false, 'reason', 'not_allowed', 'perm', 'po_receive');
  end if;
  if p_action = 'post' then
    return public.pos_gr_post(p_grn_id, c.staff_id, c.company_id, c.branch_id);
  elsif p_action = 'void' then
    return public.pos_gr_void(p_grn_id, c.company_id);
  end if;
  return jsonb_build_object('ok', false, 'reason', 'unknown_action');
end;
$$;

create or replace function public.gr_list_secure(p_token text, p_status text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
begin
  select * into c from public.pos_ctx(p_token, null);
  if c.role_name <> 'owner' and not exists (select 1 from public.role_permissions rp where rp.role_name = c.role_name and rp.perm in ('purchasing', 'po_post', 'po_receive')) then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  return jsonb_build_object('ok', true,
    'can_post', public.pos_perm_ok(c.role_name, 'po_post'), 'can_receive', public.pos_perm_ok(c.role_name, 'po_receive'),
    'receipts', coalesce((
    select jsonb_agg(jsonb_build_object('id', g.id, 'grn_number', g.grn_number, 'status', g.status, 'received_at', g.received_at,
             'posted_at', g.posted_at, 'po_number', po.po_number, 'supplier', s.name, 'warehouse', w.name, 'notes', g.notes,
             'received_by', rb.name, 'posted_by', pb.name,
             'small_post', c.role_name = 'branch_manager' and public.pos_gr_small(g.id, c.company_id),
             'files', (select count(*) from public.goods_receipt_files gf where gf.goods_receipt_id = g.id),
             'value', coalesce((select sum(gi.total_cost) from public.goods_receipt_items gi where gi.goods_receipt_id = g.id), 0),
             'lines', coalesce((select jsonb_agg(jsonb_build_object('ingredient', i.name, 'unit', i.unit, 'ordered', gi.ordered_qty,
                                       'qty', gi.received_qty, 'unit_cost', gi.unit_cost, 'total', gi.total_cost) order by i.name)
                                  from public.goods_receipt_items gi join public.ingredients i on i.id = gi.ingredient_id
                                 where gi.goods_receipt_id = g.id), '[]'::jsonb))
           order by g.received_at desc)
      from public.goods_receipts g
      join public.purchase_orders po on po.id = g.purchase_order_id
      join public.suppliers s on s.id = po.supplier_id
      left join public.warehouses w on w.id = g.warehouse_id
      left join public.staff rb on rb.id = g.received_by
      left join public.staff pb on pb.id = g.posted_by
     where po.company_id = c.company_id
       and (coalesce(p_status, 'pending') = 'all' or g.status = coalesce(p_status, 'pending'))
       and g.received_at > now() - interval '120 days'), '[]'::jsonb));
end;
$$;

-- ---------------------------------------------------------------- reports
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
  -- ---------------------------------------------------------------- staff activity
  when 'staff_activity' then
    v_title := 'حركات الموظفين بالتفصيل';
    v_cols := public.pos_cols(array['at','day','staff','action','order_number','details','amount'],
      array['الوقت','يوم الشغل','الموظف','الحركة','الطلب','التفاصيل','المبلغ'], 'tdttttm');
    select coalesce(jsonb_agg(to_jsonb(q) order by q.ts), '[]') into v_rows from (
      select * from (
        select l.created_at as ts, to_char(l.created_at at time zone 'Africa/Cairo', 'YYYY-MM-DD HH24:MI') as at,
               public.pos_local_date(l.created_at) as day, s.name as staff,
               case l.action when 'SEND_TO_KITCHEN' then 'إرسال للمطبخ' when 'CLOSE_ORDER' then 'دفع وتقفيل طلب'
                 when 'VOID_ITEM' then 'إلغاء صنف' when 'VOID_ITEM_CANCEL_ORDER' then 'إلغاء صنف مع الطلب'
                 when 'CANCEL_ORDER' then 'إلغاء طلب' when 'REFUND_ORDER' then 'مرتجع' when 'REFUND' then 'مرتجع'
                 when 'APPLY_DISCOUNT' then 'خصم' when 'REMOVE_DISCOUNT' then 'شيل خصم' when 'CHANGE_CHARGES' then 'تغيير الخدمة أو الضريبة'
                 when 'TRANSFER_TABLE' then 'نقل طاولة' when 'MERGE_ORDERS' then 'دمج طلبات' when 'MERGED_INTO' then 'اتدمج في طلب تاني'
                 when 'SPLIT_ORDER' then 'تقسيم الحساب' when 'SPLIT_FROM' then 'تقسيم الحساب' when 'HOSPITALITY' then 'ضيافة'
                 when 'UPDATE_ORDER_INFO' then 'تعديل بيانات الطلب' when 'QR_ORDER_ACCEPTED' then 'قبول طلب من المنيو'
                 when 'KITCHEN_STATUS' then 'تغيير حالة التحضير' else l.action end as action,
               o.order_number,
               nullif(concat_ws(' | ', l.details->>'product',
                      case when l.details ? 'qty_voided' then 'الكمية ' || (l.details->>'qty_voided') end,
                      case when mg.name is not null then 'بموافقة ' || mg.name end,
                      case when ch.name is not null then 'على حساب ' || ch.name end), '') as details,
               coalesce(case when l.action like 'VOID_ITEM%' then round(public.pos_num(l.details->>'qty_voided') * coalesce(public.pos_num(l.details->>'unit_price'), 0), 2) end,
                        public.pos_num(l.details->>'amount'), public.pos_num(l.details->>'total_before'),
                        case when l.action in ('CLOSE_ORDER', 'HOSPITALITY') then o.total_amount end) as amount
          from public.order_logs l
          join public.staff s on s.id = l.user_id
          left join public.orders o on o.id = l.order_id
          left join public.staff mg on mg.id = public.pos_uuid(l.details->>'approved_by_manager_id')
          left join public.staff ch on ch.id = public.pos_uuid(l.details->>'charged_staff_id')
         where s.company_id = c.company_id and (v_branch is null or coalesce(o.branch_id, s.branch_id) = v_branch)
           and public.pos_local_date(l.created_at) between v_from and v_to
        union all
        select sh.opened_at, to_char(sh.opened_at at time zone 'Africa/Cairo', 'YYYY-MM-DD HH24:MI'), public.pos_local_date(sh.opened_at),
               st.name, 'فتح وردية', null, 'العهدة', sh.opening_float
          from public.pos_shifts sh join public.staff st on st.id = sh.staff_id
         where sh.company_id = c.company_id and (v_branch is null or sh.branch_id = v_branch)
           and public.pos_local_date(sh.opened_at) between v_from and v_to
        union all
        select sh.closed_at, to_char(sh.closed_at at time zone 'Africa/Cairo', 'YYYY-MM-DD HH24:MI'), public.pos_local_date(sh.closed_at),
               st.name, 'قفل وردية', null, case when sh.difference < 0 then 'عجز' when sh.difference > 0 then 'زيادة' else 'مظبوطة' end, sh.difference
          from public.pos_shifts sh join public.staff st on st.id = sh.staff_id
         where sh.closed_at is not null and sh.company_id = c.company_id and (v_branch is null or sh.branch_id = v_branch)
           and public.pos_local_date(sh.closed_at) between v_from and v_to
        union all
        select m.created_at, to_char(m.created_at at time zone 'Africa/Cairo', 'YYYY-MM-DD HH24:MI'), public.pos_local_date(m.created_at),
               st.name,
               case m.move_type when 'cash_in' then 'فكة داخلة للدرج' when 'drop' then 'توريد من الدرج' when 'tips_payout' then 'صرف إكراميات'
                 when 'expense' then 'مصروف' when 'supplier_payment' then 'دفع لمورد' when 'custody' then 'عهدة' when 'advance' then 'سلفة'
                 when 'treasury_transfer' then 'تحويل خزينة' when 'payroll' then 'مرتبات' when 'shortage' then 'عجز' when 'overage' then 'زيادة'
                 when 'close_handover' then 'تسليم الدرج' else m.move_type end,
               null, nullif(btrim(coalesce(m.reason, '')), ''), m.amount
          from public.pos_cash_moves m join public.staff st on st.id = m.staff_id
         where m.move_type <> 'float' and m.company_id = c.company_id and (v_branch is null or m.branch_id = v_branch)
           and public.pos_local_date(m.created_at) between v_from and v_to
        union all
        select a.clock_in, to_char(a.clock_in at time zone 'Africa/Cairo', 'YYYY-MM-DD HH24:MI'), public.pos_local_date(a.clock_in),
               st.name, 'حضور', null, null, null::numeric
          from public.staff_attendance a join public.staff st on st.id = a.staff_id
         where st.company_id = c.company_id and (v_branch is null or a.branch_id = v_branch)
           and public.pos_local_date(a.clock_in) between v_from and v_to
        union all
        select a.clock_out, to_char(a.clock_out at time zone 'Africa/Cairo', 'YYYY-MM-DD HH24:MI'), public.pos_local_date(a.clock_out),
               st.name, 'انصراف', null, 'اشتغل ' || round(coalesce(a.minutes, 0) / 60.0, 1) || ' ساعة', null::numeric
          from public.staff_attendance a join public.staff st on st.id = a.staff_id
         where a.clock_out is not null and st.company_id = c.company_id and (v_branch is null or a.branch_id = v_branch)
           and public.pos_local_date(a.clock_out) between v_from and v_to
      ) x order by x.ts limit 5000) q;

  when 'staff_summary' then
    v_title := 'ملخص كل موظف';
    v_cols := public.pos_cols(array['staff','role','waiter_orders','waiter_sales','collected','voids','voids_value','cancelled','discounts','charged','hours','first_in','last_out'],
      array['الموظف','الوظيفة','طلبات كويتر','مبيعاته كويتر','قبضه ككاشير','إلغاء أصناف','قيمتها','طلبات ألغاها','خصومات','اتحمل عليه','ساعات الشغل','أول حضور','آخر انصراف'], 'ttnmmnmnmmntt');
    select coalesce(jsonb_agg(to_jsonb(q) order by q.waiter_sales + q.collected desc, q.staff), '[]') into v_rows from (
      select s.name as staff,
        coalesce(case r.name when 'owner' then 'المالك' when 'branch_manager' then 'مدير فرع' when 'cashier' then 'كاشير'
                 when 'waiter' then 'ويتر' when 'storekeeper' then 'أمين مخزن' else r.name end, '') as role,
        (select count(*) from public.pos_rpt_orders(c.company_id, v_branch, v_from, v_to) o where o.waiter_id = s.id) as waiter_orders,
        coalesce((select sum(o.total_amount) from public.pos_rpt_orders(c.company_id, v_branch, v_from, v_to) o where o.waiter_id = s.id), 0) as waiter_sales,
        coalesce((select sum(p.amount) from public.payments p join public.pos_shifts sh on sh.id = p.shift_id
                   where sh.staff_id = s.id and public.pos_local_date(p.created_at) between v_from and v_to), 0) as collected,
        count(l.id) filter (where l.action like 'VOID_ITEM%') as voids,
        coalesce(sum(round(public.pos_num(l.details->>'qty_voided') * coalesce(public.pos_num(l.details->>'unit_price'), 0), 2))
                 filter (where l.action like 'VOID_ITEM%'), 0) as voids_value,
        count(l.id) filter (where l.action = 'CANCEL_ORDER') as cancelled,
        coalesce(sum(public.pos_num(l.details->>'amount')) filter (where l.action = 'APPLY_DISCOUNT'), 0) as discounts,
        coalesce((select sum(sl.amount) from public.staff_ledger sl where sl.staff_id = s.id and sl.entry_type = 'shortage'
                   and public.pos_local_date(sl.created_at) between v_from and v_to), 0) as charged,
        round(coalesce((select sum(a.minutes) from public.staff_attendance a where a.staff_id = s.id
                   and public.pos_local_date(a.clock_in) between v_from and v_to), 0) / 60.0, 1) as hours,
        (select to_char(min(a.clock_in) at time zone 'Africa/Cairo', 'YYYY-MM-DD HH24:MI') from public.staff_attendance a
          where a.staff_id = s.id and public.pos_local_date(a.clock_in) between v_from and v_to) as first_in,
        (select to_char(max(a.clock_out) at time zone 'Africa/Cairo', 'YYYY-MM-DD HH24:MI') from public.staff_attendance a
          where a.staff_id = s.id and public.pos_local_date(a.clock_in) between v_from and v_to) as last_out
        from public.staff s
        left join public.roles r on r.id = s.role_id
        left join public.order_logs l on l.user_id = s.id and public.pos_local_date(l.created_at) between v_from and v_to
       where s.company_id = c.company_id and (v_branch is null or s.branch_id = v_branch)
       group by s.id, s.name, r.name) q;

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
  select '034'
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
  v_src text;
  v_co uuid;
begin
  begin
    if public.pos_num('12.5') <> 12.5 or public.pos_num('-3') <> -3 or public.pos_num('x') is not null then
      raise exception 'SELFTEST pos_num';
    end if;
    -- day start 8: 07:30 Cairo belongs to the day before, 08:30 to the same day
    perform set_config('motionpos.sync_apply', 'on', true);
    select id into v_co from public.companies order by created_at limit 1;
    if v_co is null then insert into public.companies (name) values ('selftest034') returning id into v_co; end if;
    insert into public.app_settings (company_id, section, data)
    values (v_co, 'general', '{"day_start_hour": 8}'::jsonb)
    on conflict (company_id, section) do update set data = public.app_settings.data || '{"day_start_hour": 8}'::jsonb, updated_at = now();
    if public.pos_local_date(timestamptz '2026-10-14 07:30:00+03') <> date '2026-10-13'
       or public.pos_local_date(timestamptz '2026-10-14 08:30:00+03') <> date '2026-10-14' then
      raise exception 'SELFTEST business day';
    end if;
    if public.pos_settings_defaults() -> 'purchasing' ->> 'manager_limit' <> '200'
       or public.pos_settings_defaults() -> 'general' ->> 'day_start_hour' <> '0' then
      raise exception 'SELFTEST defaults';
    end if;
    select pg_get_functiondef('public.cancel_order_secure(text,uuid,uuid,text,uuid)'::regprocedure) into v_src;
    if position('pos_staff_add_ledger' in v_src) = 0 then raise exception 'SELFTEST cancel'; end if;
    select pg_get_functiondef('public.report_secure(text,text,date,date,uuid)'::regprocedure) into v_src;
    if position('staff_activity' in v_src) = 0 or position('staff_summary' in v_src) = 0 then raise exception 'SELFTEST report'; end if;
    if to_regprocedure('public.cancel_order_secure(text,uuid,uuid,text)') is not null then raise exception 'SELFTEST old cancel still there'; end if;
    if public.motionpos_version_public() <> '034' then raise exception 'SELFTEST version'; end if;
    raise notice 'MOTIONPOS-034-SELFTEST-OK';
    raise exception using errcode = 'P0099', message = 'selftest_rollback';
  exception when sqlstate 'P0099' then
    null;
  end;
end;
$selftest$;

notify pgrst, 'reload schema';

commit;
