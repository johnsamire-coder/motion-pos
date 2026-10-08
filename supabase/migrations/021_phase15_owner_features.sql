-- 021_phase15_owner_features.sql
-- Phase 15 (what the client asked for):
--   1) Owner dashboard: one call with everything (sales, profit, charts data, live state, month forecast).
--   2) QR menu: nice menu + the customer can order from the table. The order waits for the waiter/cashier to confirm,
--      then it goes to the kitchen with the table number. Name + mobile required, birthday optional.
--   3) Loyalty discount: a customer who spent X in the last N days gets Y% off automatically (shown on the bill).
--   4) Complaints and suggestions: public page per branch + manager screen. Links go out with the WhatsApp thank-you.
--   5) Rush: when a station has many open orders, new items get extra minutes before they count as late.
--   6) Daily profit/loss with the monthly fixed costs (the recurring expenses) spread over the days of the month;
--      when the real bill is recorded, the real amount replaces the estimate.
--   7) One screen for menu + recipes (+ new ingredient on the spot), product photo/description, bulk menu import.
-- Rules: begin/commit, preflight, rolled-back self-test, grants loop. New tables are attached to the sync.

begin;

do $preflight$
begin
  if length('إكراميات') <> 8 then
    raise exception 'file_encoding_broken: read the file as UTF-8';
  end if;
  if public.motionpos_version_public() not in ('020', '021') then
    raise exception 'schema_preflight_failed: run 020 first';
  end if;
end;
$preflight$;

-- ===================================================================================
-- 1) Structure
-- ===================================================================================
alter table public.products add column if not exists description text;
alter table public.products add column if not exists image text;
alter table public.products add column if not exists sort_order integer not null default 0;
alter table public.products add column if not exists show_in_menu boolean not null default true;
alter table public.categories add column if not exists sort_order integer not null default 0;
alter table public.categories add column if not exists show_in_menu boolean not null default true;
alter table public.orders add column if not exists loyalty_percent numeric not null default 0;
alter table public.orders add column if not exists source text not null default 'pos';
alter table public.order_items add column if not exists prep_extra_minutes integer not null default 0;
alter table public.branches add column if not exists public_token text;
update public.branches set public_token = encode(extensions.gen_random_bytes(12), 'hex') where public_token is null;
alter table public.branches alter column public_token set default encode(extensions.gen_random_bytes(12), 'hex');
create unique index if not exists branches_public_token_key on public.branches (public_token);

create table if not exists public.qr_orders (
  id uuid primary key default gen_random_uuid(),
  company_id uuid,
  branch_id uuid,
  table_id uuid references public.tables(id) on delete set null,
  table_number text,
  items jsonb not null,
  total_estimate numeric not null default 0,
  customer_name text not null,
  customer_phone text not null,
  customer_birthday date,
  note text,
  status text not null default 'pending' check (status in ('pending', 'accepted', 'rejected')),
  public_ref text not null default encode(extensions.gen_random_bytes(10), 'hex'),
  order_id uuid,
  handled_by uuid,
  handled_at timestamptz,
  reject_reason text,
  created_at timestamptz not null default now()
);
alter table public.qr_orders enable row level security;
create index if not exists qr_orders_branch_status_idx on public.qr_orders (branch_id, status, created_at);
create index if not exists qr_orders_table_idx on public.qr_orders (table_id, created_at);

create table if not exists public.customer_feedback (
  id uuid primary key default gen_random_uuid(),
  company_id uuid,
  branch_id uuid,
  kind text not null check (kind in ('complaint', 'suggestion', 'praise')),
  rating integer check (rating between 1 and 5),
  message text not null,
  customer_name text,
  customer_phone text,
  order_number text,
  status text not null default 'new' check (status in ('new', 'in_progress', 'closed')),
  manager_note text,
  handled_by uuid,
  handled_at timestamptz,
  client_ip text,
  created_at timestamptz not null default now()
);
alter table public.customer_feedback enable row level security;
create index if not exists customer_feedback_branch_idx on public.customer_feedback (branch_id, status, created_at);

-- the sync copies the two new tables too
select public.pos_sync_attach_all();

-- new permissions: the owner dashboard and the complaints screen
create or replace function public.pos_all_perms()
returns text[]
language sql
immutable
as $$
  select array['pos','kds','shift','inventory','inventory_approve','purchasing','treasury','expenses','staff','payroll',
               'reports','settings','accounting','sales','customers','dashboard','feedback']
$$;

insert into public.role_permissions (role_name, perm) values ('branch_manager', 'feedback') on conflict do nothing;


-- ===================================================================================
-- 2) Settings: new keys (QR ordering, loyalty, rush, social links / complaints)
-- ===================================================================================
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


-- settings save (same as 014) + checks for the new keys
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
  if p_section in ('general', 'offline') and c.role_name <> 'owner' then
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


-- ===================================================================================
-- 3) Loyalty discount
--    The customer's paid orders in the last N days (closed orders, this order excluded) >= min_spent  -> percent off.
--    Set on the order when the customer is put on it (and re-checked on every change of customer). It is part of
--    the order discount, so totals, journal entries and reports stay the same; the bill shows it on its own line.
-- ===================================================================================
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
     and o.id is distinct from p_exclude
     and o.created_at > now() - make_interval(days => greatest(1, least(3650,
           coalesce(nullif(public.pos_app_settings(p_company_id) -> 'loyalty' ->> 'period_days', '')::numeric, 365)::int)))
$$;

create or replace function public.pos_loyalty_percent(p_customer_id uuid, p_company_id uuid, p_exclude uuid)
returns numeric
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
declare
  s jsonb;
  v_min numeric;
  v_pct numeric;
begin
  if p_customer_id is null or p_company_id is null then
    return 0;
  end if;
  s := public.pos_app_settings(p_company_id) -> 'loyalty';
  if not coalesce((s->>'enabled')::boolean, false) then
    return 0;
  end if;
  v_min := coalesce(nullif(s->>'min_spent', '')::numeric, 1000);
  v_pct := least(100, greatest(0, coalesce(nullif(s->>'percent', '')::numeric, 0)));
  if v_pct <= 0 then
    return 0;
  end if;
  if public.pos_loyalty_spent(p_customer_id, p_company_id, p_exclude) >= v_min then
    return v_pct;
  end if;
  return 0;
end;
$$;

create or replace function public.trg_orders_loyalty()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if coalesce(current_setting('motionpos.sync_apply', true), '') = 'on' then
    return new;
  end if;
  if coalesce(new.status, '') in ('closed', 'paid', 'cancelled') then
    return new;
  end if;
  if tg_op = 'UPDATE' and new.customer_id is not distinct from old.customer_id then
    return new;
  end if;
  new.loyalty_percent := public.pos_loyalty_percent(new.customer_id, new.company_id, new.id);
  return new;
end;
$$;

drop trigger if exists trg_orders_loyalty on public.orders;
create trigger trg_orders_loyalty
before insert or update of customer_id on public.orders
for each row execute function public.trg_orders_loyalty();


-- totals (same as 010) + loyalty
create or replace function public.compute_order_totals(p_order_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
declare
  v_order public.orders%rowtype;
  v_gross numeric;
  v_item_disc numeric;
  v_order_disc numeric;
  v_disc numeric;
  v_loyal numeric;
  v_net numeric;
  v_vat_pct numeric;
  v_srv_pct numeric;
  v_inclusive boolean;
  v_srv_taxable boolean;
  v_found boolean;
  v_r numeric;
  v_base numeric;
  v_service numeric;
  v_vat numeric;
begin
  select o.* into v_order from public.orders o where o.id = p_order_id;
  if not found then
    return null;
  end if;

  select coalesce(sum(coalesce(oi.total_price, 0)), 0),
         coalesce(sum(coalesce(oi.discount_amount, 0)), 0)
    into v_gross, v_item_disc
    from public.order_items oi
   where oi.order_id = p_order_id
     and coalesce(oi.status, 'active') = 'active';

  if coalesce(v_order.discount_percent, 0) > 0 then
    v_order_disc := round(greatest(0, v_gross - v_item_disc) * least(v_order.discount_percent, 100) / 100, 2);
  else
    v_order_disc := greatest(0, coalesce(v_order.order_discount_amount, 0));
  end if;
  v_loyal := round(greatest(0, v_gross - v_item_disc - v_order_disc) * least(greatest(coalesce(v_order.loyalty_percent, 0), 0), 100) / 100, 2);
  v_disc := least(v_gross, greatest(0, v_item_disc + v_order_disc + v_loyal));
  v_net := v_gross - v_disc;

  select t.vat_percentage, t.service_charge_percentage, t.is_vat_inclusive, t.is_service_taxable
    into v_vat_pct, v_srv_pct, v_inclusive, v_srv_taxable
    from public.branch_tax_settings t
   where t.branch_id = v_order.branch_id
   limit 1;
  v_found := found;

  v_vat_pct := coalesce(v_vat_pct, 14);
  v_srv_pct := coalesce(v_srv_pct, 12);
  v_inclusive := coalesce(v_inclusive, false);
  v_srv_taxable := coalesce(v_srv_taxable, true);
  v_r := v_vat_pct / 100;

  if v_inclusive then
    v_base := round(v_net / (1 + v_r), 2);
  else
    v_base := v_net;
  end if;

  if v_order.order_type = 'dine_in' and v_order.service_enabled then
    v_service := round(v_base * v_srv_pct / 100, 2);
  else
    v_service := 0;
  end if;

  if v_order.vat_enabled then
    v_vat := round(
      (case when v_inclusive then v_net - v_base else v_base * v_r end)
      + (case when v_srv_taxable then v_service * v_r else 0 end), 2);
  else
    v_vat := 0;
  end if;

  return jsonb_build_object(
    'order_id', v_order.id,
    'sub_total', v_gross,
    'discount_amount', v_disc,
    'order_discount', v_order_disc,
    'loyalty_percent', coalesce(v_order.loyalty_percent, 0),
    'loyalty_discount', v_loyal,
    'discount_percent', coalesce(v_order.discount_percent, 0),
    'service_charge_amount', v_service,
    'tax_amount', v_vat,
    'total_amount', v_base + v_service + v_vat,
    'vat_enabled', v_order.vat_enabled,
    'service_enabled', v_order.service_enabled,
    'vat_percentage', v_vat_pct,
    'service_charge_percentage', v_srv_pct,
    'is_vat_inclusive', v_inclusive,
    'is_service_taxable', v_srv_taxable,
    'tax_settings_found', v_found
  );
end;
$$;

drop trigger if exists trg_orders_recalc on public.orders;
create trigger trg_orders_recalc
after update of vat_enabled, service_enabled, order_discount_amount, discount_percent, order_type, branch_id, loyalty_percent, customer_id
on public.orders
for each row execute function public.trg_orders_recalc();


-- order for the cashier (same as 010) + loyalty percent and source
create or replace function public.get_order_secure(p_token text, p_order_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_branch uuid;
  v_res jsonb;
begin
  select rs.branch_id into v_branch from public.require_session(p_token) rs;

  select jsonb_build_object(
    'id', o.id, 'order_number', o.order_number, 'status', o.status, 'kitchen_status', o.kitchen_status,
    'order_type', o.order_type, 'area_id', o.area_id, 'table_id', o.table_id, 'table_number', t.table_number,
    'waiter_id', o.waiter_id, 'customer_id', o.customer_id, 'guest_count', o.guest_count,
    'sub_total', o.sub_total, 'discount_amount', o.discount_amount, 'service_charge_amount', o.service_charge_amount,
    'tax_amount', o.tax_amount, 'total_amount', o.total_amount,
    'vat_enabled', o.vat_enabled, 'service_enabled', o.service_enabled,
    'discount_id', o.discount_id, 'discount_percent', o.discount_percent, 'order_discount_amount', o.order_discount_amount,
    'loyalty_percent', o.loyalty_percent, 'source', o.source,
    'paid_amount', coalesce((select sum(p.amount) from public.payments p where p.order_id = o.id), 0),
    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', oi.id, 'product_id', oi.product_id, 'name', coalesce(pr.name, 'صنف'),
               'quantity', oi.quantity, 'unit_price', oi.unit_price, 'total_price', oi.total_price,
               'discount_amount', coalesce(oi.discount_amount, 0), 'item_notes', oi.item_notes,
               'modifiers', coalesce((
                 select jsonb_agg(jsonb_build_object('id', m.id, 'modifier_id', m.modifier_id,
                                                     'modifier_name', m.modifier_name, 'unit_price', m.unit_price))
                   from public.order_item_modifiers m
                  where m.order_item_id = oi.id), '[]'::jsonb)
             ) order by pr.name, oi.id)
        from public.order_items oi
        left join public.products pr on pr.id = oi.product_id
       where oi.order_id = o.id
         and coalesce(oi.status, 'active') = 'active'), '[]'::jsonb)
  )
    into v_res
    from public.orders o
    left join public.tables t on t.id = o.table_id
   where o.id = p_order_id
     and o.branch_id = v_branch;

  if v_res is null then
    return jsonb_build_object('ok', false, 'reason', 'order_not_found');
  end if;
  return jsonb_build_object('ok', true, 'order', v_res);
end;
$$;


-- bill data (same as 012) + loyalty line + complaints link
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


-- customer card in the cashier: + loyalty state
create or replace function public.pos_customer_brief(p_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public, extensions
as $$
  select jsonb_build_object('id', cu.id, 'name', cu.name, 'phone', cu.phone, 'customer_type', cu.customer_type,
                            'loyalty_percent', public.pos_loyalty_percent(cu.id, cu.company_id, null),
                            'loyalty_spent', public.pos_loyalty_spent(cu.id, cu.company_id, null))
    from public.customers cu where cu.id = p_id
$$;


-- ===================================================================================
-- 4) Rush (زحمة): per station, when the open orders at the station reach the number in the settings,
--    every new item gets extra minutes before it counts as late. The minutes are kept on the item,
--    so the kitchen screen and the delay reports use the same limit later.
-- ===================================================================================
create or replace function public.pos_station_rush(p_company_id uuid, p_branch_id uuid, p_station text, p_exclude_order uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
declare
  s jsonb := public.pos_app_settings(p_company_id) -> 'kds';
  v_limit int;
  v_extra int;
  v_open int;
begin
  v_limit := coalesce(nullif(s ->> ('rush_' || coalesce(p_station, 'kitchen') || '_orders'), '')::numeric, 0)::int;
  v_extra := coalesce(nullif(s ->> ('rush_' || coalesce(p_station, 'kitchen') || '_minutes'), '')::numeric, 0)::int;
  select count(*) into v_open
    from public.order_station_status x join public.orders o on o.id = x.order_id
   where o.branch_id = p_branch_id and x.station = p_station and x.status in ('pending', 'preparing')
     and coalesce(o.status, '') <> 'cancelled' and o.created_at > now() - interval '24 hours'
     and o.id is distinct from p_exclude_order
     -- same orders the station screen shows (a takeaway can be paid before the kitchen finishes it)
     and exists (select 1 from public.order_items i where i.order_id = o.id and coalesce(i.status, 'active') = 'active'
                   and i.ready_at is null and public.pos_item_station(i.product_id) = p_station);
  return jsonb_build_object('open', v_open, 'limit', v_limit, 'extra', v_extra,
                            'on', v_limit > 0 and v_extra > 0 and v_open >= v_limit);
end;
$$;

create or replace function public.trg_order_items_rush()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  o record;
  r jsonb;
begin
  if coalesce(current_setting('motionpos.sync_apply', true), '') = 'on' then
    return new;
  end if;
  -- an item copied by a split keeps its old times: not a new item
  if new.sent_at is not null and new.sent_at < now() - interval '1 minute' then
    return new;
  end if;
  select x.company_id, x.branch_id into o from public.orders x where x.id = new.order_id;
  if o.branch_id is null then
    return new;
  end if;
  r := public.pos_station_rush(o.company_id, o.branch_id, public.pos_item_station(new.product_id), new.order_id);
  if coalesce((r->>'on')::boolean, false) then
    new.prep_extra_minutes := (r->>'extra')::int;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_order_items_rush on public.order_items;
create trigger trg_order_items_rush
before insert on public.order_items
for each row execute function public.trg_order_items_rush();

-- Kitchen / bar / shisha screen (same as 013) + rush state + extra minutes of each card
create or replace function public.kds_station_list_secure(p_token text, p_station text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
begin
  select * into c from public.pos_ctx(p_token, 'kds');
  if coalesce(p_station, '') not in ('kitchen', 'bar', 'shisha') then
    return jsonb_build_object('ok', false, 'reason', 'invalid_value');
  end if;
  return jsonb_build_object('ok', true, 'warn_minutes', public.pos_station_warn(c.company_id, p_station),
    'rush', public.pos_station_rush(c.company_id, c.branch_id, p_station, null),
    'orders', coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', o.id, 'order_number', o.order_number, 'order_type', o.order_type, 'status', s.status,
             'created_at', o.created_at, 'station_since', s.updated_at, 'table_number', t.table_number, 'waiter', w.name,
             'source', o.source,
             'since', (select min(x.sent_at) from public.order_items x
                        where x.order_id = o.id and coalesce(x.status, 'active') = 'active' and x.ready_at is null
                          and public.pos_item_station(x.product_id) = p_station),
             'extra_minutes', (select coalesce(max(x.prep_extra_minutes), 0) from public.order_items x
                                where x.order_id = o.id and coalesce(x.status, 'active') = 'active' and x.ready_at is null
                                  and public.pos_item_station(x.product_id) = p_station),
             'items', (select jsonb_agg(jsonb_build_object(
                         'name', coalesce(p.name, 'صنف'), 'quantity', oi.quantity, 'item_notes', oi.item_notes, 'sent_at', oi.sent_at,
                         'modifiers', coalesce((select jsonb_agg(m.modifier_name) from public.order_item_modifiers m
                                                 where m.order_item_id = oi.id), '[]'::jsonb)) order by oi.sent_at, p.name)
                         from public.order_items oi left join public.products p on p.id = oi.product_id
                        where oi.order_id = o.id and coalesce(oi.status, 'active') = 'active' and oi.ready_at is null
                          and public.pos_item_station(oi.product_id) = p_station)) order by o.created_at)
      from public.order_station_status s
      join public.orders o on o.id = s.order_id
      left join public.tables t on t.id = o.table_id
      left join public.staff w on w.id = o.waiter_id
     where o.branch_id = c.branch_id and s.station = p_station and s.status in ('pending', 'preparing')
       and coalesce(o.status, '') <> 'cancelled' and o.created_at > now() - interval '24 hours'
       and exists (select 1 from public.order_items x where x.order_id = o.id and coalesce(x.status, 'active') = 'active'
                     and x.ready_at is null and public.pos_item_station(x.product_id) = p_station)), '[]'::jsonb));
end;
$$;


-- sales list (same as 013): late = station limit + rush minutes of the item
create or replace function public.sales_orders_secure(p_token text, p_from date, p_to date, p_branch_id uuid, p_filters jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
  f jsonb := coalesce(p_filters, '{}'::jsonb);
  v_from date := coalesce(p_from, public.pos_local_date(now()));
  v_to date := coalesce(p_to, public.pos_local_date(now()));
  v_branch uuid;
  v_state text := coalesce(nullif(f->>'status', ''), 'all');
  v_type text := nullif(f->>'order_type', '');
  v_waiter uuid := public.pos_uuid(f->>'waiter_id');
  v_cashier uuid := public.pos_uuid(f->>'cashier_id');
  v_q text := nullif(btrim(coalesce(f->>'search', '')), '');
  v_digits text := public.pos_phone_norm(f->>'search');
  v_late boolean := coalesce(f->>'late_only', '') = 'true';
  v_wk numeric;
  v_wb numeric;
  v_ws numeric;
  v_res jsonb;
begin
  select * into c from public.pos_ctx(p_token, 'sales');
  v_branch := c.branch_id;
  if c.role_name = 'owner' then
    v_branch := p_branch_id;
  end if;
  if v_to < v_from or v_to - v_from > 366 then
    return jsonb_build_object('ok', false, 'reason', 'invalid_period');
  end if;
  if v_state not in ('all', 'closed', 'open', 'cancelled') then
    return jsonb_build_object('ok', false, 'reason', 'invalid_value');
  end if;
  v_wk := public.pos_station_warn(c.company_id, 'kitchen');
  v_wb := public.pos_station_warn(c.company_id, 'bar');
  v_ws := public.pos_station_warn(c.company_id, 'shisha');

  v_res := (
    with base as (
      select o.id, o.order_number, o.created_at, o.closed_at, o.order_type, o.status, o.total_amount, o.discount_amount,
             o.branch_id, b.name as branch, t.table_number, w.name as waiter, cu.name as customer, cu.phone as customer_phone
        from public.orders o
        left join public.branches b on b.id = o.branch_id
        left join public.tables t on t.id = o.table_id
        left join public.staff w on w.id = o.waiter_id
        left join public.customers cu on cu.id = o.customer_id
       where o.company_id = c.company_id
         and (v_branch is null or o.branch_id = v_branch)
         and public.pos_local_date(o.created_at) between v_from and v_to
         and (v_state = 'all'
              or (v_state = 'closed' and o.status in ('closed', 'paid'))
              or (v_state = 'cancelled' and o.status = 'cancelled')
              or (v_state = 'open' and coalesce(o.status, '') not in ('closed', 'paid', 'cancelled')))
         and (v_type is null or o.order_type = v_type)
         and (v_waiter is null or o.waiter_id = v_waiter)
         and (v_cashier is null or exists (select 1 from public.payments p join public.pos_shifts sh on sh.id = p.shift_id
                                            where p.order_id = o.id and sh.staff_id = v_cashier))
         and (v_q is null or o.order_number ilike '%' || v_q || '%' or cu.name ilike '%' || v_q || '%'
              or t.table_number = v_q
              or (length(v_digits) >= 3 and public.pos_phone_norm(cu.phone) like '%' || v_digits || '%'))
    ), calc as (
      select bs.*, it.items_count, it.first_sent, it.last_ready, it.unready, it.late_items,
             case when it.items_count > 0 and it.unready = 0 and it.first_sent is not null
                  then round((extract(epoch from (it.last_ready - it.first_sent)) / 60.0)::numeric, 1) end as prep_minutes,
             (select string_agg(distinct p.payment_method, ',') from public.payments p where p.order_id = bs.id) as methods,
             (select st.name from public.payments p join public.pos_shifts sh on sh.id = p.shift_id
                join public.staff st on st.id = sh.staff_id where p.order_id = bs.id order by p.created_at limit 1) as cashier,
             (select st.name from public.order_logs l join public.staff st on st.id = l.user_id
               where l.order_id = bs.id and l.action in ('SEND_TO_KITCHEN', 'SPLIT_FROM') order by l.created_at limit 1) as created_by
        from base bs
        left join lateral (
          select coalesce(sum(oi.quantity), 0) as items_count, min(oi.sent_at) as first_sent, max(oi.ready_at) as last_ready,
                 count(*) filter (where oi.ready_at is null) as unready,
                 count(*) filter (where oi.sent_at is not null
                                    and extract(epoch from (coalesce(oi.ready_at,
                                          case when bs.status in ('closed', 'paid', 'cancelled') then null else now() end) - oi.sent_at)) / 60.0
                                        > (case public.pos_item_station(oi.product_id) when 'kitchen' then v_wk when 'bar' then v_wb else v_ws end) + coalesce(oi.prep_extra_minutes, 0)
                                 ) as late_items
            from public.order_items oi
           where oi.order_id = bs.id and coalesce(oi.status, 'active') = 'active'
        ) it on true
    ), fin as (
      select * from calc where (not v_late or late_items > 0)
    )
    select jsonb_build_object(
      'rows', coalesce((select jsonb_agg(jsonb_build_object(
                  'id', r.id, 'order_number', r.order_number, 'created_at', r.created_at, 'closed_at', r.closed_at,
                  'order_type', r.order_type, 'status', r.status, 'total_amount', r.total_amount, 'discount_amount', r.discount_amount,
                  'branch', r.branch, 'table_number', r.table_number, 'waiter', r.waiter, 'customer', r.customer,
                  'customer_phone', r.customer_phone, 'items_count', r.items_count, 'prep_minutes', r.prep_minutes,
                  'late', r.late_items > 0, 'methods', r.methods, 'cashier', r.cashier, 'created_by', r.created_by)
                  order by r.created_at desc)
                 from (select * from fin order by created_at desc limit 1000) r), '[]'::jsonb),
      'summary', (select jsonb_build_object(
                    'count', count(*),
                    'closed_count', count(*) filter (where status in ('closed', 'paid')),
                    'closed_total', coalesce(sum(total_amount) filter (where status in ('closed', 'paid')), 0),
                    'avg_ticket', round(coalesce(avg(total_amount) filter (where status in ('closed', 'paid')), 0), 2),
                    'open_count', count(*) filter (where coalesce(status, '') not in ('closed', 'paid', 'cancelled')),
                    'cancelled_count', count(*) filter (where status = 'cancelled'),
                    'late_count', count(*) filter (where late_items > 0),
                    'avg_prep', round(avg(prep_minutes), 1))
                    from fin))
  );

  return jsonb_build_object('ok', true, 'from', v_from, 'to', v_to,
    'branch', coalesce((select b.name from public.branches b where b.id = v_branch), 'كل الفروع'),
    'warn', jsonb_build_object('kitchen', v_wk, 'bar', v_wb, 'shisha', v_ws),
    'staff', coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name, 'role', r.name) order by s.name)
                         from public.staff s left join public.roles r on r.id = s.role_id
                        where s.company_id = c.company_id and (v_branch is null or s.branch_id = v_branch)
                          and r.name in ('waiter', 'cashier', 'branch_manager', 'owner')), '[]'::jsonb))
    || v_res;
end;
$$;


-- delay report (same as 013): limit + rush minutes of the item
create or replace function public.sales_timing_secure(p_token text, p_from date, p_to date, p_branch_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
  v_from date := coalesce(p_from, public.pos_local_date(now()) - 6);
  v_to date := coalesce(p_to, public.pos_local_date(now()));
  v_branch uuid;
  v_wk numeric;
  v_wb numeric;
  v_ws numeric;
  v_res jsonb;
begin
  select * into c from public.pos_ctx(p_token, 'sales');
  v_branch := c.branch_id;
  if c.role_name = 'owner' then
    v_branch := p_branch_id;
  end if;
  if v_to < v_from or v_to - v_from > 366 then
    return jsonb_build_object('ok', false, 'reason', 'invalid_period');
  end if;
  v_wk := public.pos_station_warn(c.company_id, 'kitchen');
  v_wb := public.pos_station_warn(c.company_id, 'bar');
  v_ws := public.pos_station_warn(c.company_id, 'shisha');

  v_res := (
    with it as (
      select oi.id, oi.order_id, o.order_number, o.created_at as order_created, t.table_number, w.name as waiter,
             coalesce(p.name, 'صنف') as product, oi.quantity, public.pos_item_station(oi.product_id) as station, oi.sent_at,
             extract(hour from (oi.sent_at at time zone 'Africa/Cairo'))::int as hour,
             extract(epoch from (oi.prep_started_at - oi.sent_at)) / 60.0 as wait_m,
             extract(epoch from (oi.ready_at - oi.prep_started_at)) / 60.0 as prep_m,
             extract(epoch from (oi.ready_at - oi.sent_at)) / 60.0 as total_m,
             coalesce(oi.prep_extra_minutes, 0) as extra_m
        from public.order_items oi
        join public.orders o on o.id = oi.order_id
        left join public.products p on p.id = oi.product_id
        left join public.tables t on t.id = o.table_id
        left join public.staff w on w.id = o.waiter_id
       where o.company_id = c.company_id and (v_branch is null or o.branch_id = v_branch)
         and public.pos_local_date(oi.sent_at) between v_from and v_to
         and coalesce(oi.status, 'active') = 'active' and oi.ready_at is not null and oi.sent_at is not null
    ), lim as (
      select it.*, (case it.station when 'kitchen' then v_wk when 'bar' then v_wb else v_ws end) + it.extra_m as limit_m from it
    )
    select jsonb_build_object(
      'by_station', coalesce((select jsonb_agg(jsonb_build_object(
                       'station', s.station, 'items', s.items, 'avg_wait', s.avg_wait, 'avg_prep', s.avg_prep, 'avg_total', s.avg_total,
                       'max_total', s.max_total, 'late_items', s.late_items, 'late_pct', s.late_pct, 'limit', s.limit_m) order by s.station)
                       from (select station, max(limit_m) as limit_m, count(*) as items,
                                    round(avg(wait_m)::numeric, 1) as avg_wait, round(avg(prep_m)::numeric, 1) as avg_prep,
                                    round(avg(total_m)::numeric, 1) as avg_total, round(max(total_m)::numeric, 1) as max_total,
                                    count(*) filter (where total_m > limit_m) as late_items,
                                    round(100.0 * count(*) filter (where total_m > limit_m) / count(*), 1) as late_pct
                               from lim group by station) s), '[]'::jsonb),
      'by_product', coalesce((select jsonb_agg(jsonb_build_object(
                       'product', s.product, 'station', s.station, 'items', s.items, 'avg_total', s.avg_total,
                       'max_total', s.max_total, 'late_items', s.late_items, 'late_pct', s.late_pct) order by s.avg_total desc)
                       from (select product, station, count(*) as items, round(avg(total_m)::numeric, 1) as avg_total,
                                    round(max(total_m)::numeric, 1) as max_total, count(*) filter (where total_m > limit_m) as late_items,
                                    round(100.0 * count(*) filter (where total_m > limit_m) / count(*), 1) as late_pct
                               from lim group by product, station order by avg(total_m) desc limit 60) s), '[]'::jsonb),
      'by_hour', coalesce((select jsonb_agg(jsonb_build_object('hour', s.hour, 'items', s.items, 'avg_total', s.avg_total,
                                                               'late_items', s.late_items) order by s.hour)
                       from (select hour, count(*) as items, round(avg(total_m)::numeric, 1) as avg_total,
                                    count(*) filter (where total_m > limit_m) as late_items
                               from lim group by hour) s), '[]'::jsonb),
      'late_orders', coalesce((select jsonb_agg(jsonb_build_object(
                       'order_id', s.order_id, 'order_number', s.order_number, 'created_at', s.order_created,
                       'table_number', s.table_number, 'waiter', s.waiter, 'station', s.station, 'products', s.products,
                       'minutes', s.minutes, 'limit', s.limit_m) order by s.minutes desc)
                       from (select order_id, order_number, order_created, table_number, waiter, station, max(limit_m) as limit_m,
                                    string_agg(distinct product, '، ') as products, round(max(total_m)::numeric, 1) as minutes
                               from lim where total_m > limit_m
                              group by order_id, order_number, order_created, table_number, waiter, station
                              order by max(total_m) desc limit 100) s), '[]'::jsonb))
  );
  return jsonb_build_object('ok', true, 'from', v_from, 'to', v_to,
    'branch', coalesce((select b.name from public.branches b where b.id = v_branch), 'كل الفروع'),
    'warn', jsonb_build_object('kitchen', v_wk, 'bar', v_wb, 'shisha', v_ws)) || v_res;
end;
$$;


-- ===================================================================================
-- 5) QR menu + ordering from the table
--    The customer's phone talks to the cloud (no login). The order is saved as "waiting" in qr_orders;
--    the waiter / cashier sees it with the table number and confirms it (then it is a normal order sent to
--    the kitchen) or refuses it. With a shop server the row reaches the shop through the sync.
-- ===================================================================================
create or replace function public.pos_qr_store_offline(p_branch_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, extensions
as $$
  select exists (select 1 from public.sync_node n where n.node = 'cloud')
     and exists (select 1 from public.branches b where b.id = p_branch_id and b.has_store_server)
     and coalesce((select s.value::timestamptz from public.sync_state s where s.key = 'store_seen'), '-infinity'::timestamptz)
         < now() - interval '3 minutes'
$$;

create or replace function public.qr_menu_public(p_qr text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
declare
  t record;
  s jsonb;
  tx record;
begin
  select * into t from public.pos_qr_table(p_qr);
  if t.table_id is null then
    return jsonb_build_object('ok', false, 'reason', 'not_found');
  end if;
  s := public.pos_app_settings(t.company_id);
  if not coalesce((s->'waiter_qr'->>'qr_enabled')::boolean, true) then
    return jsonb_build_object('ok', false, 'reason', 'qr_disabled');
  end if;
  select x.vat_percentage, x.service_charge_percentage, x.is_vat_inclusive into tx
    from public.branch_tax_settings x where x.branch_id = t.branch_id limit 1;
  return jsonb_build_object('ok', true,
    'company_name', s->'general'->>'company_name', 'logo', s->'general'->>'logo', 'currency', s->'general'->>'currency',
    'phone', s->'general'->>'phone', 'address', s->'general'->>'address',
    'branch', t.branch_name, 'table_number', t.table_number,
    'call_waiter', coalesce((s->'waiter_qr'->>'qr_call_waiter')::boolean, true),
    'request_bill', coalesce((s->'waiter_qr'->>'qr_request_bill')::boolean, true),
    'show_prices', coalesce((s->'waiter_qr'->>'qr_show_prices')::boolean, true),
    'ordering', coalesce((s->'waiter_qr'->>'qr_ordering')::boolean, true),
    'welcome', s->'waiter_qr'->>'qr_welcome', 'privacy_note', s->'waiter_qr'->>'qr_privacy_note',
    'facebook_url', s->'social'->>'facebook_url', 'instagram_url', s->'social'->>'instagram_url',
    'feedback_token', case when coalesce((s->'social'->>'feedback_enabled')::boolean, true)
                           then (select b.public_token from public.branches b where b.id = t.branch_id) end,
    'store_offline', public.pos_qr_store_offline(t.branch_id),
    'vat_percentage', coalesce(tx.vat_percentage, 0), 'service_percentage', coalesce(tx.service_charge_percentage, 0),
    'vat_inclusive', coalesce(tx.is_vat_inclusive, false),
    'categories', coalesce((
      select jsonb_agg(jsonb_build_object('id', cat.id, 'name', cat.name,
               'products', (select jsonb_agg(jsonb_build_object(
                                 'id', p.id, 'name', p.name, 'price', p.price, 'description', p.description,
                                 'has_image', coalesce(p.image, '') <> '',
                                 'groups', coalesce((
                                   select jsonb_agg(jsonb_build_object('id', g.id, 'name', g.name,
                                            'min', greatest(coalesce(g.min_selection, 0), case when coalesce(g.is_required, false) then 1 else 0 end),
                                            'max', coalesce(g.max_selection, 0),
                                            'modifiers', coalesce((select jsonb_agg(jsonb_build_object('id', m.id, 'name', m.name, 'price', m.price)
                                                                                    order by m.price, m.name)
                                                                     from public.modifiers m where m.group_id = g.id), '[]'::jsonb)) order by g.name)
                                     from public.product_modifier_groups pg join public.modifier_groups g on g.id = pg.group_id
                                    where pg.product_id = p.id
                                      and exists (select 1 from public.modifiers m where m.group_id = g.id)), '[]'::jsonb))
                               order by p.sort_order, p.name)
                              from public.products p
                             where p.category_id = cat.id and p.is_available is true and p.show_in_menu is true))
             order by cat.sort_order, cat.name)
        from public.categories cat
       where cat.brand_id = t.brand_id and cat.show_in_menu is true
         and exists (select 1 from public.products p where p.category_id = cat.id and p.is_available is true and p.show_in_menu is true)),
      '[]'::jsonb));
end;
$$;

-- one photo at a time (the menu loads them while the customer scrolls)
create or replace function public.qr_image_public(p_qr text, p_product_id uuid)
returns text
language sql
stable
security definer
set search_path = public, extensions
as $$
  select p.image
    from public.pos_qr_table(p_qr) t
    join public.products p on p.brand_id = t.brand_id
   where p.id = p_product_id and p.is_available is true and p.show_in_menu is true and coalesce(p.image, '') <> ''
$$;

create or replace function public.qr_order_public(p_qr text, p_items jsonb, p_name text, p_phone text, p_birthday text, p_note text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  t record;
  s jsonb;
  v_name text := nullif(btrim(coalesce(p_name, '')), '');
  v_phone text := public.pos_phone_norm(p_phone);
  v_birthday date;
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  e jsonb;
  p record;
  g record;
  v_qty int;
  v_mods uuid[];
  v_mod_total numeric;
  v_total numeric := 0;
  v_items jsonb := '[]'::jsonb;
  v_ref text;
  v_count int;
  v_notes text;
begin
  select * into t from public.pos_qr_table(p_qr);
  if t.table_id is null then
    return jsonb_build_object('ok', false, 'reason', 'not_found');
  end if;
  s := public.pos_app_settings(t.company_id);
  if not coalesce((s->'waiter_qr'->>'qr_enabled')::boolean, true) or not coalesce((s->'waiter_qr'->>'qr_ordering')::boolean, true) then
    return jsonb_build_object('ok', false, 'reason', 'qr_disabled');
  end if;
  if public.pos_qr_store_offline(t.branch_id) then
    return jsonb_build_object('ok', false, 'reason', 'store_offline');
  end if;
  if v_name is null or length(v_name) > 80 then
    return jsonb_build_object('ok', false, 'reason', 'invalid_name');
  end if;
  if length(v_phone) < 8 or length(v_phone) > 15 then
    return jsonb_build_object('ok', false, 'reason', 'invalid_phone');
  end if;
  if nullif(btrim(coalesce(p_birthday, '')), '') is not null then
    if p_birthday !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then
      return jsonb_build_object('ok', false, 'reason', 'invalid_date');
    end if;
    begin
      v_birthday := p_birthday::date;
    exception when others then
      return jsonb_build_object('ok', false, 'reason', 'invalid_date');
    end;
    if v_birthday > current_date or v_birthday < date '1900-01-01' then
      return jsonb_build_object('ok', false, 'reason', 'invalid_date');
    end if;
  end if;
  if v_note is not null and length(v_note) > 300 then
    return jsonb_build_object('ok', false, 'reason', 'item_notes_too_long');
  end if;
  if jsonb_typeof(p_items) is distinct from 'array' or jsonb_array_length(p_items) < 1 or jsonb_array_length(p_items) > 30 then
    return jsonb_build_object('ok', false, 'reason', 'invalid_item_count');
  end if;
  -- too many waiting orders from this table / this phone: someone is playing
  select count(*) into v_count from public.qr_orders q where q.table_id = t.table_id and q.status = 'pending';
  if v_count >= 3 then
    return jsonb_build_object('ok', false, 'reason', 'too_many');
  end if;
  select count(*) into v_count from public.qr_orders q where q.table_id = t.table_id and q.created_at > now() - interval '1 hour';
  if v_count >= 15 then
    return jsonb_build_object('ok', false, 'reason', 'too_many');
  end if;
  select count(*) into v_count from public.qr_orders q
   where q.company_id = t.company_id and public.pos_phone_norm(q.customer_phone) = v_phone and q.status = 'pending';
  if v_count >= 2 then
    return jsonb_build_object('ok', false, 'reason', 'too_many');
  end if;

  for e in select x.value from jsonb_array_elements(p_items) x(value) loop
    if jsonb_typeof(e) is distinct from 'object' or coalesce(e->>'quantity', '') !~ '^[0-9]{1,2}$' then
      return jsonb_build_object('ok', false, 'reason', 'invalid_quantity');
    end if;
    v_qty := (e->>'quantity')::int;
    if v_qty < 1 or v_qty > 20 then
      return jsonb_build_object('ok', false, 'reason', 'invalid_quantity');
    end if;
    select pr.id, pr.price into p from public.products pr
     where pr.id = public.pos_uuid(e->>'product_id') and pr.brand_id = t.brand_id and pr.is_available is true and pr.show_in_menu is true;
    if p.id is null then
      return jsonb_build_object('ok', false, 'reason', 'product_not_available');
    end if;
    v_notes := nullif(btrim(coalesce(e->>'item_notes', '')), '');
    if v_notes is not null and length(v_notes) > 200 then
      return jsonb_build_object('ok', false, 'reason', 'item_notes_too_long');
    end if;
    v_mods := '{}'::uuid[];
    if e ? 'modifier_ids' and jsonb_typeof(e->'modifier_ids') = 'array' then
      if jsonb_array_length(e->'modifier_ids') > 10
         or exists (select 1 from jsonb_array_elements_text(e->'modifier_ids') m(v) where public.pos_uuid(m.v) is null) then
        return jsonb_build_object('ok', false, 'reason', 'invalid_modifier_ids');
      end if;
      select coalesce(array_agg(distinct m.v::uuid), '{}'::uuid[]) into v_mods from jsonb_array_elements_text(e->'modifier_ids') m(v);
    end if;
    if exists (select 1 from unnest(v_mods) u(id)
                where not exists (select 1 from public.modifiers m join public.product_modifier_groups pg on pg.group_id = m.group_id
                                   where m.id = u.id and pg.product_id = p.id)) then
      return jsonb_build_object('ok', false, 'reason', 'modifier_not_for_product');
    end if;
    for g in
      select mg.id, greatest(coalesce(mg.min_selection, 0), case when coalesce(mg.is_required, false) then 1 else 0 end) as mn,
             coalesce(mg.max_selection, 0) as mx,
             (select count(*) from public.modifiers m where m.group_id = mg.id and m.id = any (v_mods)) as picked
        from public.product_modifier_groups pg join public.modifier_groups mg on mg.id = pg.group_id
       where pg.product_id = p.id and exists (select 1 from public.modifiers m where m.group_id = mg.id)
    loop
      if g.picked < g.mn then
        return jsonb_build_object('ok', false, 'reason', 'required_modifier_missing');
      end if;
      if g.mx > 0 and g.picked > g.mx then
        return jsonb_build_object('ok', false, 'reason', 'too_many_modifiers');
      end if;
    end loop;
    select coalesce(sum(m.price), 0) into v_mod_total from public.modifiers m where m.id = any (v_mods);
    v_total := v_total + (coalesce(p.price, 0) + v_mod_total) * v_qty;
    v_items := v_items || jsonb_build_array(jsonb_build_object('product_id', p.id, 'quantity', v_qty,
                 'modifier_ids', to_jsonb(v_mods), 'item_notes', v_notes));
  end loop;

  insert into public.qr_orders (company_id, branch_id, table_id, table_number, items, total_estimate, customer_name, customer_phone,
                                customer_birthday, note)
  values (t.company_id, t.branch_id, t.table_id, t.table_number, v_items, round(v_total, 2), left(v_name, 80), v_phone, v_birthday,
          left(v_note, 300))
  returning public_ref into v_ref;
  return jsonb_build_object('ok', true, 'ref', v_ref, 'total_estimate', round(v_total, 2));
end;
$$;

create or replace function public.qr_order_status_public(p_qr text, p_ref text)
returns jsonb
language sql
stable
security definer
set search_path = public, extensions
as $$
  select coalesce((
    select jsonb_build_object('ok', true, 'status', q.status, 'reject_reason', q.reject_reason,
                              'order_number', (select o.order_number from public.orders o where o.id = q.order_id))
      from public.pos_qr_table(p_qr) t
      join public.qr_orders q on q.table_id = t.table_id
     where q.public_ref = p_ref and coalesce(p_ref, '') ~ '^[0-9a-f]{20}$'),
    jsonb_build_object('ok', false, 'reason', 'not_found'))
$$;

-- the waiting orders with names, for the waiter / cashier
create or replace function public.pos_qr_orders_list(p_branch_id uuid, p_company_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public, extensions
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', q.id, 'table_number', q.table_number, 'table_id', q.table_id, 'created_at', q.created_at,
           'customer_name', q.customer_name, 'customer_phone', q.customer_phone, 'note', q.note, 'total_estimate', q.total_estimate,
           'known_customer', (select jsonb_build_object('name', cu.name, 'orders_count',
                                       (select count(*) from public.orders o where o.customer_id = cu.id and o.status = 'closed'))
                                from public.customers cu
                               where cu.company_id = p_company_id and public.pos_phone_norm(cu.phone) = public.pos_phone_norm(q.customer_phone)
                               limit 1),
           'has_open_order', exists (select 1 from public.orders o where o.table_id = q.table_id
                                       and coalesce(o.status, '') not in ('paid', 'closed', 'cancelled')),
           'items', (select jsonb_agg(jsonb_build_object(
                        'name', coalesce(pr.name, 'صنف'), 'quantity', (e.value->>'quantity')::int, 'notes', e.value->>'item_notes',
                        'modifiers', (select coalesce(jsonb_agg(m.name), '[]'::jsonb) from public.modifiers m
                                       where m.id in (select x.v::uuid from jsonb_array_elements_text(coalesce(e.value->'modifier_ids', '[]'::jsonb)) x(v))))
                        order by e.ord)
                       from jsonb_array_elements(q.items) with ordinality e(value, ord)
                       left join public.products pr on pr.id = (e.value->>'product_id')::uuid)
         ) order by q.created_at), '[]'::jsonb)
    from public.qr_orders q
   where q.branch_id = p_branch_id and q.status = 'pending' and q.created_at > now() - interval '12 hours'
$$;

create or replace function public.qr_orders_secure(p_token text, p_action text, p_data jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
  d jsonb := coalesce(p_data, '{}'::jsonb);
  v_q public.qr_orders%rowtype;
  v_order uuid;
  v_area uuid;
  v_waiter uuid;
  v_cust uuid;
  v_res jsonb;
  v_reason text;
begin
  select * into c from public.pos_ctx(p_token, 'pos');
  if coalesce(p_action, '') = 'list' then
    return jsonb_build_object('ok', true, 'orders', public.pos_qr_orders_list(c.branch_id, c.company_id));
  end if;
  if coalesce(p_action, '') not in ('accept', 'reject') then
    return jsonb_build_object('ok', false, 'reason', 'unknown_action');
  end if;
  select q.* into v_q from public.qr_orders q where q.id = public.pos_uuid(d->>'id') and q.branch_id = c.branch_id for update;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'not_found');
  end if;
  if v_q.status <> 'pending' then
    return jsonb_build_object('ok', false, 'reason', 'qr_handled');
  end if;

  if p_action = 'reject' then
    v_reason := nullif(btrim(coalesce(d->>'reason', '')), '');
    update public.qr_orders set status = 'rejected', reject_reason = left(coalesce(v_reason, 'اترفض'), 200),
           handled_by = c.staff_id, handled_at = now()
     where id = v_q.id;
    return jsonb_build_object('ok', true);
  end if;

  -- accept: add to the open order of the table, or open a new one on the table
  select o.id into v_order from public.orders o
   where o.table_id = v_q.table_id and o.branch_id = c.branch_id and coalesce(o.status, '') not in ('paid', 'closed', 'cancelled')
   order by o.created_at desc limit 1;
  if v_order is null then
    select t.area_id into v_area from public.tables t where t.id = v_q.table_id;
    if c.role_name = 'waiter' then
      v_waiter := c.staff_id;
    end if;
    v_res := public.submit_order_items_secure(p_token, null::uuid, 'dine_in', v_area, v_q.table_id, v_waiter, null::uuid, 1, v_q.items);
  else
    v_res := public.submit_order_items_secure(p_token, v_order, 'dine_in', null::uuid, null::uuid, null::uuid, null::uuid, 1, v_q.items);
  end if;
  if not coalesce((v_res->>'ok')::boolean, false) then
    return v_res;
  end if;
  v_order := (v_res->>'order_id')::uuid;

  -- the customer: found by mobile, or added now (birthday kept if we did not have it)
  select cu.id into v_cust from public.customers cu
   where cu.company_id = c.company_id and public.pos_phone_norm(cu.phone) = public.pos_phone_norm(v_q.customer_phone) limit 1;
  if v_cust is null then
    insert into public.customers (company_id, name, phone, customer_type, credit_limit, created_by, birthday, notes)
    values (c.company_id, v_q.customer_name, public.pos_phone_norm(v_q.customer_phone), 'registered', 0, c.staff_id, v_q.customer_birthday,
            'سجّل نفسه من منيو الـ QR')
    returning id into v_cust;
  else
    update public.customers set birthday = coalesce(birthday, v_q.customer_birthday) where id = v_cust and birthday is null;
  end if;
  update public.orders set customer_id = v_cust where id = v_order and customer_id is null;
  if coalesce((v_res->>'created')::boolean, false) then
    update public.orders set source = 'qr', notes = coalesce(nullif(notes, '') || ' | ', '') || coalesce('ملاحظة العميل: ' || v_q.note, 'طلب QR')
     where id = v_order;
  end if;
  update public.qr_orders set status = 'accepted', order_id = v_order, handled_by = c.staff_id, handled_at = now() where id = v_q.id;
  insert into public.order_logs (order_id, user_id, action, details)
  values (v_order, c.staff_id, 'QR_ORDER_ACCEPTED', jsonb_build_object('qr_order', v_q.id, 'customer', v_q.customer_name,
          'table', v_q.table_number, 'estimate', v_q.total_estimate));
  return jsonb_build_object('ok', true, 'order_id', v_order, 'order_number', v_res->>'order_number', 'created', v_res->'created');
end;
$$;


-- waiter bell (same as 012) + QR orders waiting for confirmation
create or replace function public.waiter_feed_secure(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
begin
  select * into c from public.pos_ctx(p_token, 'pos');
  return jsonb_build_object('ok', true,
    'ready', coalesce((
      select jsonb_agg(jsonb_build_object('order_id', o.id, 'order_number', o.order_number, 'table_number', t.table_number,
                                          'station', s.station, 'ready_at', s.ready_at) order by s.ready_at)
        from public.order_station_status s
        join public.orders o on o.id = s.order_id
        left join public.tables t on t.id = o.table_id
       where o.branch_id = c.branch_id and s.status = 'ready' and coalesce(o.status, '') <> 'cancelled'
         and (c.role_name <> 'waiter' or o.waiter_id = c.staff_id)
         and s.ready_at > now() - interval '12 hours'), '[]'::jsonb),
    'calls', coalesce((
      select jsonb_agg(jsonb_build_object('id', r.id, 'type', r.request_type, 'table_number', t.table_number,
                                          'created_at', r.created_at) order by r.created_at)
        from public.service_requests r join public.tables t on t.id = r.table_id
       where r.branch_id = c.branch_id and r.status = 'open'), '[]'::jsonb),
    'qr_orders', public.pos_qr_orders_list(c.branch_id, c.company_id));
end;
$$;


-- ===================================================================================
-- 6) Complaints and suggestions
--    Public page feedback.html?b=<branch public token> (no login). The manager follows them in his own screen.
-- ===================================================================================
create or replace function public.feedback_info_public(p_b text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
declare
  b record;
  s jsonb;
begin
  select x.id, x.name, br.company_id into b
    from public.branches x join public.brands br on br.id = x.brand_id
   where x.public_token = p_b and coalesce(p_b, '') ~ '^[0-9a-f]{24}$';
  if b.id is null then
    return jsonb_build_object('ok', false, 'reason', 'not_found');
  end if;
  s := public.pos_app_settings(b.company_id);
  return jsonb_build_object('ok', true, 'company_name', s->'general'->>'company_name', 'logo', s->'general'->>'logo',
    'branch', b.name, 'phone', s->'general'->>'phone', 'intro', s->'social'->>'feedback_intro',
    'facebook_url', s->'social'->>'facebook_url', 'instagram_url', s->'social'->>'instagram_url',
    'enabled', coalesce((s->'social'->>'feedback_enabled')::boolean, true));
end;
$$;

create or replace function public.feedback_submit_public(p_b text, p_kind text, p_rating integer, p_message text,
                                                         p_name text, p_phone text, p_order text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  b record;
  s jsonb;
  v_ip text := public.request_client_ip();
  v_msg text := nullif(btrim(coalesce(p_message, '')), '');
  v_phone text := nullif(public.pos_phone_norm(p_phone), '');
begin
  select x.id, br.company_id into b
    from public.branches x join public.brands br on br.id = x.brand_id
   where x.public_token = p_b and coalesce(p_b, '') ~ '^[0-9a-f]{24}$';
  if b.id is null then
    return jsonb_build_object('ok', false, 'reason', 'not_found');
  end if;
  s := public.pos_app_settings(b.company_id);
  if not coalesce((s->'social'->>'feedback_enabled')::boolean, true) then
    return jsonb_build_object('ok', false, 'reason', 'qr_disabled');
  end if;
  if coalesce(p_kind, '') not in ('complaint', 'suggestion', 'praise') or (p_rating is not null and (p_rating < 1 or p_rating > 5)) then
    return jsonb_build_object('ok', false, 'reason', 'invalid_value');
  end if;
  if v_msg is null or length(v_msg) > 2000 then
    return jsonb_build_object('ok', false, 'reason', 'reason_required');
  end if;
  if v_phone is not null and (length(v_phone) < 8 or length(v_phone) > 15) then
    return jsonb_build_object('ok', false, 'reason', 'invalid_phone');
  end if;
  if (select count(*) from public.customer_feedback f
       where f.branch_id = b.id and f.client_ip is not distinct from v_ip and f.created_at > now() - interval '1 hour') >= 5
     or (select count(*) from public.customer_feedback f where f.branch_id = b.id and f.created_at > now() - interval '1 hour') >= 200 then
    return jsonb_build_object('ok', false, 'reason', 'too_many');
  end if;
  insert into public.customer_feedback (company_id, branch_id, kind, rating, message, customer_name, customer_phone, order_number, client_ip)
  values (b.company_id, b.id, p_kind, p_rating, v_msg, left(nullif(btrim(coalesce(p_name, '')), ''), 80), v_phone,
          left(nullif(btrim(coalesce(p_order, '')), ''), 30), v_ip);
  return jsonb_build_object('ok', true);
end;
$$;

create or replace function public.feedback_secure(p_token text, p_action text, p_data jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
  d jsonb := coalesce(p_data, '{}'::jsonb);
  v_filter text := coalesce(d->>'filter', 'open');
  v_branch uuid;
begin
  select * into c from public.pos_ctx(p_token, 'feedback');
  v_branch := c.branch_id;
  if c.role_name = 'owner' and public.pos_uuid(d->>'branch_id') is not null then
    v_branch := public.pos_uuid(d->>'branch_id');
  end if;
  if coalesce(p_action, '') = 'set' then
    if coalesce(d->>'status', '') not in ('new', 'in_progress', 'closed') then
      return jsonb_build_object('ok', false, 'reason', 'invalid_status');
    end if;
    update public.customer_feedback
       set status = d->>'status', manager_note = left(coalesce(nullif(btrim(coalesce(d->>'note', '')), ''), manager_note), 1000),
           handled_by = c.staff_id, handled_at = now()
     where id = public.pos_uuid(d->>'id') and company_id = c.company_id and (c.role_name = 'owner' or branch_id = c.branch_id);
    if not found then
      return jsonb_build_object('ok', false, 'reason', 'not_found');
    end if;
  elsif coalesce(p_action, '') <> 'list' then
    return jsonb_build_object('ok', false, 'reason', 'unknown_action');
  end if;
  return jsonb_build_object('ok', true,
    'counts', (select jsonb_build_object(
                 'new', count(*) filter (where f.status = 'new'), 'in_progress', count(*) filter (where f.status = 'in_progress'),
                 'closed', count(*) filter (where f.status = 'closed'),
                 'complaints_30', count(*) filter (where f.kind = 'complaint' and f.created_at > now() - interval '30 days'),
                 'avg_rating_30', round(avg(f.rating) filter (where f.created_at > now() - interval '30 days'), 1))
                 from public.customer_feedback f where f.company_id = c.company_id and f.branch_id = v_branch),
    'items', coalesce((select jsonb_agg(jsonb_build_object(
               'id', f.id, 'kind', f.kind, 'rating', f.rating, 'message', f.message, 'customer_name', f.customer_name,
               'customer_phone', f.customer_phone, 'order_number', f.order_number, 'status', f.status, 'manager_note', f.manager_note,
               'handled_by', (select s.name from public.staff s where s.id = f.handled_by), 'handled_at', f.handled_at,
               'created_at', f.created_at) order by f.created_at desc)
               from (select * from public.customer_feedback x
                      where x.company_id = c.company_id and x.branch_id = v_branch
                        and (v_filter = 'all' or (v_filter = 'open' and x.status <> 'closed') or x.status = v_filter)
                      order by x.created_at desc limit 300) f), '[]'::jsonb));
end;
$$;

-- links of the branch for the screens (complaints page, social pages)
create or replace function public.branch_links_secure(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
begin
  select * into c from public.pos_ctx(p_token, null);
  return jsonb_build_object('ok', true, 'public_token', (select b.public_token from public.branches b where b.id = c.branch_id));
end;
$$;


-- ===================================================================================
-- 7) Daily profit / loss with the monthly fixed costs
--    Fixed costs = the active recurring expenses (المصروفات المتكررة), grouped by their account.
--    For each account: if a real amount was booked this month (expense paid, payroll, bill) the real amount is used,
--    otherwise the planned amount (estimate). The month total is spread evenly over the days of the month.
--    Other expenses (not in the recurring list) count on the day they were booked.
-- ===================================================================================
create or replace function public.pos_pnl_month(p_company_id uuid, p_branch_id uuid, p_month date)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
declare
  v_start date := date_trunc('month', coalesce(p_month, public.pos_local_date(now())))::date;
  v_end date := (date_trunc('month', coalesce(p_month, public.pos_local_date(now()))) + interval '1 month - 1 day')::date;
  v_today date := public.pos_local_date(now());
  v_last date;
  v_days int;
  v_elapsed int;
  v_lines jsonb;
  v_fixed numeric;
  v_accounts uuid[];
  v_estimates int;
  v_rows jsonb;
  v_tot record;
begin
  v_days := extract(day from v_end)::int;
  v_last := least(v_today, v_end);
  v_elapsed := greatest(0, v_last - v_start + 1);

  with tpl as (
    select e.account_id, string_agg(distinct coalesce(r.description, e.name), '، ') as name, sum(r.amount) as budget
      from public.expense_recurring r join public.expense_categories e on e.id = r.category_id
     where r.company_id = p_company_id and r.is_active is true and e.account_id is not null
       and (p_branch_id is null or r.branch_id is null or r.branch_id = p_branch_id)
     group by e.account_id
  ), act as (
    select b.account_id, b.balance from public.pos_account_balances(p_company_id, v_start, v_end, p_branch_id) b
     where b.account_id in (select account_id from tpl)
  )
  select coalesce(jsonb_agg(jsonb_build_object('name', t.name, 'account', a2.code || ' - ' || a2.name_ar, 'budget', t.budget,
                                               'actual', coalesce(a.balance, 0),
                                               'used', case when coalesce(a.balance, 0) > 0 then a.balance else t.budget end,
                                               'kind', case when coalesce(a.balance, 0) > 0 then 'actual' else 'estimate' end)
                            order by t.budget desc), '[]'::jsonb),
         coalesce(sum(case when coalesce(a.balance, 0) > 0 then a.balance else t.budget end), 0),
         coalesce(array_agg(t.account_id), '{}'::uuid[]),
         count(*) filter (where coalesce(a.balance, 0) <= 0)
    into v_lines, v_fixed, v_accounts, v_estimates
    from tpl t left join act a on a.account_id = t.account_id left join public.accounts a2 on a2.id = t.account_id;

  with days as (
    select g.d::date as day from generate_series(v_start, v_last, interval '1 day') g(d) where v_elapsed > 0
  ), q as (
    select d.day,
           coalesce((select sum(o.total_amount - o.tax_amount) from public.pos_rpt_orders(p_company_id, p_branch_id, d.day, d.day) o), 0) as revenue,
           coalesce((select sum(o.total_amount) from public.pos_rpt_orders(p_company_id, p_branch_id, d.day, d.day) o), 0) as sales,
           coalesce((select sum(sm.total_cost) from public.stock_movements sm where sm.company_id = p_company_id and sm.movement_type = 'sale'
                       and (p_branch_id is null or sm.branch_id = p_branch_id) and public.pos_local_date(sm.created_at) = d.day), 0) as cogs,
           coalesce((select sum(sm.total_cost) from public.stock_movements sm where sm.company_id = p_company_id and sm.movement_type = 'waste'
                       and (p_branch_id is null or sm.branch_id = p_branch_id) and public.pos_local_date(sm.created_at) = d.day), 0) as waste,
           coalesce((select sum(b.balance) from public.pos_account_balances(p_company_id, d.day, d.day, p_branch_id) b
                      where b.account_type = 'expense' and not (b.account_id = any (v_accounts))), 0) as other_exp
      from days d
  )
  select coalesce(jsonb_agg(jsonb_build_object('day', q.day, 'sales', q.sales, 'revenue', q.revenue, 'cogs', q.cogs, 'waste', q.waste,
                                               'gross_profit', q.revenue - q.cogs - q.waste, 'other_expenses', q.other_exp,
                                               'fixed_share', round(v_fixed / v_days, 2),
                                               'net', round(q.revenue - q.cogs - q.waste - q.other_exp - v_fixed / v_days, 2))
                            order by q.day), '[]'::jsonb)
    into v_rows from q;

  select coalesce(sum((r->>'revenue')::numeric), 0) as revenue, coalesce(sum((r->>'sales')::numeric), 0) as sales,
         coalesce(sum((r->>'cogs')::numeric), 0) as cogs, coalesce(sum((r->>'waste')::numeric), 0) as waste,
         coalesce(sum((r->>'other_expenses')::numeric), 0) as other_exp
    into v_tot from jsonb_array_elements(v_rows) r;

  return jsonb_build_object('month', to_char(v_start, 'YYYY-MM'), 'from', v_start, 'to', v_end, 'days_in_month', v_days,
    'days_passed', v_elapsed, 'fixed_month', round(v_fixed, 2), 'fixed_daily', round(v_fixed / v_days, 2),
    'estimate_lines', v_estimates, 'fixed_lines', v_lines, 'days', v_rows,
    'mtd', jsonb_build_object('sales', v_tot.sales, 'revenue', v_tot.revenue, 'cogs', v_tot.cogs, 'waste', v_tot.waste,
                              'gross_profit', v_tot.revenue - v_tot.cogs - v_tot.waste, 'other_expenses', v_tot.other_exp,
                              'fixed', round(v_fixed * v_elapsed / v_days, 2),
                              'net', round(v_tot.revenue - v_tot.cogs - v_tot.waste - v_tot.other_exp - v_fixed * v_elapsed / v_days, 2)),
    'forecast', case when v_elapsed = 0 then null else jsonb_build_object(
                  'revenue', round(v_tot.revenue / v_elapsed * v_days, 2),
                  'gross_profit', round((v_tot.revenue - v_tot.cogs - v_tot.waste) / v_elapsed * v_days, 2),
                  'other_expenses', round(v_tot.other_exp / v_elapsed * v_days, 2),
                  'fixed', round(v_fixed, 2),
                  'net', round((v_tot.revenue - v_tot.cogs - v_tot.waste - v_tot.other_exp) / v_elapsed * v_days - v_fixed, 2),
                  'break_even_daily_sales', case when v_tot.revenue > 0
                      then round((v_fixed / v_days) / nullif((v_tot.revenue - v_tot.cogs - v_tot.waste) / v_tot.revenue, 0), 2) end) end);
end;
$$;

create or replace function public.pnl_daily_secure(p_token text, p_month date, p_branch_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
  v_branch uuid;
begin
  select * into c from public.pos_ctx(p_token, 'reports');
  v_branch := c.branch_id;
  if c.role_name = 'owner' then
    v_branch := p_branch_id;
  end if;
  return jsonb_build_object('ok', true, 'branch', coalesce((select b.name from public.branches b where b.id = v_branch), 'كل الفروع'))
         || public.pos_pnl_month(c.company_id, v_branch, p_month);
end;
$$;

-- ===================================================================================
-- 8) Owner dashboard: everything in one call
-- ===================================================================================
create or replace function public.dashboard_secure(p_token text, p_from date, p_to date, p_branch_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
  v_branch uuid;
  v_from date := coalesce(p_from, public.pos_local_date(now()));
  v_to date := coalesce(p_to, public.pos_local_date(now()));
  v_len int;
  v_pfrom date;
  v_pto date;
  v_res jsonb;
begin
  select * into c from public.pos_ctx(p_token, 'dashboard');
  v_branch := c.branch_id;
  if c.role_name = 'owner' then
    v_branch := p_branch_id;
  end if;
  if v_to < v_from or v_to - v_from > 366 then
    return jsonb_build_object('ok', false, 'reason', 'invalid_period');
  end if;
  v_len := v_to - v_from + 1;
  v_pto := v_from - 1;
  v_pfrom := v_from - v_len;

  with cur as (select * from public.pos_rpt_orders(c.company_id, v_branch, v_from, v_to)),
       prv as (select * from public.pos_rpt_orders(c.company_id, v_branch, v_pfrom, v_pto)),
       items as (select oi.*, o.created_at as order_at from cur o join public.order_items oi on oi.order_id = o.id
                  where coalesce(oi.status, 'active') = 'active'),
       mv as (select sm.movement_type, sm.total_cost, sm.created_at from public.stock_movements sm
               where sm.company_id = c.company_id and (v_branch is null or sm.branch_id = v_branch)
                 and public.pos_local_date(sm.created_at) between v_pfrom and v_to and sm.movement_type in ('sale', 'waste'))
  select jsonb_build_object(
    'kpi', jsonb_build_object(
      'sales', (select coalesce(sum(total_amount), 0) from cur),
      'orders', (select count(*) from cur),
      'avg_ticket', (select round(coalesce(avg(total_amount), 0), 2) from cur),
      'guests', (select coalesce(sum(coalesce(guest_count, 1)), 0) from cur),
      'discounts', (select coalesce(sum(discount_amount), 0) from cur),
      'tax', (select coalesce(sum(tax_amount), 0) from cur),
      'service', (select coalesce(sum(service_charge_amount), 0) from cur),
      'revenue', (select coalesce(sum(total_amount - tax_amount), 0) from cur),
      'cogs', (select coalesce(sum(total_cost), 0) from mv where movement_type = 'sale' and public.pos_local_date(created_at) between v_from and v_to),
      'waste', (select coalesce(sum(total_cost), 0) from mv where movement_type = 'waste' and public.pos_local_date(created_at) between v_from and v_to),
      'tips', (select coalesce(sum(p.tip_amount), 0) from public.payments p join cur o on o.id = p.order_id),
      'cancelled', (select count(*) from public.orders o where o.company_id = c.company_id and o.status = 'cancelled'
                      and (v_branch is null or o.branch_id = v_branch) and public.pos_local_date(o.created_at) between v_from and v_to),
      'qr_orders', (select count(*) from cur where source = 'qr'),
      'new_customers', (select count(*) from public.customers cu where cu.company_id = c.company_id
                          and public.pos_local_date(cu.created_at) between v_from and v_to),
      'repeat_customers', (select count(distinct o.customer_id) from cur o where o.customer_id is not null
                             and exists (select 1 from public.orders x where x.customer_id = o.customer_id and x.status = 'closed'
                                           and x.created_at < o.created_at)),
      'with_customer', (select count(*) from cur where customer_id is not null)),
    'prev', jsonb_build_object(
      'sales', (select coalesce(sum(total_amount), 0) from prv),
      'orders', (select count(*) from prv),
      'avg_ticket', (select round(coalesce(avg(total_amount), 0), 2) from prv),
      'guests', (select coalesce(sum(coalesce(guest_count, 1)), 0) from prv),
      'revenue', (select coalesce(sum(total_amount - tax_amount), 0) from prv),
      'cogs', (select coalesce(sum(total_cost), 0) from mv where movement_type = 'sale' and public.pos_local_date(created_at) between v_pfrom and v_pto),
      'waste', (select coalesce(sum(total_cost), 0) from mv where movement_type = 'waste' and public.pos_local_date(created_at) between v_pfrom and v_pto)),
    'daily', coalesce((select jsonb_agg(jsonb_build_object('day', g.d::date, 'sales', coalesce(x.sales, 0), 'orders', coalesce(x.orders, 0),
                                                         'revenue', coalesce(x.revenue, 0)) order by g.d)
                         from generate_series(v_from, v_to, interval '1 day') g(d)
                         left join (select public.pos_local_date(created_at) as day, sum(total_amount) as sales, count(*) as orders,
                                           sum(total_amount - tax_amount) as revenue from cur group by 1) x on x.day = g.d::date), '[]'::jsonb),
    'hourly', coalesce((select jsonb_agg(jsonb_build_object('hour', h.h, 'sales', coalesce(x.sales, 0), 'orders', coalesce(x.orders, 0)) order by h.h)
                          from generate_series(0, 23) h(h)
                          left join (select extract(hour from created_at at time zone 'Africa/Cairo')::int as hr, sum(total_amount) as sales,
                                            count(*) as orders from cur group by 1) x on x.hr = h.h), '[]'::jsonb),
    'weekday', coalesce((select jsonb_agg(jsonb_build_object('d', w.d, 'sales', coalesce(x.sales, 0), 'orders', coalesce(x.orders, 0)) order by w.d)
                           from generate_series(0, 6) w(d)
                           left join (select extract(dow from created_at at time zone 'Africa/Cairo')::int as dw, sum(total_amount) as sales,
                                             count(*) as orders from cur group by 1) x on x.dw = w.d), '[]'::jsonb),
    'payments', coalesce((select jsonb_agg(jsonb_build_object('method', q.method, 'amount', q.amount) order by q.amount desc)
                            from (select p.payment_method as method, sum(p.amount) as amount from public.payments p join cur o on o.id = p.order_id
                                   group by 1) q), '[]'::jsonb),
    'order_types', coalesce((select jsonb_agg(jsonb_build_object('type', q.order_type, 'amount', q.amount, 'orders', q.orders) order by q.amount desc)
                               from (select order_type, sum(total_amount) as amount, count(*) as orders from cur group by 1) q), '[]'::jsonb),
    'categories', coalesce((select jsonb_agg(jsonb_build_object('name', q.name, 'amount', q.amount, 'qty', q.qty) order by q.amount desc)
                              from (select coalesce(cat.name, '-') as name, sum(i.total_price) as amount, sum(i.quantity) as qty
                                      from items i left join public.products p on p.id = i.product_id
                                      left join public.categories cat on cat.id = p.category_id group by 1) q), '[]'::jsonb),
    'top_products', coalesce((select jsonb_agg(jsonb_build_object('name', q.name, 'qty', q.qty, 'amount', q.amount, 'cost', q.cost,
                                                                 'has_recipe', q.has_recipe) order by q.amount desc)
                                from (select coalesce(p.name, '-') as name, sum(i.quantity) as qty, sum(i.total_price) as amount,
                                             round(sum(i.quantity) * public.pos_product_cost(i.product_id), 2) as cost,
                                             exists (select 1 from public.recipes r where r.product_id = i.product_id) as has_recipe
                                        from items i left join public.products p on p.id = i.product_id
                                       group by p.name, i.product_id order by sum(i.total_price) desc limit 10) q), '[]'::jsonb),
    'slow_products', coalesce((select jsonb_agg(jsonb_build_object('name', q.name, 'qty', q.qty) order by q.qty)
                                 from (select p.name, coalesce((select sum(i.quantity) from items i where i.product_id = p.id), 0) as qty
                                         from public.products p
                                         join public.branches b on b.brand_id = p.brand_id and (v_branch is null or b.id = v_branch)
                                        where p.is_available is true
                                        group by p.id, p.name order by 2, p.name limit 5) q), '[]'::jsonb),
    'waiters', coalesce((select jsonb_agg(jsonb_build_object('name', q.name, 'amount', q.amount, 'orders', q.orders) order by q.amount desc)
                           from (select coalesce(w.name, 'بدون ويتر') as name, sum(o.total_amount) as amount, count(*) as orders
                                   from cur o left join public.staff w on w.id = o.waiter_id group by 1 order by 2 desc limit 8) q), '[]'::jsonb),
    'top_customers', coalesce((select jsonb_agg(jsonb_build_object('name', q.name, 'amount', q.amount, 'orders', q.orders) order by q.amount desc)
                                 from (select cu.name, sum(o.total_amount) as amount, count(*) as orders
                                         from cur o join public.customers cu on cu.id = o.customer_id group by cu.id, cu.name
                                        order by 2 desc limit 5) q), '[]'::jsonb),
    'prep', coalesce((select jsonb_agg(jsonb_build_object('station', q.station, 'items', q.items, 'avg_minutes', q.avg_m, 'late_pct', q.late_pct)
                                       order by q.station)
                        from (select public.pos_item_station(i.product_id) as station, count(*) as items,
                                     round(avg(extract(epoch from (i.ready_at - i.sent_at)) / 60.0)::numeric, 1) as avg_m,
                                     round(100.0 * count(*) filter (where extract(epoch from (i.ready_at - i.sent_at)) / 60.0
                                            > public.pos_station_warn(c.company_id, public.pos_item_station(i.product_id)) + coalesce(i.prep_extra_minutes, 0))
                                           / nullif(count(*), 0), 1) as late_pct
                                from items i where i.ready_at is not null and i.sent_at is not null group by 1) q), '[]'::jsonb),
    'feedback', (select jsonb_build_object('count', count(*), 'complaints', count(*) filter (where f.kind = 'complaint'),
                                           'avg_rating', round(avg(f.rating), 1), 'open', count(*) filter (where f.status <> 'closed'))
                   from public.customer_feedback f where f.company_id = c.company_id and (v_branch is null or f.branch_id = v_branch)
                    and public.pos_local_date(f.created_at) between v_from and v_to),
    'no_recipe', (select count(*) from public.products p
                   where p.is_available is true and not exists (select 1 from public.recipes r where r.product_id = p.id)
                     and exists (select 1 from public.branches b where b.brand_id = p.brand_id and (v_branch is null or b.id = v_branch)))
  ) into v_res;

  -- what is happening right now
  v_res := v_res || jsonb_build_object('live', jsonb_build_object(
    'open_orders', (select count(*) from public.orders o where o.company_id = c.company_id and (v_branch is null or o.branch_id = v_branch)
                      and coalesce(o.status, '') not in ('paid', 'closed', 'cancelled') and o.created_at > now() - interval '24 hours'),
    'open_value', (select coalesce(sum(o.total_amount), 0) from public.orders o where o.company_id = c.company_id
                     and (v_branch is null or o.branch_id = v_branch)
                     and coalesce(o.status, '') not in ('paid', 'closed', 'cancelled') and o.created_at > now() - interval '24 hours'),
    'tables_busy', (select count(*) from public.tables t join public.areas a on a.id = t.area_id
                     where (v_branch is null or a.branch_id = v_branch) and t.status = 'occupied'
                       and a.branch_id in (select b.id from public.branches b join public.brands br on br.id = b.brand_id where br.company_id = c.company_id)),
    'tables_total', (select count(*) from public.tables t join public.areas a on a.id = t.area_id
                      where (v_branch is null or a.branch_id = v_branch)
                        and a.branch_id in (select b.id from public.branches b join public.brands br on br.id = b.brand_id where br.company_id = c.company_id)),
    'open_shifts', (select count(*) from public.pos_shifts s where s.company_id = c.company_id and (v_branch is null or s.branch_id = v_branch)
                      and s.closed_at is null),
    'qr_waiting', (select count(*) from public.qr_orders q where q.company_id = c.company_id and (v_branch is null or q.branch_id = v_branch)
                     and q.status = 'pending' and q.created_at > now() - interval '12 hours'),
    'low_stock', (select count(*) from public.ingredients i
                   where coalesce(i.min_stock_alert, 0) > 0
                     and coalesce((select sum(ws.quantity) from public.warehouse_stock ws join public.warehouses w on w.id = ws.warehouse_id
                                    where ws.ingredient_id = i.id and (v_branch is null or w.branch_id = v_branch)), 0) < i.min_stock_alert
                     and exists (select 1 from public.branches b join public.brands br on br.id = b.brand_id
                                  where br.company_id = c.company_id and b.brand_id = i.brand_id))),
    'month', public.pos_pnl_month(c.company_id, v_branch, v_to),
    'from', v_from, 'to', v_to, 'prev_from', v_pfrom, 'prev_to', v_pto,
    'branch', coalesce((select b.name from public.branches b where b.id = v_branch), 'كل الفروع'),
    'branches', case when c.role_name = 'owner' then (select coalesce(jsonb_agg(jsonb_build_object('id', b.id, 'name', b.name) order by b.name), '[]'::jsonb)
                                                       from public.branches b join public.brands br on br.id = b.brand_id
                                                      where br.company_id = c.company_id) else '[]'::jsonb end,
    'can_pick_branch', c.role_name = 'owner');
  return jsonb_build_object('ok', true) || v_res;
end;
$$;


-- ===================================================================================
-- 9) Menu + recipes in one screen
-- ===================================================================================
create or replace function public.pos_menu_admin_data(p_brand uuid)
returns jsonb
language sql
stable
security definer
set search_path = public, extensions
as $$
  select jsonb_build_object(
    'categories', coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'name', x.name, 'station', coalesce(x.station, 'kitchen'),
                                   'sort_order', x.sort_order, 'show_in_menu', x.show_in_menu,
                                   'products', (select count(*) from public.products p where p.category_id = x.id)) order by x.sort_order, x.name)
                              from public.categories x where x.brand_id = p_brand), '[]'::jsonb),
    'products', coalesce((select jsonb_agg(jsonb_build_object(
                     'id', p.id, 'name', p.name, 'price', p.price, 'category_id', p.category_id, 'is_available', coalesce(p.is_available, true),
                     'show_in_menu', p.show_in_menu, 'description', p.description, 'sort_order', p.sort_order,
                     'has_image', coalesce(p.image, '') <> '',
                     'cost', round(public.pos_product_cost(p.id), 2),
                     'sold', exists (select 1 from public.order_items oi where oi.product_id = p.id),
                     'recipe', coalesce((select jsonb_agg(jsonb_build_object('ingredient_id', r.ingredient_id, 'qty', r.quantity_required)
                                                          order by i.name)
                                           from public.recipes r join public.ingredients i on i.id = r.ingredient_id
                                          where r.product_id = p.id), '[]'::jsonb),
                     'group_ids', coalesce((select jsonb_agg(g.group_id) from public.product_modifier_groups g where g.product_id = p.id), '[]'::jsonb))
                   order by p.sort_order, p.name)
                   from public.products p where p.brand_id = p_brand), '[]'::jsonb),
    'ingredients', coalesce((select jsonb_agg(jsonb_build_object('id', i.id, 'name', i.name, 'unit', i.unit, 'cost_per_unit', coalesce(i.cost_per_unit, 0))
                                              order by i.name)
                               from public.ingredients i where i.brand_id is null or i.brand_id = p_brand), '[]'::jsonb),
    'groups', coalesce((select jsonb_agg(jsonb_build_object('id', g.id, 'name', g.name,
                                 'modifiers', (select count(*) from public.modifiers m where m.group_id = g.id)) order by g.name)
                          from public.modifier_groups g where g.brand_id = p_brand), '[]'::jsonb))
$$;

create or replace function public.menu_admin_secure(p_token text, p_action text, p_data jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  c record;
  v_brand uuid;
  d jsonb := coalesce(p_data, '{}'::jsonb);
  v_id uuid;
  v_cat uuid;
  v_name text;
  v_num numeric;
  v_old record;
  l jsonb;
  r jsonb;
  v_created int := 0;
  v_updated int := 0;
  v_extra jsonb := '{}'::jsonb;
begin
  select * into c from public.pos_ctx(p_token, 'settings');
  if c.role_name not in ('owner', 'branch_manager') then
    return jsonb_build_object('ok', false, 'reason', 'not_allowed');
  end if;
  select b.brand_id into v_brand from public.branches b where b.id = c.branch_id;
  if v_brand is null then
    return jsonb_build_object('ok', false, 'reason', 'branch_brand_not_configured');
  end if;

  case coalesce(p_action, '')
  when 'get' then
    null;

  when 'save_category' then
    v_id := public.pos_uuid(d->>'id');
    v_name := nullif(btrim(coalesce(d->>'name', '')), '');
    if v_name is null or length(v_name) > 100 then
      return jsonb_build_object('ok', false, 'reason', 'invalid_name');
    end if;
    if coalesce(d->>'station', 'kitchen') not in ('kitchen', 'bar', 'shisha') then
      return jsonb_build_object('ok', false, 'reason', 'invalid_value');
    end if;
    if exists (select 1 from public.categories x where x.brand_id = v_brand and btrim(x.name) = v_name and x.id is distinct from v_id) then
      return jsonb_build_object('ok', false, 'reason', 'name_taken');
    end if;
    if v_id is null then
      insert into public.categories (brand_id, name, station, sort_order, show_in_menu)
      values (v_brand, v_name, coalesce(d->>'station', 'kitchen'),
              coalesce((select max(x.sort_order) + 1 from public.categories x where x.brand_id = v_brand), 0),
              coalesce((d->>'show_in_menu')::boolean, true))
      returning id into v_id;
    else
      update public.categories
         set name = v_name, station = coalesce(d->>'station', station),
             sort_order = coalesce(nullif(d->>'sort_order', '')::int, sort_order),
             show_in_menu = coalesce((d->>'show_in_menu')::boolean, show_in_menu)
       where id = v_id and brand_id = v_brand;
      if not found then
        return jsonb_build_object('ok', false, 'reason', 'invalid_category');
      end if;
    end if;
    v_extra := jsonb_build_object('id', v_id);

  when 'delete_category' then
    v_id := public.pos_uuid(d->>'id');
    if exists (select 1 from public.products p where p.category_id = v_id) then
      return jsonb_build_object('ok', false, 'reason', 'category_not_empty');
    end if;
    delete from public.categories where id = v_id and brand_id = v_brand;

  when 'save_product' then
    v_id := public.pos_uuid(d->>'id');
    v_name := nullif(btrim(coalesce(d->>'name', '')), '');
    v_num := public.pos_amount(d->>'price');
    v_cat := public.pos_uuid(d->>'category_id');
    if v_name is null or length(v_name) > 150 then
      return jsonb_build_object('ok', false, 'reason', 'invalid_name');
    end if;
    if v_num is null or v_num > 999999 then
      return jsonb_build_object('ok', false, 'reason', 'invalid_price');
    end if;
    if v_cat is null or not exists (select 1 from public.categories x where x.id = v_cat and x.brand_id = v_brand) then
      return jsonb_build_object('ok', false, 'reason', 'invalid_category');
    end if;
    if length(coalesce(d->>'description', '')) > 500 then
      return jsonb_build_object('ok', false, 'reason', 'value_too_long');
    end if;
    if exists (select 1 from public.products p where p.brand_id = v_brand and btrim(p.name) = v_name and p.id is distinct from v_id) then
      return jsonb_build_object('ok', false, 'reason', 'name_taken');
    end if;
    if jsonb_typeof(d->'recipe') = 'array' then
      if jsonb_array_length(d->'recipe') > 50 then
        return jsonb_build_object('ok', false, 'reason', 'invalid_items');
      end if;
      for l in select e.value from jsonb_array_elements(d->'recipe') e(value) loop
        if not exists (select 1 from public.ingredients i where i.id = public.pos_uuid(l->>'ingredient_id'))
           or coalesce(public.pos_amount(l->>'qty'), 0) <= 0 then
          return jsonb_build_object('ok', false, 'reason', 'invalid_items');
        end if;
      end loop;
    end if;
    if jsonb_typeof(d->'group_ids') = 'array'
       and exists (select 1 from jsonb_array_elements_text(d->'group_ids') g(v)
                    where not exists (select 1 from public.modifier_groups mg where mg.id = public.pos_uuid(g.v) and mg.brand_id = v_brand)) then
      return jsonb_build_object('ok', false, 'reason', 'group_not_found');
    end if;
    if v_id is null then
      insert into public.products (brand_id, category_id, name, price, is_available, description, show_in_menu, sort_order)
      values (v_brand, v_cat, v_name, round(v_num, 2), coalesce((d->>'is_available')::boolean, true),
              nullif(btrim(coalesce(d->>'description', '')), ''), coalesce((d->>'show_in_menu')::boolean, true),
              coalesce(nullif(d->>'sort_order', '')::int, 0))
      returning id into v_id;
      insert into public.settings_logs (staff_id, action, details)
      values (c.staff_id, 'add_product', jsonb_build_object('product_id', v_id, 'name', v_name, 'price', round(v_num, 2)));
    else
      select p.price, p.name, p.is_available into v_old from public.products p where p.id = v_id and p.brand_id = v_brand for update;
      if not found then
        return jsonb_build_object('ok', false, 'reason', 'product_not_found');
      end if;
      update public.products
         set name = v_name, price = round(v_num, 2), category_id = v_cat,
             is_available = coalesce((d->>'is_available')::boolean, is_available),
             description = nullif(btrim(coalesce(d->>'description', '')), ''),
             show_in_menu = coalesce((d->>'show_in_menu')::boolean, show_in_menu),
             sort_order = coalesce(nullif(d->>'sort_order', '')::int, sort_order)
       where id = v_id;
      if v_old.price is distinct from round(v_num, 2) then
        insert into public.settings_logs (staff_id, action, details)
        values (c.staff_id, 'set_product_price', jsonb_build_object('product_id', v_id, 'name', v_name, 'old_price', v_old.price,
                                                                    'new_price', round(v_num, 2)));
      end if;
    end if;
    if jsonb_typeof(d->'recipe') = 'array' then
      delete from public.recipes where product_id = v_id;
      insert into public.recipes (product_id, ingredient_id, quantity_required)
      select v_id, (e.value->>'ingredient_id')::uuid, sum((e.value->>'qty')::numeric)
        from jsonb_array_elements(d->'recipe') e(value) group by 2;
    end if;
    if jsonb_typeof(d->'group_ids') = 'array' then
      delete from public.product_modifier_groups where product_id = v_id
         and group_id not in (select public.pos_uuid(g.v) from jsonb_array_elements_text(d->'group_ids') g(v));
      insert into public.product_modifier_groups (product_id, group_id)
      select v_id, public.pos_uuid(g.v) from jsonb_array_elements_text(d->'group_ids') g(v)
       where not exists (select 1 from public.product_modifier_groups x where x.product_id = v_id and x.group_id = public.pos_uuid(g.v));
    end if;
    v_extra := jsonb_build_object('id', v_id);

  when 'set_image' then
    v_id := public.pos_uuid(d->>'id');
    if coalesce(d->>'image', '') <> ''
       and ((d->>'image') !~ '^data:image/(png|jpeg|jpg|webp);base64,' or length(d->>'image') > 350000) then
      return jsonb_build_object('ok', false, 'reason', 'invalid_image');
    end if;
    update public.products set image = nullif(d->>'image', '') where id = v_id and brand_id = v_brand;
    if not found then
      return jsonb_build_object('ok', false, 'reason', 'product_not_found');
    end if;

  when 'get_image' then
    return jsonb_build_object('ok', true, 'image', (select p.image from public.products p where p.id = public.pos_uuid(d->>'id') and p.brand_id = v_brand));

  when 'delete_product' then
    v_id := public.pos_uuid(d->>'id');
    if not exists (select 1 from public.products p where p.id = v_id and p.brand_id = v_brand) then
      return jsonb_build_object('ok', false, 'reason', 'product_not_found');
    end if;
    if exists (select 1 from public.order_items oi where oi.product_id = v_id) then
      -- sold before: kept for the old bills and reports, but stopped and hidden
      update public.products set is_available = false, show_in_menu = false where id = v_id;
      v_extra := jsonb_build_object('archived', true);
    else
      delete from public.product_modifier_groups where product_id = v_id;
      delete from public.recipes where product_id = v_id;
      delete from public.products where id = v_id;
    end if;
    insert into public.settings_logs (staff_id, action, details)
    values (c.staff_id, 'delete_product', jsonb_build_object('product_id', v_id, 'archived', v_extra ? 'archived'));

  when 'add_ingredient' then
    v_name := nullif(btrim(coalesce(d->>'name', '')), '');
    if v_name is null or length(v_name) > 100 or nullif(btrim(coalesce(d->>'unit', '')), '') is null then
      return jsonb_build_object('ok', false, 'reason', 'invalid_name');
    end if;
    select i.id into v_id from public.ingredients i where btrim(i.name) = v_name and (i.brand_id is null or i.brand_id = v_brand) limit 1;
    if v_id is null then
      insert into public.ingredients (name, unit, cost_per_unit, min_stock_alert, brand_id)
      values (v_name, left(btrim(d->>'unit'), 20), coalesce(public.pos_amount(d->>'cost_per_unit'), 0),
              coalesce(nullif((public.pos_app_settings(c.company_id) -> 'inventory' ->> 'default_min_stock'), '')::numeric, 0), v_brand)
      returning id into v_id;
      v_extra := jsonb_build_object('id', v_id, 'existing', false);
    else
      v_extra := jsonb_build_object('id', v_id, 'existing', true);
    end if;

  when 'import' then
    -- the whole menu at once: [{category, name, price, description, station}]. Same name = price/category updated.
    if jsonb_typeof(d->'rows') is distinct from 'array' or jsonb_array_length(d->'rows') > 1000 then
      return jsonb_build_object('ok', false, 'reason', 'invalid_items');
    end if;
    for r in select e.value from jsonb_array_elements(d->'rows') e(value) loop
      v_name := nullif(btrim(coalesce(r->>'name', '')), '');
      v_num := public.pos_amount(r->>'price');
      if v_name is null or length(v_name) > 150 or v_num is null or nullif(btrim(coalesce(r->>'category', '')), '') is null
         or coalesce(r->>'station', 'kitchen') not in ('kitchen', 'bar', 'shisha') then
        return jsonb_build_object('ok', false, 'reason', 'invalid_items', 'row', r);
      end if;
      select x.id into v_cat from public.categories x where x.brand_id = v_brand and btrim(x.name) = btrim(r->>'category') limit 1;
      if v_cat is null then
        insert into public.categories (brand_id, name, station, sort_order)
        values (v_brand, left(btrim(r->>'category'), 100), coalesce(r->>'station', 'kitchen'),
                coalesce((select max(x.sort_order) + 1 from public.categories x where x.brand_id = v_brand), 0))
        returning id into v_cat;
      end if;
      select p.id into v_id from public.products p where p.brand_id = v_brand and btrim(p.name) = v_name limit 1;
      if v_id is null then
        insert into public.products (brand_id, category_id, name, price, is_available, description, sort_order)
        values (v_brand, v_cat, v_name, round(v_num, 2), true, nullif(btrim(coalesce(r->>'description', '')), ''),
                coalesce((select max(p.sort_order) + 1 from public.products p where p.category_id = v_cat), 0));
        v_created := v_created + 1;
      else
        update public.products set price = round(v_num, 2), category_id = v_cat,
               description = coalesce(nullif(btrim(coalesce(r->>'description', '')), ''), description)
         where id = v_id;
        v_updated := v_updated + 1;
      end if;
    end loop;
    insert into public.settings_logs (staff_id, action, details)
    values (c.staff_id, 'menu_import', jsonb_build_object('created', v_created, 'updated', v_updated));
    v_extra := jsonb_build_object('created', v_created, 'updated', v_updated);

  else
    return jsonb_build_object('ok', false, 'reason', 'unknown_action');
  end case;

  return jsonb_build_object('ok', true) || v_extra || public.pos_menu_admin_data(v_brand);
end;
$$;


-- ===================================================================================
-- 10) Version + grants
-- ===================================================================================
create or replace function public.motionpos_version_public()
returns text
language sql
immutable
as $$
  select '021'
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

-- ===================================================================================
-- 11) Self-test (everything below is rolled back)
-- ===================================================================================
do $selftest$
declare
  v_company uuid; v_brand uuid; v_branch uuid; v_area uuid; v_table uuid; v_qr text; v_owner uuid; v_role uuid;
  v_tok text := 'mp-t21-o-' || md5(random()::text || clock_timestamp()::text);
  v_res jsonb; v_cat uuid; v_prod uuid; v_prod2 uuid; v_ing uuid; v_ref text; v_qid uuid; v_order uuid; v_order2 uuid;
  v_cust uuid; v_acc uuid; v_ecat uuid; v_btok text; v_n int; v_num numeric;
begin
  begin
    insert into public.companies (name) values ('selftest021') returning id into v_company;
    insert into public.brands (company_id, name) values (v_company, 'selftest021') returning id into v_brand;
    insert into public.branches (name, brand_id, has_tables) values ('selftest021', v_brand, true) returning id, public_token into v_branch, v_btok;
    insert into public.areas (branch_id, name) values (v_branch, 'st') returning id into v_area;
    insert into public.tables (area_id, table_number, capacity, status) values (v_area, '7', 4, 'available') returning id, qr_token into v_table, v_qr;
    insert into public.branch_tax_settings (branch_id, vat_percentage, is_vat_inclusive, service_charge_percentage, is_service_taxable)
    values (v_branch, 14, false, 12, true);
    select id into v_role from public.roles where name = 'owner';
    insert into public.staff (name, role_id, branch_id, company_id, is_active)
    values ('selftest021', v_role, v_branch, v_company, true) returning id into v_owner;
    insert into public.staff_sessions (token_hash, staff_id, expires_at)
    values (encode(extensions.digest(v_tok, 'sha256'), 'hex'), v_owner, now() + interval '10 minutes');

    -- settings: new sections and checks
    if public.pos_settings_defaults() -> 'loyalty' is null or public.pos_settings_defaults() -> 'social' is null
       or (public.pos_settings_defaults() -> 'kds' ->> 'rush_bar_minutes') is null then
      raise exception 'SELFTEST defaults missing new sections';
    end if;
    v_res := public.app_settings_save_secure(v_tok, 'loyalty', jsonb_build_object('percent', 150));
    if coalesce(v_res->>'reason', '') <> 'invalid_value' then raise exception 'SELFTEST loyalty 150%% accepted: %', v_res; end if;
    v_res := public.app_settings_save_secure(v_tok, 'loyalty', jsonb_build_object('enabled', true, 'min_spent', 50, 'percent', 10));
    if not coalesce((v_res->>'ok')::boolean, false) then raise exception 'SELFTEST loyalty save failed: %', v_res; end if;
    v_res := public.app_settings_save_secure(v_tok, 'kds', jsonb_build_object('rush_kitchen_orders', 1, 'rush_kitchen_minutes', 7));
    if not coalesce((v_res->>'ok')::boolean, false) then raise exception 'SELFTEST rush save failed: %', v_res; end if;
    v_res := public.app_settings_save_secure(v_tok, 'social', jsonb_build_object('facebook_url', 'javascript:alert(1)'));
    if coalesce(v_res->>'reason', '') <> 'invalid_url' then raise exception 'SELFTEST bad url accepted: %', v_res; end if;

    -- menu screen: category, ingredient, product with recipe, import, delete
    v_res := public.menu_admin_secure(v_tok, 'save_category', jsonb_build_object('name', 'مشروبات ست', 'station', 'kitchen'));
    if not coalesce((v_res->>'ok')::boolean, false) then raise exception 'SELFTEST category failed: %', v_res; end if;
    v_cat := (v_res->>'id')::uuid;
    v_res := public.menu_admin_secure(v_tok, 'add_ingredient', jsonb_build_object('name', 'بن ست021', 'unit', 'كيلو', 'cost_per_unit', '400'));
    v_ing := (v_res->>'id')::uuid;
    v_res := public.menu_admin_secure(v_tok, 'save_product', jsonb_build_object('name', 'قهوة ست', 'price', '100', 'category_id', v_cat,
               'description', 'وصف', 'recipe', jsonb_build_array(jsonb_build_object('ingredient_id', v_ing, 'qty', '0.02'))));
    if not coalesce((v_res->>'ok')::boolean, false) then raise exception 'SELFTEST product failed: %', v_res; end if;
    v_prod := (v_res->>'id')::uuid;
    if public.pos_product_cost(v_prod) <> 8 then raise exception 'SELFTEST recipe cost wrong'; end if;
    v_res := public.menu_admin_secure(v_tok, 'save_product', jsonb_build_object('name', 'قهوة ست', 'price', '50', 'category_id', v_cat));
    if coalesce(v_res->>'reason', '') <> 'name_taken' then raise exception 'SELFTEST duplicate product name accepted: %', v_res; end if;
    v_res := public.menu_admin_secure(v_tok, 'import', jsonb_build_object('rows', jsonb_build_array(
               jsonb_build_object('category', 'حلويات ست', 'name', 'كيكة ست', 'price', 60),
               jsonb_build_object('category', 'مشروبات ست', 'name', 'قهوة ست', 'price', 110))));
    if (v_res->>'created')::int <> 1 or (v_res->>'updated')::int <> 1 or (select price from public.products where id = v_prod) <> 110 then
      raise exception 'SELFTEST import wrong: %', v_res->>'created';
    end if;
    select id into v_prod2 from public.products where name = 'كيكة ست' and brand_id = v_brand;
    v_res := public.menu_admin_secure(v_tok, 'delete_product', jsonb_build_object('id', v_prod2));
    if exists (select 1 from public.products where id = v_prod2) then raise exception 'SELFTEST unsold product not deleted'; end if;

    -- QR: menu, order, waiting list, accept -> real order on the table with the customer
    v_res := public.qr_menu_public(v_qr);
    if not coalesce((v_res->>'ok')::boolean, false) or jsonb_array_length(v_res->'categories') <> 1 then
      raise exception 'SELFTEST qr menu wrong: %', v_res;
    end if;
    v_res := public.qr_order_public(v_qr, jsonb_build_array(jsonb_build_object('product_id', v_prod, 'quantity', 2, 'item_notes', 'سكر بره')),
                                    'سارة ست', '01099998888', '1995-10-20', null);
    if not coalesce((v_res->>'ok')::boolean, false) or (v_res->>'total_estimate')::numeric <> 220 then
      raise exception 'SELFTEST qr order failed: %', v_res;
    end if;
    v_ref := v_res->>'ref';
    v_res := public.qr_order_public(v_qr, jsonb_build_array(jsonb_build_object('product_id', v_prod, 'quantity', 1)), '', '01099998888', null, null);
    if coalesce(v_res->>'reason', '') <> 'invalid_name' then raise exception 'SELFTEST qr without name accepted'; end if;
    v_res := public.qr_orders_secure(v_tok, 'list', null);
    if jsonb_array_length(v_res->'orders') <> 1 or v_res->'orders'->0->>'table_number' <> '7' then
      raise exception 'SELFTEST qr list wrong: %', v_res;
    end if;
    v_qid := (v_res->'orders'->0->>'id')::uuid;
    v_res := public.waiter_feed_secure(v_tok);
    if jsonb_array_length(v_res->'qr_orders') <> 1 then raise exception 'SELFTEST waiter bell has no QR order'; end if;
    v_res := public.qr_orders_secure(v_tok, 'accept', jsonb_build_object('id', v_qid));
    if not coalesce((v_res->>'ok')::boolean, false) then raise exception 'SELFTEST qr accept failed: %', v_res; end if;
    v_order := (v_res->>'order_id')::uuid;
    select o.customer_id into v_cust from public.orders o where o.id = v_order and o.table_id = v_table and o.source = 'qr';
    if v_cust is null or (select birthday from public.customers where id = v_cust) <> date '1995-10-20' then
      raise exception 'SELFTEST accepted order has no table/customer';
    end if;
    v_res := public.qr_orders_secure(v_tok, 'accept', jsonb_build_object('id', v_qid));
    if coalesce(v_res->>'reason', '') <> 'qr_handled' then raise exception 'SELFTEST qr accepted twice'; end if;
    v_res := public.qr_order_status_public(v_qr, v_ref);
    if v_res->>'status' <> 'accepted' or v_res->>'order_number' is null then raise exception 'SELFTEST qr status wrong: %', v_res; end if;

    -- loyalty: an old paid order of 100 for this customer -> 10% off on the open one
    if (select loyalty_percent from public.orders where id = v_order) <> 0 then raise exception 'SELFTEST loyalty given too early'; end if;
    insert into public.orders (company_id, brand_id, branch_id, order_type, status, total_amount, customer_id, created_at)
    values (v_company, v_brand, v_branch, 'takeaway', 'closed', 100, v_cust, now() - interval '2 days');
    update public.orders set customer_id = null where id = v_order;
    update public.orders set customer_id = v_cust where id = v_order;
    if (select loyalty_percent from public.orders where id = v_order) <> 10
       or (public.compute_order_totals(v_order) ->> 'loyalty_discount')::numeric <> 22
       or (select discount_amount from public.orders where id = v_order) <> 22 then
      raise exception 'SELFTEST loyalty discount wrong: %', public.compute_order_totals(v_order);
    end if;

    -- rush: kitchen has 1 open order and the limit is 1 -> the next order's items get +7 minutes
    v_res := public.submit_order_items_secure(v_tok, null::uuid, 'takeaway', null::uuid, null::uuid, null::uuid, null::uuid, 1,
               jsonb_build_array(jsonb_build_object('product_id', v_prod, 'quantity', 1, 'modifier_ids', '[]'::jsonb)));
    if not coalesce((v_res->>'ok')::boolean, false) then raise exception 'SELFTEST second order failed: %', v_res; end if;
    v_order2 := (v_res->>'order_id')::uuid;
    if (select max(prep_extra_minutes) from public.order_items where order_id = v_order2) <> 7
       or (select max(prep_extra_minutes) from public.order_items where order_id = v_order) <> 0 then
      raise exception 'SELFTEST rush minutes wrong';
    end if;
    v_res := public.kds_station_list_secure(v_tok, 'kitchen');
    if not coalesce((v_res->'rush'->>'on')::boolean, false) then raise exception 'SELFTEST kitchen screen does not show rush: %', v_res->'rush'; end if;

    -- complaints
    v_res := public.feedback_submit_public(v_btok, 'complaint', 2, 'القهوة كانت باردة', 'سارة', '01099998888', null);
    if not coalesce((v_res->>'ok')::boolean, false) then raise exception 'SELFTEST feedback failed: %', v_res; end if;
    v_res := public.feedback_secure(v_tok, 'list', null);
    if jsonb_array_length(v_res->'items') <> 1 or (v_res->'counts'->>'new')::int <> 1 then raise exception 'SELFTEST feedback list wrong: %', v_res; end if;
    v_res := public.feedback_secure(v_tok, 'set', jsonb_build_object('id', v_res->'items'->0->>'id', 'status', 'closed', 'note', 'اتكلمنا معاها'));
    if (v_res->'counts'->>'closed')::int <> 1 then raise exception 'SELFTEST feedback close failed'; end if;

    -- monthly fixed costs + dashboard
    insert into public.accounts (company_id, code, name_ar, account_type, normal_balance) values (v_company, '6200', 'كهرباء', 'expense', 'debit')
    returning id into v_acc;
    insert into public.expense_categories (company_id, name, account_id) values (v_company, 'كهرباء', v_acc) returning id into v_ecat;
    insert into public.expense_recurring (company_id, branch_id, category_id, amount, day_of_month, description)
    values (v_company, v_branch, v_ecat, 3100, 1, 'كهرباء');
    v_res := public.pnl_daily_secure(v_tok, null, v_branch);
    if (v_res->>'fixed_month')::numeric <> 3100 or (v_res->>'estimate_lines')::int <> 1 then
      raise exception 'SELFTEST monthly fixed costs wrong: % %', v_res->>'fixed_month', v_res->>'estimate_lines';
    end if;
    v_res := public.dashboard_secure(v_tok, null, null, v_branch);
    if not coalesce((v_res->>'ok')::boolean, false) or (v_res->'live'->>'open_orders')::int <> 2 then
      raise exception 'SELFTEST dashboard wrong: %', v_res->'live';
    end if;

    raise notice 'MOTIONPOS-021-SELFTEST-OK';
    raise exception using errcode = 'P0099', message = 'selftest_rollback';
  exception when sqlstate 'P0099' then
    null;
  end;
end;
$selftest$;

-- the shop API (PostgREST) re-reads the new columns and functions right after commit
notify pgrst, 'reload schema';

commit;
