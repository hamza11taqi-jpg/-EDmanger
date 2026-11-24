-- EDManager v23.6: persist the optional employee nickname.
-- Safe additive migration: does not modify or delete existing employee data.
ALTER TABLE public.employees
  ADD COLUMN IF NOT EXISTS nickname text;

NOTIFY pgrst, 'reload schema';
