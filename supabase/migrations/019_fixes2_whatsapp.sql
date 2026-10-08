-- 019_fixes2_whatsapp.sql
-- Fixes pack 2 (part 1): WhatsApp messages.
--   * new settings section "whatsapp": customer_message (from the customers screen), thanks_enabled + thanks_message
--     (after payment the cashier gets one button that opens WhatsApp with the message ready)
--   * {الاسم} = customer name, {المحل} = company name. Saved through the normal app_settings_save_secure (manager or owner).
-- Nothing else changes.

begin;

do $preflight$
begin
  if length('إكراميات') <> 8 then
    raise exception 'file_encoding_broken: read the file as UTF-8';
  end if;
  if public.motionpos_version_public() not in ('018', '019') then
    raise exception 'schema_preflight_failed: run 018 first';
  end if;
end;
$preflight$;

create or replace function public.pos_settings_defaults()
returns jsonb
language sql
immutable
as $$
  select jsonb_build_object(
    'general', jsonb_build_object('company_name', 'Motion POS', 'logo', '', 'address', '', 'phone', '', 'tax_number', '',
                                  'commercial_register', '', 'currency', 'ج.م'),
    'receipt', jsonb_build_object('header', '', 'footer', 'شكراً لزيارتكم', 'show_logo', true, 'paper_mm', 80, 'copies', 1,
                                  'auto_print_after_pay', false, 'auto_kitchen_ticket', false, 'show_tax_number', true),
    'pos', jsonb_build_object('order_types', jsonb_build_array('dine_in', 'takeaway', 'delivery', 'pickup'),
                              'payment_methods', jsonb_build_array('cash', 'card', 'instapay', 'wallet', 'on_account'),
                              'require_waiter', false, 'round_total', false,
                              'quick_notes', jsonb_build_array('بدون بصل', 'بدون طماطم', 'بدون مايونيز', 'حار', 'سكر زيادة',
                                                               'سكر خفيف', 'سكر بره', 'من غير سكر', 'من غير تلج', 'تلج زيادة')),
    'kds', jsonb_build_object('stations', jsonb_build_array('kitchen', 'bar', 'shisha'), 'warn_minutes', 15, 'sound', true,
                              'refresh_seconds', 10, 'warn_kitchen_minutes', 20, 'warn_bar_minutes', 10, 'warn_shisha_minutes', 10),
    'waiter_qr', jsonb_build_object('qr_enabled', true, 'qr_call_waiter', true, 'qr_request_bill', true, 'qr_show_prices', true),
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

create or replace function public.motionpos_version_public()
returns text
language sql
immutable
as $$
  select '019'
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

-- self-test (rolled back): defaults carry the section, merged settings show it, a saved value overrides it
do $selftest$
declare
  v_company uuid;
  v jsonb;
begin
  begin
    v := public.pos_settings_defaults() -> 'whatsapp';
    if v is null or jsonb_typeof(v->'thanks_enabled') <> 'boolean' or position('{الاسم}' in v->>'thanks_message') = 0 then
      raise exception 'SELFTEST defaults wrong: %', v;
    end if;
    insert into public.companies (name) values ('selftest019') returning id into v_company;
    if (public.pos_app_settings(v_company) -> 'whatsapp' ->> 'customer_message') is null then
      raise exception 'SELFTEST merged settings missing whatsapp';
    end if;
    insert into public.app_settings (company_id, section, data) values (v_company, 'whatsapp', jsonb_build_object('thanks_enabled', false));
    if (public.pos_app_settings(v_company) -> 'whatsapp' ->> 'thanks_enabled')::boolean is not false
       or (public.pos_app_settings(v_company) -> 'whatsapp' ->> 'thanks_message') is null then
      raise exception 'SELFTEST saved value not merged';
    end if;
    raise notice 'MOTIONPOS-019-SELFTEST-OK';
    raise exception using errcode = 'P0099', message = 'selftest_rollback';
  exception when sqlstate 'P0099' then
    null;
  end;
end;
$selftest$;

commit;
