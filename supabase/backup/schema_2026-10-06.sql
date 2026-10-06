--
-- PostgreSQL database dump
--

\restrict mWWYp5UHc82RLwUfavMKlWlcPzEVGLKV3JYSURRPjAgvqVEGTikJxgNCfEk6zke

-- Dumped from database version 17.11
-- Dumped by pg_dump version 17.11

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: public; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA public;


--
-- Name: SCHEMA public; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON SCHEMA public IS 'standard public schema';


--
-- Name: adjust_stock(uuid, uuid, numeric, text, uuid, text, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.adjust_stock(p_warehouse_id uuid, p_ingredient_id uuid, p_quantity numeric, p_adjustment_type text, p_reason_id uuid, p_notes text DEFAULT NULL::text, p_user_id uuid DEFAULT NULL::uuid) RETURNS uuid
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_unit_cost NUMERIC(15, 4);
    v_total_cost NUMERIC(15, 2);
    v_signed_qty NUMERIC(15, 4);
    v_company_id UUID;
    v_brand_id UUID;
    v_branch_id UUID;
    v_adj_id UUID;
BEGIN
    SELECT COALESCE(cost_per_unit, 0) INTO v_unit_cost FROM ingredients WHERE id = p_ingredient_id;
    v_total_cost := p_quantity * v_unit_cost;

    IF p_adjustment_type = 'decrease' THEN
        v_signed_qty := -1 * ABS(p_quantity);
    ELSE
        v_signed_qty := ABS(p_quantity);
    END IF;

    SELECT w.branch_id, b.brand_id, br.company_id
    INTO v_branch_id, v_brand_id, v_company_id
    FROM warehouses w
    LEFT JOIN branches b ON b.id = w.branch_id
    LEFT JOIN brands br ON br.id = b.brand_id
    WHERE w.id = p_warehouse_id;

    IF v_company_id IS NULL THEN v_company_id := 'c0000000-0000-0000-0000-000000000000'::UUID; END IF;
    IF v_brand_id IS NULL THEN v_brand_id := 'b0000000-0000-0000-0000-000000000000'::UUID; END IF;

    -- إدراج التسوية
    INSERT INTO stock_adjustments (
        warehouse_id, ingredient_id, adjustment_type, quantity, unit_cost, total_cost, reason_id, notes, created_by
    ) VALUES (
        p_warehouse_id, p_ingredient_id, p_adjustment_type, ABS(p_quantity), v_unit_cost, v_total_cost, p_reason_id, p_notes, p_user_id
    ) RETURNING id INTO v_adj_id;

    -- تسجيل الحركة بجدول stock_movements
    PERFORM record_stock_movement(
        v_company_id, v_brand_id, v_branch_id, p_warehouse_id,
        p_ingredient_id, 'adjustment', v_signed_qty, v_unit_cost,
        'adjustment', v_adj_id, COALESCE(p_notes, 'تسوية مخزنية يدوية'), p_user_id
    );

    RETURN v_adj_id;
END;
$$;


--
-- Name: close_fiscal_period(uuid, uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.close_fiscal_period(p_company_id uuid, p_period_id uuid, p_user_id uuid DEFAULT NULL::uuid) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
    UPDATE fiscal_periods
    SET status = 'closed',
        closed_by = p_user_id,
        closed_at = now()
    WHERE id = p_period_id 
      AND company_id = COALESCE(p_company_id, 'c0000000-0000-0000-0000-000000000000'::UUID);
END;
$$;


--
-- Name: convert_quantity(numeric, uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.convert_quantity(p_quantity numeric, p_from_unit_id uuid, p_to_unit_id uuid) RETURNS numeric
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_factor NUMERIC;
BEGIN
    -- لو نفس الوحدة
    IF p_from_unit_id = p_to_unit_id THEN
        RETURN p_quantity;
    END IF;

    -- جلب معامل التحويل
    SELECT conversion_factor INTO v_factor
    FROM unit_conversions
    WHERE from_unit_id = p_from_unit_id AND to_unit_id = p_to_unit_id
    LIMIT 1;

    IF v_factor IS NULL THEN
        RAISE EXCEPTION 'لا يوجد تحويل متاح بين هذه الوحدات';
    END IF;

    RETURN p_quantity * v_factor;
END;
$$;


--
-- Name: create_journal_entry(uuid, uuid, date, text, text, uuid, text, jsonb, boolean, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_journal_entry(p_company_id uuid, p_branch_id uuid, p_entry_date date, p_journal_type text, p_reference_type text, p_reference_id uuid, p_description text, p_lines jsonb, p_auto_post boolean DEFAULT true, p_user_id uuid DEFAULT NULL::uuid) RETURNS uuid
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_entry_id UUID;
    v_entry_number TEXT;
    v_total_debit NUMERIC(15, 4) := 0;
    v_total_credit NUMERIC(15, 4) := 0;
    v_line JSONB;
    v_acc_id UUID;
    v_debit NUMERIC(15, 4);
    v_credit NUMERIC(15, 4);
    v_line_desc TEXT;
BEGIN
    -- أ) حساب الإجماليات أولاً والتحقق من التوازن المحاسبي (Debit = Credit)
    FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines)
    LOOP
        v_debit := COALESCE((v_line->>'debit')::NUMERIC, 0);
        v_credit := COALESCE((v_line->>'credit')::NUMERIC, 0);
        v_total_debit := v_total_debit + v_debit;
        v_total_credit := v_total_credit + v_credit;
    END LOOP;

    -- ب) تطبيق قانون التوازن المحاسبي المزدوج على مستوى السيرفر والقاعدة
    IF ABS(v_total_debit - v_total_credit) > 0.001 THEN
        RAISE EXCEPTION 'القيد غير متوازن محاسبياً: إجمالي المدين (%) لا يساوي إجمالي الدائن (%)', v_total_debit, v_total_credit;
    END IF;

    IF v_total_debit = 0 THEN
        RAISE EXCEPTION 'لا يمكن إنشاء قيد يومية بمبلغ صفر';
    END IF;

    -- ج) توليد رقم القيد التسلسلي
    v_entry_number := generate_journal_entry_number(COALESCE(p_company_id, 'c0000000-0000-0000-0000-000000000000'::UUID));

    -- د) إدراج رأس القيد (Header)
    INSERT INTO journal_entries (
        company_id, branch_id, entry_number, entry_date,
        journal_type, reference_type, reference_id, description,
        status, created_by, posted_by, posted_at
    ) VALUES (
        COALESCE(p_company_id, 'c0000000-0000-0000-0000-000000000000'::UUID),
        p_branch_id, v_entry_number, COALESCE(p_entry_date, CURRENT_DATE),
        p_journal_type, p_reference_type, p_reference_id, p_description,
        CASE WHEN p_auto_post THEN 'posted' ELSE 'draft' END,
        p_user_id,
        CASE WHEN p_auto_post THEN p_user_id ELSE NULL END,
        CASE WHEN p_auto_post THEN now() ELSE NULL END
    ) RETURNING id INTO v_entry_id;

    -- هـ) إدراج أسطر القيد التفصيلية (Lines)
    FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines)
    LOOP
        v_acc_id := (v_line->>'account_id')::UUID;
        v_debit := COALESCE((v_line->>'debit')::NUMERIC, 0);
        v_credit := COALESCE((v_line->>'credit')::NUMERIC, 0);
        v_line_desc := COALESCE(v_line->>'description', p_description);

        IF v_debit > 0 OR v_credit > 0 THEN
            INSERT INTO journal_entry_lines (
                journal_entry_id, account_id, debit, credit, description, branch_id
            ) VALUES (
                v_entry_id, v_acc_id, v_debit, v_credit, v_line_desc, p_branch_id
            );
        END IF;
    END LOOP;

    RETURN v_entry_id;
END;
$$;


--
-- Name: deduct_recipe_on_sale(uuid, uuid, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.deduct_recipe_on_sale(p_warehouse_id uuid, p_product_id uuid, p_quantity_sold integer) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    recipe_record RECORD;
    v_unit_cost NUMERIC(15, 4);
    v_company_id UUID;
    v_brand_id UUID;
    v_branch_id UUID;
    v_deduct_qty NUMERIC(15, 4);
BEGIN
    -- جلب بيانات الهيكل الإداري للمخزن
    SELECT w.branch_id, b.brand_id, br.company_id
    INTO v_branch_id, v_brand_id, v_company_id
    FROM warehouses w
    LEFT JOIN branches b ON b.id = w.branch_id
    LEFT JOIN brands br ON br.id = b.brand_id
    WHERE w.id = p_warehouse_id;

    IF v_company_id IS NULL THEN v_company_id := 'c0000000-0000-0000-0000-000000000000'::UUID; END IF;
    IF v_brand_id IS NULL THEN v_brand_id := 'b0000000-0000-0000-0000-000000000000'::UUID; END IF;

    -- التكرار على كل مكونات ريسبي الصنف المبيوع
    FOR recipe_record IN 
        SELECT ingredient_id, quantity_required 
        FROM recipes 
        WHERE product_id = p_product_id
    LOOP
        -- جلب تكلفة الخامة الحالية
        SELECT COALESCE(cost_per_unit, 0) INTO v_unit_cost 
        FROM ingredients WHERE id = recipe_record.ingredient_id;

        v_deduct_qty := (recipe_record.quantity_required * p_quantity_sold);

        -- تسجيل الحركة في دفتر حركات المخزون (بكمية سالبة)
        PERFORM record_stock_movement(
            v_company_id, v_brand_id, v_branch_id, p_warehouse_id,
            recipe_record.ingredient_id,
            'sale',
            (-1 * v_deduct_qty), -- كمية صادرة سالبة
            v_unit_cost,
            'order',
            NULL,
            'استهلاك مبيعات كاشير أوتوماتيكي',
            NULL
        );
    END LOOP;
END;
$$;


--
-- Name: execute_stock_transfer(uuid, uuid, uuid, numeric); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.execute_stock_transfer(p_from_warehouse uuid, p_to_warehouse uuid, p_ingredient uuid, p_quantity numeric) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_unit_cost NUMERIC(15, 4);
    v_company_id UUID;
    v_brand_id UUID;
    v_from_branch UUID;
    v_to_branch UUID;
    v_transfer_id UUID;
BEGIN
    SELECT COALESCE(cost_per_unit, 0) INTO v_unit_cost FROM ingredients WHERE id = p_ingredient;

    SELECT branch_id INTO v_from_branch FROM warehouses WHERE id = p_from_warehouse;
    SELECT branch_id INTO v_to_branch FROM warehouses WHERE id = p_to_warehouse;

    v_company_id := 'c0000000-0000-0000-0000-000000000000'::UUID;
    v_brand_id := 'b0000000-0000-0000-0000-000000000000'::UUID;

    -- حفظ في جدول stock_transfers
    INSERT INTO stock_transfers (from_warehouse_id, to_warehouse_id, ingredient_id, quantity)
    VALUES (p_from_warehouse, p_to_warehouse, p_ingredient, p_quantity)
    RETURNING id INTO v_transfer_id;

    -- أ) حركة الصادر من المخزن الأول
    PERFORM record_stock_movement(
        v_company_id, v_brand_id, v_from_branch, p_from_warehouse,
        p_ingredient, 'transfer_out', (-1 * ABS(p_quantity)),
        v_unit_cost, 'stock_transfer', v_transfer_id, 'تحويل صادر', NULL
    );

    -- ب) حركة الوارد إلى المخزن الثاني
    PERFORM record_stock_movement(
        v_company_id, v_brand_id, v_to_branch, p_to_warehouse,
        p_ingredient, 'transfer_in', ABS(p_quantity),
        v_unit_cost, 'stock_transfer', v_transfer_id, 'تحويل وارد', NULL
    );
END;
$$;


--
-- Name: generate_journal_entry_number(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.generate_journal_entry_number(p_company_id uuid) RETURNS text
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_year TEXT;
    v_count INT;
    v_number TEXT;
BEGIN
    v_year := TO_CHAR(CURRENT_DATE, 'YYYY');
    SELECT COUNT(*) + 1 INTO v_count
    FROM journal_entries
    WHERE company_id = p_company_id AND TO_CHAR(created_at, 'YYYY') = v_year;

    v_number := 'JE-' || v_year || '-' || LPAD(v_count::TEXT, 6, '0');
    RETURN v_number;
END;
$$;


--
-- Name: generate_order_number(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.generate_order_number() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    next_val INT;
BEGIN
    -- التأكد من وجود سجل تسلسل للفرع
    INSERT INTO order_sequences (branch_id, last_number)
    VALUES (NEW.branch_id, 1000)
    ON CONFLICT (branch_id) DO UPDATE SET last_number = order_sequences.last_number + 1
    RETURNING last_number INTO next_val;

    -- تعيين رقم الأوردر بصيغة #1001
    NEW.order_number := '#' || next_val::TEXT;
    RETURN NEW;
END;
$$;


--
-- Name: get_account_for_payment_method(uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_account_for_payment_method(p_company_id uuid, p_payment_method text) RETURNS uuid
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_account_id UUID;
BEGIN
    SELECT account_id INTO v_account_id
    FROM payment_method_account_mappings
    WHERE company_id = COALESCE(p_company_id, 'c0000000-0000-0000-0000-000000000000'::UUID)
      AND payment_method = p_payment_method
    LIMIT 1;

    -- افتراضي: حساب النقدية إذا لم يجد ربط
    IF v_account_id IS NULL THEN
        SELECT id INTO v_account_id FROM accounts WHERE code = '1100' LIMIT 1;
    END IF;

    RETURN v_account_id;
END;
$$;


--
-- Name: get_balance_sheet(uuid, date, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_balance_sheet(p_company_id uuid, p_as_of_date date, p_branch_id uuid DEFAULT NULL::uuid) RETURNS TABLE(total_assets numeric, total_liabilities numeric, total_equity numeric, current_period_net_profit numeric, total_liabilities_and_equity numeric)
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_comp UUID := COALESCE(p_company_id, 'c0000000-0000-0000-0000-000000000000'::UUID);
    v_assets NUMERIC(15, 2) := 0;
    v_liab NUMERIC(15, 2) := 0;
    v_equity NUMERIC(15, 2) := 0;
    v_net_profit NUMERIC(15, 2) := 0;
    v_year_start DATE;
BEGIN
    v_year_start := DATE_TRUNC('year', p_as_of_date)::DATE;

    -- الأصول (مدين - دائن)
    SELECT COALESCE(SUM(jel.debit - jel.credit), 0) INTO v_assets
    FROM journal_entry_lines jel
    JOIN journal_entries je ON je.id = jel.journal_entry_id
    JOIN accounts acc ON acc.id = jel.account_id
    WHERE je.company_id = v_comp AND acc.account_type = 'asset' AND je.status = 'posted'
      AND je.entry_date <= p_as_of_date AND (p_branch_id IS NULL OR je.branch_id = p_branch_id);

    -- الخصوم (دائن - مدين)
    SELECT COALESCE(SUM(jel.credit - jel.debit), 0) INTO v_liab
    FROM journal_entry_lines jel
    JOIN journal_entries je ON je.id = jel.journal_entry_id
    JOIN accounts acc ON acc.id = jel.account_id
    WHERE je.company_id = v_comp AND acc.account_type = 'liability' AND je.status = 'posted'
      AND je.entry_date <= p_as_of_date AND (p_branch_id IS NULL OR je.branch_id = p_branch_id);

    -- حقوق الملكية (دائن - مدين)
    SELECT COALESCE(SUM(jel.credit - jel.debit), 0) INTO v_equity
    FROM journal_entry_lines jel
    JOIN journal_entries je ON je.id = jel.journal_entry_id
    JOIN accounts acc ON acc.id = jel.account_id
    WHERE je.company_id = v_comp AND acc.account_type = 'equity' AND je.status = 'posted'
      AND je.entry_date <= p_as_of_date AND (p_branch_id IS NULL OR je.branch_id = p_branch_id);

    -- صافي ربح الفترة الحالية المكمل للميزانية
    SELECT net_profit INTO v_net_profit
    FROM get_profit_and_loss_from_gl(v_comp, v_year_start, p_as_of_date, p_branch_id);

    total_assets := v_assets;
    total_liabilities := v_liab;
    total_equity := v_equity;
    current_period_net_profit := COALESCE(v_net_profit, 0);
    total_liabilities_and_equity := v_liab + v_equity + COALESCE(v_net_profit, 0);

    RETURN NEXT;
END;
$$;


--
-- Name: get_customer_statement(uuid, date, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_customer_statement(p_customer_id uuid, p_start_date date, p_end_date date) RETURNS TABLE(transaction_date timestamp with time zone, transaction_type text, reference_number text, notes text, debit numeric, credit numeric, running_balance numeric)
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN QUERY
    SELECT 
        cl.created_at AS transaction_date,
        cl.transaction_type,
        cl.reference_number,
        cl.notes,
        CASE WHEN cl.amount > 0 THEN cl.amount ELSE 0 END AS debit,
        CASE WHEN cl.amount < 0 THEN ABS(cl.amount) ELSE 0 END AS credit,
        cl.balance_after AS running_balance
    FROM customer_ledger cl
    WHERE cl.customer_id = p_customer_id
      AND cl.created_at::DATE BETWEEN p_start_date AND p_end_date
    ORDER BY cl.created_at ASC;
END;
$$;


--
-- Name: get_financial_summary(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_financial_summary() RETURNS TABLE(total_sales numeric, total_cogs numeric, total_waste_loss numeric, net_profit numeric)
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_sales NUMERIC := 0;
    v_cogs NUMERIC := 0;
    v_waste NUMERIC := 0;
    v_net NUMERIC := 0;
BEGIN
    -- 1. إجمالي المبيعات من الطلبات المكتملة
    SELECT COALESCE(SUM(total_amount), 0) INTO v_sales 
    FROM orders 
    WHERE status = 'completed';

    -- 2. إجمالي تكلفة البضاعة المبيوعة (COGS) بناءً على الريسبي والتكلفة
    SELECT COALESCE(SUM(oi.quantity * r.quantity_required * ing.cost_per_unit), 0) INTO v_cogs
    FROM order_items oi
    JOIN recipes r ON oi.product_id = r.product_id
    JOIN ingredients ing ON r.ingredient_id = ing.id;

    -- 3. إجمالي خسائر الهالك
    SELECT COALESCE(SUM(cost_loss), 0) INTO v_waste 
    FROM waste_logs;

    -- 4. الربح الصافي = المبيعات - (التكلفة المباشرة + الهالك)
    v_net := v_sales - (v_cogs + v_waste);

    RETURN QUERY SELECT v_sales, v_cogs, v_waste, v_net;
END;
$$;


--
-- Name: get_general_ledger(uuid, uuid, date, date, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_general_ledger(p_company_id uuid, p_account_id uuid, p_start_date date, p_end_date date, p_branch_id uuid DEFAULT NULL::uuid) RETURNS TABLE(entry_number text, entry_date date, journal_type text, description text, debit numeric, credit numeric, running_balance numeric)
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN QUERY
    WITH entries AS (
        SELECT 
            je.entry_number,
            je.entry_date,
            je.journal_type,
            jel.description,
            jel.debit,
            jel.credit,
            jel.created_at
        FROM journal_entry_lines jel
        JOIN journal_entries je ON je.id = jel.journal_entry_id
        WHERE je.company_id = COALESCE(p_company_id, 'c0000000-0000-0000-0000-000000000000'::UUID)
          AND jel.account_id = p_account_id
          AND je.status = 'posted'
          AND je.entry_date BETWEEN p_start_date AND p_end_date
          AND (p_branch_id IS NULL OR je.branch_id = p_branch_id)
        ORDER BY je.entry_date ASC, jel.created_at ASC
    )
    SELECT 
        e.entry_number,
        e.entry_date,
        e.journal_type,
        e.description,
        e.debit,
        e.credit,
        SUM(e.debit - e.credit) OVER (ORDER BY e.entry_date ASC, e.created_at ASC) AS running_balance
    FROM entries e;
END;
$$;


--
-- Name: get_low_stock_alerts(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_low_stock_alerts(p_warehouse_id uuid) RETURNS TABLE(ingredient_id uuid, ingredient_name text, unit_name text, current_stock numeric, min_stock_alert numeric, reorder_point numeric, alert_level text)
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN QUERY
    SELECT 
        ing.id AS ingredient_id,
        ing.name AS ingredient_name,
        ing.unit AS unit_name,
        COALESCE(ws.quantity, 0) AS current_stock,
        ing.min_stock_alert,
        ing.reorder_point,
        CASE 
            WHEN COALESCE(ws.quantity, 0) <= ing.min_stock_alert THEN 'critical'
            WHEN COALESCE(ws.quantity, 0) <= ing.reorder_point THEN 'warning'
            ELSE 'normal'
        END AS alert_level
    FROM ingredients ing
    LEFT JOIN warehouse_stock ws ON ws.ingredient_id = ing.id AND ws.warehouse_id = p_warehouse_id
    WHERE COALESCE(ws.quantity, 0) <= ing.reorder_point;
END;
$$;


--
-- Name: get_profit_and_loss_from_gl(uuid, date, date, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_profit_and_loss_from_gl(p_company_id uuid, p_start_date date, p_end_date date, p_branch_id uuid DEFAULT NULL::uuid) RETURNS TABLE(total_revenue numeric, total_cogs numeric, gross_profit numeric, total_expenses numeric, net_profit numeric)
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_comp UUID := COALESCE(p_company_id, 'c0000000-0000-0000-0000-000000000000'::UUID);
    v_rev NUMERIC(15, 2) := 0;
    v_cogs NUMERIC(15, 2) := 0;
    v_exp NUMERIC(15, 2) := 0;
BEGIN
    -- حساب إجمالي الإيرادات (دائن - مدين) للحسابات ذات النمط revenue
    SELECT COALESCE(SUM(jel.credit - jel.debit), 0) INTO v_rev
    FROM journal_entry_lines jel
    JOIN journal_entries je ON je.id = jel.journal_entry_id
    JOIN accounts acc ON acc.id = jel.account_id
    WHERE je.company_id = v_comp AND acc.account_type = 'revenue' AND je.status = 'posted'
      AND je.entry_date BETWEEN p_start_date AND p_end_date
      AND (p_branch_id IS NULL OR je.branch_id = p_branch_id);

    -- حساب تكلفة المبيعات (مدين - دائن) للحسابات ذات النمط cogs
    SELECT COALESCE(SUM(jel.debit - jel.credit), 0) INTO v_cogs
    FROM journal_entry_lines jel
    JOIN journal_entries je ON je.id = jel.journal_entry_id
    JOIN accounts acc ON acc.id = jel.account_id
    WHERE je.company_id = v_comp AND acc.account_type = 'cogs' AND je.status = 'posted'
      AND je.entry_date BETWEEN p_start_date AND p_end_date
      AND (p_branch_id IS NULL OR je.branch_id = p_branch_id);

    -- حساب المصروفات التشغيلية (مدين - دائن) للحسابات ذات النمط expense
    SELECT COALESCE(SUM(jel.debit - jel.credit), 0) INTO v_exp
    FROM journal_entry_lines jel
    JOIN journal_entries je ON je.id = jel.journal_entry_id
    JOIN accounts acc ON acc.id = jel.account_id
    WHERE je.company_id = v_comp AND acc.account_type = 'expense' AND je.status = 'posted'
      AND je.entry_date BETWEEN p_start_date AND p_end_date
      AND (p_branch_id IS NULL OR je.branch_id = p_branch_id);

    total_revenue := v_rev;
    total_cogs := v_cogs;
    gross_profit := v_rev - v_cogs;
    total_expenses := v_exp;
    net_profit := (v_rev - v_cogs) - v_exp;

    RETURN NEXT;
END;
$$;


--
-- Name: get_theoretical_vs_actual_consumption(uuid, timestamp with time zone, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_theoretical_vs_actual_consumption(p_warehouse_id uuid, p_start_date timestamp with time zone, p_end_date timestamp with time zone) RETURNS TABLE(ingredient_id uuid, ingredient_name text, unit_name text, cost_per_unit numeric, theoretical_qty numeric, actual_qty numeric, variance_qty numeric, variance_cost numeric)
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN QUERY
    WITH theo AS (
        -- الاستهلاك النظري المفروض بناءً على المبيعات المغلقة فقط والريسبي
        SELECT 
            r.ingredient_id,
            SUM(oi.quantity * r.quantity_required) AS total_theo_qty
        FROM orders o
        JOIN order_items oi ON oi.order_id = o.id
        JOIN recipes r ON r.product_id = oi.product_id
        WHERE o.status = 'closed'
          AND oi.status = 'active'
          AND o.created_at BETWEEN p_start_date AND p_end_date
        GROUP BY r.ingredient_id
    ),
    act AS (
        -- الاستهلاك الفعلي المسجل في الدفتر (مبيعات + هالك)
        SELECT 
            sm.ingredient_id,
            SUM(ABS(sm.quantity)) AS total_act_qty
        FROM stock_movements sm
        WHERE sm.warehouse_id = p_warehouse_id
          AND sm.movement_type IN ('sale', 'waste')
          AND sm.created_at BETWEEN p_start_date AND p_end_date
        GROUP BY sm.ingredient_id
    )
    SELECT 
        ing.id AS ingredient_id,
        ing.name AS ingredient_name,
        ing.unit AS unit_name,
        ing.cost_per_unit,
        COALESCE(t.total_theo_qty, 0) AS theoretical_qty,
        COALESCE(a.total_act_qty, 0) AS actual_qty,
        (COALESCE(a.total_act_qty, 0) - COALESCE(t.total_theo_qty, 0)) AS variance_qty,
        ((COALESCE(a.total_act_qty, 0) - COALESCE(t.total_theo_qty, 0)) * ing.cost_per_unit) AS variance_cost
    FROM ingredients ing
    LEFT JOIN theo t ON t.ingredient_id = ing.id
    LEFT JOIN act a ON a.ingredient_id = ing.id
    WHERE COALESCE(t.total_theo_qty, 0) > 0 OR COALESCE(a.total_act_qty, 0) > 0;
END;
$$;


--
-- Name: get_trial_balance(uuid, date, date, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_trial_balance(p_company_id uuid, p_start_date date, p_end_date date, p_branch_id uuid DEFAULT NULL::uuid) RETURNS TABLE(account_id uuid, account_code text, account_name_ar text, account_type text, period_debit numeric, period_credit numeric, ending_debit numeric, ending_credit numeric)
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN QUERY
    WITH acc_balances AS (
        SELECT 
            acc.id AS acc_id,
            acc.code AS acc_code,
            acc.name_ar AS acc_name,
            acc.account_type AS acc_type,
            acc.normal_balance AS acc_norm,
            COALESCE(SUM(jel.debit), 0) AS total_debit,
            COALESCE(SUM(jel.credit), 0) AS total_credit
        FROM accounts acc
        LEFT JOIN journal_entry_lines jel ON jel.account_id = acc.id
        LEFT JOIN journal_entries je ON je.id = jel.journal_entry_id 
            AND je.status = 'posted' 
            AND je.entry_date BETWEEN p_start_date AND p_end_date
            AND (p_branch_id IS NULL OR je.branch_id = p_branch_id)
        WHERE acc.company_id = COALESCE(p_company_id, 'c0000000-0000-0000-0000-000000000000'::UUID)
        GROUP BY acc.id, acc.code, acc.name_ar, acc.account_type, acc.normal_balance
    )
    SELECT 
        b.acc_id,
        b.acc_code,
        b.acc_name,
        b.acc_type,
        b.total_debit AS period_debit,
        b.total_credit AS period_credit,
        CASE WHEN (b.total_debit - b.total_credit) > 0 THEN (b.total_debit - b.total_credit) ELSE 0 END AS ending_debit,
        CASE WHEN (b.total_credit - b.total_debit) > 0 THEN (b.total_credit - b.total_debit) ELSE 0 END AS ending_credit
    FROM acc_balances b
    WHERE b.total_debit > 0 OR b.total_credit > 0
    ORDER BY b.acc_code ASC;
END;
$$;


--
-- Name: log_waste(uuid, uuid, numeric, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.log_waste(p_warehouse_id uuid, p_ingredient_id uuid, p_quantity numeric, p_reason text) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_unit_cost NUMERIC(15, 4);
    v_total_loss NUMERIC(15, 2);
    v_company_id UUID;
    v_brand_id UUID;
    v_branch_id UUID;
    v_waste_id UUID;
    v_waste_acc_id UUID;
    v_inv_acc_id UUID;
    v_gl_lines JSONB;
BEGIN
    SELECT COALESCE(cost_per_unit, 0) INTO v_unit_cost FROM ingredients WHERE id = p_ingredient_id;
    v_total_loss := p_quantity * v_unit_cost;

    SELECT w.branch_id, b.brand_id, br.company_id INTO v_branch_id, v_brand_id, v_company_id
    FROM warehouses w LEFT JOIN branches b ON b.id = w.branch_id LEFT JOIN brands br ON br.id = b.brand_id WHERE w.id = p_warehouse_id;

    v_company_id := COALESCE(v_company_id, 'c0000000-0000-0000-0000-000000000000'::UUID);

    INSERT INTO waste_logs (warehouse_id, ingredient_id, quantity, reason, cost_loss)
    VALUES (p_warehouse_id, p_ingredient_id, p_quantity, p_reason, v_total_loss)
    RETURNING id INTO v_waste_id;

    PERFORM record_stock_movement(v_company_id, v_brand_id, v_branch_id, p_warehouse_id, p_ingredient_id, 'waste', (-1 * ABS(p_quantity)), v_unit_cost, 'waste_log', v_waste_id, 'هالك: ' || p_reason, NULL);

    -- قيد GL: Dr Waste Cost (5100) / Cr Inventory (1200)
    SELECT id INTO v_waste_acc_id FROM accounts WHERE code = '5100' LIMIT 1;
    SELECT id INTO v_inv_acc_id FROM accounts WHERE code = '1200' LIMIT 1;

    IF v_total_loss > 0 AND v_waste_acc_id IS NOT NULL AND v_inv_acc_id IS NOT NULL THEN
        v_gl_lines := jsonb_build_array(
            jsonb_build_object('account_id', v_waste_acc_id, 'debit', v_total_loss, 'credit', 0, 'description', 'تكلفة هالك: ' || p_reason),
            jsonb_build_object('account_id', v_inv_acc_id, 'debit', 0, 'credit', v_total_loss, 'description', 'خصم قيمة الهالك من المخزون')
        );

        PERFORM create_journal_entry(v_company_id, v_branch_id, CURRENT_DATE, 'inventory', 'waste_log', v_waste_id, 'إثبات هالك مخزني', v_gl_lines, true, NULL);
    END IF;
END;
$$;


--
-- Name: merge_orders(uuid, uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.merge_orders(p_source_order_id uuid, p_target_order_id uuid, p_user_id uuid) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_source_num TEXT;
    v_target_num TEXT;
    v_source_table UUID;
BEGIN
    SELECT order_number, table_id INTO v_source_num, v_source_table FROM orders WHERE id = p_source_order_id;
    SELECT order_number INTO v_target_num FROM orders WHERE id = p_target_order_id;

    -- نقل جميع أصناف الطلب المصدر إلى الطلب الهدف
    UPDATE order_items SET order_id = p_target_order_id WHERE order_id = p_source_order_id;

    -- إلغاء/إغلاق الطلب المصدر
    UPDATE orders SET status = 'cancelled', notes = 'دمج مع أوردر ' || v_target_num WHERE id = p_source_order_id;

    -- تفريغ طاولة الطلب المصدر
    IF v_source_table IS NOT NULL THEN
        IF NOT EXISTS (SELECT 1 FROM orders WHERE table_id = v_source_table AND status NOT IN ('closed', 'cancelled')) THEN
            UPDATE tables SET status = 'available' WHERE id = v_source_table;
        END IF;
    END IF;

    -- تدوين عملية الدمج في الـ Audit Log
    INSERT INTO order_logs (order_id, user_id, action, details)
    VALUES (p_target_order_id, p_user_id, 'MERGE_ORDERS', jsonb_build_object(
        'source_order', v_source_num,
        'target_order', v_target_num
    ));
END;
$$;


--
-- Name: pay_supplier(uuid, numeric, text, uuid, text, text, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.pay_supplier(p_supplier_id uuid, p_amount numeric, p_payment_method text, p_purchase_order_id uuid DEFAULT NULL::uuid, p_reference_number text DEFAULT NULL::text, p_notes text DEFAULT NULL::text, p_user_id uuid DEFAULT NULL::uuid) RETURNS uuid
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_payment_id UUID;
    v_ap_acc_id UUID;
    v_cash_acc_id UUID;
    v_gl_lines JSONB;
BEGIN
    IF p_amount <= 0 THEN RAISE EXCEPTION 'مبلغ السداد يجب أن يكون أكبر من الصفر'; END IF;

    INSERT INTO supplier_payments (supplier_id, purchase_order_id, amount, payment_method, reference_number, paid_by, notes)
    VALUES (p_supplier_id, p_purchase_order_id, p_amount, p_payment_method, p_reference_number, p_user_id, p_notes)
    RETURNING id INTO v_payment_id;

    UPDATE suppliers SET current_balance = COALESCE(current_balance, 0) - p_amount WHERE id = p_supplier_id;

    -- قيد GL: Dr AP / Cr Cash or Bank
    SELECT id INTO v_ap_acc_id FROM accounts WHERE code = '2100' LIMIT 1;
    v_cash_acc_id := get_account_for_payment_method('c0000000-0000-0000-0000-000000000000'::UUID, p_payment_method);

    v_gl_lines := jsonb_build_array(
        jsonb_build_object('account_id', v_ap_acc_id, 'debit', p_amount, 'credit', 0, 'description', 'سداد مديونية مورد'),
        jsonb_build_object('account_id', v_cash_acc_id, 'debit', 0, 'credit', p_amount, 'description', 'صرف من الخزينة/البنك للمورد')
    );

    PERFORM create_journal_entry('c0000000-0000-0000-0000-000000000000'::UUID, NULL, CURRENT_DATE, 'payment', 'supplier_payment', v_payment_id, COALESCE(p_notes, 'سداد دفعة مورد'), v_gl_lines, true, p_user_id);

    RETURN v_payment_id;
END;
$$;


--
-- Name: post_order_to_gl(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.post_order_to_gl(p_order_id uuid) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_order RECORD;
    v_item RECORD;
    v_pm RECORD;
    v_company_id UUID := 'c0000000-0000-0000-0000-000000000000'::UUID;
    v_food_rev_acc UUID;
    v_service_rev_acc UUID;
    v_vat_acc UUID;
    v_cogs_acc UUID;
    v_inv_acc UUID;
    v_pay_acc UUID;
    v_total_cogs NUMERIC(15, 4) := 0;
    v_item_cogs NUMERIC(15, 4) := 0;
    v_gl_lines JSONB := '[]'::JSONB;
    v_net_sales NUMERIC(15, 2);
    v_is_already_posted BOOLEAN;
BEGIN
    SELECT * INTO v_order FROM orders WHERE id = p_order_id;
    IF v_order IS NULL THEN RETURN; END IF;

    -- منع الترحيل المزدوج
    IF COALESCE(v_order.is_posted_to_gl, false) = true THEN RETURN; END IF;

    -- جلب الحسابات
    SELECT id INTO v_food_rev_acc FROM accounts WHERE code = '4000' LIMIT 1;
    SELECT id INTO v_service_rev_acc FROM accounts WHERE code = '4100' LIMIT 1;
    SELECT id INTO v_vat_acc FROM accounts WHERE code = '2200' LIMIT 1;
    SELECT id INTO v_cogs_acc FROM accounts WHERE code = '5000' LIMIT 1;
    SELECT id INTO v_inv_acc FROM accounts WHERE code = '1200' LIMIT 1;

    -- أ) إضافة أسطر التحصيل (Debit) حسب طريقة الدفع
    FOR v_pm IN SELECT payment_method, SUM(amount) as total_pm FROM payments WHERE order_id = p_order_id GROUP BY payment_method
    LOOP
        v_pay_acc := get_account_for_payment_method(v_company_id, v_pm.payment_method);
        v_gl_lines := v_gl_lines || jsonb_build_object('account_id', v_pay_acc, 'debit', v_pm.total_pm, 'credit', 0, 'description', 'تحصيل مبيعات ' || v_pm.payment_method);
    END LOOP;

    -- إذا لم تسجل مدفوعات بجدول payments، اعتبار المبلغ كاش
    IF jsonb_array_length(v_gl_lines) = 0 THEN
        v_pay_acc := get_account_for_payment_method(v_company_id, 'cash');
        v_gl_lines := v_gl_lines || jsonb_build_object('account_id', v_pay_acc, 'debit', v_order.total_amount, 'credit', 0, 'description', 'تحصيل مبيعات كاش');
    END IF;

    -- ب) إضافة أسطر الإيراد والضريبة والخدمة (Credit)
    v_net_sales := COALESCE(v_order.subtotal, v_order.total_amount) - COALESCE(v_order.discount_amount, 0);

    IF v_net_sales > 0 THEN
        v_gl_lines := v_gl_lines || jsonb_build_object('account_id', v_food_rev_acc, 'debit', 0, 'credit', v_net_sales, 'description', 'إيراد مبيعات فاتورة #' || v_order.order_number);
    END IF;

    IF COALESCE(v_order.service_amount, 0) > 0 THEN
        v_gl_lines := v_gl_lines || jsonb_build_object('account_id', v_service_rev_acc, 'debit', 0, 'credit', v_order.service_amount, 'description', 'إيراد خدمة صالة');
    END IF;

    IF COALESCE(v_order.tax_amount, 0) > 0 THEN
        v_gl_lines := v_gl_lines || jsonb_build_object('account_id', v_vat_acc, 'debit', 0, 'credit', v_order.tax_amount, 'description', 'ضريبة قيمة مضافة مستحقة');
    END IF;

    -- ترحيل قيد المبيعات والتحصيل
    PERFORM create_journal_entry(v_company_id, v_order.branch_id, v_order.created_at::DATE, 'sales', 'order', p_order_id, 'قيد مبيعات أوردر #' || v_order.order_number, v_gl_lines, true, NULL);

    -- ج) حساب التكلفة المباشرة (COGS) وقيد الخصم من المخزون
    FOR v_item IN 
        SELECT oi.quantity, r.ingredient_id, r.quantity_required, COALESCE(ing.cost_per_unit, 0) as ing_cost
        FROM order_items oi
        JOIN recipes r ON r.product_id = oi.product_id
        JOIN ingredients ing ON ing.id = r.ingredient_id
        WHERE oi.order_id = p_order_id AND oi.status = 'active'
    LOOP
        v_item_cogs := (v_item.quantity * v_item.quantity_required * v_item.ing_cost);
        v_total_cogs := v_total_cogs + v_item_cogs;
    END LOOP;

    IF v_total_cogs > 0 THEN
        v_gl_lines := jsonb_build_array(
            jsonb_build_object('account_id', v_cogs_acc, 'debit', v_total_cogs, 'credit', 0, 'description', 'تكلفة البضاعة المباعة أوردر #' || v_order.order_number),
            jsonb_build_object('account_id', v_inv_acc, 'debit', 0, 'credit', v_total_cogs, 'description', 'خصم تكلفة المنتجات المباعة من المخزون')
        );

        PERFORM create_journal_entry(v_company_id, v_order.branch_id, v_order.created_at::DATE, 'inventory', 'order', p_order_id, 'قيد كوست المبيعات أوردر #' || v_order.order_number, v_gl_lines, true, NULL);
    END IF;

    -- علم الطلب كمُرحّل
    UPDATE orders SET is_posted_to_gl = true WHERE id = p_order_id;
END;
$$;


--
-- Name: prevent_posted_journal_deletion(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.prevent_posted_journal_deletion() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF OLD.status = 'posted' THEN
        RAISE EXCEPTION 'عملية غير مسموحة: لا يمكن حذف القيد المحاسبي المعتمد برقم (%). يرجى استخدام دالة عكس القيد (Reverse Entry) بدلاً من الحذف', OLD.entry_number;
    END IF;
    RETURN OLD;
END;
$$;


--
-- Name: process_purchase_item(uuid, uuid, numeric, numeric); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.process_purchase_item(p_warehouse_id uuid, p_ingredient_id uuid, p_quantity numeric, p_unit_price numeric) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_current_total_stock NUMERIC(15, 4) := 0;
    v_old_cost NUMERIC(15, 4) := 0;
    v_new_avg_cost NUMERIC(15, 4) := 0;
    v_company_id UUID;
    v_brand_id UUID;
    v_branch_id UUID;
BEGIN
    -- أ) جلب التكلفة القديمة للخامة
    SELECT COALESCE(cost_per_unit, 0), brand_id INTO v_old_cost, v_brand_id
    FROM ingredients WHERE id = p_ingredient_id;

    -- ب) جلب إجمالي الرصيد الحالي للخامة عبر كل المخازن
    SELECT COALESCE(SUM(quantity), 0) INTO v_current_total_stock
    FROM warehouse_stock WHERE ingredient_id = p_ingredient_id;

    -- ج) جلب بيانات الشركة والفرع للربط الهيكلي
    SELECT w.branch_id, b.brand_id, br.company_id
    INTO v_branch_id, v_brand_id, v_company_id
    FROM warehouses w
    LEFT JOIN branches b ON b.id = w.branch_id
    LEFT JOIN brands br ON br.id = b.brand_id
    WHERE w.id = p_warehouse_id;

    -- تعيين قيم افتراضية في حالة الـ NULL لعدم توقف التنفيذ
    IF v_company_id IS NULL THEN v_company_id := 'c0000000-0000-0000-0000-000000000000'::UUID; END IF;
    IF v_brand_id IS NULL THEN v_brand_id := 'b0000000-0000-0000-0000-000000000000'::UUID; END IF;

    -- د) حساب متوسط التكلفة المرجح (Weighted Average Cost)
    IF (v_current_total_stock + p_quantity) <= 0 THEN
        v_new_avg_cost := p_unit_price;
    ELSE
        v_new_avg_cost := ((GREATEST(0, v_current_total_stock) * v_old_cost) + (p_quantity * p_unit_price)) / (GREATEST(0, v_current_total_stock) + p_quantity);
    END IF;

    -- هـ) تحديث سعر التكلفة للوحدة في جدول الخامات بالمتوسط الجديد
    UPDATE ingredients
    SET cost_per_unit = v_new_avg_cost
    WHERE id = p_ingredient_id;

    -- و) تسجيل التغيير في سجل تاريخ التكاليف
    IF v_old_cost <> v_new_avg_cost THEN
        INSERT INTO ingredient_cost_history (ingredient_id, old_cost, new_cost, change_reason)
        VALUES (p_ingredient_id, v_old_cost, v_new_avg_cost, 'purchase');
    END IF;

    -- ز) تسجيل حركة الدخول في دفتر حركات المخزون (Stock Movements Ledger)
    PERFORM record_stock_movement(
        v_company_id,
        v_brand_id,
        v_branch_id,
        p_warehouse_id,
        p_ingredient_id,
        'purchase',
        p_quantity,       -- موجب للدخول
        p_unit_price,     -- سعر الشراء الفعلي
        'purchase_order',
        NULL,
        'استلام فاتورة مشتريات بمتوسط تكلفة جديد: ' || ROUND(v_new_avg_cost, 4)::TEXT,
        NULL
    );
END;
$$;


--
-- Name: receive_customer_payment(uuid, uuid, uuid, numeric, text, text, text, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.receive_customer_payment(p_company_id uuid, p_branch_id uuid, p_customer_id uuid, p_amount numeric, p_payment_method text, p_reference_number text DEFAULT NULL::text, p_notes text DEFAULT NULL::text, p_user_id uuid DEFAULT NULL::uuid) RETURNS uuid
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_current_bal NUMERIC(15, 2) := 0;
    v_new_bal NUMERIC(15, 2) := 0;
    v_ledger_id UUID;
    v_cash_acc_id UUID;
    v_ar_acc_id UUID;
    v_lines JSONB;
BEGIN
    IF p_amount <= 0 THEN
        RAISE EXCEPTION 'مبلغ التحصيل يجب أن يكون أكبر من الصفر';
    END IF;

    -- أ) جلب الرصيد الحالي للعميل
    SELECT COALESCE(current_balance, 0) INTO v_current_bal
    FROM customers WHERE id = p_customer_id;

    v_new_bal := v_current_bal - p_amount; -- تخفيض المديونية

    -- ب) إدراج الحركة في دفتر حركات العميل (Subledger)
    INSERT INTO customer_ledger (
        company_id, customer_id, transaction_type, amount, payment_method, reference_number, balance_after, notes, created_by
    ) VALUES (
        COALESCE(p_company_id, 'c0000000-0000-0000-0000-000000000000'::UUID),
        p_customer_id, 'payment_received', (-1 * p_amount), p_payment_method, p_reference_number, v_new_bal, p_notes, p_user_id
    ) RETURNING id INTO v_ledger_id;

    -- ج) تحديث رصيد العميل بجدول customers
    UPDATE customers SET current_balance = v_new_bal WHERE id = p_customer_id;

    -- د) إنشاء قيد اليومية المزدوج أوتوماتيكياً بـ General Ledger
    -- جلب حساب النقدية/البنك المقابل لوسيلة التحصيل
    v_cash_acc_id := get_account_for_payment_method(p_company_id, p_payment_method);
    
    -- حساب ذمم العملاء (1120)
    SELECT id INTO v_ar_acc_id FROM accounts WHERE code = '1120' LIMIT 1;

    v_lines := jsonb_build_array(
        -- من حـ/ النقدية أو البنك (مدين)
        jsonb_build_object('account_id', v_cash_acc_id, 'debit', p_amount, 'credit', 0, 'description', 'تحصيل دفعة من عميل'),
        -- إلى حـ/ ذمم العملاء AR (دائن)
        jsonb_build_object('account_id', v_ar_acc_id, 'debit', 0, 'credit', p_amount, 'description', 'تخفيض مديونية العميل')
    );

    PERFORM create_journal_entry(
        p_company_id,
        p_branch_id,
        CURRENT_DATE,
        'receipt',
        'payment',
        v_ledger_id,
        COALESCE(p_notes, 'تحصيل دفعة مديونية عميل'),
        v_lines,
        true,
        p_user_id
    );

    RETURN v_ledger_id;
END;
$$;


--
-- Name: receive_goods_receipt(uuid, uuid, text, jsonb, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.receive_goods_receipt(p_purchase_order_id uuid, p_warehouse_id uuid, p_grn_number text, p_items jsonb, p_received_by uuid DEFAULT NULL::uuid) RETURNS uuid
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_grn_id UUID;
    v_item JSONB;
    v_ing_id UUID;
    v_rec_qty NUMERIC(15, 4);
    v_unit_cost NUMERIC(15, 4);
    v_total_cost NUMERIC(15, 2);
    v_po_total NUMERIC(15, 2) := 0;
    v_supplier_id UUID;
    v_company_id UUID;
    v_branch_id UUID;
    v_inv_acc_id UUID;
    v_ap_acc_id UUID;
    v_gl_lines JSONB;
BEGIN
    -- أ) جلب بيانات المؤسسة والفرع
    SELECT w.branch_id, b.brand_id, br.company_id
    INTO v_branch_id, v_company_id, v_company_id
    FROM warehouses w
    LEFT JOIN branches b ON b.id = w.branch_id
    LEFT JOIN brands br ON br.id = b.brand_id
    WHERE w.id = p_warehouse_id;

    v_company_id := COALESCE(v_company_id, 'c0000000-0000-0000-0000-000000000000'::UUID);

    -- ب) إنشاء سند الاستلام
    INSERT INTO goods_receipts (purchase_order_id, warehouse_id, grn_number, received_by)
    VALUES (p_purchase_order_id, p_warehouse_id, p_grn_number, p_received_by)
    RETURNING id INTO v_grn_id;

    -- ج) التكرار وتغذية المخزون ومتوسط التكلفة
    FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
    LOOP
        v_ing_id := (v_item->>'ingredient_id')::UUID;
        v_rec_qty := (v_item->>'received_qty')::NUMERIC;
        v_unit_cost := (v_item->>'unit_cost')::NUMERIC;
        v_total_cost := v_rec_qty * v_unit_cost;

        INSERT INTO goods_receipt_items (goods_receipt_id, ingredient_id, ordered_qty, received_qty, unit_cost, total_cost)
        VALUES (v_grn_id, v_ing_id, v_rec_qty, v_rec_qty, v_unit_cost, v_total_cost);

        PERFORM process_purchase_item(p_warehouse_id, v_ing_id, v_rec_qty, v_unit_cost);
        v_po_total := v_po_total + v_total_cost;
    END LOOP;

    -- د) تحديث أمر الشراء ومديونية المورد
    IF p_purchase_order_id IS NOT NULL THEN
        UPDATE purchase_orders
        SET status = 'fully_received',
            total_amount = COALESCE(total_amount, 0) + v_po_total
        WHERE id = p_purchase_order_id
        RETURNING supplier_id INTO v_supplier_id;

        IF v_supplier_id IS NOT NULL THEN
            UPDATE suppliers SET current_balance = COALESCE(current_balance, 0) + v_po_total WHERE id = v_supplier_id;
        END IF;
    END IF;

    -- هـ) توليد قيد اليومية المزدوج أوتوماتيكياً (Dr Inventory / Cr AP)
    SELECT id INTO v_inv_acc_id FROM accounts WHERE code = '1200' LIMIT 1;
    SELECT id INTO v_ap_acc_id FROM accounts WHERE code = '2100' LIMIT 1;

    IF v_po_total > 0 AND v_inv_acc_id IS NOT NULL AND v_ap_acc_id IS NOT NULL THEN
        v_gl_lines := jsonb_build_array(
            jsonb_build_object('account_id', v_inv_acc_id, 'debit', v_po_total, 'credit', 0, 'description', 'استلام مشتريات مخزنية - ' || p_grn_number),
            jsonb_build_object('account_id', v_ap_acc_id, 'debit', 0, 'credit', v_po_total, 'description', 'استحقاق المورد عن سند ' || p_grn_number)
        );

        PERFORM create_journal_entry(v_company_id, v_branch_id, CURRENT_DATE, 'purchase', 'goods_receipt', v_grn_id, 'توريد بضاعة سند ' || p_grn_number, v_gl_lines, true, p_received_by);
    END IF;

    RETURN v_grn_id;
END;
$$;


--
-- Name: record_expense(uuid, uuid, uuid, numeric, text, text, text, text, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.record_expense(p_company_id uuid, p_branch_id uuid, p_expense_account_id uuid, p_amount numeric, p_payment_method text, p_description text, p_reference_number text DEFAULT NULL::text, p_vendor_name text DEFAULT NULL::text, p_user_id uuid DEFAULT NULL::uuid) RETURNS uuid
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_expense_id UUID;
    v_credit_acc_id UUID;
    v_lines JSONB;
BEGIN
    IF p_amount <= 0 THEN
        RAISE EXCEPTION 'مبلغ المصروف يجب أن يكون أكبر من الصفر';
    END IF;

    -- أ) إدراج حركة المصروف بجدول المصروفات
    INSERT INTO expenses (
        company_id, branch_id, expense_account_id, amount, payment_method,
        reference_number, vendor_name, description, created_by
    ) VALUES (
        COALESCE(p_company_id, 'c0000000-0000-0000-0000-000000000000'::UUID),
        p_branch_id, p_expense_account_id, p_amount, p_payment_method,
        p_reference_number, p_vendor_name, p_description, p_user_id
    ) RETURNING id INTO v_expense_id;

    -- ب) جلب الحساب الدائن المقابل لوسيلة السداد (نقدية/بنك/موردين)
    IF p_payment_method = 'credit' THEN
        -- حساب الموردين (ذمم دائنة) 2100
        SELECT id INTO v_credit_acc_id FROM accounts WHERE code = '2100' LIMIT 1;
    ELSE
        -- حساب النقدية أو البنك المقابل لوسيلة الدفع
        v_credit_acc_id := get_account_for_payment_method(p_company_id, p_payment_method);
    END IF;

    -- ج) بناء أسطر قيد اليومية المزدوج
    v_lines := jsonb_build_array(
        -- من حـ/ المصروف (مدين)
        jsonb_build_object('account_id', p_expense_account_id, 'debit', p_amount, 'credit', 0, 'description', p_description),
        -- إلى حـ/ الخزينة أو البنك أو المورد (دائن)
        jsonb_build_object('account_id', v_credit_acc_id, 'debit', 0, 'credit', p_amount, 'description', 'سداد مصروف: ' || p_description)
    );

    -- د) إدراج القيد المحاسبي في General Ledger
    PERFORM create_journal_entry(
        p_company_id,
        p_branch_id,
        CURRENT_DATE,
        'expense',
        'expense',
        v_expense_id,
        p_description,
        v_lines,
        true,
        p_user_id
    );

    RETURN v_expense_id;
END;
$$;


--
-- Name: record_stock_movement(uuid, uuid, uuid, uuid, uuid, text, numeric, numeric, text, uuid, text, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.record_stock_movement(p_company_id uuid, p_brand_id uuid, p_branch_id uuid, p_warehouse_id uuid, p_ingredient_id uuid, p_movement_type text, p_quantity numeric, p_unit_cost numeric, p_reference_type text, p_reference_id uuid, p_notes text DEFAULT NULL::text, p_created_by uuid DEFAULT NULL::uuid) RETURNS uuid
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_current_balance NUMERIC(15, 4) := 0;
    v_new_balance NUMERIC(15, 4) := 0;
    v_movement_id UUID;
    v_total_cost NUMERIC(15, 2);
BEGIN
    -- أ) جلب الرصيد الحالي للخامة في هذا المخزن
    SELECT COALESCE(quantity, 0) INTO v_current_balance
    FROM warehouse_stock
    WHERE warehouse_id = p_warehouse_id AND ingredient_id = p_ingredient_id;

    -- ب) حساب الرصيد الجديد والتكلفة
    v_new_balance := v_current_balance + p_quantity;
    v_total_cost := ABS(p_quantity) * p_unit_cost;

    -- ج) إدراج الحركة في دفتر حركات المخزون (Ledger)
    INSERT INTO stock_movements (
        company_id, brand_id, branch_id, warehouse_id, ingredient_id,
        movement_type, quantity, unit_cost, total_cost,
        reference_type, reference_id, balance_after, notes, created_by
    ) VALUES (
        p_company_id, p_brand_id, p_branch_id, p_warehouse_id, p_ingredient_id,
        p_movement_type, p_quantity, p_unit_price, v_total_cost,
        p_reference_type, p_reference_id, v_new_balance, p_notes, p_created_by
    ) RETURNING id INTO v_movement_id;

    -- د) تحديث الرصيد في جدول warehouse_stock (للحفاظ على توافقية الكاشير القديم)
    INSERT INTO warehouse_stock (warehouse_id, ingredient_id, quantity)
    VALUES (p_warehouse_id, p_ingredient_id, v_new_balance)
    ON CONFLICT (warehouse_id, ingredient_id)
    DO UPDATE SET quantity = EXCLUDED.quantity;

    RETURN v_movement_id;
END;
$$;


--
-- Name: record_stock_take(uuid, uuid, numeric); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.record_stock_take(p_warehouse_id uuid, p_ingredient_id uuid, p_actual_qty numeric) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_theoretical_qty NUMERIC(15, 4) := 0;
    v_variance_qty NUMERIC(15, 4) := 0;
    v_unit_cost NUMERIC(15, 4) := 0;
    v_variance_cost NUMERIC(15, 2) := 0;
    v_company_id UUID;
    v_brand_id UUID;
    v_branch_id UUID;
    v_stocktake_id UUID;
BEGIN
    SELECT COALESCE(quantity, 0) INTO v_theoretical_qty 
    FROM warehouse_stock WHERE warehouse_id = p_warehouse_id AND ingredient_id = p_ingredient_id;

    SELECT COALESCE(cost_per_unit, 0) INTO v_unit_cost FROM ingredients WHERE id = p_ingredient_id;

    v_variance_qty := p_actual_qty - v_theoretical_qty;
    v_variance_cost := v_variance_qty * v_unit_cost;

    SELECT w.branch_id, b.brand_id, br.company_id
    INTO v_branch_id, v_brand_id, v_company_id
    FROM warehouses w
    LEFT JOIN branches b ON b.id = w.branch_id
    LEFT JOIN brands br ON br.id = b.brand_id
    WHERE w.id = p_warehouse_id;

    IF v_company_id IS NULL THEN v_company_id := 'c0000000-0000-0000-0000-000000000000'::UUID; END IF;
    IF v_brand_id IS NULL THEN v_brand_id := 'b0000000-0000-0000-0000-000000000000'::UUID; END IF;

    -- إدراج بجدول stock_takes
    INSERT INTO stock_takes (warehouse_id, ingredient_id, theoretical_qty, actual_qty, variance_qty, variance_cost)
    VALUES (p_warehouse_id, p_ingredient_id, v_theoretical_qty, p_actual_qty, v_variance_qty, v_variance_cost)
    RETURNING id INTO v_stocktake_id;

    -- تسجيل حركة تسوية في stock_movements بالفارق فقط
    IF v_variance_qty <> 0 THEN
        PERFORM record_stock_movement(
            v_company_id, v_brand_id, v_branch_id, p_warehouse_id,
            p_ingredient_id,
            'adjustment',
            v_variance_qty, -- قد يكون موجب أو سالب
            v_unit_cost,
            'stocktake',
            v_stocktake_id,
            'تسوية جرد فعلي (الفارق: ' || v_variance_qty::TEXT || ')',
            NULL
        );
    END IF;
END;
$$;


--
-- Name: reverse_journal_entry(uuid, uuid, text, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.reverse_journal_entry(p_company_id uuid, p_journal_entry_id uuid, p_reversal_reason text, p_user_id uuid DEFAULT NULL::uuid) RETURNS uuid
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_orig_entry RECORD;
    v_orig_line RECORD;
    v_reversed_lines JSONB := '[]'::JSONB;
    v_new_entry_id UUID;
    v_comp UUID := COALESCE(p_company_id, 'c0000000-0000-0000-0000-000000000000'::UUID);
BEGIN
    SELECT * INTO v_orig_entry FROM journal_entries WHERE id = p_journal_entry_id AND company_id = v_comp;

    IF v_orig_entry IS NULL THEN
        RAISE EXCEPTION 'القيد غير موجود أو لا ينتمي لهذه الشركة';
    END IF;

    IF v_orig_entry.status = 'reversed' THEN
        RAISE EXCEPTION 'هذا القيد تم عكسه سابقاً ولا يمكن عكسه مرة أخرى';
    END IF;

    -- بناء أسطر القيد العكسي (قلب المدين دائن والدائن مدين)
    FOR v_orig_line IN SELECT * FROM journal_entry_lines WHERE journal_entry_id = p_journal_entry_id
    LOOP
        v_reversed_lines := v_reversed_lines || jsonb_build_object(
            'account_id', v_orig_line.account_id,
            'debit', v_orig_line.credit,  -- قلب الدائن لمدين
            'credit', v_orig_line.debit,  -- قلب المدين لدائن
            'description', 'عكس قيد: ' || COALESCE(v_orig_line.description, '')
        );
    END LOOP;

    -- إنشاء القيد العكسي
    v_new_entry_id := create_journal_entry(
        v_comp,
        v_orig_entry.branch_id,
        CURRENT_DATE,
        v_orig_entry.journal_type,
        v_orig_entry.reference_type,
        v_orig_entry.reference_id,
        'قيد عكسي للقيد رقم (' || v_orig_entry.entry_number || ') - السبب: ' || p_reversal_reason,
        v_reversed_lines,
        true,
        p_user_id
    );

    -- علم القيد الأصلي كـ reversed
    UPDATE journal_entries SET status = 'reversed' WHERE id = p_journal_entry_id;

    -- تسجيل في سجل التدقيق الأمني
    INSERT INTO accounting_audit_logs (company_id, action, journal_entry_id, user_id, notes)
    VALUES (v_comp, 'REVERSE_ENTRY', p_journal_entry_id, p_user_id, 'عكس القيد برقم جديد: ' || v_new_entry_id::TEXT || ' - السبب: ' || p_reversal_reason);

    RETURN v_new_entry_id;
END;
$$;


--
-- Name: secure_adjust_tip(uuid, numeric, text, uuid, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.secure_adjust_tip(p_payment_id uuid, p_new_tip numeric, p_manager_pin text, p_branch_id uuid, p_reason text) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_manager_id UUID;
    v_old_tip NUMERIC;
    v_order_id UUID;
BEGIN
    -- أ) التحقق من الصلاحيات داخلياً (Backend Security)
    v_manager_id := verify_manager_pin(p_manager_pin, p_branch_id);

    -- ب) جلب البيانات القديمة
    SELECT tip_amount, order_id INTO v_old_tip, v_order_id FROM payments WHERE id = p_payment_id;

    -- ج) التحديث
    UPDATE payments SET tip_amount = p_new_tip WHERE id = p_payment_id;

    -- د) تسجيل المراجعة (Audit Log)
    INSERT INTO order_logs (order_id, user_id, action, details)
    VALUES (v_order_id, v_manager_id, 'EDIT_TIP', jsonb_build_object(
        'old_tip', v_old_tip, 'new_tip', p_new_tip, 'reason', p_reason
    ));
END;
$$;


--
-- Name: transfer_table_order(uuid, uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.transfer_table_order(p_order_id uuid, p_new_table_id uuid, p_user_id uuid) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_old_table_id UUID;
    v_old_table_num TEXT := '---';
    v_new_table_num TEXT := '---';
BEGIN
    -- جلب الطاولة القديمة
    SELECT table_id INTO v_old_table_id FROM orders WHERE id = p_order_id;
    SELECT table_number INTO v_old_table_num FROM tables WHERE id = v_old_table_id;
    SELECT table_number INTO v_new_table_num FROM tables WHERE id = p_new_table_id;

    -- تحديث الطاولة في الطلب
    UPDATE orders SET table_id = p_new_table_id WHERE id = p_order_id;

    -- تفريغ الطاولة القديمة إذا لم تكن هناك طلبات مفتوحة عليها
    IF v_old_table_id IS NOT NULL THEN
        IF NOT EXISTS (SELECT 1 FROM orders WHERE table_id = v_old_table_id AND status NOT IN ('closed', 'cancelled') AND id <> p_order_id) THEN
            UPDATE tables SET status = 'available' WHERE id = v_old_table_id;
        END IF;
    END IF;

    -- تعيين الطاولة الجديدة كـ "مشغولة"
    IF p_new_table_id IS NOT NULL THEN
        UPDATE tables SET status = 'occupied' WHERE id = p_new_table_id;
    END IF;

    -- تدوين العملية في سجل المراجعة
    INSERT INTO order_logs (order_id, user_id, action, details)
    VALUES (p_order_id, p_user_id, 'TRANSFER_TABLE', jsonb_build_object(
        'from_table', v_old_table_num,
        'to_table', v_new_table_num
    ));
END;
$$;


--
-- Name: update_order_financials(uuid, numeric, numeric, numeric, numeric, numeric); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.update_order_financials(p_order_id uuid, p_sub_total numeric, p_tax_amount numeric, p_service_amount numeric, p_discount_amount numeric, p_total_amount numeric) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
    UPDATE orders 
    SET 
        sub_total = p_sub_total,
        tax_amount = p_tax_amount,
        service_charge_amount = p_service_amount,
        discount_amount = p_discount_amount,
        total_amount = p_total_amount
    WHERE id = p_order_id;
END;
$$;


--
-- Name: validate_journal_entry_period(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.validate_journal_entry_period() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_period_status TEXT;
BEGIN
    SELECT status INTO v_period_status
    FROM fiscal_periods
    WHERE company_id = NEW.company_id
      AND NEW.entry_date BETWEEN start_date AND end_date
    ORDER BY created_at DESC
    LIMIT 1;

    IF v_period_status = 'closed' THEN
        RAISE EXCEPTION 'عملية مرفوضة: لا يمكن إضافة أو تعديل قيد محاسبي بتاريخ (%) يقع بداخل فترة مالية مغلقة', NEW.entry_date;
    END IF;

    RETURN NEW;
END;
$$;


--
-- Name: verify_manager_pin(text, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.verify_manager_pin(p_pin text, p_branch_id uuid) RETURNS uuid
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_user_id UUID;
BEGIN
    SELECT s.id INTO v_user_id 
    FROM staff s
    JOIN roles r ON s.role_id = r.id
    WHERE s.pin_code = p_pin AND s.branch_id = p_branch_id AND r.name IN ('owner', 'branch_manager') AND s.is_active = true;
    
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'غير مصرح لك بإجراء هذه العملية. يتطلب صلاحية مدير.';
    END IF;
    
    RETURN v_user_id;
END;
$$;


--
-- Name: void_order_item(uuid, uuid, uuid, uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.void_order_item(p_order_item_id uuid, p_reason_id uuid, p_user_id uuid, p_warehouse_id uuid) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_order_id UUID;
    v_product_id UUID;
    v_quantity INT;
    v_product_name TEXT;
    recipe_record RECORD;
BEGIN
    -- أ) التأكد من وجود الصنف وحالته النشطة
    SELECT oi.order_id, oi.product_id, oi.quantity, p.name 
    INTO v_order_id, v_product_id, v_quantity, v_product_name
    FROM order_items oi
    JOIN products p ON p.id = oi.product_id
    WHERE oi.id = p_order_item_id AND oi.status = 'active';

    IF NOT FOUND THEN 
        RAISE EXCEPTION 'الصنف غير موجود أو تم إلغاؤه مسبقاً'; 
    END IF;

    -- ب) تغيير حالة الصنف إلى "ملغي" وربطه بسبب الإلغاء
    UPDATE order_items 
    SET status = 'voided', void_reason_id = p_reason_id 
    WHERE id = p_order_item_id;

    -- ج) إرجاع مكونات الريسبي إلى المخزن
    FOR recipe_record IN SELECT ingredient_id, quantity_required FROM recipes WHERE product_id = v_product_id 
    LOOP
        UPDATE warehouse_stock
        SET quantity = quantity + (recipe_record.quantity_required * v_quantity)
        WHERE warehouse_id = p_warehouse_id AND ingredient_id = recipe_record.ingredient_id;
    END LOOP;

    -- د) تسجيل الحركة في سجل المراجعة (Audit Log) ليراها المالك
    INSERT INTO order_logs (order_id, user_id, action, details)
    VALUES (v_order_id, p_user_id, 'VOID_ITEM', jsonb_build_object(
        'product', v_product_name, 
        'qty_voided', v_quantity, 
        'reason_id', p_reason_id
    ));
END;
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: accounting_audit_logs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.accounting_audit_logs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid DEFAULT 'c0000000-0000-0000-0000-000000000000'::uuid,
    action text NOT NULL,
    journal_entry_id uuid,
    user_id uuid,
    old_value jsonb,
    new_value jsonb,
    notes text,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: accounts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.accounts (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid DEFAULT 'c0000000-0000-0000-0000-000000000000'::uuid,
    code text NOT NULL,
    name_ar text NOT NULL,
    name_en text,
    account_type text NOT NULL,
    normal_balance text NOT NULL,
    parent_id uuid,
    is_system_account boolean DEFAULT false,
    is_active boolean DEFAULT true,
    created_at timestamp with time zone DEFAULT now(),
    CONSTRAINT accounts_account_type_check CHECK ((account_type = ANY (ARRAY['asset'::text, 'liability'::text, 'equity'::text, 'revenue'::text, 'cogs'::text, 'expense'::text]))),
    CONSTRAINT accounts_normal_balance_check CHECK ((normal_balance = ANY (ARRAY['debit'::text, 'credit'::text])))
);


--
-- Name: adjustment_reasons; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.adjustment_reasons (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    brand_id uuid,
    reason text NOT NULL,
    adjustment_type text NOT NULL,
    created_at timestamp with time zone DEFAULT now(),
    CONSTRAINT adjustment_reasons_adjustment_type_check CHECK ((adjustment_type = ANY (ARRAY['increase'::text, 'decrease'::text, 'both'::text])))
);


--
-- Name: areas; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.areas (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    branch_id uuid,
    name text NOT NULL,
    sort_order integer DEFAULT 0,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: branch_tax_settings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.branch_tax_settings (
    branch_id uuid NOT NULL,
    vat_percentage numeric(5,2) DEFAULT 14.00,
    is_vat_inclusive boolean DEFAULT false,
    service_charge_percentage numeric(5,2) DEFAULT 12.00,
    is_service_taxable boolean DEFAULT true
);


--
-- Name: branches; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.branches (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    address text,
    created_at timestamp with time zone DEFAULT now(),
    brand_id uuid,
    has_tables boolean DEFAULT true
);


--
-- Name: brands; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.brands (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid,
    name text NOT NULL,
    currency text DEFAULT 'EGP'::text,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: cancel_reasons; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.cancel_reasons (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    brand_id uuid,
    reason text NOT NULL,
    reason_type text NOT NULL,
    created_at timestamp with time zone DEFAULT now(),
    CONSTRAINT cancel_reasons_reason_type_check CHECK ((reason_type = ANY (ARRAY['void_item'::text, 'cancel_order'::text, 'return'::text])))
);


--
-- Name: cash_bank_accounts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.cash_bank_accounts (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid DEFAULT 'c0000000-0000-0000-0000-000000000000'::uuid,
    branch_id uuid,
    account_id uuid,
    name_ar text NOT NULL,
    name_en text,
    account_type text NOT NULL,
    account_number text,
    bank_name text,
    is_active boolean DEFAULT true,
    created_at timestamp with time zone DEFAULT now(),
    CONSTRAINT cash_bank_accounts_account_type_check CHECK ((account_type = ANY (ARRAY['cash_drawer'::text, 'main_cash'::text, 'bank_account'::text, 'card_clearing'::text, 'wallet'::text, 'instapay'::text])))
);


--
-- Name: categories; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.categories (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    created_at timestamp with time zone DEFAULT now(),
    name_en text,
    brand_id uuid
);


--
-- Name: companies; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.companies (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    tax_number text,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: cost_centers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.cost_centers (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid DEFAULT 'c0000000-0000-0000-0000-000000000000'::uuid,
    branch_id uuid,
    code text NOT NULL,
    name_ar text NOT NULL,
    name_en text,
    parent_id uuid,
    is_active boolean DEFAULT true,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: customer_ledger; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.customer_ledger (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid DEFAULT 'c0000000-0000-0000-0000-000000000000'::uuid,
    customer_id uuid,
    order_id uuid,
    transaction_type text NOT NULL,
    amount numeric(15,2) NOT NULL,
    payment_method text,
    reference_number text,
    balance_after numeric(15,2) DEFAULT 0 NOT NULL,
    notes text,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now(),
    CONSTRAINT customer_ledger_payment_method_check CHECK ((payment_method = ANY (ARRAY['cash'::text, 'card'::text, 'instapay'::text, 'wallet'::text, 'bank_transfer'::text, 'check'::text]))),
    CONSTRAINT customer_ledger_transaction_type_check CHECK ((transaction_type = ANY (ARRAY['credit_sale'::text, 'payment_received'::text, 'refund'::text, 'adjustment'::text])))
);


--
-- Name: customers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.customers (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid,
    name text NOT NULL,
    phone text,
    email text,
    address text,
    customer_type text DEFAULT 'cash'::text,
    credit_limit numeric(10,2) DEFAULT 0.00,
    current_balance numeric(10,2) DEFAULT 0.00,
    created_at timestamp with time zone DEFAULT now(),
    CONSTRAINT customers_customer_type_check CHECK ((customer_type = ANY (ARRAY['cash'::text, 'registered'::text, 'on_account'::text])))
);


--
-- Name: discounts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.discounts (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    brand_id uuid,
    name text NOT NULL,
    discount_type text NOT NULL,
    value numeric(10,2) NOT NULL,
    requires_approval boolean DEFAULT true,
    created_at timestamp with time zone DEFAULT now(),
    CONSTRAINT discounts_discount_type_check CHECK ((discount_type = ANY (ARRAY['percentage'::text, 'fixed'::text])))
);


--
-- Name: expenses; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.expenses (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid DEFAULT 'c0000000-0000-0000-0000-000000000000'::uuid,
    branch_id uuid,
    expense_account_id uuid,
    amount numeric(15,2) NOT NULL,
    payment_method text NOT NULL,
    cash_bank_account_id uuid,
    reference_number text,
    vendor_name text,
    description text NOT NULL,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now(),
    cost_center_id uuid,
    CONSTRAINT expenses_amount_check CHECK ((amount > (0)::numeric)),
    CONSTRAINT expenses_payment_method_check CHECK ((payment_method = ANY (ARRAY['cash'::text, 'card'::text, 'bank_transfer'::text, 'wallet'::text, 'instapay'::text, 'check'::text, 'credit'::text])))
);


--
-- Name: fiscal_periods; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.fiscal_periods (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid,
    period_name text NOT NULL,
    start_date date NOT NULL,
    end_date date NOT NULL,
    status text DEFAULT 'open'::text,
    created_at timestamp with time zone DEFAULT now(),
    closed_by uuid,
    closed_at timestamp with time zone,
    CONSTRAINT fiscal_periods_status_check CHECK ((status = ANY (ARRAY['open'::text, 'closed'::text])))
);


--
-- Name: goods_receipt_items; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.goods_receipt_items (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    goods_receipt_id uuid,
    ingredient_id uuid,
    ordered_qty numeric(15,4) NOT NULL,
    received_qty numeric(15,4) NOT NULL,
    unit_cost numeric(15,4) NOT NULL,
    total_cost numeric(15,2) NOT NULL
);


--
-- Name: goods_receipts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.goods_receipts (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    purchase_order_id uuid,
    warehouse_id uuid,
    grn_number text NOT NULL,
    received_by uuid,
    received_at timestamp with time zone DEFAULT now(),
    notes text
);


--
-- Name: ingredient_cost_history; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ingredient_cost_history (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    ingredient_id uuid,
    old_cost numeric(15,4) NOT NULL,
    new_cost numeric(15,4) NOT NULL,
    change_reason text NOT NULL,
    reference_id uuid,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: ingredients; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.ingredients (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    unit text NOT NULL,
    cost_per_unit numeric(10,4) DEFAULT 0 NOT NULL,
    stock_quantity numeric(10,2) DEFAULT 0 NOT NULL,
    min_stock_alert numeric(10,2) DEFAULT 5,
    created_at timestamp with time zone DEFAULT now(),
    name_en text,
    brand_id uuid,
    base_unit_id uuid,
    purchase_unit_id uuid,
    recipe_unit_id uuid,
    purchase_to_base_factor numeric(15,6) DEFAULT 1,
    reorder_point numeric(15,4) DEFAULT 10,
    max_stock_level numeric(15,4) DEFAULT 100
);


--
-- Name: journal_entries; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.journal_entries (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid DEFAULT 'c0000000-0000-0000-0000-000000000000'::uuid,
    branch_id uuid,
    entry_number text NOT NULL,
    entry_date date DEFAULT CURRENT_DATE NOT NULL,
    journal_type text NOT NULL,
    reference_type text,
    reference_id uuid,
    description text NOT NULL,
    status text DEFAULT 'draft'::text NOT NULL,
    created_by uuid,
    posted_by uuid,
    posted_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now(),
    CONSTRAINT journal_entries_journal_type_check CHECK ((journal_type = ANY (ARRAY['sales'::text, 'purchase'::text, 'payment'::text, 'receipt'::text, 'expense'::text, 'inventory'::text, 'adjustment'::text, 'manual'::text, 'tax'::text]))),
    CONSTRAINT journal_entries_reference_type_check CHECK ((reference_type = ANY (ARRAY['order'::text, 'purchase_order'::text, 'goods_receipt'::text, 'waste_log'::text, 'stock_transfer'::text, 'expense'::text, 'payment'::text, 'supplier_payment'::text, 'adjustment'::text, 'manual'::text]))),
    CONSTRAINT journal_entries_status_check CHECK ((status = ANY (ARRAY['draft'::text, 'posted'::text, 'reversed'::text])))
);


--
-- Name: journal_entry_lines; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.journal_entry_lines (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    journal_entry_id uuid,
    account_id uuid,
    debit numeric(15,4) DEFAULT 0 NOT NULL,
    credit numeric(15,4) DEFAULT 0 NOT NULL,
    description text,
    branch_id uuid,
    created_at timestamp with time zone DEFAULT now(),
    cost_center_id uuid,
    CONSTRAINT check_debit_credit_nonzero CHECK ((((debit > (0)::numeric) AND (credit = (0)::numeric)) OR ((credit > (0)::numeric) AND (debit = (0)::numeric)))),
    CONSTRAINT journal_entry_lines_credit_check CHECK ((credit >= (0)::numeric)),
    CONSTRAINT journal_entry_lines_debit_check CHECK ((debit >= (0)::numeric))
);


--
-- Name: modifier_groups; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.modifier_groups (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    brand_id uuid,
    name text NOT NULL,
    name_en text,
    min_selection integer DEFAULT 0,
    max_selection integer DEFAULT 1,
    is_required boolean DEFAULT false,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: modifiers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.modifiers (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    group_id uuid,
    name text NOT NULL,
    name_en text,
    price numeric(10,2) DEFAULT 0.00,
    ingredient_id uuid,
    ingredient_quantity numeric(10,4) DEFAULT 0.0000,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: opening_balances; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.opening_balances (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    fiscal_period_id uuid,
    warehouse_id uuid,
    ingredient_id uuid,
    quantity numeric(15,4) NOT NULL,
    unit_cost numeric(15,4) NOT NULL,
    total_value numeric(15,2) NOT NULL,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: order_item_modifiers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.order_item_modifiers (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    order_item_id uuid,
    modifier_id uuid,
    modifier_name text NOT NULL,
    unit_price numeric(10,2) DEFAULT 0.00,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: order_items; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.order_items (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    order_id uuid,
    product_id uuid,
    quantity integer DEFAULT 1 NOT NULL,
    unit_price numeric(10,2) NOT NULL,
    total_price numeric(10,2) NOT NULL,
    item_notes text,
    discount_amount numeric(10,2) DEFAULT 0.00,
    status text DEFAULT 'active'::text,
    void_reason_id uuid,
    CONSTRAINT order_items_status_check CHECK ((status = ANY (ARRAY['active'::text, 'voided'::text, 'cancelled'::text])))
);


--
-- Name: order_logs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.order_logs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    order_id uuid,
    user_id uuid,
    action text NOT NULL,
    details jsonb,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: order_sequences; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.order_sequences (
    branch_id uuid NOT NULL,
    last_number integer DEFAULT 1000
);


--
-- Name: order_split_items; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.order_split_items (
    split_id uuid NOT NULL,
    order_item_id uuid NOT NULL,
    quantity integer NOT NULL
);


--
-- Name: order_splits; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.order_splits (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    order_id uuid,
    split_number integer NOT NULL,
    split_type text,
    amount_due numeric(10,2) NOT NULL,
    status text DEFAULT 'pending'::text,
    created_at timestamp with time zone DEFAULT now(),
    CONSTRAINT order_splits_split_type_check CHECK ((split_type = ANY (ARRAY['amount'::text, 'item'::text, 'guest'::text]))),
    CONSTRAINT order_splits_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'paid'::text])))
);


--
-- Name: orders; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.orders (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    order_type text DEFAULT 'dine_in'::text NOT NULL,
    table_number text,
    total_amount numeric(10,2) DEFAULT 0 NOT NULL,
    payment_method text DEFAULT 'cash'::text,
    status text DEFAULT 'pending'::text,
    created_at timestamp with time zone DEFAULT now(),
    kitchen_status text DEFAULT 'pending'::text,
    notes text,
    company_id uuid,
    brand_id uuid,
    branch_id uuid,
    area_id uuid,
    table_id uuid,
    customer_id uuid,
    waiter_id uuid,
    guest_count integer DEFAULT 1,
    order_number text,
    sub_total numeric(10,2) DEFAULT 0,
    tax_amount numeric(10,2) DEFAULT 0,
    service_charge_amount numeric(10,2) DEFAULT 0,
    discount_amount numeric(10,2) DEFAULT 0,
    is_posted_to_gl boolean DEFAULT false,
    CONSTRAINT orders_status_check CHECK ((status = ANY (ARRAY['draft'::text, 'open'::text, 'sent'::text, 'preparing'::text, 'ready'::text, 'served'::text, 'paid'::text, 'closed'::text, 'cancelled'::text])))
);


--
-- Name: payment_method_account_mappings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.payment_method_account_mappings (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid DEFAULT 'c0000000-0000-0000-0000-000000000000'::uuid,
    payment_method text NOT NULL,
    account_id uuid,
    cash_bank_account_id uuid,
    created_at timestamp with time zone DEFAULT now(),
    CONSTRAINT payment_method_account_mappings_payment_method_check CHECK ((payment_method = ANY (ARRAY['cash'::text, 'card'::text, 'instapay'::text, 'wallet'::text, 'on_account'::text, 'check'::text, 'other'::text])))
);


--
-- Name: payments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.payments (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    order_id uuid,
    payment_method text NOT NULL,
    amount numeric(10,2) NOT NULL,
    tip_amount numeric(10,2) DEFAULT 0.00,
    reference_number text,
    created_at timestamp with time zone DEFAULT now(),
    tip_staff_id uuid,
    split_id uuid,
    CONSTRAINT payments_payment_method_check CHECK ((payment_method = ANY (ARRAY['cash'::text, 'card'::text, 'instapay'::text, 'wallet'::text, 'on_account'::text])))
);


--
-- Name: product_modifier_groups; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.product_modifier_groups (
    product_id uuid NOT NULL,
    group_id uuid NOT NULL
);


--
-- Name: products; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.products (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    category_id uuid,
    name text NOT NULL,
    price numeric(10,2) NOT NULL,
    is_available boolean DEFAULT true,
    created_at timestamp with time zone DEFAULT now(),
    name_en text,
    brand_id uuid
);


--
-- Name: purchase_order_items; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.purchase_order_items (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    purchase_order_id uuid,
    ingredient_id uuid,
    quantity numeric(10,2) NOT NULL,
    unit_price numeric(10,4) NOT NULL,
    total_price numeric(10,2) NOT NULL
);


--
-- Name: purchase_orders; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.purchase_orders (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    supplier_id uuid,
    warehouse_id uuid,
    total_amount numeric(10,2) DEFAULT 0,
    status text DEFAULT 'received'::text,
    created_at timestamp with time zone DEFAULT now(),
    approved_by uuid,
    approved_at timestamp with time zone,
    po_number text,
    notes text,
    CONSTRAINT purchase_orders_status_check CHECK ((status = ANY (ARRAY['draft'::text, 'approved'::text, 'sent'::text, 'partially_received'::text, 'fully_received'::text, 'closed'::text, 'cancelled'::text])))
);


--
-- Name: recipes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.recipes (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    product_id uuid,
    ingredient_id uuid,
    quantity_required numeric(10,4) NOT NULL
);


--
-- Name: roles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.roles (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL
);


--
-- Name: staff; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.staff (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    pin_code text NOT NULL,
    role_id uuid,
    branch_id uuid,
    created_at timestamp with time zone DEFAULT now(),
    company_id uuid,
    email text,
    is_active boolean DEFAULT true
);


--
-- Name: stock_adjustments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.stock_adjustments (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    warehouse_id uuid,
    ingredient_id uuid,
    adjustment_type text NOT NULL,
    quantity numeric(15,4) NOT NULL,
    unit_cost numeric(15,4) NOT NULL,
    total_cost numeric(15,2) NOT NULL,
    reason_id uuid,
    notes text,
    created_by uuid,
    approved_by uuid,
    created_at timestamp with time zone DEFAULT now(),
    CONSTRAINT stock_adjustments_adjustment_type_check CHECK ((adjustment_type = ANY (ARRAY['increase'::text, 'decrease'::text])))
);


--
-- Name: stock_movements; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.stock_movements (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid,
    brand_id uuid,
    branch_id uuid,
    warehouse_id uuid,
    ingredient_id uuid,
    movement_type text NOT NULL,
    quantity numeric(15,4) NOT NULL,
    unit_cost numeric(15,4) DEFAULT 0 NOT NULL,
    total_cost numeric(15,2) DEFAULT 0 NOT NULL,
    reference_type text,
    reference_id uuid,
    balance_after numeric(15,4) DEFAULT 0 NOT NULL,
    notes text,
    created_by uuid,
    created_at timestamp with time zone DEFAULT now(),
    CONSTRAINT stock_movements_movement_type_check CHECK ((movement_type = ANY (ARRAY['opening_balance'::text, 'purchase'::text, 'sale'::text, 'waste'::text, 'transfer_in'::text, 'transfer_out'::text, 'adjustment'::text]))),
    CONSTRAINT stock_movements_reference_type_check CHECK ((reference_type = ANY (ARRAY['purchase_order'::text, 'order'::text, 'waste_log'::text, 'stock_transfer'::text, 'stocktake'::text, 'adjustment'::text, 'opening'::text])))
);


--
-- Name: stock_takes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.stock_takes (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    warehouse_id uuid,
    ingredient_id uuid,
    theoretical_qty numeric(10,2) NOT NULL,
    actual_qty numeric(10,2) NOT NULL,
    variance_qty numeric(10,2) NOT NULL,
    variance_cost numeric(10,2) NOT NULL,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: stock_transfers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.stock_transfers (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    from_warehouse_id uuid,
    to_warehouse_id uuid,
    ingredient_id uuid,
    quantity numeric(10,2) NOT NULL,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: supplier_payments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.supplier_payments (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    company_id uuid DEFAULT 'c0000000-0000-0000-0000-000000000000'::uuid,
    supplier_id uuid,
    purchase_order_id uuid,
    amount numeric(15,2) NOT NULL,
    payment_method text NOT NULL,
    reference_number text,
    paid_by uuid,
    notes text,
    created_at timestamp with time zone DEFAULT now(),
    CONSTRAINT supplier_payments_amount_check CHECK ((amount > (0)::numeric)),
    CONSTRAINT supplier_payments_payment_method_check CHECK ((payment_method = ANY (ARRAY['cash'::text, 'bank_transfer'::text, 'cheque'::text, 'wallet'::text])))
);


--
-- Name: supplier_prices; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.supplier_prices (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    supplier_id uuid,
    ingredient_id uuid,
    unit_price numeric(15,4) NOT NULL,
    min_order_qty numeric(15,4) DEFAULT 1,
    lead_time_days integer DEFAULT 1,
    is_preferred boolean DEFAULT false,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: suppliers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.suppliers (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    phone text,
    company_name text,
    created_at timestamp with time zone DEFAULT now(),
    payment_terms text DEFAULT 'cash'::text,
    credit_limit numeric(15,2) DEFAULT 0,
    current_balance numeric(15,2) DEFAULT 0,
    tax_number text,
    is_active boolean DEFAULT true
);


--
-- Name: tables; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tables (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    area_id uuid,
    table_number text NOT NULL,
    capacity integer DEFAULT 4,
    status text DEFAULT 'available'::text NOT NULL,
    created_at timestamp with time zone DEFAULT now(),
    CONSTRAINT tables_status_check CHECK ((status = ANY (ARRAY['available'::text, 'occupied'::text, 'reserved'::text, 'cleaning'::text, 'out_of_service'::text])))
);


--
-- Name: unit_conversions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.unit_conversions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    from_unit_id uuid,
    to_unit_id uuid,
    conversion_factor numeric(15,6) NOT NULL,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: units; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.units (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    code text NOT NULL,
    name_ar text NOT NULL,
    name_en text NOT NULL,
    unit_type text NOT NULL,
    is_base_unit boolean DEFAULT false,
    created_at timestamp with time zone DEFAULT now(),
    CONSTRAINT units_unit_type_check CHECK ((unit_type = ANY (ARRAY['weight'::text, 'volume'::text, 'count'::text])))
);


--
-- Name: variance_investigations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.variance_investigations (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    warehouse_id uuid,
    ingredient_id uuid,
    period_start timestamp with time zone NOT NULL,
    period_end timestamp with time zone NOT NULL,
    theoretical_qty numeric(15,4) NOT NULL,
    actual_qty numeric(15,4) NOT NULL,
    variance_qty numeric(15,4) NOT NULL,
    variance_cost numeric(15,2) NOT NULL,
    root_cause text,
    action_taken text,
    investigated_by uuid,
    approved_by uuid,
    status text DEFAULT 'pending'::text,
    created_at timestamp with time zone DEFAULT now(),
    CONSTRAINT variance_investigations_root_cause_check CHECK ((root_cause = ANY (ARRAY['theft'::text, 'measurement_error'::text, 'spoilage'::text, 'recipe_error'::text, 'unrecorded_waste'::text, 'other'::text]))),
    CONSTRAINT variance_investigations_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'investigating'::text, 'resolved'::text, 'closed'::text])))
);


--
-- Name: warehouse_stock; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.warehouse_stock (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    warehouse_id uuid,
    ingredient_id uuid,
    quantity numeric(10,2) DEFAULT 0 NOT NULL
);


--
-- Name: warehouses; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.warehouses (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    branch_id uuid,
    name text NOT NULL,
    is_main boolean DEFAULT false,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: waste_logs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.waste_logs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    warehouse_id uuid,
    ingredient_id uuid,
    quantity numeric(10,2) NOT NULL,
    reason text NOT NULL,
    cost_loss numeric(10,2) NOT NULL,
    created_at timestamp with time zone DEFAULT now()
);


--
-- Name: accounting_audit_logs accounting_audit_logs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.accounting_audit_logs
    ADD CONSTRAINT accounting_audit_logs_pkey PRIMARY KEY (id);


--
-- Name: accounts accounts_company_id_code_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.accounts
    ADD CONSTRAINT accounts_company_id_code_key UNIQUE (company_id, code);


--
-- Name: accounts accounts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.accounts
    ADD CONSTRAINT accounts_pkey PRIMARY KEY (id);


--
-- Name: adjustment_reasons adjustment_reasons_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.adjustment_reasons
    ADD CONSTRAINT adjustment_reasons_pkey PRIMARY KEY (id);


--
-- Name: areas areas_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.areas
    ADD CONSTRAINT areas_pkey PRIMARY KEY (id);


--
-- Name: branch_tax_settings branch_tax_settings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.branch_tax_settings
    ADD CONSTRAINT branch_tax_settings_pkey PRIMARY KEY (branch_id);


--
-- Name: branches branches_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.branches
    ADD CONSTRAINT branches_pkey PRIMARY KEY (id);


--
-- Name: brands brands_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.brands
    ADD CONSTRAINT brands_pkey PRIMARY KEY (id);


--
-- Name: cancel_reasons cancel_reasons_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cancel_reasons
    ADD CONSTRAINT cancel_reasons_pkey PRIMARY KEY (id);


--
-- Name: cash_bank_accounts cash_bank_accounts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cash_bank_accounts
    ADD CONSTRAINT cash_bank_accounts_pkey PRIMARY KEY (id);


--
-- Name: categories categories_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.categories
    ADD CONSTRAINT categories_pkey PRIMARY KEY (id);


--
-- Name: companies companies_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.companies
    ADD CONSTRAINT companies_pkey PRIMARY KEY (id);


--
-- Name: cost_centers cost_centers_company_id_code_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cost_centers
    ADD CONSTRAINT cost_centers_company_id_code_key UNIQUE (company_id, code);


--
-- Name: cost_centers cost_centers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cost_centers
    ADD CONSTRAINT cost_centers_pkey PRIMARY KEY (id);


--
-- Name: customer_ledger customer_ledger_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_ledger
    ADD CONSTRAINT customer_ledger_pkey PRIMARY KEY (id);


--
-- Name: customers customers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customers
    ADD CONSTRAINT customers_pkey PRIMARY KEY (id);


--
-- Name: discounts discounts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.discounts
    ADD CONSTRAINT discounts_pkey PRIMARY KEY (id);


--
-- Name: expenses expenses_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.expenses
    ADD CONSTRAINT expenses_pkey PRIMARY KEY (id);


--
-- Name: fiscal_periods fiscal_periods_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fiscal_periods
    ADD CONSTRAINT fiscal_periods_pkey PRIMARY KEY (id);


--
-- Name: goods_receipt_items goods_receipt_items_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.goods_receipt_items
    ADD CONSTRAINT goods_receipt_items_pkey PRIMARY KEY (id);


--
-- Name: goods_receipts goods_receipts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.goods_receipts
    ADD CONSTRAINT goods_receipts_pkey PRIMARY KEY (id);


--
-- Name: ingredient_cost_history ingredient_cost_history_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ingredient_cost_history
    ADD CONSTRAINT ingredient_cost_history_pkey PRIMARY KEY (id);


--
-- Name: ingredients ingredients_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ingredients
    ADD CONSTRAINT ingredients_pkey PRIMARY KEY (id);


--
-- Name: journal_entries journal_entries_company_id_entry_number_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.journal_entries
    ADD CONSTRAINT journal_entries_company_id_entry_number_key UNIQUE (company_id, entry_number);


--
-- Name: journal_entries journal_entries_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.journal_entries
    ADD CONSTRAINT journal_entries_pkey PRIMARY KEY (id);


--
-- Name: journal_entry_lines journal_entry_lines_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.journal_entry_lines
    ADD CONSTRAINT journal_entry_lines_pkey PRIMARY KEY (id);


--
-- Name: modifier_groups modifier_groups_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.modifier_groups
    ADD CONSTRAINT modifier_groups_pkey PRIMARY KEY (id);


--
-- Name: modifiers modifiers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.modifiers
    ADD CONSTRAINT modifiers_pkey PRIMARY KEY (id);


--
-- Name: opening_balances opening_balances_fiscal_period_id_warehouse_id_ingredient_i_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.opening_balances
    ADD CONSTRAINT opening_balances_fiscal_period_id_warehouse_id_ingredient_i_key UNIQUE (fiscal_period_id, warehouse_id, ingredient_id);


--
-- Name: opening_balances opening_balances_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.opening_balances
    ADD CONSTRAINT opening_balances_pkey PRIMARY KEY (id);


--
-- Name: order_item_modifiers order_item_modifiers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.order_item_modifiers
    ADD CONSTRAINT order_item_modifiers_pkey PRIMARY KEY (id);


--
-- Name: order_items order_items_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.order_items
    ADD CONSTRAINT order_items_pkey PRIMARY KEY (id);


--
-- Name: order_logs order_logs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.order_logs
    ADD CONSTRAINT order_logs_pkey PRIMARY KEY (id);


--
-- Name: order_sequences order_sequences_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.order_sequences
    ADD CONSTRAINT order_sequences_pkey PRIMARY KEY (branch_id);


--
-- Name: order_split_items order_split_items_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.order_split_items
    ADD CONSTRAINT order_split_items_pkey PRIMARY KEY (split_id, order_item_id);


--
-- Name: order_splits order_splits_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.order_splits
    ADD CONSTRAINT order_splits_pkey PRIMARY KEY (id);


--
-- Name: orders orders_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.orders
    ADD CONSTRAINT orders_pkey PRIMARY KEY (id);


--
-- Name: payment_method_account_mappings payment_method_account_mappings_company_id_payment_method_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payment_method_account_mappings
    ADD CONSTRAINT payment_method_account_mappings_company_id_payment_method_key UNIQUE (company_id, payment_method);


--
-- Name: payment_method_account_mappings payment_method_account_mappings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payment_method_account_mappings
    ADD CONSTRAINT payment_method_account_mappings_pkey PRIMARY KEY (id);


--
-- Name: payments payments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payments
    ADD CONSTRAINT payments_pkey PRIMARY KEY (id);


--
-- Name: product_modifier_groups product_modifier_groups_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_modifier_groups
    ADD CONSTRAINT product_modifier_groups_pkey PRIMARY KEY (product_id, group_id);


--
-- Name: products products_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.products
    ADD CONSTRAINT products_pkey PRIMARY KEY (id);


--
-- Name: purchase_order_items purchase_order_items_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.purchase_order_items
    ADD CONSTRAINT purchase_order_items_pkey PRIMARY KEY (id);


--
-- Name: purchase_orders purchase_orders_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.purchase_orders
    ADD CONSTRAINT purchase_orders_pkey PRIMARY KEY (id);


--
-- Name: recipes recipes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recipes
    ADD CONSTRAINT recipes_pkey PRIMARY KEY (id);


--
-- Name: roles roles_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.roles
    ADD CONSTRAINT roles_name_key UNIQUE (name);


--
-- Name: roles roles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.roles
    ADD CONSTRAINT roles_pkey PRIMARY KEY (id);


--
-- Name: staff staff_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.staff
    ADD CONSTRAINT staff_pkey PRIMARY KEY (id);


--
-- Name: stock_adjustments stock_adjustments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stock_adjustments
    ADD CONSTRAINT stock_adjustments_pkey PRIMARY KEY (id);


--
-- Name: stock_movements stock_movements_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stock_movements
    ADD CONSTRAINT stock_movements_pkey PRIMARY KEY (id);


--
-- Name: stock_takes stock_takes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stock_takes
    ADD CONSTRAINT stock_takes_pkey PRIMARY KEY (id);


--
-- Name: stock_transfers stock_transfers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stock_transfers
    ADD CONSTRAINT stock_transfers_pkey PRIMARY KEY (id);


--
-- Name: supplier_payments supplier_payments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.supplier_payments
    ADD CONSTRAINT supplier_payments_pkey PRIMARY KEY (id);


--
-- Name: supplier_prices supplier_prices_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.supplier_prices
    ADD CONSTRAINT supplier_prices_pkey PRIMARY KEY (id);


--
-- Name: supplier_prices supplier_prices_supplier_id_ingredient_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.supplier_prices
    ADD CONSTRAINT supplier_prices_supplier_id_ingredient_id_key UNIQUE (supplier_id, ingredient_id);


--
-- Name: suppliers suppliers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.suppliers
    ADD CONSTRAINT suppliers_pkey PRIMARY KEY (id);


--
-- Name: tables tables_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tables
    ADD CONSTRAINT tables_pkey PRIMARY KEY (id);


--
-- Name: unit_conversions unit_conversions_from_unit_id_to_unit_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.unit_conversions
    ADD CONSTRAINT unit_conversions_from_unit_id_to_unit_id_key UNIQUE (from_unit_id, to_unit_id);


--
-- Name: unit_conversions unit_conversions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.unit_conversions
    ADD CONSTRAINT unit_conversions_pkey PRIMARY KEY (id);


--
-- Name: units units_code_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.units
    ADD CONSTRAINT units_code_key UNIQUE (code);


--
-- Name: units units_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.units
    ADD CONSTRAINT units_pkey PRIMARY KEY (id);


--
-- Name: variance_investigations variance_investigations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.variance_investigations
    ADD CONSTRAINT variance_investigations_pkey PRIMARY KEY (id);


--
-- Name: warehouse_stock warehouse_stock_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.warehouse_stock
    ADD CONSTRAINT warehouse_stock_pkey PRIMARY KEY (id);


--
-- Name: warehouse_stock warehouse_stock_warehouse_id_ingredient_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.warehouse_stock
    ADD CONSTRAINT warehouse_stock_warehouse_id_ingredient_id_key UNIQUE (warehouse_id, ingredient_id);


--
-- Name: warehouses warehouses_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.warehouses
    ADD CONSTRAINT warehouses_pkey PRIMARY KEY (id);


--
-- Name: waste_logs waste_logs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.waste_logs
    ADD CONSTRAINT waste_logs_pkey PRIMARY KEY (id);


--
-- Name: journal_entries trg_check_fiscal_period; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_check_fiscal_period BEFORE INSERT OR UPDATE ON public.journal_entries FOR EACH ROW EXECUTE FUNCTION public.validate_journal_entry_period();


--
-- Name: orders trg_generate_order_number; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_generate_order_number BEFORE INSERT ON public.orders FOR EACH ROW WHEN ((new.branch_id IS NOT NULL)) EXECUTE FUNCTION public.generate_order_number();


--
-- Name: journal_entries trg_prevent_posted_journal_deletion; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_prevent_posted_journal_deletion BEFORE DELETE ON public.journal_entries FOR EACH ROW EXECUTE FUNCTION public.prevent_posted_journal_deletion();


--
-- Name: accounting_audit_logs accounting_audit_logs_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.accounting_audit_logs
    ADD CONSTRAINT accounting_audit_logs_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: accounting_audit_logs accounting_audit_logs_journal_entry_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.accounting_audit_logs
    ADD CONSTRAINT accounting_audit_logs_journal_entry_id_fkey FOREIGN KEY (journal_entry_id) REFERENCES public.journal_entries(id) ON DELETE SET NULL;


--
-- Name: accounting_audit_logs accounting_audit_logs_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.accounting_audit_logs
    ADD CONSTRAINT accounting_audit_logs_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.staff(id) ON DELETE SET NULL;


--
-- Name: accounts accounts_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.accounts
    ADD CONSTRAINT accounts_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: accounts accounts_parent_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.accounts
    ADD CONSTRAINT accounts_parent_id_fkey FOREIGN KEY (parent_id) REFERENCES public.accounts(id) ON DELETE RESTRICT;


--
-- Name: adjustment_reasons adjustment_reasons_brand_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.adjustment_reasons
    ADD CONSTRAINT adjustment_reasons_brand_id_fkey FOREIGN KEY (brand_id) REFERENCES public.brands(id) ON DELETE CASCADE;


--
-- Name: areas areas_branch_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.areas
    ADD CONSTRAINT areas_branch_id_fkey FOREIGN KEY (branch_id) REFERENCES public.branches(id) ON DELETE CASCADE;


--
-- Name: branch_tax_settings branch_tax_settings_branch_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.branch_tax_settings
    ADD CONSTRAINT branch_tax_settings_branch_id_fkey FOREIGN KEY (branch_id) REFERENCES public.branches(id) ON DELETE CASCADE;


--
-- Name: branches branches_brand_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.branches
    ADD CONSTRAINT branches_brand_id_fkey FOREIGN KEY (brand_id) REFERENCES public.brands(id) ON DELETE CASCADE;


--
-- Name: brands brands_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.brands
    ADD CONSTRAINT brands_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: cancel_reasons cancel_reasons_brand_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cancel_reasons
    ADD CONSTRAINT cancel_reasons_brand_id_fkey FOREIGN KEY (brand_id) REFERENCES public.brands(id) ON DELETE CASCADE;


--
-- Name: cash_bank_accounts cash_bank_accounts_account_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cash_bank_accounts
    ADD CONSTRAINT cash_bank_accounts_account_id_fkey FOREIGN KEY (account_id) REFERENCES public.accounts(id) ON DELETE RESTRICT;


--
-- Name: cash_bank_accounts cash_bank_accounts_branch_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cash_bank_accounts
    ADD CONSTRAINT cash_bank_accounts_branch_id_fkey FOREIGN KEY (branch_id) REFERENCES public.branches(id) ON DELETE SET NULL;


--
-- Name: cash_bank_accounts cash_bank_accounts_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cash_bank_accounts
    ADD CONSTRAINT cash_bank_accounts_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: categories categories_brand_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.categories
    ADD CONSTRAINT categories_brand_id_fkey FOREIGN KEY (brand_id) REFERENCES public.brands(id) ON DELETE CASCADE;


--
-- Name: cost_centers cost_centers_branch_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cost_centers
    ADD CONSTRAINT cost_centers_branch_id_fkey FOREIGN KEY (branch_id) REFERENCES public.branches(id) ON DELETE SET NULL;


--
-- Name: cost_centers cost_centers_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cost_centers
    ADD CONSTRAINT cost_centers_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: cost_centers cost_centers_parent_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cost_centers
    ADD CONSTRAINT cost_centers_parent_id_fkey FOREIGN KEY (parent_id) REFERENCES public.cost_centers(id) ON DELETE RESTRICT;


--
-- Name: customer_ledger customer_ledger_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_ledger
    ADD CONSTRAINT customer_ledger_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: customer_ledger customer_ledger_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_ledger
    ADD CONSTRAINT customer_ledger_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.staff(id) ON DELETE SET NULL;


--
-- Name: customer_ledger customer_ledger_customer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_ledger
    ADD CONSTRAINT customer_ledger_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES public.customers(id) ON DELETE CASCADE;


--
-- Name: customer_ledger customer_ledger_order_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_ledger
    ADD CONSTRAINT customer_ledger_order_id_fkey FOREIGN KEY (order_id) REFERENCES public.orders(id) ON DELETE SET NULL;


--
-- Name: customers customers_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customers
    ADD CONSTRAINT customers_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: discounts discounts_brand_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.discounts
    ADD CONSTRAINT discounts_brand_id_fkey FOREIGN KEY (brand_id) REFERENCES public.brands(id) ON DELETE CASCADE;


--
-- Name: expenses expenses_branch_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.expenses
    ADD CONSTRAINT expenses_branch_id_fkey FOREIGN KEY (branch_id) REFERENCES public.branches(id) ON DELETE SET NULL;


--
-- Name: expenses expenses_cash_bank_account_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.expenses
    ADD CONSTRAINT expenses_cash_bank_account_id_fkey FOREIGN KEY (cash_bank_account_id) REFERENCES public.cash_bank_accounts(id) ON DELETE SET NULL;


--
-- Name: expenses expenses_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.expenses
    ADD CONSTRAINT expenses_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: expenses expenses_cost_center_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.expenses
    ADD CONSTRAINT expenses_cost_center_id_fkey FOREIGN KEY (cost_center_id) REFERENCES public.cost_centers(id) ON DELETE SET NULL;


--
-- Name: expenses expenses_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.expenses
    ADD CONSTRAINT expenses_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.staff(id) ON DELETE SET NULL;


--
-- Name: expenses expenses_expense_account_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.expenses
    ADD CONSTRAINT expenses_expense_account_id_fkey FOREIGN KEY (expense_account_id) REFERENCES public.accounts(id) ON DELETE RESTRICT;


--
-- Name: fiscal_periods fiscal_periods_closed_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fiscal_periods
    ADD CONSTRAINT fiscal_periods_closed_by_fkey FOREIGN KEY (closed_by) REFERENCES public.staff(id) ON DELETE SET NULL;


--
-- Name: fiscal_periods fiscal_periods_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.fiscal_periods
    ADD CONSTRAINT fiscal_periods_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id);


--
-- Name: order_logs fk_order_logs_staff; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.order_logs
    ADD CONSTRAINT fk_order_logs_staff FOREIGN KEY (user_id) REFERENCES public.staff(id) ON DELETE SET NULL;


--
-- Name: orders fk_orders_customer; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.orders
    ADD CONSTRAINT fk_orders_customer FOREIGN KEY (customer_id) REFERENCES public.customers(id) ON DELETE SET NULL;


--
-- Name: orders fk_orders_waiter; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.orders
    ADD CONSTRAINT fk_orders_waiter FOREIGN KEY (waiter_id) REFERENCES public.staff(id) ON DELETE SET NULL;


--
-- Name: goods_receipt_items goods_receipt_items_goods_receipt_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.goods_receipt_items
    ADD CONSTRAINT goods_receipt_items_goods_receipt_id_fkey FOREIGN KEY (goods_receipt_id) REFERENCES public.goods_receipts(id) ON DELETE CASCADE;


--
-- Name: goods_receipt_items goods_receipt_items_ingredient_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.goods_receipt_items
    ADD CONSTRAINT goods_receipt_items_ingredient_id_fkey FOREIGN KEY (ingredient_id) REFERENCES public.ingredients(id) ON DELETE RESTRICT;


--
-- Name: goods_receipts goods_receipts_purchase_order_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.goods_receipts
    ADD CONSTRAINT goods_receipts_purchase_order_id_fkey FOREIGN KEY (purchase_order_id) REFERENCES public.purchase_orders(id) ON DELETE CASCADE;


--
-- Name: goods_receipts goods_receipts_received_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.goods_receipts
    ADD CONSTRAINT goods_receipts_received_by_fkey FOREIGN KEY (received_by) REFERENCES public.staff(id);


--
-- Name: goods_receipts goods_receipts_warehouse_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.goods_receipts
    ADD CONSTRAINT goods_receipts_warehouse_id_fkey FOREIGN KEY (warehouse_id) REFERENCES public.warehouses(id) ON DELETE CASCADE;


--
-- Name: ingredient_cost_history ingredient_cost_history_ingredient_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ingredient_cost_history
    ADD CONSTRAINT ingredient_cost_history_ingredient_id_fkey FOREIGN KEY (ingredient_id) REFERENCES public.ingredients(id) ON DELETE CASCADE;


--
-- Name: ingredients ingredients_base_unit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ingredients
    ADD CONSTRAINT ingredients_base_unit_id_fkey FOREIGN KEY (base_unit_id) REFERENCES public.units(id);


--
-- Name: ingredients ingredients_brand_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ingredients
    ADD CONSTRAINT ingredients_brand_id_fkey FOREIGN KEY (brand_id) REFERENCES public.brands(id) ON DELETE CASCADE;


--
-- Name: ingredients ingredients_purchase_unit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ingredients
    ADD CONSTRAINT ingredients_purchase_unit_id_fkey FOREIGN KEY (purchase_unit_id) REFERENCES public.units(id);


--
-- Name: ingredients ingredients_recipe_unit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.ingredients
    ADD CONSTRAINT ingredients_recipe_unit_id_fkey FOREIGN KEY (recipe_unit_id) REFERENCES public.units(id);


--
-- Name: journal_entries journal_entries_branch_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.journal_entries
    ADD CONSTRAINT journal_entries_branch_id_fkey FOREIGN KEY (branch_id) REFERENCES public.branches(id) ON DELETE SET NULL;


--
-- Name: journal_entries journal_entries_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.journal_entries
    ADD CONSTRAINT journal_entries_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: journal_entries journal_entries_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.journal_entries
    ADD CONSTRAINT journal_entries_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.staff(id) ON DELETE SET NULL;


--
-- Name: journal_entries journal_entries_posted_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.journal_entries
    ADD CONSTRAINT journal_entries_posted_by_fkey FOREIGN KEY (posted_by) REFERENCES public.staff(id) ON DELETE SET NULL;


--
-- Name: journal_entry_lines journal_entry_lines_account_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.journal_entry_lines
    ADD CONSTRAINT journal_entry_lines_account_id_fkey FOREIGN KEY (account_id) REFERENCES public.accounts(id) ON DELETE RESTRICT;


--
-- Name: journal_entry_lines journal_entry_lines_branch_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.journal_entry_lines
    ADD CONSTRAINT journal_entry_lines_branch_id_fkey FOREIGN KEY (branch_id) REFERENCES public.branches(id) ON DELETE SET NULL;


--
-- Name: journal_entry_lines journal_entry_lines_cost_center_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.journal_entry_lines
    ADD CONSTRAINT journal_entry_lines_cost_center_id_fkey FOREIGN KEY (cost_center_id) REFERENCES public.cost_centers(id) ON DELETE SET NULL;


--
-- Name: journal_entry_lines journal_entry_lines_journal_entry_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.journal_entry_lines
    ADD CONSTRAINT journal_entry_lines_journal_entry_id_fkey FOREIGN KEY (journal_entry_id) REFERENCES public.journal_entries(id) ON DELETE CASCADE;


--
-- Name: modifier_groups modifier_groups_brand_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.modifier_groups
    ADD CONSTRAINT modifier_groups_brand_id_fkey FOREIGN KEY (brand_id) REFERENCES public.brands(id) ON DELETE CASCADE;


--
-- Name: modifiers modifiers_group_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.modifiers
    ADD CONSTRAINT modifiers_group_id_fkey FOREIGN KEY (group_id) REFERENCES public.modifier_groups(id) ON DELETE CASCADE;


--
-- Name: modifiers modifiers_ingredient_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.modifiers
    ADD CONSTRAINT modifiers_ingredient_id_fkey FOREIGN KEY (ingredient_id) REFERENCES public.ingredients(id) ON DELETE SET NULL;


--
-- Name: opening_balances opening_balances_fiscal_period_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.opening_balances
    ADD CONSTRAINT opening_balances_fiscal_period_id_fkey FOREIGN KEY (fiscal_period_id) REFERENCES public.fiscal_periods(id) ON DELETE CASCADE;


--
-- Name: opening_balances opening_balances_ingredient_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.opening_balances
    ADD CONSTRAINT opening_balances_ingredient_id_fkey FOREIGN KEY (ingredient_id) REFERENCES public.ingredients(id) ON DELETE CASCADE;


--
-- Name: opening_balances opening_balances_warehouse_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.opening_balances
    ADD CONSTRAINT opening_balances_warehouse_id_fkey FOREIGN KEY (warehouse_id) REFERENCES public.warehouses(id) ON DELETE CASCADE;


--
-- Name: order_item_modifiers order_item_modifiers_modifier_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.order_item_modifiers
    ADD CONSTRAINT order_item_modifiers_modifier_id_fkey FOREIGN KEY (modifier_id) REFERENCES public.modifiers(id) ON DELETE RESTRICT;


--
-- Name: order_item_modifiers order_item_modifiers_order_item_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.order_item_modifiers
    ADD CONSTRAINT order_item_modifiers_order_item_id_fkey FOREIGN KEY (order_item_id) REFERENCES public.order_items(id) ON DELETE CASCADE;


--
-- Name: order_items order_items_order_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.order_items
    ADD CONSTRAINT order_items_order_id_fkey FOREIGN KEY (order_id) REFERENCES public.orders(id) ON DELETE CASCADE;


--
-- Name: order_items order_items_product_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.order_items
    ADD CONSTRAINT order_items_product_id_fkey FOREIGN KEY (product_id) REFERENCES public.products(id) ON DELETE RESTRICT;


--
-- Name: order_items order_items_void_reason_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.order_items
    ADD CONSTRAINT order_items_void_reason_id_fkey FOREIGN KEY (void_reason_id) REFERENCES public.cancel_reasons(id) ON DELETE SET NULL;


--
-- Name: order_logs order_logs_order_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.order_logs
    ADD CONSTRAINT order_logs_order_id_fkey FOREIGN KEY (order_id) REFERENCES public.orders(id) ON DELETE CASCADE;


--
-- Name: order_sequences order_sequences_branch_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.order_sequences
    ADD CONSTRAINT order_sequences_branch_id_fkey FOREIGN KEY (branch_id) REFERENCES public.branches(id) ON DELETE CASCADE;


--
-- Name: order_split_items order_split_items_order_item_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.order_split_items
    ADD CONSTRAINT order_split_items_order_item_id_fkey FOREIGN KEY (order_item_id) REFERENCES public.order_items(id) ON DELETE CASCADE;


--
-- Name: order_split_items order_split_items_split_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.order_split_items
    ADD CONSTRAINT order_split_items_split_id_fkey FOREIGN KEY (split_id) REFERENCES public.order_splits(id) ON DELETE CASCADE;


--
-- Name: order_splits order_splits_order_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.order_splits
    ADD CONSTRAINT order_splits_order_id_fkey FOREIGN KEY (order_id) REFERENCES public.orders(id) ON DELETE CASCADE;


--
-- Name: orders orders_area_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.orders
    ADD CONSTRAINT orders_area_id_fkey FOREIGN KEY (area_id) REFERENCES public.areas(id);


--
-- Name: orders orders_branch_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.orders
    ADD CONSTRAINT orders_branch_id_fkey FOREIGN KEY (branch_id) REFERENCES public.branches(id);


--
-- Name: orders orders_brand_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.orders
    ADD CONSTRAINT orders_brand_id_fkey FOREIGN KEY (brand_id) REFERENCES public.brands(id);


--
-- Name: orders orders_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.orders
    ADD CONSTRAINT orders_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id);


--
-- Name: orders orders_table_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.orders
    ADD CONSTRAINT orders_table_id_fkey FOREIGN KEY (table_id) REFERENCES public.tables(id);


--
-- Name: payment_method_account_mappings payment_method_account_mappings_account_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payment_method_account_mappings
    ADD CONSTRAINT payment_method_account_mappings_account_id_fkey FOREIGN KEY (account_id) REFERENCES public.accounts(id) ON DELETE RESTRICT;


--
-- Name: payment_method_account_mappings payment_method_account_mappings_cash_bank_account_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payment_method_account_mappings
    ADD CONSTRAINT payment_method_account_mappings_cash_bank_account_id_fkey FOREIGN KEY (cash_bank_account_id) REFERENCES public.cash_bank_accounts(id) ON DELETE SET NULL;


--
-- Name: payment_method_account_mappings payment_method_account_mappings_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payment_method_account_mappings
    ADD CONSTRAINT payment_method_account_mappings_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: payments payments_order_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payments
    ADD CONSTRAINT payments_order_id_fkey FOREIGN KEY (order_id) REFERENCES public.orders(id) ON DELETE CASCADE;


--
-- Name: payments payments_split_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payments
    ADD CONSTRAINT payments_split_id_fkey FOREIGN KEY (split_id) REFERENCES public.order_splits(id) ON DELETE CASCADE;


--
-- Name: payments payments_tip_staff_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payments
    ADD CONSTRAINT payments_tip_staff_id_fkey FOREIGN KEY (tip_staff_id) REFERENCES public.staff(id);


--
-- Name: product_modifier_groups product_modifier_groups_group_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_modifier_groups
    ADD CONSTRAINT product_modifier_groups_group_id_fkey FOREIGN KEY (group_id) REFERENCES public.modifier_groups(id) ON DELETE CASCADE;


--
-- Name: product_modifier_groups product_modifier_groups_product_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_modifier_groups
    ADD CONSTRAINT product_modifier_groups_product_id_fkey FOREIGN KEY (product_id) REFERENCES public.products(id) ON DELETE CASCADE;


--
-- Name: products products_brand_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.products
    ADD CONSTRAINT products_brand_id_fkey FOREIGN KEY (brand_id) REFERENCES public.brands(id) ON DELETE CASCADE;


--
-- Name: products products_category_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.products
    ADD CONSTRAINT products_category_id_fkey FOREIGN KEY (category_id) REFERENCES public.categories(id) ON DELETE SET NULL;


--
-- Name: purchase_order_items purchase_order_items_ingredient_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.purchase_order_items
    ADD CONSTRAINT purchase_order_items_ingredient_id_fkey FOREIGN KEY (ingredient_id) REFERENCES public.ingredients(id) ON DELETE RESTRICT;


--
-- Name: purchase_order_items purchase_order_items_purchase_order_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.purchase_order_items
    ADD CONSTRAINT purchase_order_items_purchase_order_id_fkey FOREIGN KEY (purchase_order_id) REFERENCES public.purchase_orders(id) ON DELETE CASCADE;


--
-- Name: purchase_orders purchase_orders_approved_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.purchase_orders
    ADD CONSTRAINT purchase_orders_approved_by_fkey FOREIGN KEY (approved_by) REFERENCES public.staff(id);


--
-- Name: purchase_orders purchase_orders_supplier_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.purchase_orders
    ADD CONSTRAINT purchase_orders_supplier_id_fkey FOREIGN KEY (supplier_id) REFERENCES public.suppliers(id) ON DELETE SET NULL;


--
-- Name: purchase_orders purchase_orders_warehouse_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.purchase_orders
    ADD CONSTRAINT purchase_orders_warehouse_id_fkey FOREIGN KEY (warehouse_id) REFERENCES public.warehouses(id) ON DELETE CASCADE;


--
-- Name: recipes recipes_ingredient_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recipes
    ADD CONSTRAINT recipes_ingredient_id_fkey FOREIGN KEY (ingredient_id) REFERENCES public.ingredients(id) ON DELETE CASCADE;


--
-- Name: recipes recipes_product_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.recipes
    ADD CONSTRAINT recipes_product_id_fkey FOREIGN KEY (product_id) REFERENCES public.products(id) ON DELETE CASCADE;


--
-- Name: staff staff_branch_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.staff
    ADD CONSTRAINT staff_branch_id_fkey FOREIGN KEY (branch_id) REFERENCES public.branches(id) ON DELETE SET NULL;


--
-- Name: staff staff_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.staff
    ADD CONSTRAINT staff_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id) ON DELETE CASCADE;


--
-- Name: staff staff_role_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.staff
    ADD CONSTRAINT staff_role_id_fkey FOREIGN KEY (role_id) REFERENCES public.roles(id);


--
-- Name: stock_adjustments stock_adjustments_approved_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stock_adjustments
    ADD CONSTRAINT stock_adjustments_approved_by_fkey FOREIGN KEY (approved_by) REFERENCES public.staff(id);


--
-- Name: stock_adjustments stock_adjustments_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stock_adjustments
    ADD CONSTRAINT stock_adjustments_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.staff(id);


--
-- Name: stock_adjustments stock_adjustments_ingredient_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stock_adjustments
    ADD CONSTRAINT stock_adjustments_ingredient_id_fkey FOREIGN KEY (ingredient_id) REFERENCES public.ingredients(id) ON DELETE CASCADE;


--
-- Name: stock_adjustments stock_adjustments_reason_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stock_adjustments
    ADD CONSTRAINT stock_adjustments_reason_id_fkey FOREIGN KEY (reason_id) REFERENCES public.adjustment_reasons(id);


--
-- Name: stock_adjustments stock_adjustments_warehouse_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stock_adjustments
    ADD CONSTRAINT stock_adjustments_warehouse_id_fkey FOREIGN KEY (warehouse_id) REFERENCES public.warehouses(id) ON DELETE CASCADE;


--
-- Name: stock_movements stock_movements_branch_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stock_movements
    ADD CONSTRAINT stock_movements_branch_id_fkey FOREIGN KEY (branch_id) REFERENCES public.branches(id) ON DELETE SET NULL;


--
-- Name: stock_movements stock_movements_brand_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stock_movements
    ADD CONSTRAINT stock_movements_brand_id_fkey FOREIGN KEY (brand_id) REFERENCES public.brands(id);


--
-- Name: stock_movements stock_movements_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stock_movements
    ADD CONSTRAINT stock_movements_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id);


--
-- Name: stock_movements stock_movements_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stock_movements
    ADD CONSTRAINT stock_movements_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.staff(id) ON DELETE SET NULL;


--
-- Name: stock_movements stock_movements_ingredient_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stock_movements
    ADD CONSTRAINT stock_movements_ingredient_id_fkey FOREIGN KEY (ingredient_id) REFERENCES public.ingredients(id) ON DELETE RESTRICT;


--
-- Name: stock_movements stock_movements_warehouse_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stock_movements
    ADD CONSTRAINT stock_movements_warehouse_id_fkey FOREIGN KEY (warehouse_id) REFERENCES public.warehouses(id) ON DELETE CASCADE;


--
-- Name: stock_takes stock_takes_ingredient_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stock_takes
    ADD CONSTRAINT stock_takes_ingredient_id_fkey FOREIGN KEY (ingredient_id) REFERENCES public.ingredients(id) ON DELETE CASCADE;


--
-- Name: stock_takes stock_takes_warehouse_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stock_takes
    ADD CONSTRAINT stock_takes_warehouse_id_fkey FOREIGN KEY (warehouse_id) REFERENCES public.warehouses(id) ON DELETE CASCADE;


--
-- Name: stock_transfers stock_transfers_from_warehouse_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stock_transfers
    ADD CONSTRAINT stock_transfers_from_warehouse_id_fkey FOREIGN KEY (from_warehouse_id) REFERENCES public.warehouses(id);


--
-- Name: stock_transfers stock_transfers_ingredient_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stock_transfers
    ADD CONSTRAINT stock_transfers_ingredient_id_fkey FOREIGN KEY (ingredient_id) REFERENCES public.ingredients(id);


--
-- Name: stock_transfers stock_transfers_to_warehouse_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.stock_transfers
    ADD CONSTRAINT stock_transfers_to_warehouse_id_fkey FOREIGN KEY (to_warehouse_id) REFERENCES public.warehouses(id);


--
-- Name: supplier_payments supplier_payments_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.supplier_payments
    ADD CONSTRAINT supplier_payments_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id);


--
-- Name: supplier_payments supplier_payments_paid_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.supplier_payments
    ADD CONSTRAINT supplier_payments_paid_by_fkey FOREIGN KEY (paid_by) REFERENCES public.staff(id) ON DELETE SET NULL;


--
-- Name: supplier_payments supplier_payments_purchase_order_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.supplier_payments
    ADD CONSTRAINT supplier_payments_purchase_order_id_fkey FOREIGN KEY (purchase_order_id) REFERENCES public.purchase_orders(id) ON DELETE SET NULL;


--
-- Name: supplier_payments supplier_payments_supplier_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.supplier_payments
    ADD CONSTRAINT supplier_payments_supplier_id_fkey FOREIGN KEY (supplier_id) REFERENCES public.suppliers(id) ON DELETE CASCADE;


--
-- Name: supplier_prices supplier_prices_ingredient_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.supplier_prices
    ADD CONSTRAINT supplier_prices_ingredient_id_fkey FOREIGN KEY (ingredient_id) REFERENCES public.ingredients(id) ON DELETE CASCADE;


--
-- Name: supplier_prices supplier_prices_supplier_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.supplier_prices
    ADD CONSTRAINT supplier_prices_supplier_id_fkey FOREIGN KEY (supplier_id) REFERENCES public.suppliers(id) ON DELETE CASCADE;


--
-- Name: tables tables_area_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tables
    ADD CONSTRAINT tables_area_id_fkey FOREIGN KEY (area_id) REFERENCES public.areas(id) ON DELETE CASCADE;


--
-- Name: unit_conversions unit_conversions_from_unit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.unit_conversions
    ADD CONSTRAINT unit_conversions_from_unit_id_fkey FOREIGN KEY (from_unit_id) REFERENCES public.units(id) ON DELETE CASCADE;


--
-- Name: unit_conversions unit_conversions_to_unit_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.unit_conversions
    ADD CONSTRAINT unit_conversions_to_unit_id_fkey FOREIGN KEY (to_unit_id) REFERENCES public.units(id) ON DELETE CASCADE;


--
-- Name: variance_investigations variance_investigations_approved_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.variance_investigations
    ADD CONSTRAINT variance_investigations_approved_by_fkey FOREIGN KEY (approved_by) REFERENCES public.staff(id);


--
-- Name: variance_investigations variance_investigations_ingredient_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.variance_investigations
    ADD CONSTRAINT variance_investigations_ingredient_id_fkey FOREIGN KEY (ingredient_id) REFERENCES public.ingredients(id) ON DELETE CASCADE;


--
-- Name: variance_investigations variance_investigations_investigated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.variance_investigations
    ADD CONSTRAINT variance_investigations_investigated_by_fkey FOREIGN KEY (investigated_by) REFERENCES public.staff(id);


--
-- Name: variance_investigations variance_investigations_warehouse_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.variance_investigations
    ADD CONSTRAINT variance_investigations_warehouse_id_fkey FOREIGN KEY (warehouse_id) REFERENCES public.warehouses(id) ON DELETE CASCADE;


--
-- Name: warehouse_stock warehouse_stock_ingredient_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.warehouse_stock
    ADD CONSTRAINT warehouse_stock_ingredient_id_fkey FOREIGN KEY (ingredient_id) REFERENCES public.ingredients(id) ON DELETE CASCADE;


--
-- Name: warehouse_stock warehouse_stock_warehouse_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.warehouse_stock
    ADD CONSTRAINT warehouse_stock_warehouse_id_fkey FOREIGN KEY (warehouse_id) REFERENCES public.warehouses(id) ON DELETE CASCADE;


--
-- Name: warehouses warehouses_branch_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.warehouses
    ADD CONSTRAINT warehouses_branch_id_fkey FOREIGN KEY (branch_id) REFERENCES public.branches(id) ON DELETE SET NULL;


--
-- Name: waste_logs waste_logs_ingredient_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.waste_logs
    ADD CONSTRAINT waste_logs_ingredient_id_fkey FOREIGN KEY (ingredient_id) REFERENCES public.ingredients(id) ON DELETE CASCADE;


--
-- Name: waste_logs waste_logs_warehouse_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.waste_logs
    ADD CONSTRAINT waste_logs_warehouse_id_fkey FOREIGN KEY (warehouse_id) REFERENCES public.warehouses(id) ON DELETE CASCADE;


--
-- Name: accounts; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.accounts ENABLE ROW LEVEL SECURITY;

--
-- Name: accounts company_accounts_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY company_accounts_isolation ON public.accounts USING (((company_id = 'c0000000-0000-0000-0000-000000000000'::uuid) OR (company_id IS NULL)));


--
-- Name: journal_entries company_journals_isolation; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY company_journals_isolation ON public.journal_entries USING (((company_id = 'c0000000-0000-0000-0000-000000000000'::uuid) OR (company_id IS NULL)));


--
-- Name: journal_entries; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.journal_entries ENABLE ROW LEVEL SECURITY;

--
-- Name: journal_entry_lines; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.journal_entry_lines ENABLE ROW LEVEL SECURITY;

--
-- Name: SCHEMA public; Type: ACL; Schema: -; Owner: -
--

GRANT USAGE ON SCHEMA public TO postgres;
GRANT USAGE ON SCHEMA public TO anon;
GRANT USAGE ON SCHEMA public TO authenticated;
GRANT USAGE ON SCHEMA public TO service_role;


--
-- Name: FUNCTION adjust_stock(p_warehouse_id uuid, p_ingredient_id uuid, p_quantity numeric, p_adjustment_type text, p_reason_id uuid, p_notes text, p_user_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.adjust_stock(p_warehouse_id uuid, p_ingredient_id uuid, p_quantity numeric, p_adjustment_type text, p_reason_id uuid, p_notes text, p_user_id uuid) TO anon;
GRANT ALL ON FUNCTION public.adjust_stock(p_warehouse_id uuid, p_ingredient_id uuid, p_quantity numeric, p_adjustment_type text, p_reason_id uuid, p_notes text, p_user_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.adjust_stock(p_warehouse_id uuid, p_ingredient_id uuid, p_quantity numeric, p_adjustment_type text, p_reason_id uuid, p_notes text, p_user_id uuid) TO service_role;


--
-- Name: FUNCTION close_fiscal_period(p_company_id uuid, p_period_id uuid, p_user_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.close_fiscal_period(p_company_id uuid, p_period_id uuid, p_user_id uuid) TO anon;
GRANT ALL ON FUNCTION public.close_fiscal_period(p_company_id uuid, p_period_id uuid, p_user_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.close_fiscal_period(p_company_id uuid, p_period_id uuid, p_user_id uuid) TO service_role;


--
-- Name: FUNCTION convert_quantity(p_quantity numeric, p_from_unit_id uuid, p_to_unit_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.convert_quantity(p_quantity numeric, p_from_unit_id uuid, p_to_unit_id uuid) TO anon;
GRANT ALL ON FUNCTION public.convert_quantity(p_quantity numeric, p_from_unit_id uuid, p_to_unit_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.convert_quantity(p_quantity numeric, p_from_unit_id uuid, p_to_unit_id uuid) TO service_role;


--
-- Name: FUNCTION create_journal_entry(p_company_id uuid, p_branch_id uuid, p_entry_date date, p_journal_type text, p_reference_type text, p_reference_id uuid, p_description text, p_lines jsonb, p_auto_post boolean, p_user_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.create_journal_entry(p_company_id uuid, p_branch_id uuid, p_entry_date date, p_journal_type text, p_reference_type text, p_reference_id uuid, p_description text, p_lines jsonb, p_auto_post boolean, p_user_id uuid) TO anon;
GRANT ALL ON FUNCTION public.create_journal_entry(p_company_id uuid, p_branch_id uuid, p_entry_date date, p_journal_type text, p_reference_type text, p_reference_id uuid, p_description text, p_lines jsonb, p_auto_post boolean, p_user_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.create_journal_entry(p_company_id uuid, p_branch_id uuid, p_entry_date date, p_journal_type text, p_reference_type text, p_reference_id uuid, p_description text, p_lines jsonb, p_auto_post boolean, p_user_id uuid) TO service_role;


--
-- Name: FUNCTION deduct_recipe_on_sale(p_warehouse_id uuid, p_product_id uuid, p_quantity_sold integer); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.deduct_recipe_on_sale(p_warehouse_id uuid, p_product_id uuid, p_quantity_sold integer) TO anon;
GRANT ALL ON FUNCTION public.deduct_recipe_on_sale(p_warehouse_id uuid, p_product_id uuid, p_quantity_sold integer) TO authenticated;
GRANT ALL ON FUNCTION public.deduct_recipe_on_sale(p_warehouse_id uuid, p_product_id uuid, p_quantity_sold integer) TO service_role;


--
-- Name: FUNCTION execute_stock_transfer(p_from_warehouse uuid, p_to_warehouse uuid, p_ingredient uuid, p_quantity numeric); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.execute_stock_transfer(p_from_warehouse uuid, p_to_warehouse uuid, p_ingredient uuid, p_quantity numeric) TO anon;
GRANT ALL ON FUNCTION public.execute_stock_transfer(p_from_warehouse uuid, p_to_warehouse uuid, p_ingredient uuid, p_quantity numeric) TO authenticated;
GRANT ALL ON FUNCTION public.execute_stock_transfer(p_from_warehouse uuid, p_to_warehouse uuid, p_ingredient uuid, p_quantity numeric) TO service_role;


--
-- Name: FUNCTION generate_journal_entry_number(p_company_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.generate_journal_entry_number(p_company_id uuid) TO anon;
GRANT ALL ON FUNCTION public.generate_journal_entry_number(p_company_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.generate_journal_entry_number(p_company_id uuid) TO service_role;


--
-- Name: FUNCTION generate_order_number(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.generate_order_number() TO anon;
GRANT ALL ON FUNCTION public.generate_order_number() TO authenticated;
GRANT ALL ON FUNCTION public.generate_order_number() TO service_role;


--
-- Name: FUNCTION get_account_for_payment_method(p_company_id uuid, p_payment_method text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.get_account_for_payment_method(p_company_id uuid, p_payment_method text) TO anon;
GRANT ALL ON FUNCTION public.get_account_for_payment_method(p_company_id uuid, p_payment_method text) TO authenticated;
GRANT ALL ON FUNCTION public.get_account_for_payment_method(p_company_id uuid, p_payment_method text) TO service_role;


--
-- Name: FUNCTION get_balance_sheet(p_company_id uuid, p_as_of_date date, p_branch_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.get_balance_sheet(p_company_id uuid, p_as_of_date date, p_branch_id uuid) TO anon;
GRANT ALL ON FUNCTION public.get_balance_sheet(p_company_id uuid, p_as_of_date date, p_branch_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.get_balance_sheet(p_company_id uuid, p_as_of_date date, p_branch_id uuid) TO service_role;


--
-- Name: FUNCTION get_customer_statement(p_customer_id uuid, p_start_date date, p_end_date date); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.get_customer_statement(p_customer_id uuid, p_start_date date, p_end_date date) TO anon;
GRANT ALL ON FUNCTION public.get_customer_statement(p_customer_id uuid, p_start_date date, p_end_date date) TO authenticated;
GRANT ALL ON FUNCTION public.get_customer_statement(p_customer_id uuid, p_start_date date, p_end_date date) TO service_role;


--
-- Name: FUNCTION get_financial_summary(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.get_financial_summary() TO anon;
GRANT ALL ON FUNCTION public.get_financial_summary() TO authenticated;
GRANT ALL ON FUNCTION public.get_financial_summary() TO service_role;


--
-- Name: FUNCTION get_general_ledger(p_company_id uuid, p_account_id uuid, p_start_date date, p_end_date date, p_branch_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.get_general_ledger(p_company_id uuid, p_account_id uuid, p_start_date date, p_end_date date, p_branch_id uuid) TO anon;
GRANT ALL ON FUNCTION public.get_general_ledger(p_company_id uuid, p_account_id uuid, p_start_date date, p_end_date date, p_branch_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.get_general_ledger(p_company_id uuid, p_account_id uuid, p_start_date date, p_end_date date, p_branch_id uuid) TO service_role;


--
-- Name: FUNCTION get_low_stock_alerts(p_warehouse_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.get_low_stock_alerts(p_warehouse_id uuid) TO anon;
GRANT ALL ON FUNCTION public.get_low_stock_alerts(p_warehouse_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.get_low_stock_alerts(p_warehouse_id uuid) TO service_role;


--
-- Name: FUNCTION get_profit_and_loss_from_gl(p_company_id uuid, p_start_date date, p_end_date date, p_branch_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.get_profit_and_loss_from_gl(p_company_id uuid, p_start_date date, p_end_date date, p_branch_id uuid) TO anon;
GRANT ALL ON FUNCTION public.get_profit_and_loss_from_gl(p_company_id uuid, p_start_date date, p_end_date date, p_branch_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.get_profit_and_loss_from_gl(p_company_id uuid, p_start_date date, p_end_date date, p_branch_id uuid) TO service_role;


--
-- Name: FUNCTION get_theoretical_vs_actual_consumption(p_warehouse_id uuid, p_start_date timestamp with time zone, p_end_date timestamp with time zone); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.get_theoretical_vs_actual_consumption(p_warehouse_id uuid, p_start_date timestamp with time zone, p_end_date timestamp with time zone) TO anon;
GRANT ALL ON FUNCTION public.get_theoretical_vs_actual_consumption(p_warehouse_id uuid, p_start_date timestamp with time zone, p_end_date timestamp with time zone) TO authenticated;
GRANT ALL ON FUNCTION public.get_theoretical_vs_actual_consumption(p_warehouse_id uuid, p_start_date timestamp with time zone, p_end_date timestamp with time zone) TO service_role;


--
-- Name: FUNCTION get_trial_balance(p_company_id uuid, p_start_date date, p_end_date date, p_branch_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.get_trial_balance(p_company_id uuid, p_start_date date, p_end_date date, p_branch_id uuid) TO anon;
GRANT ALL ON FUNCTION public.get_trial_balance(p_company_id uuid, p_start_date date, p_end_date date, p_branch_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.get_trial_balance(p_company_id uuid, p_start_date date, p_end_date date, p_branch_id uuid) TO service_role;


--
-- Name: FUNCTION log_waste(p_warehouse_id uuid, p_ingredient_id uuid, p_quantity numeric, p_reason text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.log_waste(p_warehouse_id uuid, p_ingredient_id uuid, p_quantity numeric, p_reason text) TO anon;
GRANT ALL ON FUNCTION public.log_waste(p_warehouse_id uuid, p_ingredient_id uuid, p_quantity numeric, p_reason text) TO authenticated;
GRANT ALL ON FUNCTION public.log_waste(p_warehouse_id uuid, p_ingredient_id uuid, p_quantity numeric, p_reason text) TO service_role;


--
-- Name: FUNCTION merge_orders(p_source_order_id uuid, p_target_order_id uuid, p_user_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.merge_orders(p_source_order_id uuid, p_target_order_id uuid, p_user_id uuid) TO anon;
GRANT ALL ON FUNCTION public.merge_orders(p_source_order_id uuid, p_target_order_id uuid, p_user_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.merge_orders(p_source_order_id uuid, p_target_order_id uuid, p_user_id uuid) TO service_role;


--
-- Name: FUNCTION pay_supplier(p_supplier_id uuid, p_amount numeric, p_payment_method text, p_purchase_order_id uuid, p_reference_number text, p_notes text, p_user_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.pay_supplier(p_supplier_id uuid, p_amount numeric, p_payment_method text, p_purchase_order_id uuid, p_reference_number text, p_notes text, p_user_id uuid) TO anon;
GRANT ALL ON FUNCTION public.pay_supplier(p_supplier_id uuid, p_amount numeric, p_payment_method text, p_purchase_order_id uuid, p_reference_number text, p_notes text, p_user_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.pay_supplier(p_supplier_id uuid, p_amount numeric, p_payment_method text, p_purchase_order_id uuid, p_reference_number text, p_notes text, p_user_id uuid) TO service_role;


--
-- Name: FUNCTION post_order_to_gl(p_order_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.post_order_to_gl(p_order_id uuid) TO anon;
GRANT ALL ON FUNCTION public.post_order_to_gl(p_order_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.post_order_to_gl(p_order_id uuid) TO service_role;


--
-- Name: FUNCTION prevent_posted_journal_deletion(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.prevent_posted_journal_deletion() TO anon;
GRANT ALL ON FUNCTION public.prevent_posted_journal_deletion() TO authenticated;
GRANT ALL ON FUNCTION public.prevent_posted_journal_deletion() TO service_role;


--
-- Name: FUNCTION process_purchase_item(p_warehouse_id uuid, p_ingredient_id uuid, p_quantity numeric, p_unit_price numeric); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.process_purchase_item(p_warehouse_id uuid, p_ingredient_id uuid, p_quantity numeric, p_unit_price numeric) TO anon;
GRANT ALL ON FUNCTION public.process_purchase_item(p_warehouse_id uuid, p_ingredient_id uuid, p_quantity numeric, p_unit_price numeric) TO authenticated;
GRANT ALL ON FUNCTION public.process_purchase_item(p_warehouse_id uuid, p_ingredient_id uuid, p_quantity numeric, p_unit_price numeric) TO service_role;


--
-- Name: FUNCTION receive_customer_payment(p_company_id uuid, p_branch_id uuid, p_customer_id uuid, p_amount numeric, p_payment_method text, p_reference_number text, p_notes text, p_user_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.receive_customer_payment(p_company_id uuid, p_branch_id uuid, p_customer_id uuid, p_amount numeric, p_payment_method text, p_reference_number text, p_notes text, p_user_id uuid) TO anon;
GRANT ALL ON FUNCTION public.receive_customer_payment(p_company_id uuid, p_branch_id uuid, p_customer_id uuid, p_amount numeric, p_payment_method text, p_reference_number text, p_notes text, p_user_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.receive_customer_payment(p_company_id uuid, p_branch_id uuid, p_customer_id uuid, p_amount numeric, p_payment_method text, p_reference_number text, p_notes text, p_user_id uuid) TO service_role;


--
-- Name: FUNCTION receive_goods_receipt(p_purchase_order_id uuid, p_warehouse_id uuid, p_grn_number text, p_items jsonb, p_received_by uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.receive_goods_receipt(p_purchase_order_id uuid, p_warehouse_id uuid, p_grn_number text, p_items jsonb, p_received_by uuid) TO anon;
GRANT ALL ON FUNCTION public.receive_goods_receipt(p_purchase_order_id uuid, p_warehouse_id uuid, p_grn_number text, p_items jsonb, p_received_by uuid) TO authenticated;
GRANT ALL ON FUNCTION public.receive_goods_receipt(p_purchase_order_id uuid, p_warehouse_id uuid, p_grn_number text, p_items jsonb, p_received_by uuid) TO service_role;


--
-- Name: FUNCTION record_expense(p_company_id uuid, p_branch_id uuid, p_expense_account_id uuid, p_amount numeric, p_payment_method text, p_description text, p_reference_number text, p_vendor_name text, p_user_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.record_expense(p_company_id uuid, p_branch_id uuid, p_expense_account_id uuid, p_amount numeric, p_payment_method text, p_description text, p_reference_number text, p_vendor_name text, p_user_id uuid) TO anon;
GRANT ALL ON FUNCTION public.record_expense(p_company_id uuid, p_branch_id uuid, p_expense_account_id uuid, p_amount numeric, p_payment_method text, p_description text, p_reference_number text, p_vendor_name text, p_user_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.record_expense(p_company_id uuid, p_branch_id uuid, p_expense_account_id uuid, p_amount numeric, p_payment_method text, p_description text, p_reference_number text, p_vendor_name text, p_user_id uuid) TO service_role;


--
-- Name: FUNCTION record_stock_movement(p_company_id uuid, p_brand_id uuid, p_branch_id uuid, p_warehouse_id uuid, p_ingredient_id uuid, p_movement_type text, p_quantity numeric, p_unit_cost numeric, p_reference_type text, p_reference_id uuid, p_notes text, p_created_by uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.record_stock_movement(p_company_id uuid, p_brand_id uuid, p_branch_id uuid, p_warehouse_id uuid, p_ingredient_id uuid, p_movement_type text, p_quantity numeric, p_unit_cost numeric, p_reference_type text, p_reference_id uuid, p_notes text, p_created_by uuid) TO anon;
GRANT ALL ON FUNCTION public.record_stock_movement(p_company_id uuid, p_brand_id uuid, p_branch_id uuid, p_warehouse_id uuid, p_ingredient_id uuid, p_movement_type text, p_quantity numeric, p_unit_cost numeric, p_reference_type text, p_reference_id uuid, p_notes text, p_created_by uuid) TO authenticated;
GRANT ALL ON FUNCTION public.record_stock_movement(p_company_id uuid, p_brand_id uuid, p_branch_id uuid, p_warehouse_id uuid, p_ingredient_id uuid, p_movement_type text, p_quantity numeric, p_unit_cost numeric, p_reference_type text, p_reference_id uuid, p_notes text, p_created_by uuid) TO service_role;


--
-- Name: FUNCTION record_stock_take(p_warehouse_id uuid, p_ingredient_id uuid, p_actual_qty numeric); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.record_stock_take(p_warehouse_id uuid, p_ingredient_id uuid, p_actual_qty numeric) TO anon;
GRANT ALL ON FUNCTION public.record_stock_take(p_warehouse_id uuid, p_ingredient_id uuid, p_actual_qty numeric) TO authenticated;
GRANT ALL ON FUNCTION public.record_stock_take(p_warehouse_id uuid, p_ingredient_id uuid, p_actual_qty numeric) TO service_role;


--
-- Name: FUNCTION reverse_journal_entry(p_company_id uuid, p_journal_entry_id uuid, p_reversal_reason text, p_user_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.reverse_journal_entry(p_company_id uuid, p_journal_entry_id uuid, p_reversal_reason text, p_user_id uuid) TO anon;
GRANT ALL ON FUNCTION public.reverse_journal_entry(p_company_id uuid, p_journal_entry_id uuid, p_reversal_reason text, p_user_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.reverse_journal_entry(p_company_id uuid, p_journal_entry_id uuid, p_reversal_reason text, p_user_id uuid) TO service_role;


--
-- Name: FUNCTION secure_adjust_tip(p_payment_id uuid, p_new_tip numeric, p_manager_pin text, p_branch_id uuid, p_reason text); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.secure_adjust_tip(p_payment_id uuid, p_new_tip numeric, p_manager_pin text, p_branch_id uuid, p_reason text) TO anon;
GRANT ALL ON FUNCTION public.secure_adjust_tip(p_payment_id uuid, p_new_tip numeric, p_manager_pin text, p_branch_id uuid, p_reason text) TO authenticated;
GRANT ALL ON FUNCTION public.secure_adjust_tip(p_payment_id uuid, p_new_tip numeric, p_manager_pin text, p_branch_id uuid, p_reason text) TO service_role;


--
-- Name: FUNCTION transfer_table_order(p_order_id uuid, p_new_table_id uuid, p_user_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.transfer_table_order(p_order_id uuid, p_new_table_id uuid, p_user_id uuid) TO anon;
GRANT ALL ON FUNCTION public.transfer_table_order(p_order_id uuid, p_new_table_id uuid, p_user_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.transfer_table_order(p_order_id uuid, p_new_table_id uuid, p_user_id uuid) TO service_role;


--
-- Name: FUNCTION update_order_financials(p_order_id uuid, p_sub_total numeric, p_tax_amount numeric, p_service_amount numeric, p_discount_amount numeric, p_total_amount numeric); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.update_order_financials(p_order_id uuid, p_sub_total numeric, p_tax_amount numeric, p_service_amount numeric, p_discount_amount numeric, p_total_amount numeric) TO anon;
GRANT ALL ON FUNCTION public.update_order_financials(p_order_id uuid, p_sub_total numeric, p_tax_amount numeric, p_service_amount numeric, p_discount_amount numeric, p_total_amount numeric) TO authenticated;
GRANT ALL ON FUNCTION public.update_order_financials(p_order_id uuid, p_sub_total numeric, p_tax_amount numeric, p_service_amount numeric, p_discount_amount numeric, p_total_amount numeric) TO service_role;


--
-- Name: FUNCTION validate_journal_entry_period(); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.validate_journal_entry_period() TO anon;
GRANT ALL ON FUNCTION public.validate_journal_entry_period() TO authenticated;
GRANT ALL ON FUNCTION public.validate_journal_entry_period() TO service_role;


--
-- Name: FUNCTION verify_manager_pin(p_pin text, p_branch_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.verify_manager_pin(p_pin text, p_branch_id uuid) TO anon;
GRANT ALL ON FUNCTION public.verify_manager_pin(p_pin text, p_branch_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.verify_manager_pin(p_pin text, p_branch_id uuid) TO service_role;


--
-- Name: FUNCTION void_order_item(p_order_item_id uuid, p_reason_id uuid, p_user_id uuid, p_warehouse_id uuid); Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON FUNCTION public.void_order_item(p_order_item_id uuid, p_reason_id uuid, p_user_id uuid, p_warehouse_id uuid) TO anon;
GRANT ALL ON FUNCTION public.void_order_item(p_order_item_id uuid, p_reason_id uuid, p_user_id uuid, p_warehouse_id uuid) TO authenticated;
GRANT ALL ON FUNCTION public.void_order_item(p_order_item_id uuid, p_reason_id uuid, p_user_id uuid, p_warehouse_id uuid) TO service_role;


--
-- Name: TABLE accounting_audit_logs; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.accounting_audit_logs TO anon;
GRANT ALL ON TABLE public.accounting_audit_logs TO authenticated;
GRANT ALL ON TABLE public.accounting_audit_logs TO service_role;


--
-- Name: TABLE accounts; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.accounts TO anon;
GRANT ALL ON TABLE public.accounts TO authenticated;
GRANT ALL ON TABLE public.accounts TO service_role;


--
-- Name: TABLE adjustment_reasons; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.adjustment_reasons TO anon;
GRANT ALL ON TABLE public.adjustment_reasons TO authenticated;
GRANT ALL ON TABLE public.adjustment_reasons TO service_role;


--
-- Name: TABLE areas; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.areas TO anon;
GRANT ALL ON TABLE public.areas TO authenticated;
GRANT ALL ON TABLE public.areas TO service_role;


--
-- Name: TABLE branch_tax_settings; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.branch_tax_settings TO anon;
GRANT ALL ON TABLE public.branch_tax_settings TO authenticated;
GRANT ALL ON TABLE public.branch_tax_settings TO service_role;


--
-- Name: TABLE branches; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.branches TO anon;
GRANT ALL ON TABLE public.branches TO authenticated;
GRANT ALL ON TABLE public.branches TO service_role;


--
-- Name: TABLE brands; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.brands TO anon;
GRANT ALL ON TABLE public.brands TO authenticated;
GRANT ALL ON TABLE public.brands TO service_role;


--
-- Name: TABLE cancel_reasons; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.cancel_reasons TO anon;
GRANT ALL ON TABLE public.cancel_reasons TO authenticated;
GRANT ALL ON TABLE public.cancel_reasons TO service_role;


--
-- Name: TABLE cash_bank_accounts; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.cash_bank_accounts TO anon;
GRANT ALL ON TABLE public.cash_bank_accounts TO authenticated;
GRANT ALL ON TABLE public.cash_bank_accounts TO service_role;


--
-- Name: TABLE categories; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.categories TO anon;
GRANT ALL ON TABLE public.categories TO authenticated;
GRANT ALL ON TABLE public.categories TO service_role;


--
-- Name: TABLE companies; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.companies TO anon;
GRANT ALL ON TABLE public.companies TO authenticated;
GRANT ALL ON TABLE public.companies TO service_role;


--
-- Name: TABLE cost_centers; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.cost_centers TO anon;
GRANT ALL ON TABLE public.cost_centers TO authenticated;
GRANT ALL ON TABLE public.cost_centers TO service_role;


--
-- Name: TABLE customer_ledger; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.customer_ledger TO anon;
GRANT ALL ON TABLE public.customer_ledger TO authenticated;
GRANT ALL ON TABLE public.customer_ledger TO service_role;


--
-- Name: TABLE customers; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.customers TO anon;
GRANT ALL ON TABLE public.customers TO authenticated;
GRANT ALL ON TABLE public.customers TO service_role;


--
-- Name: TABLE discounts; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.discounts TO anon;
GRANT ALL ON TABLE public.discounts TO authenticated;
GRANT ALL ON TABLE public.discounts TO service_role;


--
-- Name: TABLE expenses; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.expenses TO anon;
GRANT ALL ON TABLE public.expenses TO authenticated;
GRANT ALL ON TABLE public.expenses TO service_role;


--
-- Name: TABLE fiscal_periods; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.fiscal_periods TO anon;
GRANT ALL ON TABLE public.fiscal_periods TO authenticated;
GRANT ALL ON TABLE public.fiscal_periods TO service_role;


--
-- Name: TABLE goods_receipt_items; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.goods_receipt_items TO anon;
GRANT ALL ON TABLE public.goods_receipt_items TO authenticated;
GRANT ALL ON TABLE public.goods_receipt_items TO service_role;


--
-- Name: TABLE goods_receipts; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.goods_receipts TO anon;
GRANT ALL ON TABLE public.goods_receipts TO authenticated;
GRANT ALL ON TABLE public.goods_receipts TO service_role;


--
-- Name: TABLE ingredient_cost_history; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.ingredient_cost_history TO anon;
GRANT ALL ON TABLE public.ingredient_cost_history TO authenticated;
GRANT ALL ON TABLE public.ingredient_cost_history TO service_role;


--
-- Name: TABLE ingredients; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.ingredients TO anon;
GRANT ALL ON TABLE public.ingredients TO authenticated;
GRANT ALL ON TABLE public.ingredients TO service_role;


--
-- Name: TABLE journal_entries; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.journal_entries TO anon;
GRANT ALL ON TABLE public.journal_entries TO authenticated;
GRANT ALL ON TABLE public.journal_entries TO service_role;


--
-- Name: TABLE journal_entry_lines; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.journal_entry_lines TO anon;
GRANT ALL ON TABLE public.journal_entry_lines TO authenticated;
GRANT ALL ON TABLE public.journal_entry_lines TO service_role;


--
-- Name: TABLE modifier_groups; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.modifier_groups TO anon;
GRANT ALL ON TABLE public.modifier_groups TO authenticated;
GRANT ALL ON TABLE public.modifier_groups TO service_role;


--
-- Name: TABLE modifiers; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.modifiers TO anon;
GRANT ALL ON TABLE public.modifiers TO authenticated;
GRANT ALL ON TABLE public.modifiers TO service_role;


--
-- Name: TABLE opening_balances; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.opening_balances TO anon;
GRANT ALL ON TABLE public.opening_balances TO authenticated;
GRANT ALL ON TABLE public.opening_balances TO service_role;


--
-- Name: TABLE order_item_modifiers; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.order_item_modifiers TO anon;
GRANT ALL ON TABLE public.order_item_modifiers TO authenticated;
GRANT ALL ON TABLE public.order_item_modifiers TO service_role;


--
-- Name: TABLE order_items; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.order_items TO anon;
GRANT ALL ON TABLE public.order_items TO authenticated;
GRANT ALL ON TABLE public.order_items TO service_role;


--
-- Name: TABLE order_logs; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.order_logs TO anon;
GRANT ALL ON TABLE public.order_logs TO authenticated;
GRANT ALL ON TABLE public.order_logs TO service_role;


--
-- Name: TABLE order_sequences; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.order_sequences TO anon;
GRANT ALL ON TABLE public.order_sequences TO authenticated;
GRANT ALL ON TABLE public.order_sequences TO service_role;


--
-- Name: TABLE order_split_items; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.order_split_items TO anon;
GRANT ALL ON TABLE public.order_split_items TO authenticated;
GRANT ALL ON TABLE public.order_split_items TO service_role;


--
-- Name: TABLE order_splits; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.order_splits TO anon;
GRANT ALL ON TABLE public.order_splits TO authenticated;
GRANT ALL ON TABLE public.order_splits TO service_role;


--
-- Name: TABLE orders; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.orders TO anon;
GRANT ALL ON TABLE public.orders TO authenticated;
GRANT ALL ON TABLE public.orders TO service_role;


--
-- Name: TABLE payment_method_account_mappings; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.payment_method_account_mappings TO anon;
GRANT ALL ON TABLE public.payment_method_account_mappings TO authenticated;
GRANT ALL ON TABLE public.payment_method_account_mappings TO service_role;


--
-- Name: TABLE payments; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.payments TO anon;
GRANT ALL ON TABLE public.payments TO authenticated;
GRANT ALL ON TABLE public.payments TO service_role;


--
-- Name: TABLE product_modifier_groups; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.product_modifier_groups TO anon;
GRANT ALL ON TABLE public.product_modifier_groups TO authenticated;
GRANT ALL ON TABLE public.product_modifier_groups TO service_role;


--
-- Name: TABLE products; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.products TO anon;
GRANT ALL ON TABLE public.products TO authenticated;
GRANT ALL ON TABLE public.products TO service_role;


--
-- Name: TABLE purchase_order_items; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.purchase_order_items TO anon;
GRANT ALL ON TABLE public.purchase_order_items TO authenticated;
GRANT ALL ON TABLE public.purchase_order_items TO service_role;


--
-- Name: TABLE purchase_orders; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.purchase_orders TO anon;
GRANT ALL ON TABLE public.purchase_orders TO authenticated;
GRANT ALL ON TABLE public.purchase_orders TO service_role;


--
-- Name: TABLE recipes; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.recipes TO anon;
GRANT ALL ON TABLE public.recipes TO authenticated;
GRANT ALL ON TABLE public.recipes TO service_role;


--
-- Name: TABLE roles; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.roles TO anon;
GRANT ALL ON TABLE public.roles TO authenticated;
GRANT ALL ON TABLE public.roles TO service_role;


--
-- Name: TABLE staff; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.staff TO anon;
GRANT ALL ON TABLE public.staff TO authenticated;
GRANT ALL ON TABLE public.staff TO service_role;


--
-- Name: TABLE stock_adjustments; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.stock_adjustments TO anon;
GRANT ALL ON TABLE public.stock_adjustments TO authenticated;
GRANT ALL ON TABLE public.stock_adjustments TO service_role;


--
-- Name: TABLE stock_movements; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.stock_movements TO anon;
GRANT ALL ON TABLE public.stock_movements TO authenticated;
GRANT ALL ON TABLE public.stock_movements TO service_role;


--
-- Name: TABLE stock_takes; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.stock_takes TO anon;
GRANT ALL ON TABLE public.stock_takes TO authenticated;
GRANT ALL ON TABLE public.stock_takes TO service_role;


--
-- Name: TABLE stock_transfers; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.stock_transfers TO anon;
GRANT ALL ON TABLE public.stock_transfers TO authenticated;
GRANT ALL ON TABLE public.stock_transfers TO service_role;


--
-- Name: TABLE supplier_payments; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.supplier_payments TO anon;
GRANT ALL ON TABLE public.supplier_payments TO authenticated;
GRANT ALL ON TABLE public.supplier_payments TO service_role;


--
-- Name: TABLE supplier_prices; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.supplier_prices TO anon;
GRANT ALL ON TABLE public.supplier_prices TO authenticated;
GRANT ALL ON TABLE public.supplier_prices TO service_role;


--
-- Name: TABLE suppliers; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.suppliers TO anon;
GRANT ALL ON TABLE public.suppliers TO authenticated;
GRANT ALL ON TABLE public.suppliers TO service_role;


--
-- Name: TABLE tables; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.tables TO anon;
GRANT ALL ON TABLE public.tables TO authenticated;
GRANT ALL ON TABLE public.tables TO service_role;


--
-- Name: TABLE unit_conversions; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.unit_conversions TO anon;
GRANT ALL ON TABLE public.unit_conversions TO authenticated;
GRANT ALL ON TABLE public.unit_conversions TO service_role;


--
-- Name: TABLE units; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.units TO anon;
GRANT ALL ON TABLE public.units TO authenticated;
GRANT ALL ON TABLE public.units TO service_role;


--
-- Name: TABLE variance_investigations; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.variance_investigations TO anon;
GRANT ALL ON TABLE public.variance_investigations TO authenticated;
GRANT ALL ON TABLE public.variance_investigations TO service_role;


--
-- Name: TABLE warehouse_stock; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.warehouse_stock TO anon;
GRANT ALL ON TABLE public.warehouse_stock TO authenticated;
GRANT ALL ON TABLE public.warehouse_stock TO service_role;


--
-- Name: TABLE warehouses; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.warehouses TO anon;
GRANT ALL ON TABLE public.warehouses TO authenticated;
GRANT ALL ON TABLE public.warehouses TO service_role;


--
-- Name: TABLE waste_logs; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON TABLE public.waste_logs TO anon;
GRANT ALL ON TABLE public.waste_logs TO authenticated;
GRANT ALL ON TABLE public.waste_logs TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR SEQUENCES; Type: DEFAULT ACL; Schema: public; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON SEQUENCES TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON SEQUENCES TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON SEQUENCES TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON SEQUENCES TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR SEQUENCES; Type: DEFAULT ACL; Schema: public; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON SEQUENCES TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON SEQUENCES TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON SEQUENCES TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON SEQUENCES TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR FUNCTIONS; Type: DEFAULT ACL; Schema: public; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON FUNCTIONS TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON FUNCTIONS TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON FUNCTIONS TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON FUNCTIONS TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR FUNCTIONS; Type: DEFAULT ACL; Schema: public; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON FUNCTIONS TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON FUNCTIONS TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON FUNCTIONS TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON FUNCTIONS TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR TABLES; Type: DEFAULT ACL; Schema: public; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON TABLES TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON TABLES TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON TABLES TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON TABLES TO service_role;


--
-- Name: DEFAULT PRIVILEGES FOR TABLES; Type: DEFAULT ACL; Schema: public; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON TABLES TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON TABLES TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON TABLES TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public GRANT ALL ON TABLES TO service_role;


--
-- PostgreSQL database dump complete
--

\unrestrict mWWYp5UHc82RLwUfavMKlWlcPzEVGLKV3JYSURRPjAgvqVEGTikJxgNCfEk6zke

