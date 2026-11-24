-- EDManager v22.7 - Consolidated Supabase migration / employee picker RPC
-- Additive migration: preserves existing records, users, roles and legacy permissions.
-- Run only after reviewing/backing up the Supabase project.
BEGIN;

-- 0) Remove broad non-admin table SELECT. Admin remains covered by employees_admin_all.
-- Non-admin application access is routed through the limited RPC below, so base_salary
-- and other columns cannot be fetched directly through the REST table endpoint.
DROP POLICY IF EXISTS employees_select_authenticated ON public.employees;

-- The legacy full-management permissions pt/ac must retain their read access too.
-- The view-only permissions remain separate and do not gain write access.
DROP POLICY IF EXISTS attendance_select_access ON public.attendance;
CREATE POLICY attendance_select_access ON public.attendance
FOR SELECT TO authenticated
USING (public.is_admin() OR public.has_permission('pt') OR public.has_permission('pt_view'));

DROP POLICY IF EXISTS attendance_justifications_select_access ON public.attendance_justifications;
CREATE POLICY attendance_justifications_select_access ON public.attendance_justifications
FOR SELECT TO authenticated
USING (public.is_admin() OR public.has_permission('pt') OR public.has_permission('pt_view'));

DROP POLICY IF EXISTS advances_select_access ON public.advances;
CREATE POLICY advances_select_access ON public.advances
FOR SELECT TO authenticated
USING (public.is_admin() OR public.has_permission('ac') OR public.has_permission('ac_view'));

-- 1) Safe employee picker: return only non-sensitive employee fields.
-- This avoids granting table-wide SELECT (which could expose base_salary).
CREATE OR REPLACE FUNCTION public.get_employees_for_operations()
RETURNS TABLE (
  id uuid,
  full_name text,
  job_title text,
  section_id bigint,
  start_date date,
  active boolean
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

  IF NOT (
    public.is_admin()
    OR public.has_permission('employee_view')
    OR public.has_permission('pt')
    OR public.has_permission('pt_record')
    OR public.has_permission('pt_view')
    OR public.has_permission('ac')
    OR public.has_permission('ac_record')
    OR public.has_permission('ac_view')
    OR public.has_permission('rc')
    OR public.has_permission('an')
    OR public.has_permission('jr')
    OR public.has_permission('rp')
  ) THEN
    RAISE EXCEPTION 'Permission denied';
  END IF;

  RETURN QUERY
  SELECT e.id, e.full_name, e.job_title, e.section_id, e.start_date, e.active
  FROM public.employees AS e
  ORDER BY e.full_name;
END;
$function$;
REVOKE ALL ON FUNCTION public.get_employees_for_operations() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_employees_for_operations() TO authenticated;

-- Required zero-argument endpoint used by the v22.7 application.
-- If this function is absent from Supabase, the client will receive HTTP 404.
-- This migration creates it in the public schema and grants authenticated execution.
-- Compatibility endpoint: the deployed client reports/calls employee_picker_list().
-- Keep this exact zero-argument RPC name available to PostgREST.
CREATE OR REPLACE FUNCTION public.employee_picker_list()
RETURNS TABLE (
  id uuid,
  full_name text,
  job_title text,
  section_id bigint,
  start_date date,
  active boolean
)
LANGUAGE sql
STABLE
SET search_path TO ''
AS $function$
  SELECT * FROM public.get_employees_for_operations();
$function$;
REVOKE ALL ON FUNCTION public.employee_picker_list() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.employee_picker_list() TO authenticated;

-- 2) Insert-only attendance endpoint for pt_record.
-- It cannot update/delete an existing attendance row or read attendance history.
CREATE OR REPLACE FUNCTION public.record_attendance_only(
  p_employee_id uuid,
  p_work_date date,
  p_status text,
  p_justified boolean DEFAULT false
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_inserted integer;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;
  IF NOT (public.is_admin() OR public.has_permission('pt_record')) THEN
    RAISE EXCEPTION 'Permission denied';
  END IF;
  IF p_employee_id IS NULL OR p_work_date IS NULL THEN
    RAISE EXCEPTION 'Employee and work date are required';
  END IF;
  IF p_work_date > (now() AT TIME ZONE 'Africa/Algiers')::date THEN
    RAISE EXCEPTION 'لا يمكن تسجيل الغياب بتاريخ مستقبلي';
  END IF;
  IF p_status IS NULL OR p_status NOT IN ('absent', 'half_day') THEN
    RAISE EXCEPTION 'Invalid attendance status';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.employees e WHERE e.id = p_employee_id AND e.active = true) THEN
    RAISE EXCEPTION 'Employee not found or inactive';
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.day_validations dv
    WHERE dv.work_date = p_work_date AND dv.is_locked = true
  ) THEN
    RAISE EXCEPTION 'هذا اليوم مغلق ولا يمكن التسجيل فيه';
  END IF;

  INSERT INTO public.attendance (employee_id, work_date, status, justified)
  VALUES (p_employee_id, p_work_date, p_status, COALESCE(p_justified, false))
  ON CONFLICT (employee_id, work_date) DO NOTHING;
  GET DIAGNOSTICS v_inserted = ROW_COUNT;
  IF v_inserted = 0 THEN
    RAISE EXCEPTION 'يوجد سجل لهذا العامل في هذا اليوم؛ صلاحيتك لا تسمح بتعديله';
  END IF;
END;
$function$;
REVOKE ALL ON FUNCTION public.record_attendance_only(uuid, date, text, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.record_attendance_only(uuid, date, text, boolean) TO authenticated;

-- 3) Insert-only advances endpoint for ac_record.
-- Returns only the row just submitted to the caller; no historical list/read access.
CREATE OR REPLACE FUNCTION public.record_advance_only(
  p_employee_id uuid,
  p_amount numeric,
  p_advance_date date,
  p_note text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_row public.advances%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Authentication required';
  END IF;
  IF NOT (public.is_admin() OR public.has_permission('ac_record')) THEN
    RAISE EXCEPTION 'Permission denied';
  END IF;
  IF p_employee_id IS NULL OR p_advance_date IS NULL THEN
    RAISE EXCEPTION 'Employee and advance date are required';
  END IF;
  IF p_amount IS NULL OR p_amount <= 0 OR p_amount <> round(p_amount, 2) THEN
    RAISE EXCEPTION 'Invalid amount: enter a positive amount with up to 2 decimals';
  END IF;
  IF p_advance_date > (now() AT TIME ZONE 'Africa/Algiers')::date THEN
    RAISE EXCEPTION 'لا يمكن تسجيل تسبيق بتاريخ مستقبلي';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.employees e WHERE e.id = p_employee_id AND e.active = true) THEN
    RAISE EXCEPTION 'Employee not found or inactive';
  END IF;

  INSERT INTO public.advances (employee_id, amount, advance_date, note)
  VALUES (p_employee_id, p_amount, p_advance_date, NULLIF(btrim(p_note), ''))
  RETURNING * INTO v_row;

  RETURN jsonb_build_object('record', jsonb_build_object(
    'id', v_row.id,
    'employee_id', v_row.employee_id,
    'amount', v_row.amount,
    'advance_date', v_row.advance_date,
    'note', v_row.note
  ));
END;
$function$;
REVOKE ALL ON FUNCTION public.record_advance_only(uuid, numeric, date, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.record_advance_only(uuid, numeric, date, text) TO authenticated;

-- Ask PostgREST to refresh its schema cache so the zero-argument RPC is visible immediately.
NOTIFY pgrst, 'reload schema';

COMMIT;
