-- 014_phase12_fixes.sql
-- Fixes found in the full test:
--   * login: the same PIN on two active people is refused (before, one of them got in as the other)
--   * settings that are for the owner only now say "owner only"
--   * new setting inventory.units: units added from the ingredient screen are remembered
-- Same rules: if anything fails (including the self-test) the WHOLE file is rolled back.

begin;

do $preflight$
begin
  if length('إكراميات') <> 8 then
    raise exception 'file_encoding_broken: read the file as UTF-8';
  end if;
  if to_regprocedure('public.sales_orders_secure(text,date,date,uuid,jsonb)') is null then
    raise exception 'schema_preflight_failed: run 013 first';
  end if;
end;
$preflight$;

create or replace function public.staff_login(p_pin text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_headers json;
  v_ip text;
  v_ip_failures int;
  v_all_failures int;
  v_staff public.staff%rowtype;
  v_role_name text;
  v_branch jsonb;
  v_tax jsonb;
  v_token text;
  v_expires timestamptz;
  v_matches int;
begin
  begin
    v_headers := nullif(current_setting('request.headers', true), '')::json;
  exception when others then
    v_headers := null;
  end;
  v_ip := coalesce(v_headers->>'cf-connecting-ip',
                   nullif(trim(split_part(coalesce(v_headers->>'x-forwarded-for', ''), ',', 1)), ''),
                   'unknown');

  delete from public.login_attempts where attempted_at < now() - interval '1 day';

  select count(*) into v_ip_failures from public.login_attempts
   where client_ip = v_ip and not success and attempted_at > now() - interval '10 minutes';
  select count(*) into v_all_failures from public.login_attempts
   where not success and attempted_at > now() - interval '10 minutes';

  if v_ip_failures >= 10 or v_all_failures >= 100 then
    return jsonb_build_object('ok', false, 'reason', 'locked');
  end if;

  if p_pin is null or p_pin !~ '^[0-9]{4}$' then
    insert into public.login_attempts (client_ip, success) values (v_ip, false);
    return jsonb_build_object('ok', false, 'reason', 'wrong_pin');
  end if;

  -- the same PIN on two active people: refuse instead of letting one of them in as the other
  select count(*) into v_matches
    from public.staff s
   where s.is_active = true and s.pin_hash is not null and s.pin_hash = extensions.crypt(p_pin, s.pin_hash);
  if v_matches > 1 then
    insert into public.login_attempts (client_ip, success) values (v_ip, false);
    return jsonb_build_object('ok', false, 'reason', 'pin_duplicate');
  end if;

  select s.* into v_staff
    from public.staff s
   where s.is_active = true
     and s.pin_hash is not null
     and s.pin_hash = extensions.crypt(p_pin, s.pin_hash)
   limit 1;

  if v_staff.id is null then
    insert into public.login_attempts (client_ip, success) values (v_ip, false);
    return jsonb_build_object('ok', false, 'reason', 'wrong_pin');
  end if;

  delete from public.login_attempts where client_ip = v_ip and not success;
  insert into public.login_attempts (client_ip, success) values (v_ip, true);

  select r.name into v_role_name from public.roles r where r.id = v_staff.role_id;
  select to_jsonb(b) into v_branch from public.branches b where b.id = v_staff.branch_id;
  select jsonb_build_object('vat_percentage', t.vat_percentage,
                            'service_charge_percentage', t.service_charge_percentage)
    into v_tax
    from public.branch_tax_settings t
   where t.branch_id = v_staff.branch_id
   limit 1;

  delete from public.staff_sessions where expires_at < now() - interval '7 days';
  v_token := encode(extensions.gen_random_bytes(32), 'hex');
  v_expires := now() + interval '12 hours';
  insert into public.staff_sessions (token_hash, staff_id, expires_at)
  values (encode(extensions.digest(v_token, 'sha256'), 'hex'), v_staff.id, v_expires);

  return jsonb_build_object(
    'ok', true,
    'session_token', v_token,
    'session_expires_at', v_expires,
    'staff', jsonb_build_object(
      'id', v_staff.id,
      'name', v_staff.name,
      'email', v_staff.email,
      'role_id', v_staff.role_id,
      'branch_id', v_staff.branch_id,
      'company_id', v_staff.company_id,
      'brand_id', v_branch->>'brand_id',
      'is_active', v_staff.is_active),
    'role', jsonb_build_object('name', coalesce(v_role_name, 'cashier')),
    'branch', v_branch,
    'tax', v_tax
  );
end;
$$;


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
    'offline', jsonb_build_object('mode', 'none', 'local_server_url', '')
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


-- tells the install script which database version is installed (no data, no login needed)
create or replace function public.motionpos_version_public()
returns text
language sql
immutable
as $$
  select '014'
$$;

do $grants$
begin
  revoke all on function public.motionpos_version_public() from public;
  grant execute on function public.motionpos_version_public() to anon, authenticated, service_role;
  revoke all on function public.pos_settings_defaults() from public, anon, authenticated;
  revoke all on function public.app_settings_save_secure(text, text, jsonb) from public, anon, authenticated;
  grant execute on function public.app_settings_save_secure(text, text, jsonb) to anon, authenticated, service_role;
  revoke all on function public.staff_login(text) from public;
  grant execute on function public.staff_login(text) to anon, authenticated, service_role;
end;
$grants$;

do $selftest$
declare
  v_a uuid;
  v_b uuid;
  v_manager uuid;
  v_tok text := 'mp-t14-m-' || md5(random()::text || clock_timestamp()::text);
  v_res jsonb;
begin
  begin
    select s.id into v_manager from public.staff s join public.roles r on r.id = s.role_id
     where s.is_active is true and r.name = 'branch_manager' limit 1;
    select s.id into v_a from public.staff s join public.roles r on r.id = s.role_id
     where s.is_active is true and r.name <> 'owner' order by s.id limit 1;
    select s.id into v_b from public.staff s join public.roles r on r.id = s.role_id
     where s.is_active is true and r.name <> 'owner' and s.id <> v_a order by s.id limit 1;
    if v_a is null or v_b is null or v_manager is null then
      raise notice 'selftest skipped';
      raise exception using errcode = 'P0099', message = 'selftest_skip';
    end if;
    delete from public.login_attempts;  -- (rolled back) so earlier wrong tries do not lock the test
    -- two people with the same PIN: refused
    update public.staff set pin_hash = extensions.crypt('7391', extensions.gen_salt('bf', 8)) where id in (v_a, v_b);
    v_res := public.staff_login('7391');
    if coalesce(v_res->>'reason', '') <> 'pin_duplicate' then
      raise exception 'SELFTEST duplicate PIN not refused: %', v_res;
    end if;
    -- one person: logs in as that person
    update public.staff set pin_hash = null where id = v_b;
    v_res := public.staff_login('7391');
    if not coalesce((v_res->>'ok')::boolean, false) then
      raise exception 'SELFTEST single PIN login failed: %', v_res;
    end if;
    -- manager on owner-only settings: "owner_only"
    insert into public.staff_sessions (token_hash, staff_id, expires_at)
    values (encode(extensions.digest(v_tok, 'sha256'), 'hex'), v_manager, now() + interval '10 minutes');
    v_res := public.app_settings_save_secure(v_tok, 'general', jsonb_build_object('company_name', 'x'));
    if coalesce(v_res->>'reason', '') <> 'owner_only' then
      raise exception 'SELFTEST owner-only message wrong: %', v_res;
    end if;
    v_res := public.app_settings_save_secure(v_tok, 'inventory', jsonb_build_object('units', jsonb_build_array('شوال')));
    if not coalesce((v_res->>'ok')::boolean, false) or v_res->'settings'->'inventory'->'units'->>0 <> 'شوال' then
      raise exception 'SELFTEST units not saved: %', v_res;
    end if;
    raise notice 'MOTIONPOS-014-SELFTEST-OK';
    raise exception using errcode = 'P0099', message = 'selftest_rollback';
  exception when sqlstate 'P0099' then
    null;
  end;
end;
$selftest$;

commit;
