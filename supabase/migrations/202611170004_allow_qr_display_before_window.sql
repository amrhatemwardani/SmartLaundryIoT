-- Allow students to generate and view their ticket QR credential ahead of time.
-- The access time window constraint is strictly enforced at the physical door scanner by iot_consume_door_qr(),
-- so students can view their ticket QR on their phone without throwing a premature error.

create or replace function public.student_issue_ticket_qr(p_ticket_id uuid)
returns text language plpgsql security definer set search_path=public,extensions
as $$
declare
  actor uuid := auth.uid();
  t public.laundry_tickets%rowtype;
  s public.laundry_slots%rowtype;
  token text;
  digest bytea;
  existing_cred public.access_credentials%rowtype;
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

  -- If ticket slot is already past (finished + 10 min grace period), reject
  if now() > s.starts_at + (s.duration_minutes || ' minutes')::interval + interval '10 minutes' then
    raise exception 'This ticket slot has already ended';
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
    token_hash = excluded.token_hash,
    valid_from = excluded.valid_from,
    valid_until = excluded.valid_until,
    used_at = null,
    created_at = now();

  return token;
end $$;

revoke all on function public.student_issue_ticket_qr(uuid) from public, anon;
grant execute on function public.student_issue_ticket_qr(uuid) to authenticated;
