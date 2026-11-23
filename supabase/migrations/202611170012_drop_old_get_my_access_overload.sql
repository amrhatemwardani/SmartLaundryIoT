-- Migration: Drop duplicate get_my_access() overload to resolve PGRST203 candidate ambiguity
-- File: supabase/migrations/202611170012_drop_old_get_my_access_overload.sql

-- 1. Drop the zero-argument overload
drop function if exists public.get_my_access();

-- 2. Ensure only the single unified function exists with default parameter
create or replace function public.get_my_access(p_preferred_role text default null)
returns jsonb language plpgsql stable security definer set search_path=public,extensions
as $$
declare 
  p public.student_profiles%rowtype; 
  r text; 
  scoped text; 
  confirmed timestamptz;
  u_email text;
  u_name text;
begin
  select email_confirmed_at, email, coalesce(raw_user_meta_data->>'full_name', '')
  into confirmed, u_email, u_name
  from auth.users where id=auth.uid();

  if confirmed is null then 
    return jsonb_build_object('allowed',false,'reason','email_unverified'); 
  end if;

  select * into p from public.student_profiles where user_id=auth.uid();

  -- If preferred role is requested and active, prioritize it; otherwise use admin > supervisor > student
  if p_preferred_role is not null and exists(select 1 from public.role_assignments where user_id=auth.uid() and role=p_preferred_role and active) then
    select role, dorm_class into r, scoped 
    from public.role_assignments 
    where user_id=auth.uid() and role=p_preferred_role and active 
    limit 1;
  else
    select role, dorm_class into r, scoped 
    from public.role_assignments 
    where user_id=auth.uid() and active 
    order by case role when 'admin' then 1 when 'supervisor' then 2 else 3 end limit 1;
  end if;

  if r is null then 
    return jsonb_build_object('allowed',false,'reason','no_active_role'); 
  end if;

  if r='student' and (p.user_id is null or p.approval_status<>'approved' or p.approved_at is null) then
    return jsonb_build_object(
      'allowed', false,
      'reason', coalesce(p.approval_status,'profile_missing'),
      'role', 'student',
      'dormClass', coalesce(p.dorm_class, 'A'),
      'name', coalesce(p.full_name, u_name, split_part(u_email, '@', 1)),
      'email', u_email,
      'roles', (select coalesce(jsonb_agg(role), '[]'::jsonb) from public.role_assignments where user_id=auth.uid() and active)
    );
  end if;

  return jsonb_build_object(
    'allowed', true,
    'role', r,
    'dormClass', scoped,
    'name', coalesce(p.full_name, u_name, split_part(u_email, '@', 1)),
    'email', u_email,
    'roles', (select coalesce(jsonb_agg(role), '[]'::jsonb) from public.role_assignments where user_id=auth.uid() and active)
  );
end $$;

grant execute on function public.get_my_access(text) to authenticated, service_role, anon, supabase_read_only_user;
