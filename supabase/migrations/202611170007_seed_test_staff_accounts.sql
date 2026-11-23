-- Migration: Seed test supervisor and student accounts with verified bcrypt passwords
-- File: supabase/migrations/202611170007_seed_test_staff_accounts.sql

-- 1. Create or update supervisor.dormc@zewailcity.edu.eg
do $$
declare
  sup_uid uuid := '88888888-8888-8888-8888-888888888888';
begin
  if not exists (select 1 from auth.users where id = sup_uid) then
    insert into auth.users (
      instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
      raw_app_meta_data, raw_user_meta_data, created_at, updated_at
    ) values (
      '00000000-0000-0000-0000-000000000000',
      sup_uid,
      'authenticated',
      'authenticated',
      'supervisor.dormc@zewailcity.edu.eg',
      extensions.crypt('Supervisor2026!#', extensions.gen_salt('bf')),
      now(),
      '{"provider":"email","providers":["email"]}'::jsonb,
      jsonb_build_object(
        'full_name', 'Eng. Ahmed Supervisor',
        'staff_invite', 'true'
      ),
      now(),
      now()
    );
  else
    update auth.users
    set encrypted_password = extensions.crypt('Supervisor2026!#', extensions.gen_salt('bf')),
        email_confirmed_at = coalesce(email_confirmed_at, now())
    where id = sup_uid;
  end if;

  -- Assign supervisor role for Dorm C and Admin role
  insert into public.role_assignments (user_id, role, dorm_class, active)
  values 
    (sup_uid, 'supervisor', 'C', true),
    (sup_uid, 'admin', null, true)
  on conflict (user_id, role, dorm_class) do update set active = true;
end $$;

-- 2. Update password for pending test student s-youssef.ali@zewailcity.edu.eg
update auth.users
set encrypted_password = extensions.crypt('StudentPass2026!#', extensions.gen_salt('bf')),
    email_confirmed_at = coalesce(email_confirmed_at, now())
where id = '77777777-7777-7777-7777-777777777777';
