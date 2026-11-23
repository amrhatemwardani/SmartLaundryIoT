-- Migration: Role isolation, admin wallet top-up, and manual student & supervisor management
-- File: supabase/migrations/202611230001_role_isolation_and_admin_management.sql

-- =====================================================================
-- 1. CLEAN UP MULTI-ROLE CONFLICTS & ENFORCE SINGLE ACTIVE ROLE
-- =====================================================================

-- Deactivate cross-roles for existing test accounts
-- Admin: admin@zewailcity.edu.eg must ONLY be admin
update public.role_assignments
set active = false
where user_id in (select id from auth.users where lower(email) = 'admin@zewailcity.edu.eg')
  and role <> 'admin';

-- Supervisor: supervisor.dormc@zewailcity.edu.eg must ONLY be supervisor
update public.role_assignments
set active = false
where user_id in (select id from auth.users where lower(email) = 'supervisor.dormc@zewailcity.edu.eg')
  and role <> 'supervisor';

-- Student Amr Farouk: s-amr.farouk@zewailcity.edu.eg must ONLY be student
update public.role_assignments
set active = false
where user_id in (select id from auth.users where lower(email) = 's-amr.farouk@zewailcity.edu.eg')
  and role <> 'student';

-- Ensure single active role constraint: drop old if exists, create partial unique index
drop index if exists public.role_assignments_single_active_role_idx;
create unique index role_assignments_single_active_role_idx
  on public.role_assignments(user_id)
  where (active = true);


-- =====================================================================
-- 2. HARDEN get_my_access TO PREVENT ROLE MASQUERADING
-- =====================================================================
create or replace function public.get_my_access(p_preferred_role text default null)
returns jsonb language plpgsql stable security definer
set search_path = public, extensions
as $$
declare
  p         public.student_profiles%rowtype;
  r         text;
  scoped    text;
  confirmed timestamptz;
  u_email   text;
  u_name    text;
  disp_name text;
begin
  select email_confirmed_at, email,
         coalesce(raw_user_meta_data->>'full_name', '')
  into   confirmed, u_email, u_name
  from   auth.users
  where  id = auth.uid();

  if confirmed is null then
    return jsonb_build_object('allowed', false, 'reason', 'email_unverified');
  end if;

  select * into p from public.student_profiles where user_id = auth.uid();

  disp_name := coalesce(
    nullif(trim(p.full_name), ''),
    nullif(trim(u_name), ''),
    public._format_email_name(split_part(u_email, '@', 1))
  );

  -- Authoritatively fetch the user's active role from role_assignments.
  -- Role priority: admin > supervisor > student (if somehow multiple exist)
  select role, dorm_class into r, scoped
  from   public.role_assignments
  where  user_id = auth.uid() and active
  order  by case role when 'admin' then 1 when 'supervisor' then 2 else 3 end
  limit  1;

  if r is null then
    return jsonb_build_object('allowed', false, 'reason', 'no_active_role');
  end if;

  -- If preferred role was provided but does not match the active role, do NOT switch
  if p_preferred_role is not null and p_preferred_role <> r then
    return jsonb_build_object(
      'allowed', false,
      'reason', 'unauthorized_role_attempt',
      'role', r,
      'name', disp_name,
      'email', u_email
    );
  end if;

  -- Pending student check
  if r = 'student'
     and (p.user_id is null
          or p.approval_status <> 'approved'
          or p.approved_at is null)
  then
    return jsonb_build_object(
      'allowed',   false,
      'reason',    coalesce(p.approval_status, 'profile_missing'),
      'role',      'student',
      'dormClass', coalesce(p.dorm_class, 'A'),
      'name',      disp_name,
      'email',     u_email,
      'roles',     jsonb_build_array('student')
    );
  end if;

  return jsonb_build_object(
    'allowed',   true,
    'role',      r,
    'dormClass', coalesce(scoped, p.dorm_class, 'A'),
    'name',      disp_name,
    'email',     u_email,
    'roles',     jsonb_build_array(r)
  );
end $$;

revoke all on function public.get_my_access(text) from public, anon;
grant execute on function public.get_my_access(text) to authenticated, service_role;


-- =====================================================================
-- 3. ADVANCED STUDENT SEARCH & LIST FOR ADMIN
-- =====================================================================
drop function if exists public.admin_find_student(text);
create or replace function public.admin_find_student(p_query text)
returns table(
  user_id uuid,
  full_name text,
  university_email text,
  university_id text,
  wallet_balance_cents integer,
  dorm_class text,
  approval_status text
)
language plpgsql stable security definer set search_path=public
as $$
declare
  q text := trim(lower(coalesce(p_query, '')));
  clean_local text;
begin
  if not exists(select 1 from public.role_assignments ra where ra.user_id=auth.uid() and ra.role='admin' and ra.active) then
    raise exception 'Admin role required';
  end if;

  clean_local := split_part(q, '@', 1);

  return query
  select 
    p.user_id,
    p.full_name,
    p.university_email,
    p.university_id,
    coalesce((select sum(w.amount_cents)::integer from public.wallet_ledger w where w.user_id = p.user_id), 0),
    p.dorm_class,
    p.approval_status
  from public.student_profiles p
  where lower(p.university_email) = q
     or split_part(lower(p.university_email), '@', 1) = clean_local
     or p.university_id = q
     or p.full_name ilike '%' || q || '%'
     or p.university_email ilike '%' || q || '%'
  order by 
    case when lower(p.university_email) = q then 1
         when split_part(lower(p.university_email), '@', 1) = clean_local then 2
         when p.university_id = q then 3
         else 4 end,
    p.created_at desc
  limit 15;
end $$;

revoke all on function public.admin_find_student(text) from public, anon;
grant execute on function public.admin_find_student(text) to authenticated, service_role, anon, postgres;


create or replace function public.admin_list_students(p_query text default null)
returns table(
  user_id uuid,
  full_name text,
  university_email text,
  university_id text,
  dorm_class text,
  major text,
  phone_number text,
  approval_status text,
  wallet_balance_cents integer,
  created_at timestamptz
)
language plpgsql stable security definer set search_path=public
as $$
begin
  if not exists(select 1 from public.role_assignments ra where ra.user_id=auth.uid() and ra.role='admin' and ra.active) then
    raise exception 'Admin role required';
  end if;

  return query
  select 
    p.user_id,
    p.full_name,
    p.university_email,
    p.university_id,
    p.dorm_class,
    p.major,
    p.phone_number,
    p.approval_status,
    coalesce((select sum(w.amount_cents)::integer from public.wallet_ledger w where w.user_id = p.user_id), 0),
    p.created_at
  from public.student_profiles p
  where (p_query is null or p_query = ''
         or p.full_name ilike '%' || trim(p_query) || '%'
         or p.university_email ilike '%' || trim(p_query) || '%'
         or p.university_id ilike '%' || trim(p_query) || '%')
  order by p.created_at desc
  limit 200;
end $$;

revoke all on function public.admin_list_students(text) from public, anon;
grant execute on function public.admin_list_students(text) to authenticated, service_role, anon, postgres;


-- =====================================================================
-- 4. HARDENED WALLET CREDIT & RECENT TRANSACTIONS
-- =====================================================================
drop function if exists public.admin_credit_wallet(uuid, integer, text, text);
create or replace function public.admin_credit_wallet(
  p_student_id uuid,
  p_amount_cents integer,
  p_reason text,
  p_reference text
)
returns jsonb language plpgsql security definer set search_path=public
as $$
declare
  actor uuid := auth.uid();
  dorm text;
  existing public.wallet_ledger%rowtype;
  new_balance integer;
begin
  if not exists(select 1 from public.role_assignments where user_id=actor and role='admin' and active) then
    raise exception 'Admin role required';
  end if;

  if p_amount_cents < 1 or p_amount_cents > 500000 or length(trim(coalesce(p_reason,''))) < 3 or length(trim(coalesce(p_reference,''))) < 4 then
    raise exception 'A valid amount, reason and reference are required';
  end if;

  -- Verify student exists and resolve dorm
  select coalesce(dorm_class, 'A') into dorm
  from public.student_profiles
  where user_id = p_student_id;

  if dorm is null then
    if not exists (select 1 from auth.users where id = p_student_id) then
      raise exception 'Student user not found';
    end if;
    dorm := 'A';
  end if;

  -- Ensure student profile is approved so they can immediately book slots
  update public.student_profiles
  set approval_status = 'approved',
      approved_at = coalesce(approved_at, now()),
      approved_by = coalesce(approved_by, actor)
  where user_id = p_student_id and (approval_status <> 'approved' or approved_at is null);

  -- Idempotency check
  select * into existing from public.wallet_ledger where reference = p_reference for update;
  if found then
    if existing.user_id = p_student_id and existing.amount_cents = p_amount_cents and existing.entry_type = 'admin_credit' then
      select coalesce(sum(amount_cents), 0)::integer into new_balance from public.wallet_ledger where user_id = p_student_id;
      return jsonb_build_object('success', true, 'idempotent', true, 'new_balance_cents', new_balance);
    else
      raise exception 'Reference already used for a different wallet action';
    end if;
  end if;

  -- Insert ledger entry
  insert into public.wallet_ledger(user_id, amount_cents, entry_type, actor_user_id, reference, note)
  values(p_student_id, p_amount_cents, 'admin_credit', actor, p_reference, left(trim(p_reason), 1000));

  -- Insert notification for student
  insert into public.notifications(user_id, title, body, category)
  values(
    p_student_id,
    'Wallet credit added',
    'An administrator added EGP ' || to_char(p_amount_cents / 100.0, 'FM999999990.00') || ' to your wallet. Note: ' || left(trim(p_reason), 200),
    'payment'
  );

  -- Log audit event
  insert into public.audit_events(actor_user_id, actor_role, action, entity_type, entity_id, reason, details)
  values(actor, 'admin', 'wallet_credit', 'student', p_student_id::text, left(p_reason, 1000), jsonb_build_object('amount_cents', p_amount_cents, 'reference', p_reference, 'dorm_class', dorm));

  select coalesce(sum(amount_cents), 0)::integer into new_balance from public.wallet_ledger where user_id = p_student_id;

  return jsonb_build_object('success', true, 'amount_cents', p_amount_cents, 'new_balance_cents', new_balance);
end $$;

revoke all on function public.admin_credit_wallet(uuid, integer, text, text) from public, anon;
grant execute on function public.admin_credit_wallet(uuid, integer, text, text) to authenticated, service_role, anon, postgres;


create or replace function public.admin_list_recent_transactions()
returns table(
  id uuid,
  student_name text,
  student_email text,
  amount_cents integer,
  entry_type text,
  reference text,
  note text,
  created_at timestamptz
)
language plpgsql stable security definer set search_path=public
as $$
begin
  if not exists(select 1 from public.role_assignments ra where ra.user_id=auth.uid() and ra.role='admin' and ra.active) then
    raise exception 'Admin role required';
  end if;

  return query
  select 
    w.id,
    coalesce(p.full_name, split_part(u.email, '@', 1))::text,
    u.email::text,
    w.amount_cents,
    w.entry_type::text,
    w.reference::text,
    w.note::text,
    w.created_at
  from public.wallet_ledger w
  join auth.users u on u.id = w.user_id
  left join public.student_profiles p on p.user_id = w.user_id
  order by w.created_at desc
  limit 50;
end $$;

revoke all on function public.admin_list_recent_transactions() from public, anon;
grant execute on function public.admin_list_recent_transactions() to authenticated, service_role, anon, postgres;


-- =====================================================================
-- 5. ADMIN MANUAL STUDENT CREATION
-- =====================================================================
create or replace function public.admin_create_student(
  p_full_name text,
  p_university_email text,
  p_university_id text,
  p_password text,
  p_dorm_class text,
  p_major text,
  p_phone_number text,
  p_whatsapp_number text default null,
  p_age integer default 20
)
returns jsonb
language plpgsql security definer set search_path = public, extensions
as $$
declare
  actor      uuid := auth.uid();
  target_id  uuid;
  em         text := lower(trim(p_university_email));
  sid        text := trim(p_university_id);
  nm         text := trim(p_full_name);
  ph         text := trim(p_phone_number);
  wa         text := nullif(trim(p_whatsapp_number), '');
  mj         text := trim(p_major);
  age_val    integer := coalesce(p_age, 20);
begin
  -- Check admin permission
  if not exists (select 1 from public.role_assignments where user_id = actor and role = 'admin' and active) then
    raise exception 'Admin role required';
  end if;

  -- Validate inputs
  if length(nm) < 2 then raise exception 'Valid student full name is required'; end if;
  if em not like '%@zewailcity.edu.eg' then raise exception 'University email must end with @zewailcity.edu.eg'; end if;
  if sid !~ '^[0-9]+$' then raise exception 'University ID must contain numeric digits only'; end if;
  if p_dorm_class not in ('A', 'B', 'C', 'D') then raise exception 'Dorm class must be A, B, C, or D'; end if;
  if length(mj) < 2 then raise exception 'Major is required'; end if;
  if length(ph) < 8 then raise exception 'Valid phone number is required'; end if;
  if length(p_password) < 6 then raise exception 'Password must be at least 6 characters'; end if;
  if age_val < 18 or age_val > 120 then raise exception 'Age must be between 18 and 120'; end if;

  -- Find or create auth user
  select id into target_id from auth.users where lower(email) = em;

  if target_id is null then
    target_id := gen_random_uuid();
    insert into auth.users (
      instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
      raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
      confirmation_token, recovery_token, email_change_token_new, email_change_token_current,
      email_change, phone_change, phone_change_token, reauthentication_token,
      email_change_confirm_status, is_anonymous, is_sso_user
    ) values (
      '00000000-0000-0000-0000-000000000000',
      target_id,
      'authenticated',
      'authenticated',
      em,
      extensions.crypt(p_password, extensions.gen_salt('bf', 10)),
      now(),
      '{"provider":"email","providers":["email"]}'::jsonb,
      jsonb_build_object(
        'full_name', nm,
        'university_id', sid,
        'dorm_class', p_dorm_class,
        'major', mj,
        'phone_number', ph,
        'role', 'student',
        'staff_invite', 'true' -- bypass default auto-insert trigger to insert directly below
      ),
      now(), now(),
      '', '', '', '', '', '', '', '', 0, false, false
    );

    insert into auth.identities (
      id, user_id, identity_data, provider, provider_id, last_sign_in_at, created_at, updated_at
    ) values (
      target_id,
      target_id,
      jsonb_build_object('sub', target_id::text, 'email', em, 'email_verified', true, 'phone_verified', false),
      'email',
      target_id::text,
      now(), now(), now()
    );
  else
    -- Update existing user password and confirmed status
    update auth.users
    set encrypted_password = extensions.crypt(p_password, extensions.gen_salt('bf', 10)),
        email_confirmed_at = coalesce(email_confirmed_at, now()),
        raw_user_meta_data = coalesce(raw_user_meta_data, '{}'::jsonb) || jsonb_build_object('full_name', nm, 'dorm_class', p_dorm_class)
    where id = target_id;
  end if;

  -- Create or update student profile (pre-approved by Admin)
  insert into public.student_profiles (
    user_id, full_name, university_email, university_id, major, age,
    phone_number, whatsapp_number, dorm_class, approval_status,
    approved_at, approved_by, approval_note, terms_accepted_at, privacy_accepted_at
  ) values (
    target_id, nm, em, sid, mj, age_val,
    ph, wa, p_dorm_class, 'approved',
    now(), actor, 'Registered and approved directly by administrator', now(), now()
  )
  on conflict (user_id) do update set
    full_name = excluded.full_name,
    university_id = excluded.university_id,
    major = excluded.major,
    phone_number = excluded.phone_number,
    whatsapp_number = coalesce(excluded.whatsapp_number, student_profiles.whatsapp_number),
    dorm_class = excluded.dorm_class,
    approval_status = 'approved',
    approved_at = now(),
    approved_by = actor,
    approval_note = 'Updated by administrator';

  -- Deactivate any non-student roles to guarantee strict role separation
  update public.role_assignments
  set active = false
  where user_id = target_id and role <> 'student';

  -- Assign student role
  insert into public.role_assignments (user_id, role, dorm_class, active, assigned_by)
  values (target_id, 'student', null, true, actor)
  on conflict (user_id, role, dorm_class) do update set active = true, assigned_by = actor;

  -- Audit event
  insert into public.audit_events(actor_user_id, actor_role, action, entity_type, entity_id, details)
  values(actor, 'admin', 'student_created_manually', 'student', target_id::text, jsonb_build_object(
    'email', em, 'full_name', nm, 'university_id', sid, 'dorm_class', p_dorm_class
  ));

  return jsonb_build_object(
    'success', true,
    'user_id', target_id,
    'email', em,
    'full_name', nm,
    'dorm_class', p_dorm_class
  );
end $$;

revoke all on function public.admin_create_student(text, text, text, text, text, text, text, text, integer) from public, anon;
grant execute on function public.admin_create_student(text, text, text, text, text, text, text, text, integer) to authenticated, service_role, anon, postgres;


-- =====================================================================
-- 6. ADMIN MANUAL SUPERVISOR CREATION
-- =====================================================================
create or replace function public.admin_create_supervisor(
  p_full_name text,
  p_email text,
  p_password text,
  p_dorm_class text,
  p_phone_number text default null
)
returns jsonb
language plpgsql security definer set search_path = public, extensions
as $$
declare
  actor      uuid := auth.uid();
  target_id  uuid;
  em         text := lower(trim(p_email));
  nm         text := trim(p_full_name);
begin
  -- Check admin permission
  if not exists (select 1 from public.role_assignments where user_id = actor and role = 'admin' and active) then
    raise exception 'Admin role required';
  end if;

  -- Validate inputs
  if length(nm) < 2 then raise exception 'Valid supervisor full name is required'; end if;
  if em not like '%@zewailcity.edu.eg' then raise exception 'Staff email must end with @zewailcity.edu.eg'; end if;
  if p_dorm_class not in ('A', 'B', 'C', 'D') then raise exception 'Assigned dorm class must be A, B, C, or D'; end if;
  if length(p_password) < 6 then raise exception 'Password must be at least 6 characters'; end if;

  -- Find or create auth user
  select id into target_id from auth.users where lower(email) = em;

  if target_id is null then
    target_id := gen_random_uuid();
    insert into auth.users (
      instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
      raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
      confirmation_token, recovery_token, email_change_token_new, email_change_token_current,
      email_change, phone_change, phone_change_token, reauthentication_token,
      email_change_confirm_status, is_anonymous, is_sso_user
    ) values (
      '00000000-0000-0000-0000-000000000000',
      target_id,
      'authenticated',
      'authenticated',
      em,
      extensions.crypt(p_password, extensions.gen_salt('bf', 10)),
      now(),
      '{"provider":"email","providers":["email"]}'::jsonb,
      jsonb_build_object(
        'full_name', nm,
        'dorm_class', p_dorm_class,
        'role', 'supervisor',
        'staff_invite', 'true',
        'phone_number', trim(coalesce(p_phone_number, ''))
      ),
      now(), now(),
      '', '', '', '', '', '', '', '', 0, false, false
    );

    insert into auth.identities (
      id, user_id, identity_data, provider, provider_id, last_sign_in_at, created_at, updated_at
    ) values (
      target_id,
      target_id,
      jsonb_build_object('sub', target_id::text, 'email', em, 'email_verified', true, 'phone_verified', false),
      'email',
      target_id::text,
      now(), now(), now()
    );
  else
    -- Update existing user password and metadata
    update auth.users
    set encrypted_password = extensions.crypt(p_password, extensions.gen_salt('bf', 10)),
        email_confirmed_at = coalesce(email_confirmed_at, now()),
        raw_user_meta_data = coalesce(raw_user_meta_data, '{}'::jsonb) || jsonb_build_object('full_name', nm, 'staff_invite', 'true', 'dorm_class', p_dorm_class)
    where id = target_id;
  end if;

  -- Strict role isolation: deactivate any other active roles (e.g. student or old supervisor assignments)
  update public.role_assignments
  set active = false
  where user_id = target_id and (role <> 'supervisor' or dorm_class <> p_dorm_class);

  -- Assign supervisor role for the specific dorm
  insert into public.role_assignments (user_id, role, dorm_class, active, assigned_by)
  values (target_id, 'supervisor', p_dorm_class, true, actor)
  on conflict (user_id, role, dorm_class) do update set active = true, assigned_by = actor;

  -- Audit event
  insert into public.audit_events(actor_user_id, actor_role, action, entity_type, entity_id, details)
  values(actor, 'admin', 'supervisor_created_manually', 'staff', target_id::text, jsonb_build_object(
    'email', em, 'full_name', nm, 'dorm_class', p_dorm_class
  ));

  return jsonb_build_object(
    'success', true,
    'user_id', target_id,
    'email', em,
    'full_name', nm,
    'dorm_class', p_dorm_class
  );
end $$;

revoke all on function public.admin_create_supervisor(text, text, text, text, text) from public, anon;
grant execute on function public.admin_create_supervisor(text, text, text, text, text) to authenticated, service_role, anon, postgres;
