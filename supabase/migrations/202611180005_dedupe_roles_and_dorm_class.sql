-- Migration: Clean up duplicate role_assignments and ensure student dormClass falls back to student_profiles
-- File: supabase/migrations/202611180005_dedupe_roles_and_dorm_class.sql

-- 1. Deduplicate role_assignments (keep 1 row per user_id, role, dorm_class)
delete from public.role_assignments a
using public.role_assignments b
where a.ctid < b.ctid
  and a.user_id = b.user_id
  and a.role = b.role
  and coalesce(a.dorm_class, '') = coalesce(b.dorm_class, '');

-- 2. Ensure get_my_access returns student's dorm_class from student_profiles if scoped is null
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
    nullif(trim(p.full_name),  ''),
    nullif(trim(u_name),       ''),
    public._format_email_name(split_part(u_email, '@', 1))
  );

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

  -- Fallback scoped dorm_class to student_profiles.dorm_class if null
  if scoped is null and p.dorm_class is not null then
    scoped := p.dorm_class;
  end if;

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
        select coalesce(jsonb_agg(distinct role), '[]'::jsonb)
        from   public.role_assignments
        where  user_id = auth.uid() and active
      )
    );
  end if;

  return jsonb_build_object(
    'allowed',   true,
    'role',      r,
    'dormClass', coalesce(scoped, p.dorm_class, 'A'),
    'name',      disp_name,
    'email',     u_email,
    'roles',     (
      select coalesce(jsonb_agg(distinct role), '[]'::jsonb)
      from   public.role_assignments
      where  user_id = auth.uid() and active
    )
  );
end $$;

revoke all on function public.get_my_access(text) from public, anon;
grant execute on function public.get_my_access(text) to authenticated;
