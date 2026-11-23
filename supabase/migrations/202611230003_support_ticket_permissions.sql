-- Grant permissions on support_tickets table
grant select, insert on public.support_tickets to authenticated;

-- Ensure RLS is active and allows students to insert their own tickets
alter table public.support_tickets enable row level security;

drop policy if exists support_tickets_student_insert on public.support_tickets;
create policy support_tickets_student_insert on public.support_tickets
  for insert to authenticated
  with check (user_id = auth.uid());

drop policy if exists support_tickets_student_select on public.support_tickets;
create policy support_tickets_student_select on public.support_tickets
  for select to authenticated
  using (
    user_id = auth.uid()
    or exists (select 1 from public.role_assignments ra where ra.user_id = auth.uid() and ra.role in ('admin', 'supervisor') and ra.active)
  );

-- Also provide a robust student_create_support_ticket RPC
create or replace function public.student_create_support_ticket(
  p_category text,
  p_machine_key text default null,
  p_urgency text default 'medium',
  p_subject text default null,
  p_description text default null
)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  actor uuid := auth.uid();
  s_dorm text;
  new_id uuid;
  new_num text;
begin
  if actor is null then
    raise exception 'Authentication required';
  end if;

  select dorm_class into s_dorm
  from public.student_profiles
  where user_id = actor;

  if s_dorm is null then
    s_dorm := 'A';
  end if;

  insert into public.support_tickets (
    user_id,
    dorm_class,
    category,
    machine_key,
    urgency,
    subject,
    description
  )
  values (
    actor,
    s_dorm,
    coalesce(nullif(trim(p_category), ''), 'other'),
    nullif(trim(p_machine_key), ''),
    coalesce(nullif(trim(p_urgency), ''), 'medium'),
    coalesce(nullif(trim(p_subject), ''), 'Support Request'),
    coalesce(nullif(trim(p_description), ''), 'No description provided')
  )
  returning id, ticket_number into new_id, new_num;

  insert into public.audit_events (
    actor_user_id,
    actor_role,
    action,
    entity_type,
    entity_id,
    details
  )
  values (
    actor,
    'student',
    'support_ticket_created',
    'support_ticket',
    new_id::text,
    jsonb_build_object('ticket_number', new_num, 'category', p_category, 'urgency', p_urgency)
  );

  return jsonb_build_object(
    'success', true,
    'ticket_id', new_id,
    'ticket_number', new_num
  );
end $$;

grant execute on function public.student_create_support_ticket(text, text, text, text, text) to authenticated, service_role, anon, postgres;
