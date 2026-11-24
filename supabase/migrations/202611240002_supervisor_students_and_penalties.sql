-- Migration: Supervisor student directory, student activity details, and penalty enhancements
-- Date: 2026-11-24

-- 1. Ensure staff_set_student_penalty works cleanly without overloading ambiguity and allows staff actions
drop function if exists public.staff_set_student_penalty(uuid, text, text, integer);

create or replace function public.staff_set_student_penalty(
  p_student_id uuid,
  p_penalty_status text,
  p_reason text,
  p_duration_days integer default null,
  p_suspended_until timestamptz default null
)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  actor uuid := auth.uid();
  actor_r text;
  actor_dorm text;
  target_dorm text;
  until_ts timestamptz := null;
  target_name text;
begin
  select ra.role, ra.dorm_class into actor_r, actor_dorm
  from public.role_assignments ra
  where ra.user_id = actor and ra.active
  limit 1;

  if actor_r is null or actor_r not in ('admin', 'supervisor') then
    raise exception 'Staff permissions required';
  end if;

  select dorm_class, full_name into target_dorm, target_name
  from public.student_profiles
  where user_id = p_student_id;

  if target_dorm is null and target_name is null then
    raise exception 'Student profile not found';
  end if;

  if p_penalty_status not in ('none', 'warning', 'suspended', 'blocked') then
    raise exception 'Invalid penalty status: %', p_penalty_status;
  end if;

  if p_penalty_status = 'suspended' then
    if p_suspended_until is not null then
      until_ts := p_suspended_until;
    elsif p_duration_days is not null and p_duration_days > 0 then
      until_ts := now() + (p_duration_days || ' days')::interval;
    else
      until_ts := now() + interval '7 days';
    end if;
  end if;

  update public.student_profiles
  set penalty_status = p_penalty_status,
      penalty_reason = nullif(trim(p_reason), ''),
      suspended_until = until_ts,
      penalty_updated_at = now(),
      penalty_updated_by = actor
  where user_id = p_student_id;

  -- Notify student
  insert into public.notifications(user_id, title, body, category)
  values (
    p_student_id,
    case p_penalty_status
      when 'none' then 'Account status restored'
      when 'warning' then 'Policy warning from dorm supervisor'
      when 'suspended' then 'Laundry account suspended'
      when 'blocked' then 'Laundry account access blocked'
    end,
    case p_penalty_status
      when 'none' then 'Your laundry account has been reinstated to normal status.'
      when 'warning' then 'Notice: ' || coalesce(p_reason, 'Please adhere to laundry room guidelines.')
      when 'suspended' then 'Your account is suspended until ' || to_char(until_ts, 'YYYY-MM-DD HH24:MI') || '. Reason: ' || coalesce(p_reason, 'Policy infraction.')
      when 'blocked' then 'Your account has been blocked from dorm laundry access. Reason: ' || coalesce(p_reason, 'Contact administration.')
    end,
    'support'
  );

  -- Audit log
  insert into public.audit_events(actor_user_id, actor_role, action, entity_type, entity_id, reason, details)
  values (
    actor, actor_r, 'student_penalty_updated', 'student', p_student_id::text, p_reason,
    jsonb_build_object('status', p_penalty_status, 'until', until_ts, 'dorm_class', target_dorm)
  );

  return jsonb_build_object(
    'success', true,
    'user_id', p_student_id,
    'penalty_status', p_penalty_status,
    'suspended_until', until_ts,
    'student_name', target_name
  );
end $$;

grant execute on function public.staff_set_student_penalty(uuid, text, text, integer, timestamptz) to authenticated, service_role, anon, postgres;

-- 2. Enhanced staff_list_dorm_students: allows filtering by dorm or returning all, and adds booking count
drop function if exists public.staff_list_dorm_students(text);

create or replace function public.staff_list_dorm_students(p_dorm_class text default null)
returns table(
  user_id uuid,
  full_name text,
  university_email text,
  university_id text,
  dorm_class text,
  major text,
  phone_number text,
  approval_status text,
  penalty_status text,
  penalty_reason text,
  suspended_until timestamptz,
  wallet_balance_cents integer,
  booking_count bigint,
  created_at timestamptz
)
language plpgsql stable security definer set search_path = public
as $$
declare
  actor uuid := auth.uid();
  actor_r text;
  actor_dorm text;
  filter_dorm text;
begin
  select ra.role, ra.dorm_class into actor_r, actor_dorm
  from public.role_assignments ra
  where ra.user_id = actor and ra.active
  limit 1;

  if actor_r is null or actor_r not in ('admin', 'supervisor') then
    raise exception 'Staff permissions required';
  end if;

  if p_dorm_class is not null and upper(trim(p_dorm_class)) not in ('', 'ALL', 'ANY') then
    filter_dorm := upper(trim(p_dorm_class));
  else
    filter_dorm := null;
  end if;

  return query
  select 
    p.user_id,
    p.full_name::text,
    p.university_email::text,
    p.university_id::text,
    p.dorm_class::text,
    p.major::text,
    p.phone_number::text,
    p.approval_status::text,
    p.penalty_status::text,
    p.penalty_reason::text,
    p.suspended_until,
    coalesce((select sum(w.amount_cents)::integer from public.wallet_ledger w where w.user_id = p.user_id), 0),
    coalesce((select count(*)::bigint from public.laundry_tickets lt where lt.user_id = p.user_id), 0),
    p.created_at
  from public.student_profiles p
  where (filter_dorm is null or p.dorm_class = filter_dorm)
  order by p.created_at desc;
end $$;

grant execute on function public.staff_list_dorm_students(text) to authenticated, service_role, anon, postgres;

-- 3. New RPC: staff_get_student_activity
-- Returns complete profile, booking history, support tickets, and penalty audit events for a student
create or replace function public.staff_get_student_activity(p_student_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  actor uuid := auth.uid();
  actor_r text;
  v_student jsonb;
  v_bookings jsonb;
  v_support jsonb;
  v_audits jsonb;
begin
  select ra.role into actor_r
  from public.role_assignments ra
  where ra.user_id = actor and ra.active
  limit 1;

  if actor_r is null or actor_r not in ('admin', 'supervisor') then
    raise exception 'Staff permissions required';
  end if;

  -- 1. Student profile
  select to_jsonb(sub) into v_student
  from (
    select 
      p.user_id,
      p.full_name,
      p.university_email,
      p.university_id,
      p.dorm_class,
      p.major,
      p.phone_number,
      p.whatsapp_number,
      p.age,
      p.approval_status,
      p.approval_note,
      p.approved_at,
      p.penalty_status,
      p.penalty_reason,
      p.suspended_until,
      p.penalty_updated_at,
      p.created_at,
      coalesce((select sum(w.amount_cents)::integer from public.wallet_ledger w where w.user_id = p.user_id), 0) as wallet_balance_cents,
      coalesce((select sum(lp.points)::integer from public.loyalty_points lp where lp.user_id = p.user_id), 0) as loyalty_points
    from public.student_profiles p
    where p.user_id = p_student_id
  ) sub;

  if v_student is null then
    raise exception 'Student profile not found';
  end if;

  -- 2. Laundry tickets / bookings
  select coalesce(jsonb_agg(to_jsonb(b) order by b.starts_at desc), '[]'::jsonb) into v_bookings
  from (
    select 
      t.id as ticket_id,
      t.status as ticket_status,
      t.created_at,
      t.used_at,
      t.access_granted_at,
      s.starts_at,
      s.duration_minutes,
      s.machine_key,
      coalesce(m.display_name, s.machine_key) as machine_name,
      m.dorm_class as machine_dorm
    from public.laundry_tickets t
    join public.laundry_slots s on s.id = t.slot_id
    left join public.laundry_machines m on m.machine_key = s.machine_key
    where t.user_id = p_student_id
    order by s.starts_at desc
  ) b;

  -- 3. Support tickets
  select coalesce(jsonb_agg(to_jsonb(st) order by st.created_at desc), '[]'::jsonb) into v_support
  from (
    select 
      stk.id,
      stk.ticket_number,
      stk.category,
      stk.subject,
      stk.description,
      stk.status,
      stk.urgency,
      stk.resolution,
      stk.created_at,
      stk.updated_at
    from public.support_tickets stk
    where stk.user_id = p_student_id
    order by stk.created_at desc
  ) st;

  -- 4. Audit history for penalties
  select coalesce(jsonb_agg(to_jsonb(ae) order by ae.created_at desc), '[]'::jsonb) into v_audits
  from (
    select 
      a.id,
      a.action,
      a.actor_role,
      a.reason,
      a.details,
      a.created_at
    from public.audit_events a
    where a.entity_id = p_student_id::text
      and a.action in ('student_penalty_updated', 'student_approved', 'student_rejected', 'student_suspended')
    order by a.created_at desc
    limit 20
  ) ae;

  return jsonb_build_object(
    'student', v_student,
    'bookings', v_bookings,
    'support_tickets', v_support,
    'audit_events', v_audits
  );
end $$;

grant execute on function public.staff_get_student_activity(uuid) to authenticated, service_role, anon, postgres;
