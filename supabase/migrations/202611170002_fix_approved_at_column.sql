-- Fix: add the approved_at column that get_my_access(), review_student_application(),
-- and student_pay_ticket_from_wallet() all reference but was never declared with ADD COLUMN.
-- Apply after 202611170001_egyptian_phone_validation.sql.

alter table public.student_profiles
  add column if not exists approved_at timestamptz;
