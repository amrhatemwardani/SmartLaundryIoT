-- Normalize student phone contacts to Egypt's E.164 mobile format (+20...)
-- and enforce validation in PostgreSQL as well as in the signup form.
alter table public.student_profiles
  drop constraint if exists student_profiles_phone_egypt_mobile_check;
alter table public.student_profiles
  add constraint student_profiles_phone_egypt_mobile_check
  check (phone_number ~ '^\+201[0125][0-9]{8}$') not valid;

alter table public.student_profiles
  drop constraint if exists student_profiles_whatsapp_egypt_mobile_check;
alter table public.student_profiles
  add constraint student_profiles_whatsapp_egypt_mobile_check
  check (whatsapp_number is null or whatsapp_number ~ '^\+201[0125][0-9]{8}$') not valid;
