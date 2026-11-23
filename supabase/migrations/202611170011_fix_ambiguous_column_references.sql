-- Migration: Fix ambiguous user_id references in staff_pending_applications, admin_list_staff, and staff_list_bookings
-- File: supabase/migrations/202611170011_fix_ambiguous_column_references.sql

-- 1. staff_pending_applications
create or replace function public.staff_pending_applications()
returns table(user_id uuid, full_name text, university_email text, university_id text, major text, age smallint, phone_number text, dorm_class text, created_at timestamptz)
language plpgsql stable security definer set search_path=public
as $$
declare
  actor uuid := auth.uid();
begin
  if not exists(select 1 from public.role_assignments r where r.role='admin' and r.user_id=actor and r.active)
     and not exists(select 1 from public.role_assignments r where r.role='supervisor' and r.user_id=actor and r.active) then
    raise exception 'Staff role required';
  end if;

  return query select 
    p.user_id, p.full_name, p.university_email, p.university_id, p.major, p.age, p.phone_number, p.dorm_class, p.created_at 
  from public.student_profiles p
  where p.approval_status='pending' 
    and (
      exists(select 1 from public.role_assignments a where a.user_id=actor and a.role='admin' and a.active)
      or exists(select 1 from public.role_assignments a where a.user_id=actor and a.role='supervisor' and a.active and a.dorm_class=p.dorm_class)
    )
  order by p.created_at asc;
end $$;

grant execute on function public.staff_pending_applications() to authenticated, service_role, anon, supabase_read_only_user;


-- 2. admin_list_staff
create or replace function public.admin_list_staff()
returns table(user_id uuid, email text, role text, dorm_class text, active boolean, assigned_at timestamptz)
language plpgsql stable security definer set search_path=public
as $$
declare
  actor uuid := auth.uid();
begin
  if not exists(select 1 from public.role_assignments ra where ra.user_id=actor and ra.role='admin' and ra.active) then
    raise exception 'Admin role required';
  end if;

  return query select 
    r.user_id, u.email::text, r.role, r.dorm_class, r.active, r.created_at 
  from public.role_assignments r 
  join auth.users u on u.id=r.user_id 
  where r.role in ('admin','supervisor') 
  order by r.active desc, r.role, r.created_at desc;
end $$;

grant execute on function public.admin_list_staff() to authenticated, service_role, anon, supabase_read_only_user;


-- 3. staff_list_bookings
create or replace function public.staff_list_bookings(p_from timestamptz default now()-interval '7 days', p_until timestamptz default now()+interval '60 days')
returns table(ticket_id uuid, student_id uuid, student_name text, student_email text, dorm_class text, machine_key text, machine_name text, starts_at timestamptz, duration_minutes smallint, status text, created_at timestamptz)
language plpgsql stable security definer set search_path=public
as $$
declare
  actor uuid := auth.uid();
begin
  if not exists(select 1 from public.role_assignments r where r.user_id=actor and r.active and r.role in ('supervisor','admin')) then
    raise exception 'Staff role required';
  end if;

  return query select 
    t.id, t.user_id, p.full_name, p.university_email, m.dorm_class, m.machine_key, m.display_name, s.starts_at, s.duration_minutes, t.status, t.created_at 
  from public.laundry_tickets t 
  join public.laundry_slots s on s.id=t.slot_id 
  join public.laundry_machines m on m.machine_key=s.machine_key 
  join public.student_profiles p on p.user_id=t.user_id
  where s.starts_at between p_from and p_until 
    and (
      exists(select 1 from public.role_assignments a where a.user_id=actor and a.role='admin' and a.active)
      or exists(select 1 from public.role_assignments a where a.user_id=actor and a.role='supervisor' and a.active and a.dorm_class=m.dorm_class)
    )
  order by s.starts_at;
end $$;

grant execute on function public.staff_list_bookings(timestamptz, timestamptz) to authenticated, service_role, anon, supabase_read_only_user;
