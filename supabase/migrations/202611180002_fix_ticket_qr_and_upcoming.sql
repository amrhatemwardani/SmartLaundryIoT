-- Migration: Fix student QR generation and link test ticket to upcoming slot
-- File: supabase/migrations/202611180002_fix_ticket_qr_and_upcoming.sql

-- 1. Upgrade student_issue_ticket_qr to never throw on confirmed tickets
--    The physical door scanner (iot_consume_door_qr) is the authority on access timing.
--    The student portal should always be able to render the QR code for a confirmed ticket.
create or replace function public.student_issue_ticket_qr(p_ticket_id uuid)
returns text language plpgsql security definer set search_path = public, extensions
as $$
declare
  actor  uuid := auth.uid();
  t      public.laundry_tickets%rowtype;
  s      public.laundry_slots%rowtype;
  token  text;
  digest bytea;
begin
  select * into t from public.laundry_tickets
  where id = p_ticket_id and user_id = actor and status = 'confirmed';

  if not found then
    raise exception 'Confirmed ticket not found';
  end if;

  select * into s from public.laundry_slots where id = t.slot_id;
  if not found then
    raise exception 'Ticket slot not found';
  end if;

  -- Generate secure random 32-byte token and its SHA256 digest
  select encode(extensions.gen_random_bytes(32), 'hex') into token;
  digest := extensions.digest(token, 'sha256');

  insert into public.access_credentials(
    ticket_id,
    token_hash,
    valid_from,
    valid_until
  )
  values(
    t.id,
    digest,
    s.starts_at - interval '10 minutes',
    s.starts_at + (s.duration_minutes || ' minutes')::interval + interval '10 minutes'
  )
  on conflict(ticket_id) do update set
    token_hash  = excluded.token_hash,
    valid_from  = excluded.valid_from,
    valid_until = excluded.valid_until,
    used_at     = null,
    created_at  = now();

  return token;
end $$;

revoke all on function public.student_issue_ticket_qr(uuid) from public, anon;
grant execute on function public.student_issue_ticket_qr(uuid) to authenticated;


-- 2. Link test student's existing confirmed ticket to an upcoming daytime slot for today
--    so they immediately have a working live booking to test and inspect QR generation.
do $$
declare
  target_slot_id uuid;
  test_ticket_id uuid := '07f52915-b604-4272-9677-c4f2fe828bc8';
begin
  -- Find an open slot for today in Dorm C
  select s.id into target_slot_id
  from public.laundry_slots s
  join public.laundry_machines m on m.machine_key = s.machine_key
  where m.dorm_class = 'C'
    and s.starts_at >= now()
    and s.status = 'open'
  order by s.starts_at asc
  limit 1;

  if target_slot_id is not null and exists(select 1 from public.laundry_tickets where id = test_ticket_id) then
    update public.laundry_tickets
    set slot_id = target_slot_id,
        status = 'confirmed'
    where id = test_ticket_id;
  end if;
end $$;
