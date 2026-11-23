-- Migration: Fix student name display — set proper full_name for test user and
--             improve get_my_access fallback so email prefixes are formatted as
--             readable names (e.g. "s-amr.farouk" → "Amr Farouk").
-- File: supabase/migrations/202611180001_fix_student_name_display.sql

-- ─────────────────────────────────────────────────────────────────
-- 1.  Patch test user s-amr.farouk@zewailcity.edu.eg
--     UUID: 4f7011d5-5e6a-486a-8ef1-8e9ca23f4e26
-- ─────────────────────────────────────────────────────────────────
do $$
declare
  test_uid uuid := '4f7011d5-5e6a-486a-8ef1-8e9ca23f4e26';
begin
  -- 1a. Patch raw_user_meta_data in auth.users so get_my_access returns the
  --     proper name from the very first sign-in.
  update auth.users
  set raw_user_meta_data = coalesce(raw_user_meta_data, '{}'::jsonb)
                        || jsonb_build_object('full_name', 'Amr Farouk')
  where id = test_uid
    and (raw_user_meta_data->>'full_name' is null
         or raw_user_meta_data->>'full_name' = ''
         or raw_user_meta_data->>'full_name' like 's-%');

  -- 1b. Patch student_profiles so the name is correct in approvals and portals.
  update public.student_profiles
  set full_name = 'Amr Farouk'
  where user_id = test_uid
    and (full_name is null or full_name = '' or full_name like 's-%');
end $$;


-- ─────────────────────────────────────────────────────────────────
-- 2.  Add a helper function that turns an email-local-part into a
--     human-readable name.
--
--     Rules:
--       • Strip a leading student prefix  "s-"  or  "u-"
--       • Replace dots / hyphens / underscores with spaces
--       • Title-case every word
--
--     Examples:
--       s-amr.farouk       →  Amr Farouk
--       m.ali_hassan       →  M Ali Hassan
--       ahmed-tawfik       →  Ahmed Tawfik
-- ─────────────────────────────────────────────────────────────────
create or replace function public._format_email_name(p_local text)
returns text language plpgsql immutable strict
as $$
declare
  cleaned text;
  words   text[];
  w       text;
  result  text[];
begin
  -- strip leading student prefix (s- or u-)
  cleaned := regexp_replace(p_local, '^[su]-', '');
  -- replace dots, hyphens, underscores with a single space
  cleaned := regexp_replace(cleaned, '[._\-]+', ' ', 'g');
  cleaned := trim(cleaned);

  -- title-case each word
  words := string_to_array(cleaned, ' ');
  foreach w in array words loop
    if length(w) > 0 then
      result := array_append(result,
        upper(substring(w, 1, 1)) || lower(substring(w, 2)));
    end if;
  end loop;

  return array_to_string(result, ' ');
end $$;

-- Keep this internal; no public grants needed.
revoke all on function public._format_email_name(text) from public, anon, authenticated;


-- ─────────────────────────────────────────────────────────────────
-- 3.  Upgrade get_my_access to use the helper as the name fallback
-- ─────────────────────────────────────────────────────────────────
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
  disp_name text;   -- resolved display name
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

  -- Resolve the best available display name:
  --   1. student_profiles.full_name  (set during registration insert trigger)
  --   2. raw_user_meta_data->>'full_name'  (set by signUp() options.data)
  --   3. formatted email local-part  (graceful fallback, human-readable)
  disp_name := coalesce(
    nullif(trim(p.full_name),  ''),
    nullif(trim(u_name),       ''),
    public._format_email_name(split_part(u_email, '@', 1))
  );

  -- Resolve active role (preferred > highest priority)
  if p_preferred_role is not null
     and exists (
       select 1 from public.role_assignments
       where user_id = auth.uid() and role = p_preferred_role and active
     )
  then
    select role, dorm_class into r, scoped
    from   public.role_assignments
    where  user_id = auth.uid() and role = p_preferred_role and active
    limit  1;
  else
    select role, dorm_class into r, scoped
    from   public.role_assignments
    where  user_id = auth.uid() and active
    order  by case role when 'admin' then 1 when 'supervisor' then 2 else 3 end
    limit  1;
  end if;

  if r is null then
    return jsonb_build_object('allowed', false, 'reason', 'no_active_role');
  end if;

  -- Student pending approval branch
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
      'roles',     (
        select coalesce(jsonb_agg(role), '[]'::jsonb)
        from   public.role_assignments
        where  user_id = auth.uid() and active
      )
    );
  end if;

  return jsonb_build_object(
    'allowed',   true,
    'role',      r,
    'dormClass', scoped,
    'name',      disp_name,
    'email',     u_email,
    'roles',     (
      select coalesce(jsonb_agg(role), '[]'::jsonb)
      from   public.role_assignments
      where  user_id = auth.uid() and active
    )
  );
end $$;

revoke all on function public.get_my_access(text) from public, anon;
grant execute on function public.get_my_access(text) to authenticated;
