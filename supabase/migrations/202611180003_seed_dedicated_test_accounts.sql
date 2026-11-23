-- Migration: Seed dedicated test accounts for Admin, Supervisor, Approved Student, and Pending Student
-- File: supabase/migrations/202611180003_seed_dedicated_test_accounts.sql

do $$
declare
  admin_uid   uuid := '99999999-9999-9999-9999-999999999999';
  sup_uid     uuid := '88888888-8888-8888-8888-888888888888';
  student_uid uuid := '77777777-7777-7777-7777-777777777777';
  pending_uid uuid := '66666666-6666-6666-6666-666666666666';
begin
  -- 1. Main Admin: admin@zewailcity.edu.eg
  -- Note: staff_invite: 'true' bypasses student_profiles auto-insert trigger
  if not exists (select 1 from auth.users where id = admin_uid) then
    insert into auth.users (
      instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
      raw_app_meta_data, raw_user_meta_data, created_at, updated_at
    ) values (
      '00000000-0000-0000-0000-000000000000',
      admin_uid,
      'authenticated',
      'authenticated',
      'admin@zewailcity.edu.eg',
      extensions.crypt('AdminPass2026!#', extensions.gen_salt('bf')),
      now(),
      '{"provider":"email","providers":["email"]}'::jsonb,
      jsonb_build_object('full_name', 'Main Administrator', 'role', 'admin', 'staff_invite', 'true'),
      now(),
      now()
    );
  else
    update auth.users
    set encrypted_password = extensions.crypt('AdminPass2026!#', extensions.gen_salt('bf')),
        email_confirmed_at = coalesce(email_confirmed_at, now()),
        raw_user_meta_data = jsonb_build_object('full_name', 'Main Administrator', 'role', 'admin', 'staff_invite', 'true')
    where id = admin_uid;
  end if;

  insert into public.role_assignments (user_id, role, dorm_class, active)
  values (admin_uid, 'admin', null, true)
  on conflict (user_id, role, dorm_class) do update set active = true;


  -- 2. Dorm C Supervisor: supervisor.dormc@zewailcity.edu.eg
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
      jsonb_build_object('full_name', 'Eng. Ahmed Supervisor', 'staff_invite', 'true'),
      now(),
      now()
    );
  else
    update auth.users
    set encrypted_password = extensions.crypt('Supervisor2026!#', extensions.gen_salt('bf')),
        email_confirmed_at = coalesce(email_confirmed_at, now()),
        raw_user_meta_data = jsonb_build_object('full_name', 'Eng. Ahmed Supervisor', 'staff_invite', 'true')
    where id = sup_uid;
  end if;

  insert into public.role_assignments (user_id, role, dorm_class, active)
  values (sup_uid, 'supervisor', 'C', true)
  on conflict (user_id, role, dorm_class) do update set active = true;


  -- 3. Approved Student: s-youssef.ali@zewailcity.edu.eg
  if not exists (select 1 from auth.users where id = student_uid) then
    insert into auth.users (
      instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
      raw_app_meta_data, raw_user_meta_data, created_at, updated_at
    ) values (
      '00000000-0000-0000-0000-000000000000',
      student_uid,
      'authenticated',
      'authenticated',
      's-youssef.ali@zewailcity.edu.eg',
      extensions.crypt('StudentPass2026!#', extensions.gen_salt('bf')),
      now(),
      '{"provider":"email","providers":["email"]}'::jsonb,
      jsonb_build_object(
        'full_name', 'Youssef Ali',
        'university_id', '20251101',
        'age', 21,
        'major', 'Computer Science',
        'phone_number', '+201019998881',
        'whatsapp_number', '+201019998881',
        'dorm_class', 'C',
        'privacy_accepted', true,
        'terms_accepted', true
      ),
      now(),
      now()
    );
  else
    update auth.users
    set encrypted_password = extensions.crypt('StudentPass2026!#', extensions.gen_salt('bf')),
        email_confirmed_at = coalesce(email_confirmed_at, now())
    where id = student_uid;
  end if;

  insert into public.student_profiles (
    user_id, full_name, university_id, university_email, major, age,
    phone_number, whatsapp_number, dorm_class, approval_status, approved_at,
    terms_accepted_at, privacy_accepted_at
  ) values (
    student_uid, 'Youssef Ali', '20251101', 's-youssef.ali@zewailcity.edu.eg',
    'Computer Science', 21, '+201019998881', '+201019998881', 'C',
    'approved', now(), now(), now()
  ) on conflict (user_id) do update set
    approval_status = 'approved',
    approved_at = coalesce(student_profiles.approved_at, now());

  insert into public.role_assignments (user_id, role, dorm_class, active)
  values (student_uid, 'student', null, true)
  on conflict (user_id, role, dorm_class) do update set active = true;

  -- Seed initial wallet balance (EGP 100) for Youssef if not already present
  if not exists (select 1 from public.wallet_ledger where user_id = student_uid) then
    insert into public.wallet_ledger (
      user_id, amount_cents, entry_type, actor_user_id, reference, note
    ) values (
      student_uid, 10000, 'admin_credit', student_uid, 'INIT-CREDIT-2026', 'Welcome test credit (EGP 100)'
    );
  end if;


  -- 4. Pending Student: s-karim.hassan@zewailcity.edu.eg (for testing supervisor approvals)
  if not exists (select 1 from auth.users where id = pending_uid) then
    insert into auth.users (
      instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
      raw_app_meta_data, raw_user_meta_data, created_at, updated_at
    ) values (
      '00000000-0000-0000-0000-000000000000',
      pending_uid,
      'authenticated',
      'authenticated',
      's-karim.hassan@zewailcity.edu.eg',
      extensions.crypt('StudentPass2026!#', extensions.gen_salt('bf')),
      now(),
      '{"provider":"email","providers":["email"]}'::jsonb,
      jsonb_build_object(
        'full_name', 'Karim Hassan',
        'university_id', '20251109',
        'age', 20,
        'major', 'Aerospace Engineering',
        'phone_number', '+201021234567',
        'whatsapp_number', '+201021234567',
        'dorm_class', 'C',
        'privacy_accepted', true,
        'terms_accepted', true
      ),
      now(),
      now()
    );
  else
    update auth.users
    set encrypted_password = extensions.crypt('StudentPass2026!#', extensions.gen_salt('bf')),
        email_confirmed_at = coalesce(email_confirmed_at, now())
    where id = pending_uid;
  end if;

  insert into public.student_profiles (
    user_id, full_name, university_id, university_email, major, age,
    phone_number, whatsapp_number, dorm_class, approval_status, approved_at,
    terms_accepted_at, privacy_accepted_at
  ) values (
    pending_uid, 'Karim Hassan', '20251109', 's-karim.hassan@zewailcity.edu.eg',
    'Aerospace Engineering', 20, '+201021234567', '+201021234567', 'C',
    'pending', null, now(), now()
  ) on conflict (user_id) do update set
    approval_status = 'pending',
    approved_at = null;

  insert into public.role_assignments (user_id, role, dorm_class, active)
  values (pending_uid, 'student', null, true)
  on conflict (user_id, role, dorm_class) do update set active = true;

end $$;

-- 5. Ensure identities exist for GoTrue sign-in on all users
insert into auth.identities (
  id, user_id, identity_data, provider, provider_id, last_sign_in_at, created_at, updated_at
)
select 
  gen_random_uuid(),
  u.id,
  jsonb_build_object('sub', u.id::text, 'email', u.email),
  'email',
  u.id::text,
  now(),
  now(),
  now()
from auth.users u
where not exists (
  select 1 from auth.identities i where i.user_id = u.id and i.provider = 'email'
);
