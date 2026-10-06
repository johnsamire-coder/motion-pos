-- 008_server_order_item_submission.sql
-- Phase 2 / Step 2.1: submit the final unsent cart through one server transaction.
-- The browser sends product IDs, quantities and modifier IDs only; prices are read here.
-- Financial totals, discounts, inventory and payment remain separate later steps.

BEGIN;

DO $preflight$
DECLARE
  v_missing text;
BEGIN
  IF to_regprocedure('public.require_session(text)') IS NULL THEN
    RAISE EXCEPTION 'schema_preflight_failed: public.require_session(text) is missing';
  END IF;

  WITH expected(table_name, column_name) AS (
    VALUES
      ('branches','id'), ('branches','brand_id'),
      ('areas','id'), ('areas','branch_id'),
      ('tables','id'), ('tables','area_id'), ('tables','status'),
      ('customers','id'), ('customers','company_id'),
      ('staff','id'), ('staff','branch_id'), ('staff','company_id'), ('staff','is_active'),
      ('products','id'), ('products','name'), ('products','brand_id'), ('products','price'), ('products','is_available'),
      ('product_modifier_groups','product_id'), ('product_modifier_groups','group_id'),
      ('modifier_groups','id'), ('modifier_groups','min_selection'), ('modifier_groups','max_selection'), ('modifier_groups','is_required'),
      ('modifiers','id'), ('modifiers','group_id'), ('modifiers','name'), ('modifiers','price'),
      ('orders','id'), ('orders','company_id'), ('orders','brand_id'), ('orders','branch_id'),
      ('orders','area_id'), ('orders','table_id'), ('orders','waiter_id'), ('orders','customer_id'),
      ('orders','order_type'), ('orders','guest_count'), ('orders','status'), ('orders','kitchen_status'), ('orders','order_number'),
      ('order_items','id'), ('order_items','order_id'), ('order_items','product_id'), ('order_items','quantity'),
      ('order_items','unit_price'), ('order_items','total_price'), ('order_items','item_notes'),
      ('order_item_modifiers','order_item_id'), ('order_item_modifiers','modifier_id'),
      ('order_item_modifiers','modifier_name'), ('order_item_modifiers','unit_price'),
      ('order_logs','order_id'), ('order_logs','user_id'), ('order_logs','action'), ('order_logs','details')
  )
  SELECT string_agg(format('%s.%s', e.table_name, e.column_name), ', ' ORDER BY e.table_name, e.column_name)
    INTO v_missing
    FROM expected e
   WHERE NOT EXISTS (
     SELECT 1
       FROM information_schema.columns c
      WHERE c.table_schema = 'public'
        AND c.table_name = e.table_name
        AND c.column_name = e.column_name
   );

  IF v_missing IS NOT NULL THEN
    RAISE EXCEPTION 'schema_preflight_failed: missing columns: %', v_missing;
  END IF;
END;
$preflight$;

CREATE OR REPLACE FUNCTION public.submit_order_items_secure(
  p_token text,
  p_order_id uuid,
  p_order_type text,
  p_area_id uuid,
  p_table_id uuid,
  p_waiter_id uuid,
  p_customer_id uuid,
  p_guest_count integer,
  p_items jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $function$
DECLARE
  v_staff_id uuid;
  v_company_id uuid;
  v_branch_id uuid;
  v_brand_id uuid;
  v_is_new boolean;
  v_order public.orders%ROWTYPE;
  v_order_id uuid;
  v_order_number text;
  v_area_id uuid;
  v_table_area_id uuid;
  v_table_status text;
  v_item jsonb;
  v_line jsonb;
  v_lines jsonb := '[]'::jsonb;
  v_saved_items jsonb := '[]'::jsonb;
  v_ordinal bigint;
  v_product_id uuid;
  v_product public.products%ROWTYPE;
  v_quantity integer;
  v_quantity_text text;
  v_item_notes text;
  v_modifier_input jsonb;
  v_modifier_ids uuid[];
  v_modifier_count integer;
  v_distinct_modifier_count integer;
  v_valid_modifier_count integer;
  v_modifier_total numeric;
  v_modifier_records jsonb;
  v_unit_price numeric;
  v_line_total numeric;
  v_group record;
  v_group_selected integer;
  v_modifier record;
  v_order_item_id uuid;
BEGIN
  SELECT rs.staff_id, rs.company_id, rs.branch_id
    INTO v_staff_id, v_company_id, v_branch_id
    FROM public.require_session(p_token) AS rs;

  IF v_company_id IS NULL OR v_branch_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'session_scope_missing');
  END IF;

  SELECT b.brand_id
    INTO v_brand_id
    FROM public.branches b
   WHERE b.id = v_branch_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'branch_not_found');
  END IF;
  IF v_brand_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'branch_brand_not_configured');
  END IF;

  IF p_order_type IS NULL OR length(btrim(p_order_type)) = 0 OR length(p_order_type) > 50 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_order_type');
  END IF;
  IF p_guest_count IS NULL OR p_guest_count < 1 OR p_guest_count > 9999 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_guest_count');
  END IF;
  IF jsonb_typeof(p_items) IS DISTINCT FROM 'array' THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_items');
  END IF;
  IF jsonb_array_length(p_items) < 1 OR jsonb_array_length(p_items) > 500 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'invalid_item_count');
  END IF;

  IF p_waiter_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.staff s
     WHERE s.id = p_waiter_id
       AND s.branch_id = v_branch_id
       AND s.company_id = v_company_id
       AND s.is_active IS TRUE
  ) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'waiter_not_in_branch');
  END IF;
  IF p_customer_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.customers c
     WHERE c.id = p_customer_id
       AND c.company_id = v_company_id
  ) THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'customer_not_in_company');
  END IF;

  v_is_new := p_order_id IS NULL;
  IF NOT v_is_new THEN
    SELECT o.*
      INTO v_order
      FROM public.orders o
     WHERE o.id = p_order_id
     FOR UPDATE;
    IF NOT FOUND
       OR v_order.branch_id IS DISTINCT FROM v_branch_id
       OR v_order.company_id IS DISTINCT FROM v_company_id
       OR v_order.brand_id IS DISTINCT FROM v_brand_id THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'order_not_found');
    END IF;
    IF v_order.status IN ('paid', 'closed', 'cancelled') THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'order_not_open');
    END IF;
    v_order_id := v_order.id;
    v_order_number := v_order.order_number;
  ELSE
    v_area_id := p_area_id;
    IF p_area_id IS NOT NULL AND NOT EXISTS (
      SELECT 1 FROM public.areas a
       WHERE a.id = p_area_id
         AND a.branch_id = v_branch_id
    ) THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'area_not_in_branch');
    END IF;
    IF p_table_id IS NOT NULL THEN
      SELECT t.area_id, t.status
        INTO v_table_area_id, v_table_status
        FROM public.tables t
        JOIN public.areas a ON a.id = t.area_id
       WHERE t.id = p_table_id
         AND a.branch_id = v_branch_id
       FOR UPDATE OF t;
      IF NOT FOUND THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'table_not_in_branch');
      END IF;
      IF v_area_id IS NOT NULL AND v_area_id IS DISTINCT FROM v_table_area_id THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'table_area_mismatch');
      END IF;
      IF v_table_status NOT IN ('available', 'reserved') THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'table_not_available');
      END IF;
      v_area_id := v_table_area_id;
    END IF;
  END IF;

  FOR v_item, v_ordinal IN
    SELECT e.value, e.ordinality
      FROM jsonb_array_elements(p_items) WITH ORDINALITY AS e(value, ordinality)
  LOOP
    IF jsonb_typeof(v_item) IS DISTINCT FROM 'object' THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'invalid_item', 'position', v_ordinal);
    END IF;

    IF coalesce(v_item->>'product_id', '') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'invalid_product_id', 'position', v_ordinal);
    END IF;
    v_product_id := (v_item->>'product_id')::uuid;

    v_quantity_text := coalesce(v_item->>'quantity', '');
    IF v_quantity_text !~ '^[1-9][0-9]{0,5}$' THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'invalid_quantity', 'position', v_ordinal);
    END IF;
    v_quantity := v_quantity_text::integer;

    v_item_notes := nullif(btrim(v_item->>'item_notes'), '');
    IF length(coalesce(v_item_notes, '')) > 500 THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'item_notes_too_long', 'position', v_ordinal);
    END IF;

    IF v_item->'modifier_ids' IS NULL OR v_item->'modifier_ids' = 'null'::jsonb THEN
      v_modifier_input := '[]'::jsonb;
    ELSE
      v_modifier_input := v_item->'modifier_ids';
    END IF;
    IF jsonb_typeof(v_modifier_input) IS DISTINCT FROM 'array'
       OR jsonb_array_length(v_modifier_input) > 100 THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'invalid_modifier_ids', 'position', v_ordinal);
    END IF;
    IF EXISTS (
      SELECT 1
        FROM jsonb_array_elements_text(v_modifier_input) AS x(value)
       WHERE x.value !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    ) THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'invalid_modifier_ids', 'position', v_ordinal);
    END IF;
    SELECT coalesce(array_agg(x.value::uuid), ARRAY[]::uuid[]), count(*)::integer
      INTO v_modifier_ids, v_modifier_count
      FROM jsonb_array_elements_text(v_modifier_input) AS x(value);
    SELECT count(DISTINCT x)::integer
      INTO v_distinct_modifier_count
      FROM unnest(v_modifier_ids) AS x;
    IF v_modifier_count <> v_distinct_modifier_count THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'duplicate_modifier_id', 'position', v_ordinal);
    END IF;

    SELECT p.*
      INTO v_product
      FROM public.products p
     WHERE p.id = v_product_id
     FOR SHARE;
    IF NOT FOUND THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'product_not_found', 'position', v_ordinal);
    END IF;
    IF v_product.is_available IS DISTINCT FROM TRUE THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'product_not_available', 'position', v_ordinal);
    END IF;
    IF v_product.brand_id IS DISTINCT FROM v_brand_id THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'product_not_in_branch_brand', 'position', v_ordinal);
    END IF;
    IF v_product.price < 0 THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'invalid_product_price', 'position', v_ordinal);
    END IF;

    FOR v_group IN
      SELECT mg.id,
             greatest(coalesce(mg.min_selection, 0), CASE WHEN coalesce(mg.is_required, false) THEN 1 ELSE 0 END) AS min_required,
             coalesce(mg.max_selection, 2147483647) AS max_allowed
        FROM public.product_modifier_groups pmg
        JOIN public.modifier_groups mg ON mg.id = pmg.group_id
       WHERE pmg.product_id = v_product_id
       FOR SHARE OF pmg, mg
    LOOP
      SELECT count(*)::integer
        INTO v_group_selected
        FROM unnest(v_modifier_ids) AS selected(id)
        JOIN public.modifiers m ON m.id = selected.id
       WHERE m.group_id = v_group.id;
      IF v_group_selected < v_group.min_required THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'required_modifier_missing', 'position', v_ordinal, 'group_id', v_group.id);
      END IF;
      IF v_group_selected > v_group.max_allowed THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'too_many_modifiers', 'position', v_ordinal, 'group_id', v_group.id);
      END IF;
    END LOOP;

    v_modifier_total := 0;
    v_modifier_records := '[]'::jsonb;
    v_valid_modifier_count := 0;
    FOR v_modifier IN
      SELECT m.id, m.name, coalesce(m.price, 0) AS price
        FROM unnest(v_modifier_ids) AS selected(id)
        JOIN public.modifiers m ON m.id = selected.id
        JOIN public.product_modifier_groups pmg
          ON pmg.product_id = v_product_id
         AND pmg.group_id = m.group_id
       ORDER BY m.id
       FOR SHARE OF m, pmg
    LOOP
      v_valid_modifier_count := v_valid_modifier_count + 1;
      v_modifier_total := v_modifier_total + v_modifier.price;
      v_modifier_records := v_modifier_records || jsonb_build_array(
        jsonb_build_object('id', v_modifier.id, 'name', v_modifier.name, 'price', v_modifier.price)
      );
    END LOOP;
    IF v_valid_modifier_count <> v_modifier_count THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'modifier_not_for_product', 'position', v_ordinal);
    END IF;

    v_unit_price := round(v_product.price + v_modifier_total, 2);
    v_line_total := round(v_unit_price * v_quantity, 2);
    IF v_unit_price < 0 OR v_unit_price > 99999999.99 OR v_line_total > 99999999.99 THEN
      RETURN jsonb_build_object('ok', false, 'reason', 'item_total_out_of_range', 'position', v_ordinal);
    END IF;

    v_lines := v_lines || jsonb_build_array(jsonb_build_object(
      'position', v_ordinal,
      'product_id', v_product_id,
      'product_name', v_product.name,
      'quantity', v_quantity,
      'item_notes', v_item_notes,
      'unit_price', v_unit_price,
      'total_price', v_line_total,
      'modifiers', v_modifier_records
    ));
  END LOOP;

  IF v_is_new THEN
    INSERT INTO public.orders (
      company_id, brand_id, branch_id, area_id, table_id,
      waiter_id, customer_id, order_type, guest_count, status, kitchen_status
    ) VALUES (
      v_company_id, v_brand_id, v_branch_id, v_area_id, p_table_id,
      p_waiter_id, p_customer_id, btrim(p_order_type), p_guest_count, 'sent', 'pending'
    )
    RETURNING id, order_number INTO v_order_id, v_order_number;
  ELSE
    UPDATE public.orders
       SET waiter_id = p_waiter_id,
           customer_id = p_customer_id,
           order_type = btrim(p_order_type),
           guest_count = p_guest_count
     WHERE id = v_order_id;
  END IF;

  FOR v_line IN
    SELECT e.value FROM jsonb_array_elements(v_lines) AS e(value)
  LOOP
    INSERT INTO public.order_items (
      order_id, product_id, quantity, unit_price, total_price, item_notes
    ) VALUES (
      v_order_id,
      (v_line->>'product_id')::uuid,
      (v_line->>'quantity')::integer,
      (v_line->>'unit_price')::numeric,
      (v_line->>'total_price')::numeric,
      v_line->>'item_notes'
    )
    RETURNING id INTO v_order_item_id;

    INSERT INTO public.order_item_modifiers (
      order_item_id, modifier_id, modifier_name, unit_price
    )
    SELECT v_order_item_id,
           (m.value->>'id')::uuid,
           m.value->>'name',
           (m.value->>'price')::numeric
      FROM jsonb_array_elements(v_line->'modifiers') AS m(value);

    v_saved_items := v_saved_items || jsonb_build_array(jsonb_build_object(
      'position', (v_line->>'position')::integer,
      'order_item_id', v_order_item_id,
      'product_id', v_line->>'product_id',
      'product_name', v_line->>'product_name',
      'quantity', (v_line->>'quantity')::integer,
      'unit_price', (v_line->>'unit_price')::numeric,
      'total_price', (v_line->>'total_price')::numeric,
      'modifiers', v_line->'modifiers'
    ));
  END LOOP;

  IF v_is_new AND p_table_id IS NOT NULL THEN
    UPDATE public.tables SET status = 'occupied' WHERE id = p_table_id;
  END IF;

  INSERT INTO public.order_logs (order_id, user_id, action, details)
  VALUES (
    v_order_id,
    v_staff_id,
    CASE WHEN v_is_new THEN 'SEND_TO_KITCHEN' ELSE 'ADD_ITEMS_TO_ORDER' END,
    jsonb_build_object('item_count', jsonb_array_length(v_lines), 'prices_checked_on_server', true)
  );

  RETURN jsonb_build_object(
    'ok', true,
    'order_id', v_order_id,
    'order_number', v_order_number,
    'created', v_is_new,
    'items', v_saved_items
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.submit_order_items_secure(text, uuid, text, uuid, uuid, uuid, uuid, integer, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.submit_order_items_secure(text, uuid, text, uuid, uuid, uuid, uuid, integer, jsonb) TO anon, authenticated, service_role;
COMMENT ON FUNCTION public.submit_order_items_secure(text, uuid, text, uuid, uuid, uuid, uuid, integer, jsonb)
  IS 'Submits only final unsent cart rows. Product and modifier prices are loaded and validated server-side.';

COMMIT;
