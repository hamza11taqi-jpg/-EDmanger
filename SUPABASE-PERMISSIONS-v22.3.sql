-- EDManager v22.3
-- Restrict employee row visibility to Admin or employee_view.
-- This changes access policy only; it does not modify or delete application data.
BEGIN;

DROP POLICY IF EXISTS employees_select_authenticated ON public.employees;

CREATE POLICY employees_select_authenticated
ON public.employees
FOR SELECT
TO authenticated
USING (
  public.is_admin()
  OR public.has_permission('employee_view')
);

COMMIT;
