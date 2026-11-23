-- Migration: Activate Admin and Supervisor Portals, metrics, multi-role access, and staff assignment
-- File: supabase/migrations/202611170005_admin_supervisor_portal_activation.sql

-- 1. Upgrade get_my_access to support optional preferred_role and return available active roles
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

revoke all on function public.get_my_access(text) from public,anon;
grant execute on function public.get_my_access(text) to authenticated;


-- 2. Create admin_dashboard_metrics RPC for live overview stats
create or replace function public.admin_dashboard_metrics()
returns jsonb language plpgsql stable security definer set search_path=public
as $$
declare
  actor uuid := auth.uid();
  total_students integer;
  pending_students integer;
  approved_students integer;
  tickets_today integer;
  active_machines integer;
  total_machines integer;
  active_staff integer;
  pending_invitations integer := 0;
begin
  if not exists(select 1 from public.role_assignments where user_id=actor and role='admin' and active) then
    raise exception 'Admin role required';
  end if;

  select count(*) into total_students from public.student_profiles;
  select count(*) into pending_students from public.student_profiles where approval_status='pending';
  select count(*) into approved_students from public.student_profiles where approval_status='approved';
  select count(*) into tickets_today from public.laundry_tickets t
    join public.laundry_slots s on s.id=t.slot_id
    where s.starts_at >= current_date and s.starts_at < current_date + interval '1 day';
  select count(*) into total_machines from public.laundry_machines;
  select count(*) into active_machines from public.laundry_machines where status='available';
  select count(distinct user_id) into active_staff from public.role_assignments where role in ('admin','supervisor') and active;

  return jsonb_build_object(
    'total_students', total_students,
    'pending_students', pending_students,
    'approved_students', approved_students,
    'tickets_today', tickets_today,
    'total_machines', total_machines,
    'active_machines', active_machines,
    'active_staff', active_staff,
    'pending_invitations', pending_invitations,
    'system_status', 'Operational'
  );
end $$;

revoke all on function public.admin_dashboard_metrics() from public,anon;
grant execute on function public.admin_dashboard_metrics() to authenticated;


-- 3. Create supervisor_dashboard_metrics RPC for live supervisor stats
create or replace function public.supervisor_dashboard_metrics(p_dorm_class text default null)
returns jsonb language plpgsql stable security definer set search_path=public
as $$
declare
  actor uuid := auth.uid();
  assigned_dorm text := p_dorm_class;
  today_bookings integer;
  free_capacity integer;
  total_capacity integer;
  active_cycles integer;
  online_devices integer;
  total_devices integer;
begin
  if not exists(select 1 from public.role_assignments where user_id=actor and active and role in ('admin','supervisor')) then
    raise exception 'Staff role required';
  end if;

  if assigned_dorm is null then
    select dorm_class into assigned_dorm from public.role_assignments where user_id=actor and active and role='supervisor' limit 1;
    if assigned_dorm is null then assigned_dorm := 'C'; end if;
  end if;

  select count(*) into today_bookings
  from public.laundry_tickets t
  join public.laundry_slots s on s.id=t.slot_id
  join public.laundry_machines m on m.machine_key=s.machine_key
  where m.dorm_class=assigned_dorm
    and s.starts_at >= current_date and s.starts_at < current_date + interval '1 day';

  select count(*) into total_capacity from public.laundry_machines where dorm_class=assigned_dorm;
  select count(*) into free_capacity from public.laundry_machines where dorm_class=assigned_dorm and status='available';
  select count(*) into active_cycles from public.laundry_tickets t
    join public.laundry_slots s on s.id=t.slot_id
    join public.laundry_machines m on m.machine_key=s.machine_key
    where m.dorm_class=assigned_dorm and t.status='confirmed'
      and now() between s.starts_at and s.starts_at + (s.duration_minutes || ' minutes')::interval;

  select count(*) into total_devices from public.iot_devices where dorm_class=assigned_dorm;
  select count(*) into online_devices from public.iot_devices where dorm_class=assigned_dorm and status='online';

  return jsonb_build_object(
    'dorm_class', assigned_dorm,
    'today_bookings', today_bookings,
    'free_capacity', free_capacity,
    'total_capacity', total_capacity,
    'active_cycles', active_cycles,
    'online_devices', online_devices,
    'total_devices', greatest(total_devices, 1)
  );
end $$;

revoke all on function public.supervisor_dashboard_metrics(text) from public,anon;
grant execute on function public.supervisor_dashboard_metrics(text) to authenticated;


-- 4. Assign Admin and Dorm C Supervisor roles to user s-amr.farouk@zewailcity.edu.eg
insert into public.role_assignments (user_id, role, dorm_class, active)
values 
  ('4f7011d5-5e6a-486a-8ef1-8e9ca23f4e26', 'admin', null, true),
  ('4f7011d5-5e6a-486a-8ef1-8e9ca23f4e26', 'supervisor', 'C', true)
on conflict (user_id, role, dorm_class) do update set active = true;


-- 5. Seed a pending student application in auth.users + student_profiles for review testing
do $$
declare
  test_uid uuid := '77777777-7777-7777-7777-777777777777';
begin
  if not exists (select 1 from auth.users where id = test_uid) then
    insert into auth.users (
      instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
      raw_app_meta_data, raw_user_meta_data, created_at, updated_at
    ) values (
      '00000000-0000-0000-0000-000000000000',
      test_uid,
      'authenticated',
      'authenticated',
      's-youssef.ali@zewailcity.edu.eg',
      '$2a$10$e8wV8qC696hR/tT3R5qXpuxgZk/g6p4P9fO0m8j9VbFhWq/3.lZ0q',
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
  end if;
end $$;


-- 6. Seed a support ticket in Dorm C for queue testing
insert into public.support_tickets (
  user_id, dorm_class, category, subject, description, status
)
select 
  '4f7011d5-5e6a-486a-8ef1-8e9ca23f4e26',
  'C',
  'washer',
  'Washer 02 door latch loose',
  'Washer 02 in Dorm C has a loose door latch and stops mid-cycle with an unbalance error.',
  'open'
where not exists (
  select 1 from public.support_tickets where subject = 'Washer 02 door latch loose'
);
