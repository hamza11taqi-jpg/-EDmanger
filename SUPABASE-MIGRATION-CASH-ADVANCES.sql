-- EDManager v23.0 - Cash advances, unified discharge/preseller workflow
-- Additive migration. Does NOT touch the existing public.advances table or old Acomptes module.
-- Run this migration once in Supabase SQL Editor after reviewing the project backup.
BEGIN;

-- 1) Separate cash-box advances table. Deliberately distinct from public.advances.
CREATE TABLE IF NOT EXISTS public.cash_employee_advances (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    cash_day_id uuid NOT NULL REFERENCES public.cash_days(id) ON DELETE RESTRICT,
    employee_id uuid NOT NULL REFERENCES public.employees(id) ON DELETE RESTRICT,
    amount numeric(14,2) NOT NULL CHECK (amount > 0 AND amount = round(amount, 2)),
    note text,
    recorded_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS cash_employee_advances_day_idx
    ON public.cash_employee_advances(cash_day_id, created_at DESC);
CREATE INDEX IF NOT EXISTS cash_employee_advances_employee_idx
    ON public.cash_employee_advances(employee_id, created_at DESC);

ALTER TABLE public.cash_employee_advances ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS cash_employee_advances_no_direct_access ON public.cash_employee_advances;
CREATE POLICY cash_employee_advances_no_direct_access
    ON public.cash_employee_advances
    FOR ALL TO authenticated
    USING (false)
    WITH CHECK (false);
REVOKE ALL ON TABLE public.cash_employee_advances FROM PUBLIC, anon, authenticated;

-- 2) Searchable employee picker dedicated to cash management permissions.
CREATE OR REPLACE FUNCTION public.cash_employee_picker_list()
RETURNS TABLE(id uuid, full_name text, job_title text)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $function$
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'Authentication required';
    END IF;
    IF NOT (public.is_admin() OR public.has_permission('cash_management')) THEN
        RAISE EXCEPTION 'Permission denied';
    END IF;
    RETURN QUERY
    SELECT e.id, e.full_name, e.job_title
    FROM public.employees e
    ORDER BY e.full_name;
END;
$function$;
REVOKE ALL ON FUNCTION public.cash_employee_picker_list() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cash_employee_picker_list() TO authenticated;

-- 3) Add a new cash-box advance. It does not write to public.advances.
CREATE OR REPLACE FUNCTION public.cash_employee_advance_add(
    p_cash_day_id uuid,
    p_employee_id uuid,
    p_amount numeric,
    p_note text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
    v_user_id uuid := auth.uid();
    v_day public.cash_days%ROWTYPE;
    v_row public.cash_employee_advances%ROWTYPE;
    v_employee_name text;
BEGIN
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'Authentication required';
    END IF;
    IF NOT (public.is_admin() OR public.has_permission('cash_management')) THEN
        RAISE EXCEPTION 'Permission denied';
    END IF;
    IF p_cash_day_id IS NULL OR p_employee_id IS NULL THEN
        RAISE EXCEPTION 'Cash day and employee are required';
    END IF;
    IF p_amount IS NULL OR p_amount <= 0 OR p_amount <> round(p_amount, 2) THEN
        RAISE EXCEPTION 'Invalid amount: enter a positive amount with up to 2 decimals';
    END IF;
    SELECT * INTO v_day
    FROM public.cash_days
    WHERE id = p_cash_day_id
    FOR UPDATE;
    IF NOT FOUND OR v_day.status <> 'open' THEN
        RAISE EXCEPTION 'Cash day not found or already closed';
    END IF;
    SELECT e.full_name INTO v_employee_name
    FROM public.employees e
    WHERE e.id = p_employee_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Employee not found or inactive';
    END IF;
    INSERT INTO public.cash_employee_advances(cash_day_id, employee_id, amount, note, recorded_by)
    VALUES (p_cash_day_id, p_employee_id, p_amount, NULLIF(btrim(p_note), ''), v_user_id)
    RETURNING * INTO v_row;
    INSERT INTO public.cash_audit_events(
        event_type, cash_day_id, old_values, new_values, reason, performed_by, created_at
    ) VALUES (
        'cash_employee_advance_added', p_cash_day_id, '{}'::jsonb,
        jsonb_build_object('advance_id', v_row.id, 'employee_id', p_employee_id,
                           'employee_name', v_employee_name, 'amount', p_amount),
        'Cash employee advance recorded', v_user_id, now()
    );
    RETURN jsonb_build_object(
        'success', true, 'id', v_row.id, 'employee_id', p_employee_id,
        'employee_name', v_employee_name, 'amount', p_amount, 'created_at', v_row.created_at
    );
END;
$function$;
REVOKE ALL ON FUNCTION public.cash_employee_advance_add(uuid, uuid, numeric, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cash_employee_advance_add(uuid, uuid, numeric, text) TO authenticated;

-- 4) Read cash advances for a given cash day.
CREATE OR REPLACE FUNCTION public.cash_employee_advances_list(p_cash_day_id uuid)
RETURNS TABLE(
    id uuid,
    employee_id uuid,
    employee_name text,
    amount numeric,
    note text,
    created_at timestamptz
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO ''
AS $function$
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'Authentication required';
    END IF;
    IF NOT public.can_view_cash() THEN
        RAISE EXCEPTION 'Permission denied';
    END IF;
    RETURN QUERY
    SELECT a.id, a.employee_id, e.full_name, a.amount, a.note, a.created_at
    FROM public.cash_employee_advances a
    JOIN public.employees e ON e.id = a.employee_id
    WHERE a.cash_day_id = p_cash_day_id
    ORDER BY a.created_at DESC;
END;
$function$;
REVOKE ALL ON FUNCTION public.cash_employee_advances_list(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cash_employee_advances_list(uuid) TO authenticated;

-- 5) Keep physical cash closing accurate: employee cash advances reduce cash on hand.
-- This is separate from the dashboard's requested Total formula, which ADDS advances.
CREATE OR REPLACE FUNCTION public.cash_close_day(
    p_cash_day_id uuid,
    p_count_2000 integer,
    p_count_1000 integer,
    p_count_500 integer,
    p_count_200 integer,
    p_count_100 integer,
    p_count_50 integer,
    p_count_20 integer,
    p_count_10 integer,
    p_note text DEFAULT NULL::text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user_id uuid := auth.uid();
    v_day public.cash_days%ROWTYPE;
    v_theoretical numeric(14,2);
    v_actual numeric(14,2);
    v_difference numeric(14,2);
    v_closure_id uuid;
    v_closed_at timestamptz := now();
BEGIN
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'Authentication required';
    END IF;
    IF NOT (public.is_admin() OR public.has_permission('cash_management')) THEN
        RAISE EXCEPTION 'Permission denied';
    END IF;
    IF p_count_2000 IS NULL OR p_count_2000 < 0
       OR p_count_1000 IS NULL OR p_count_1000 < 0
       OR p_count_500 IS NULL OR p_count_500 < 0
       OR p_count_200 IS NULL OR p_count_200 < 0
       OR p_count_100 IS NULL OR p_count_100 < 0
       OR p_count_50 IS NULL OR p_count_50 < 0
       OR p_count_20 IS NULL OR p_count_20 < 0
       OR p_count_10 IS NULL OR p_count_10 < 0 THEN
        RAISE EXCEPTION 'Invalid cash denomination counts';
    END IF;

    SELECT * INTO v_day
    FROM public.cash_days
    WHERE id = p_cash_day_id
    FOR UPDATE;
    IF NOT FOUND OR v_day.status <> 'open' THEN
        RAISE EXCEPTION 'Cash day is missing or already closed';
    END IF;
    IF EXISTS (
        SELECT 1 FROM public.cash_day_closures WHERE cash_day_id = p_cash_day_id
    ) THEN
        RAISE EXCEPTION 'This cash day already has a closure';
    END IF;
    IF EXISTS (
        SELECT 1 FROM public.cash_truck_sessions
        WHERE cash_day_id = p_cash_day_id AND status = 'open'
    ) THEN
        RAISE EXCEPTION 'Cannot close cash day while truck sessions are still open';
    END IF;

    SELECT COALESCE(SUM(CASE WHEN direction = 'in' THEN amount ELSE -amount END), 0)
    INTO v_theoretical
    FROM public.cash_operations
    WHERE cash_day_id = p_cash_day_id;

    -- Cash advances are cash paid out, so subtract them from the physical cash expected.
    v_theoretical := v_theoretical - COALESCE((
        SELECT SUM(a.amount)
        FROM public.cash_employee_advances a
        WHERE a.cash_day_id = p_cash_day_id
    ), 0);

    v_actual :=
          (p_count_2000::numeric * 2000)
        + (p_count_1000::numeric * 1000)
        + (p_count_500::numeric * 500)
        + (p_count_200::numeric * 200)
        + (p_count_100::numeric * 100)
        + (p_count_50::numeric * 50)
        + (p_count_20::numeric * 20)
        + (p_count_10::numeric * 10);
    v_difference := v_actual - v_theoretical;

    INSERT INTO public.cash_day_closures (
        cash_day_id, theoretical_balance, count_2000, count_1000, count_500,
        count_200, count_100, count_50, count_20, count_10, actual_cash,
        difference, note, closed_by, closed_at
    ) VALUES (
        p_cash_day_id, v_theoretical, p_count_2000, p_count_1000, p_count_500,
        p_count_200, p_count_100, p_count_50, p_count_20, p_count_10, v_actual,
        v_difference, NULLIF(trim(p_note), ''), v_user_id, v_closed_at
    ) RETURNING id INTO v_closure_id;

    UPDATE public.cash_days
    SET status = 'closed', closed_by = v_user_id, closed_at = v_closed_at
    WHERE id = p_cash_day_id;

    INSERT INTO public.cash_audit_events (
        event_type, cash_day_id, old_values, new_values, reason, performed_by, created_at
    ) VALUES (
        'cash_day_closed', p_cash_day_id, jsonb_build_object('status', 'open'),
        jsonb_build_object(
            'status', 'closed', 'theoretical_balance', v_theoretical,
            'actual_cash', v_actual, 'difference', v_difference, 'closure_id', v_closure_id
        ), 'Daily cash closure', v_user_id, v_closed_at
    );

    RETURN jsonb_build_object(
        'success', true, 'closure_id', v_closure_id, 'business_date', v_day.business_date,
        'theoretical_balance', v_theoretical, 'actual_cash', v_actual,
        'difference', v_difference,
        'result', CASE WHEN v_difference > 0 THEN 'surplus'
                       WHEN v_difference < 0 THEN 'shortage' ELSE 'balanced' END,
        'day_status', 'closed'
    );
END;
$function$;

NOTIFY pgrst, 'reload schema';
COMMIT;
