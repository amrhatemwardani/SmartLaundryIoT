-- Migration: Fix supervisor_dashboard_metrics query for iot_devices (active boolean instead of status)
-- File: supabase/migrations/202611170010_fix_supervisor_metrics_iot_status.sql

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
  select count(*) into online_devices from public.iot_devices where dorm_class=assigned_dorm and active;

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

grant execute on function public.supervisor_dashboard_metrics(text) to authenticated, service_role, anon, supabase_read_only_user;
