-- EDManager v23.9 - Cash totals and Passager refunds
-- Run this migration in Supabase SQL Editor after taking a database backup.
-- Preserves existing cash operations, advances, closures, permissions and excess ledger.
-- Total commercial:
--   theoretical = truck cash + passenger receipts - passenger refunds
--   final       = theoretical + MEX + discharge + preseller + employee advances
-- Physical expected cash remains separate and is calculated as signed cash_operations
-- less cash_employee_advances, matching cash_close_day(). MEX is not physical cash.

BEGIN;

-- 1) Permit the passenger_refund type already handled by cash_add_operation().
DO $$
DECLARE
    c record;
BEGIN
    FOR c IN
        SELECT conname
        FROM pg_constraint
        WHERE conrelid = 'public.cash_operations'::regclass
          AND contype = 'c'
          AND pg_get_constraintdef(oid) ILIKE '%operation_type%'
    LOOP
        EXECUTE format(
            'ALTER TABLE public.cash_operations DROP CONSTRAINT %I',
            c.conname
        );
    END LOOP;
END $$;

ALTER TABLE public.cash_operations
    ADD CONSTRAINT cash_operations_operation_type_check
    CHECK (operation_type IN (
        'truck_deposit',
        'passenger',
        'passenger_refund',
        'discharge',
        'preseller',
        'correction'
    ));

-- 2) Make the live summary net Passager refunds and align its physical balance
--    with the formula used by cash_close_day().
CREATE OR REPLACE FUNCTION public.cash_get_live_balance(p_cash_day_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user_id uuid := auth.uid();
    v_day public.cash_days%ROWTYPE;
    v_truck_deposits numeric(14,2) := 0;
    v_passengers_gross numeric(14,2) := 0;
    v_passenger_refunds numeric(14,2) := 0;
    v_passengers_net numeric(14,2) := 0;
    v_discharges numeric(14,2) := 0;
    v_presellers numeric(14,2) := 0;
    v_operations_count integer := 0;
    v_entries numeric(14,2) := 0;
    v_expenses numeric(14,2) := 0;
    v_operations_cash_balance numeric(14,2) := 0;
    v_employee_advances numeric(14,2) := 0;
    v_current_balance numeric(14,2) := 0;
BEGIN
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'Authentication required';
    END IF;

    IF NOT public.can_view_cash() THEN
        RAISE EXCEPTION 'Permission denied';
    END IF;

    SELECT *
    INTO v_day
    FROM public.cash_days
    WHERE id = p_cash_day_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Cash day not found';
    END IF;

    SELECT
        COALESCE(SUM(amount) FILTER (WHERE operation_type = 'truck_deposit'), 0),
        COALESCE(SUM(amount) FILTER (WHERE operation_type = 'passenger'), 0),
        COALESCE(SUM(amount) FILTER (WHERE operation_type = 'passenger_refund'), 0),
        COALESCE(SUM(amount) FILTER (WHERE operation_type = 'discharge'), 0),
        COALESCE(SUM(amount) FILTER (WHERE operation_type = 'preseller'), 0),
        COUNT(*)::integer,
        COALESCE(SUM(CASE WHEN direction = 'in' THEN amount ELSE -amount END), 0)
    INTO
        v_truck_deposits,
        v_passengers_gross,
        v_passenger_refunds,
        v_discharges,
        v_presellers,
        v_operations_count,
        v_operations_cash_balance
    FROM public.cash_operations
    WHERE cash_day_id = p_cash_day_id;

    v_passengers_net := v_passengers_gross - v_passenger_refunds;
    v_entries := v_truck_deposits + v_passengers_net;
    v_expenses := v_discharges + v_presellers;

    SELECT COALESCE(SUM(a.amount), 0)
    INTO v_employee_advances
    FROM public.cash_employee_advances a
    WHERE a.cash_day_id = p_cash_day_id;

    -- This is the expected physical cash, not the commercial Total.
    -- It matches the calculation performed by cash_close_day().
    v_current_balance := v_operations_cash_balance - v_employee_advances;

    RETURN jsonb_build_object(
        'success', true,
        'cash_day_id', v_day.id,
        'business_date', v_day.business_date,
        'day_status', v_day.status,
        'truck_deposits', v_truck_deposits,
        'passengers', v_passengers_net,
        'passengers_gross', v_passengers_gross,
        'passenger_refunds', v_passenger_refunds,
        'total_entries', v_entries,
        'entries', v_entries,
        'discharges', v_discharges,
        'presellers', v_presellers,
        'total_expenses', v_expenses,
        'expenses', v_expenses,
        'employee_advances', v_employee_advances,
        'operations_cash_balance', v_operations_cash_balance,
        'current_balance', v_current_balance,
        'operations_count', v_operations_count
    );
END;
$function$;

REVOKE ALL ON FUNCTION public.cash_get_live_balance(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cash_get_live_balance(uuid) TO authenticated;

NOTIFY pgrst, 'reload schema';

COMMIT;
