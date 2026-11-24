-- Migration: Support ticket messages, threaded replies, supervisor escalation, and penalty controls
-- Author: Antigravity Team
-- Date: 2026-11-24

-- 1. Support Ticket Messages Table
create table if not exists public.support_ticket_messages (
  id uuid primary key default gen_random_uuid(),
  ticket_id uuid not null references public.support_tickets(id) on delete cascade,
  sender_user_id uuid references auth.users(id) on delete set null,
  sender_role text not null check (sender_role in ('student', 'supervisor', 'admin', 'system')),
  sender_name text not null,
  message text not null,
  created_at timestamptz not null default now()
);

create index if not exists idx_support_ticket_messages_ticket on public.support_ticket_messages(ticket_id, created_at asc);

-- Enable RLS
alter table public.support_ticket_messages enable row level security;

-- 2. RPC to fetch all messages for a ticket
create or replace function public.get_support_ticket_messages(p_ticket_id uuid)
returns table(
  id uuid,
  ticket_id uuid,
  sender_user_id uuid,
  sender_role text,
  sender_name text,
  message text,
  created_at timestamptz
)
language plpgsql stable security definer set search_path = public
as $$
declare
  actor uuid := auth.uid();
  t public.support_tickets%rowtype;
  actor_r text;
  actor_dorm text;
begin
  select * into t from public.support_tickets where id = p_ticket_id;
  if not found then
    raise exception 'Ticket not found';
  end if;

  -- Check caller role
  select ra.role, ra.dorm_class into actor_r, actor_dorm
  from public.role_assignments ra
  where ra.user_id = actor and ra.active
  limit 1;

  -- Authorization check: Admin, Supervisor for dorm, or Student owner
  if actor_r = 'admin' then
    -- allowed
  elsif actor_r = 'supervisor' and (actor_dorm is null or actor_dorm = t.dorm_class) then
    -- allowed
  elsif t.user_id = actor then
    -- allowed
  else
    raise exception 'Access denied to this ticket thread';
  end if;

  return query
  select 
    m.id,
    m.ticket_id,
    m.sender_user_id,
    m.sender_role,
    m.sender_name,
    m.message,
    m.created_at
  from public.support_ticket_messages m
  where m.ticket_id = p_ticket_id
  order by m.created_at asc;
end $$;

grant execute on function public.get_support_ticket_messages(uuid) to authenticated, service_role, anon, postgres;

-- 3. RPC to post a reply in a ticket thread
create or replace function public.add_support_ticket_message(
  p_ticket_id uuid,
  p_message text
)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  actor uuid := auth.uid();
  t public.support_tickets%rowtype;
  actor_r text;
  actor_dorm text;
  s_role text;
  s_name text := 'User';
  new_msg_id uuid;
begin
  if p_message is null or trim(p_message) = '' then
    raise exception 'Message cannot be empty';
  end if;

  select * into t from public.support_tickets where id = p_ticket_id for update;
  if not found then
    raise exception 'Support ticket not found';
  end if;

  -- Check caller role
  select ra.role, ra.dorm_class into actor_r, actor_dorm
  from public.role_assignments ra
  where ra.user_id = actor and ra.active
  limit 1;

  if actor_r = 'admin' then
    s_role := 'admin';
    s_name := 'Laundry Administration';
  elsif actor_r = 'supervisor' and (actor_dorm is null or actor_dorm = t.dorm_class) then
    s_role := 'supervisor';
    s_name := 'Dorm Supervisor (Dorm ' || coalesce(actor_dorm, t.dorm_class) || ')';
  elsif t.user_id = actor then
    s_role := 'student';
    select coalesce(full_name, 'Student') into s_name from public.student_profiles where user_id = actor;
  else
    raise exception 'Access denied: You cannot reply to this ticket';
  end if;

  -- Insert message
  insert into public.support_ticket_messages(ticket_id, sender_user_id, sender_role, sender_name, message)
  values (t.id, actor, s_role, s_name, trim(p_message))
  returning id into new_msg_id;

  -- Update ticket timestamp and reactivate if student replies to a resolved/closed ticket
  if s_role = 'student' and t.status in ('resolved', 'closed') then
    update public.support_tickets
    set status = 'open', updated_at = now()
    where id = t.id;
  else
    update public.support_tickets
    set updated_at = now()
    where id = t.id;
  end if;

  -- If staff replied, notify student
  if s_role in ('supervisor', 'admin') then
    insert into public.notifications(user_id, title, body, category)
    values (
      t.user_id,
      'Reply on Ticket ' || coalesce(t.ticket_number, 'SUP-' || substr(t.id::text, 1, 6)),
      left(trim(p_message), 250),
      'support'
    );
  end if;

  -- Log audit
  insert into public.audit_events(actor_user_id, actor_role, action, entity_type, entity_id, reason, details)
  values (
    actor, s_role, 'support_ticket_reply', 'support_ticket', t.id::text, left(trim(p_message), 200),
    jsonb_build_object('ticket_number', t.ticket_number, 'dorm_class', t.dorm_class)
  );

  return jsonb_build_object(
    'success', true,
    'message_id', new_msg_id,
    'sender_role', s_role,
    'sender_name', s_name,
    'ticket_id', t.id
  );
end $$;

grant execute on function public.add_support_ticket_message(uuid, text) to authenticated, service_role, anon, postgres;

-- 4. Supervisor-to-Admin Escalation RPC
create or replace function public.supervisor_escalate_ticket_to_admin(
  p_student_ticket_id uuid,
  p_subject text default null,
  p_reason text default null,
  p_requested_credit_cents integer default 0
)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  actor uuid := auth.uid();
  actor_r text;
  actor_dorm text;
  st public.support_tickets%rowtype;
  sp public.student_profiles%rowtype;
  v_new_ticket_id uuid;
  v_new_ticket_num text;
  v_escalation_body text;
  v_sup_name text := 'Supervisor';
begin
  -- Caller check
  select ra.role, ra.dorm_class into actor_r, actor_dorm
  from public.role_assignments ra
  where ra.user_id = actor and ra.active
  limit 1;

  if actor_r is null or actor_r not in ('supervisor', 'admin') then
    raise exception 'Only supervisors or administrators can escalate tickets to Admin';
  end if;

  -- Find student ticket
  select * into st from public.support_tickets where id = p_student_ticket_id;
  if not found then
    raise exception 'Target student ticket not found';
  end if;

  -- Find student details
  select * into sp from public.student_profiles where user_id = st.user_id;

  v_new_ticket_num := 'ESC-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8));

  v_escalation_body := '=== SUPERVISOR ESCALATION TO ADMIN ===' || E'\n' ||
    'Student: ' || coalesce(sp.full_name, 'Unknown') || ' (' || coalesce(sp.university_email, 'No email') || ')' || E'\n' ||
    'Student University ID: ' || coalesce(sp.university_id, 'N/A') || E'\n' ||
    'Dorm Room: Dorm ' || coalesce(st.dorm_class, sp.dorm_class, 'B') || E'\n' ||
    'Linked Student Ticket: ' || coalesce(st.ticket_number, st.id::text) || E'\n' ||
    (case when p_requested_credit_cents > 0 then 'Requested Wallet Credit: EGP ' || (p_requested_credit_cents / 100.0)::text || E'\n' else '' end) ||
    E'\nSupervisor Assessment & Notes:\n' || coalesce(nullif(trim(p_reason), ''), 'Supervisor requested administrative action or wallet adjustment.') || E'\n\n' ||
    'Original Ticket Issue:\nSubject: ' || st.subject || E'\nDescription: ' || st.description;

  -- Create new high-priority admin ticket
  insert into public.support_tickets(
    user_id,
    dorm_class,
    category,
    related_ticket_id,
    subject,
    description,
    status,
    urgency,
    ticket_number
  )
  values (
    st.user_id,
    coalesce(st.dorm_class, sp.dorm_class, 'B'),
    'supervisor_escalation',
    st.id,
    coalesce(p_subject, '[ESCALATION] Request Admin Credit / Intervention for ' || coalesce(sp.full_name, 'Student')),
    v_escalation_body,
    'open',
    'urgent',
    v_new_ticket_num
  )
  returning id into v_new_ticket_id;

  -- Append notice message in original student ticket
  insert into public.support_ticket_messages(ticket_id, sender_user_id, sender_role, sender_name, message)
  values (
    st.id,
    actor,
    'supervisor',
    'Dorm Supervisor',
    '⚠️ Escalated this ticket to Administration for priority handling (Reference: ' || v_new_ticket_num || ').' ||
    (case when p_requested_credit_cents > 0 then ' Requested credit: EGP ' || (p_requested_credit_cents / 100.0)::text || '.' else '' end) ||
    (case when p_reason is not null and trim(p_reason) <> '' then ' Note: ' || trim(p_reason) else '' end)
  );

  -- Also seed first message in the escalation ticket
  insert into public.support_ticket_messages(ticket_id, sender_user_id, sender_role, sender_name, message)
  values (
    v_new_ticket_id,
    actor,
    'supervisor',
    'Dorm Supervisor',
    v_escalation_body
  );

  -- Audit event
  insert into public.audit_events(actor_user_id, actor_role, action, entity_type, entity_id, reason, details)
  values (
    actor, actor_r, 'supervisor_escalated_to_admin', 'support_ticket', v_new_ticket_id::text, p_reason,
    jsonb_build_object(
      'student_ticket_id', st.id,
      'student_id', st.user_id,
      'escalation_ticket_number', v_new_ticket_num,
      'requested_credit_cents', p_requested_credit_cents
    )
  );

  return jsonb_build_object(
    'success', true,
    'escalation_ticket_id', v_new_ticket_id,
    'escalation_ticket_number', v_new_ticket_num,
    'student_id', st.user_id,
    'student_name', sp.full_name,
    'student_ticket_number', st.ticket_number
  );
end $$;

grant execute on function public.supervisor_escalate_ticket_to_admin(uuid, text, text, integer) to authenticated, service_role, anon, postgres;

-- 5. Enhanced staff_set_student_penalty with direct date/time support
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

  if target_dorm is null then
    raise exception 'Student profile not found';
  end if;

  if actor_r = 'supervisor' and actor_dorm is not null and actor_dorm <> target_dorm then
    raise exception 'Supervisor can only manage students in assigned Dorm %', actor_dorm;
  end if;

  if p_penalty_status not in ('none', 'warning', 'suspended', 'blocked') then
    raise exception 'Invalid penalty status';
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

-- 6. Also update staff_update_support_ticket so resolution notes are recorded as messages
create or replace function public.staff_update_support_ticket(p_ticket_id uuid, p_status text, p_resolution text default null)
returns void language plpgsql security definer set search_path = public
as $$
declare
  t public.support_tickets%rowtype;
  actor uuid := auth.uid();
  actor_r text;
  actor_dorm text;
  s_role text;
  s_name text;
begin
  select * into t from public.support_tickets where id = p_ticket_id for update;
  if not found then raise exception 'Support request not found'; end if;
  if p_status not in ('open', 'in_progress', 'resolved', 'closed') then raise exception 'Invalid support status'; end if;

  select ra.role, ra.dorm_class into actor_r, actor_dorm
  from public.role_assignments ra
  where ra.user_id = actor and ra.active
  limit 1;

  if actor_r is null or (actor_r <> 'admin' and (actor_r <> 'supervisor' or actor_dorm <> t.dorm_class)) then
    raise exception 'Not authorized for this dorm';
  end if;

  s_role := actor_r;
  s_name := case when actor_r = 'admin' then 'Laundry Administration' else 'Dorm Supervisor' end;

  update public.support_tickets
  set status = p_status,
      resolution = coalesce(left(p_resolution, 5000), resolution),
      updated_at = now()
  where id = t.id;

  -- If resolution or message was provided, add message
  if p_resolution is not null and trim(p_resolution) <> '' then
    insert into public.support_ticket_messages(ticket_id, sender_user_id, sender_role, sender_name, message)
    values (t.id, actor, s_role, s_name, trim(p_resolution));
  end if;

  if p_status in ('resolved', 'closed') then
    insert into public.notifications(user_id, title, body, category)
    values (
      t.user_id,
      'Support request ' || p_status,
      coalesce(nullif(trim(p_resolution), ''), 'Your support request status has been updated to ' || p_status || '.'),
      'support'
    );
  end if;

  insert into public.audit_events(actor_user_id, actor_role, action, entity_type, entity_id, reason, details)
  values (
    actor, 'staff', 'support_ticket_' || p_status, 'support_ticket', t.id::text, left(p_resolution, 1000),
    jsonb_build_object('dorm_class', t.dorm_class, 'new_status', p_status)
  );
end $$;

grant execute on function public.staff_update_support_ticket(uuid, text, text) to authenticated, service_role, anon, postgres;
