-- Migration: Interactive 30-minute slot booking, machine states (GREEN/ORANGE/RED/GRAY/BLUE),
-- single-use QR invalidation, and IoT validation endpoint.
-- File: supabase/migrations/202611230004_interactive_slot_machine_booking.sql

-- 1. ADD QR ACCESS & CONSUMPTION COLUMNS TO LAUNDRY_TICKETS
alter table public.laundry_tickets
  add column if not exists used_at timestamptz,
  add column if not exists access_granted_at timestamptz;

-- 2. SEED 30-MINUTE SLOTS FOR ALL DORMS (09:00 to 21:00) FOR NEXT 7 DAYS
create or replace function public.seed_upcoming_30min_slots()
returns void
language plpgsql security definer set search_path = public
as $$
declare
  d date;
  hr integer;
  mn integer;
  m record;
  slot_ts timestamptz;
begin
  for d in select generate_series(current_date, current_date + interval '7 days', interval '1 day')::date loop
    for hr in 9..20 loop
      for mn in 0..1 loop
        slot_ts := (d || ' ' || lpad(hr::text, 2, '0') || ':' || lpad((mn * 30)::text, 2, '0') || ':00')::timestamptz;
        for m in select machine_key from public.laundry_machines loop
          insert into public.laundry_slots(machine_key, starts_at, duration_minutes, status)
          values(m.machine_key, slot_ts, 30, 'open')
          on conflict (machine_key, starts_at) do nothing;
        end loop;
      end loop;
    end loop;
  end loop;
end $$;

grant execute on function public.seed_upcoming_30min_slots() to authenticated, service_role, anon, postgres;
select public.seed_upcoming_30min_slots();


-- 3. RPC: GET ALL 30-MINUTE SLOTS FOR A DAY WITH ACCURATE STATUS (ENDED, BOOKED, BUSY, AVAILABLE)
drop function if exists public.student_get_day_slots(date);
create or replace function public.student_get_day_slots(p_date date)
returns table(
  slot_time timestamptz,
  time_label text,
  slot_status text,
  available_count integer,
  total_machines integer
)
language plpgsql stable security definer set search_path = public
as $$
declare
  p public.student_profiles%rowtype;
  m_total integer;
  now_ts timestamptz := now();
begin
  select * into p from public.student_profiles where user_id = auth.uid();
  if not found or p.approval_status <> 'approved' then
    raise exception 'Approved student account required';
  end if;

  -- Total active machines in this dorm (qualified alias to avoid ambiguity)
  select count(*) into m_total
  from public.laundry_machines lm
  where lm.dorm_class = p.dorm_class and lm.status = 'available';

  if m_total = 0 then
    m_total := 1;
  end if;

  return query
  with time_points as (
    select
      (p_date || ' ' || lpad(hr::text, 2, '0') || ':' || lpad((mn * 30)::text, 2, '0') || ':00')::timestamptz as ts
    from generate_series(9, 20) as hr
    cross join generate_series(0, 1) as mn
  ),
  slot_metrics as (
    select
      tp.ts,
      to_char(tp.ts at time zone 'Africa/Cairo', 'HH24:MI') as t_lbl,
      -- Confirmed bookings at this time for student's dorm
      count(distinct t.id) filter (
        where t.status = 'confirmed'
      ) as confirmed_cnt,
      -- Temporary checkout holds (pending_payment within 5 mins)
      count(distinct t.id) filter (
        where t.status = 'pending_payment' and t.created_at > (now_ts - interval '5 minutes')
      ) as hold_cnt
    from time_points tp
    left join public.laundry_slots s on s.starts_at = tp.ts
    left join public.laundry_machines m on m.machine_key = s.machine_key and m.dorm_class = p.dorm_class
    left join public.laundry_tickets t on t.slot_id = s.id
    group by tp.ts
  )
  select
    sm.ts as slot_time,
    sm.t_lbl as time_label,
    case
      -- Past slot (ended)
      when (sm.ts + interval '30 minutes') <= now_ts then 'ended'
      -- Currently active window with running cycle
      when now_ts between sm.ts and (sm.ts + interval '30 minutes') and sm.confirmed_cnt > 0 then 'busy'
      -- All machines booked in dorm
      when (sm.confirmed_cnt + sm.hold_cnt) >= m_total then 'booked'
      -- Otherwise available
      else 'available'
    end as slot_status,
    greatest(0, m_total - (sm.confirmed_cnt + sm.hold_cnt)::integer) as available_count,
    m_total as total_machines
  from slot_metrics sm
  order by sm.ts;
end $$;

grant execute on function public.student_get_day_slots(date) to authenticated, service_role;


-- 4. RPC: GET ALL MACHINES AND THEIR PRECISE STATES FOR A SPECIFIC 30-MIN SLOT
-- States: 'green' (Available), 'orange' (Temporarily Busy), 'red' (Reserved),
--         'gray' (Out of Service), 'blue' (Running / Washing)
create or replace function public.student_get_slot_machines(p_starts_at timestamptz)
returns table(
  machine_key text,
  display_name text,
  dorm_class text,
  machine_state text,
  state_label text,
  reservation_info text,
  is_available boolean,
  slot_id uuid
)
language plpgsql security definer set search_path = public
as $$
declare
  p public.student_profiles%rowtype;
  now_ts timestamptz := now();
  m record;
  s_id uuid;
  t_row record;
  st text;
  st_lbl text;
  res_info text;
  avail boolean;
begin
  select * into p from public.student_profiles where user_id = auth.uid();
  if not found or p.approval_status <> 'approved' then
    raise exception 'Approved student account required';
  end if;

  for m in
    select lm.machine_key, lm.display_name, lm.dorm_class, lm.status
    from public.laundry_machines lm
    where lm.dorm_class = p.dorm_class
    order by lm.display_name
  loop
    -- Ensure slot row exists
    insert into public.laundry_slots(machine_key, starts_at, duration_minutes, status)
    values(m.machine_key, p_starts_at, 30, 'open')
    on conflict (machine_key, starts_at) do nothing;

    select id into s_id
    from public.laundry_slots
    where machine_key = m.machine_key and starts_at = p_starts_at
    limit 1;

    -- Check machine hardware status
    if m.status in ('out_of_service', 'offline') then
      st := 'gray';
      st_lbl := 'Out of Service';
      res_info := 'Hardware maintenance · Sensor offline';
      avail := false;
    else
      -- Check tickets for this slot
      select t.id, t.user_id, t.status, t.created_at, sp.full_name into t_row
      from public.laundry_tickets t
      left join public.student_profiles sp on sp.user_id = t.user_id
      where t.slot_id = s_id and t.status in ('confirmed', 'pending_payment')
      order by (t.status = 'confirmed') desc, t.created_at desc
      limit 1;

      if found and t_row.status = 'confirmed' then
        -- If current time is within slot -> Running / Washing (BLUE)
        if now_ts between p_starts_at and (p_starts_at + interval '30 minutes') then
          st := 'blue';
          st_lbl := 'Running / Washing';
          res_info := case when t_row.user_id = auth.uid() then 'Your active wash cycle' else 'Active wash cycle in progress' end;
        else
          st := 'red';
          st_lbl := 'Reserved';
          res_info := case when t_row.user_id = auth.uid() then 'Reserved by you' else 'Reserved for this time slot' end;
        end if;
        avail := false;
      elsif found and t_row.status = 'pending_payment' and t_row.created_at > (now_ts - interval '5 minutes') then
        st := 'orange';
        st_lbl := 'Temporarily Busy';
        res_info := 'Checkout hold in progress (5m lock)';
        avail := false;
      else
        -- Check if past
        if (p_starts_at + interval '30 minutes') <= now_ts then
          st := 'gray';
          st_lbl := 'Time Passed';
          res_info := 'This slot timing has already passed';
          avail := false;
        else
          st := 'green';
          st_lbl := 'Available';
          res_info := 'Ready for immediate booking';
          avail := true;
        end if;
      end if;
    end if;

    machine_key      := m.machine_key;
    display_name     := m.display_name;
    dorm_class       := m.dorm_class;
    machine_state    := st;
    state_label      := st_lbl;
    reservation_info := res_info;
    is_available     := avail;
    slot_id          := s_id;
    return next;
  end loop;
end $$;

grant execute on function public.student_get_slot_machines(timestamptz) to authenticated, service_role;


-- 5. RPC: FIXED & SECURED student_issue_ticket_qr WITH PROPER ENCODE, HMAC & SINGLE-USE CHECK
create or replace function public.student_issue_ticket_qr(p_ticket_id uuid)
returns jsonb
language plpgsql security definer set search_path = public, extensions, pg_catalog
as $$
declare
  t          public.laundry_tickets%rowtype;
  s          public.laundry_slots%rowtype;
  m          public.laundry_machines%rowtype;
  p          public.student_profiles%rowtype;
  payload    text;
  sig        text;
  secret     text := 'zc-door-key-super-secret-2026';
  valid_from timestamptz;
  valid_until timestamptz;
  now_ts     timestamptz := now();
  time_remaining_seconds integer;
begin
  -- 1. Check student profile & penalty status
  select * into p from public.student_profiles where user_id = auth.uid();
  if not found or p.approval_status <> 'approved' then
    raise exception 'Approved student account required';
  end if;

  if p.penalty_status = 'blocked' then
    return jsonb_build_object(
      'allowed', false,
      'status', 'blocked',
      'message', 'Your account has been blocked by dorm administration.'
    );
  end if;

  if p.penalty_status = 'suspended' and (p.suspended_until is null or now_ts < p.suspended_until) then
    return jsonb_build_object(
      'allowed', false,
      'status', 'suspended',
      'message', 'Your account is suspended until ' || to_char(p.suspended_until, 'YYYY-MM-DD HH24:MI')
    );
  end if;

  -- 2. Find confirmed ticket
  select * into t from public.laundry_tickets where id = p_ticket_id and user_id = auth.uid() and status = 'confirmed';
  if not found then
    raise exception 'Confirmed ticket not found';
  end if;

  -- Single-use check: if already consumed by scanner
  if t.used_at is not null then
    return jsonb_build_object(
      'allowed', false,
      'status', 'expired',
      'message', 'This QR code has already been scanned and consumed. Door access closed.'
    );
  end if;

  select * into s from public.laundry_slots where id = t.slot_id;
  select * into m from public.laundry_machines where machine_key = s.machine_key;

  valid_from := s.starts_at;
  valid_until := s.starts_at + interval '10 minutes';

  -- 3. Enforce timing window: slot start to slot start + 10 mins
  if now_ts < valid_from then
    return jsonb_build_object(
      'allowed', false,
      'status', 'early',
      'starts_at', s.starts_at,
      'valid_from', valid_from,
      'valid_until', valid_until,
      'seconds_until_start', extract(epoch from (valid_from - now_ts))::integer,
      'message', 'Door QR code activates at slot start: ' || to_char(s.starts_at, 'HH12:MI AM') || '. Please return at your booking time.'
    );
  end if;

  if now_ts > valid_until then
    return jsonb_build_object(
      'allowed', false,
      'status', 'expired',
      'starts_at', s.starts_at,
      'valid_from', valid_from,
      'valid_until', valid_until,
      'message', 'QR Entry Expired: Room access window closed 10 minutes after slot start. Contact dorm supervisor if you arrived late.'
    );
  end if;

  time_remaining_seconds := greatest(1, extract(epoch from (valid_until - now_ts))::integer);

  -- 4. Generate verifiable signed QR payload using pg_catalog.encode
  payload := t.id::text || ':' || t.user_id::text || ':' || m.dorm_class || ':' || extract(epoch from valid_from)::bigint || ':' || extract(epoch from valid_until)::bigint;
  sig := encode(extensions.hmac(payload::bytea, secret::bytea, 'sha256'), 'hex');

  -- Log audit
  insert into public.audit_events(actor_user_id, actor_role, action, entity_type, entity_id, details)
  values(auth.uid(), 'student', 'door_qr_issued', 'ticket', t.id::text, jsonb_build_object(
    'slot_id', s.id, 'dorm_class', m.dorm_class, 'expires_in_sec', time_remaining_seconds
  ));

  return jsonb_build_object(
    'allowed', true,
    'status', 'active',
    'ticket_id', t.id,
    'qr_data', payload || ':' || sig,
    'dorm_class', m.dorm_class,
    'machine_name', m.display_name,
    'starts_at', s.starts_at,
    'valid_from', valid_from,
    'valid_until', valid_until,
    'time_remaining_seconds', time_remaining_seconds
  );
end $$;

grant execute on function public.student_issue_ticket_qr(uuid) to authenticated, service_role, anon, postgres;


-- 6. RPC: ESP32 IoT VALIDATION ENDPOINT WITH SINGLE-USE QR CONSUMPTION
create or replace function public.iot_validate_qr_token(
  p_qr_data text,
  p_device_key text default 'esp32-door-key-2026'
)
returns jsonb
language plpgsql security definer set search_path = public, extensions, pg_catalog
as $$
declare
  parts text[];
  t_id uuid;
  u_id uuid;
  d_class text;
  v_from timestamptz;
  v_until timestamptz;
  provided_sig text;
  expected_sig text;
  secret text := 'zc-door-key-super-secret-2026';
  raw_payload text;
  t public.laundry_tickets%rowtype;
  s public.laundry_slots%rowtype;
  m public.laundry_machines%rowtype;
  now_ts timestamptz := now();
begin
  -- Validate IoT Device Key (ESP32 must authenticate)
  if p_device_key is null or p_device_key <> 'esp32-door-key-2026' then
    return jsonb_build_object(
      'success', false,
      'code', 'INVALID_DEVICE',
      'message', 'ESP32 device authentication failed'
    );
  end if;

  -- Format: ticket_id:user_id:dorm_class:valid_from_epoch:valid_until_epoch:sig
  parts := string_to_array(p_qr_data, ':');
  if array_length(parts, 1) <> 6 then
    return jsonb_build_object(
      'success', false,
      'code', 'MALFORMED_TOKEN',
      'message', 'QR token format is invalid'
    );
  end if;

  begin
    t_id := parts[1]::uuid;
    u_id := parts[2]::uuid;
    d_class := parts[3];
    v_from := to_timestamp(parts[4]::bigint);
    v_until := to_timestamp(parts[5]::bigint);
    provided_sig := parts[6];
  exception when others then
    return jsonb_build_object('success', false, 'code', 'PARSE_ERROR', 'message', 'Invalid token parameters');
  end;

  -- Recompute signature using pg_catalog.encode
  raw_payload := parts[1] || ':' || parts[2] || ':' || parts[3] || ':' || parts[4] || ':' || parts[5];
  expected_sig := encode(extensions.hmac(raw_payload::bytea, secret::bytea, 'sha256'), 'hex');

  if provided_sig <> expected_sig then
    return jsonb_build_object(
      'success', false,
      'code', 'TAMPERED_TOKEN',
      'message', 'Cryptographic signature mismatch'
    );
  end if;

  -- Check time validity
  if now_ts < v_from then
    return jsonb_build_object('success', false, 'code', 'EARLY_ACCESS', 'message', 'Slot has not started yet');
  end if;

  if now_ts > v_until then
    return jsonb_build_object('success', false, 'code', 'EXPIRED_TOKEN', 'message', 'QR code has expired (10m window exceeded)');
  end if;

  -- Fetch ticket
  select * into t from public.laundry_tickets where id = t_id and user_id = u_id;
  if not found or t.status <> 'confirmed' then
    return jsonb_build_object('success', false, 'code', 'INVALID_TICKET', 'message', 'Ticket is not confirmed');
  end if;

  -- ENFORCE SINGLE USE: check if already used
  if t.used_at is not null then
    return jsonb_build_object(
      'success', false,
      'code', 'ALREADY_USED',
      'message', 'This QR code was already scanned and used. Single-use policy enforced.'
    );
  end if;

  select * into s from public.laundry_slots where id = t.slot_id;
  select * into m from public.laundry_machines where machine_key = s.machine_key;

  -- MARK TOKEN AS CONSUMED (single use)
  update public.laundry_tickets
  set used_at = now_ts, access_granted_at = now_ts
  where id = t_id;

  -- Log IoT access event in audit_events
  insert into public.audit_events(actor_user_id, actor_role, action, entity_type, entity_id, details)
  values(
    u_id,
    'iot_device',
    'qr_door_access_granted',
    'laundry_ticket',
    t_id::text,
    jsonb_build_object(
      'machine_key', s.machine_key,
      'dorm_class', m.dorm_class,
      'accessed_at', now_ts
    )
  );

  return jsonb_build_object(
    'success', true,
    'code', 'ACCESS_GRANTED',
    'action', 'unlock_door',
    'machine_key', s.machine_key,
    'machine_name', m.display_name,
    'dorm_class', m.dorm_class,
    'ticket_id', t.id,
    'time', now_ts
  );
end $$;

grant execute on function public.iot_validate_qr_token(text, text) to anon, authenticated, service_role, postgres;

-- 7. SEED ONE COMPLETED PAST TICKET FOR DEMO / TEST PURPOSES
do $$
declare
  u_tarek uuid;
  past_slot_id uuid;
  m_key text;
begin
  select id into u_tarek from auth.users where lower(email) = 's-tarek.nour@zewailcity.edu.eg';
  if u_tarek is not null then
    select machine_key into m_key from public.laundry_machines where dorm_class = 'B' limit 1;
    
    insert into public.laundry_slots(machine_key, starts_at, duration_minutes, status)
    values(m_key, now() - interval '2 hours', 30, 'closed')
    on conflict (machine_key, starts_at) do nothing;

    select id into past_slot_id from public.laundry_slots where machine_key = m_key and starts_at <= (now() - interval '1 hour') limit 1;

    if past_slot_id is not null and not exists(select 1 from public.laundry_tickets where slot_id = past_slot_id) then
      insert into public.laundry_tickets(id, user_id, slot_id, status, used_at, access_granted_at, created_at)
      values(
        gen_random_uuid(),
        u_tarek,
        past_slot_id,
        'confirmed',
        now() - interval '90 minutes',
        now() - interval '90 minutes',
        now() - interval '2 hours'
      );
    end if;
  end if;
end $$;
