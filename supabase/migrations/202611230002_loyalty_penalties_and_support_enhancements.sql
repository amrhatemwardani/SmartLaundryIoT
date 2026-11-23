-- Migration: Loyalty rewards, student penalties, enhanced support tickets, and QR time window
-- File: supabase/migrations/202611230002_loyalty_penalties_and_support_enhancements.sql

-- =====================================================================
-- 1. STUDENT PENALTIES & ACCOUNT SUSPENSION
-- =====================================================================
alter table public.student_profiles
  add column if not exists penalty_status text not null default 'none'
    check (penalty_status in ('none', 'warning', 'suspended', 'blocked')),
  add column if not exists penalty_reason text,
  add column if not exists suspended_until timestamptz,
  add column if not exists penalty_updated_at timestamptz,
  add column if not exists penalty_updated_by uuid references auth.users(id);

-- RPC for supervisors and admin to set or lift penalties
create or replace function public.staff_set_student_penalty(
  p_student_id uuid,
  p_penalty_status text,
  p_reason text,
  p_duration_days integer default null
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
  -- Validate caller role
  select ra.role, ra.dorm_class into actor_r, actor_dorm
  from public.role_assignments ra
  where ra.user_id = actor and ra.active
  limit 1;

  if actor_r is null or actor_r not in ('admin', 'supervisor') then
    raise exception 'Staff permissions required';
  end if;

  -- Validate student exists
  select dorm_class, full_name into target_dorm, target_name
  from public.student_profiles
  where user_id = p_student_id;

  if target_dorm is null then
    raise exception 'Student profile not found';
  end if;

  -- If supervisor, verify same dorm scope
  if actor_r = 'supervisor' and actor_dorm is not null and actor_dorm <> target_dorm then
    raise exception 'Supervisor can only manage students in assigned Dorm %', actor_dorm;
  end if;

  if p_penalty_status not in ('none', 'warning', 'suspended', 'blocked') then
    raise exception 'Invalid penalty status';
  end if;

  if p_penalty_status = 'suspended' and (p_duration_days is null or p_duration_days < 1) then
    p_duration_days := 7; -- default 7 days suspension
  end if;

  if p_penalty_status = 'suspended' then
    until_ts := now() + (p_duration_days || ' days')::interval;
  end if;

  -- Update student profile
  update public.student_profiles
  set penalty_status = p_penalty_status,
      penalty_reason = nullif(trim(p_reason), ''),
      suspended_until = until_ts,
      penalty_updated_at = now(),
      penalty_updated_by = actor
  where user_id = p_student_id;

  -- Insert notification for student
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

  -- Log audit
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

grant execute on function public.staff_set_student_penalty(uuid, text, text, integer) to authenticated, service_role, anon, postgres;


-- List students in supervisor's dorm with penalty status
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
  wallet_balance_cents integer
)
language plpgsql stable security definer set search_path = public
as $$
declare
  actor uuid := auth.uid();
  actor_r text;
  actor_dorm text;
  target_dorm text := p_dorm_class;
begin
  select ra.role, ra.dorm_class into actor_r, actor_dorm
  from public.role_assignments ra
  where ra.user_id = actor and ra.active
  limit 1;

  if actor_r is null or actor_r not in ('admin', 'supervisor') then
    raise exception 'Staff permissions required';
  end if;

  if actor_r = 'supervisor' then
    target_dorm := coalesce(actor_dorm, 'C');
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
    coalesce((select sum(w.amount_cents)::integer from public.wallet_ledger w where w.user_id = p.user_id), 0)
  from public.student_profiles p
  where (target_dorm is null or p.dorm_class = target_dorm)
  order by p.created_at desc;
end $$;

grant execute on function public.staff_list_dorm_students(text) to authenticated, service_role, anon, postgres;


-- =====================================================================
-- 2. LOYALTY REWARDS & CASH REDEMPTION
-- =====================================================================
create table if not exists public.loyalty_settings (
  id integer primary key default 1,
  points_per_cycle integer not null default 50,
  points_to_egp_ratio integer not null default 10, -- 10 points = 1 EGP (200 pts = 20 EGP)
  min_redeem_points integer not null default 100,
  enabled boolean not null default true,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id)
);

insert into public.loyalty_settings (id, points_per_cycle, points_to_egp_ratio, min_redeem_points, enabled)
values (1, 50, 10, 100, true)
on conflict (id) do nothing;

create table if not exists public.loyalty_ledger (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  points integer not null check (points <> 0),
  entry_type text not null check (entry_type in ('wash_completed', 'admin_grant', 'points_redeemed', 'bonus')),
  reference text,
  note text,
  created_at timestamptz not null default now()
);

create index if not exists loyalty_ledger_user_idx on public.loyalty_ledger(user_id, created_at desc);
alter table public.loyalty_ledger enable row level security;
drop policy if exists loyalty_ledger_self_read on public.loyalty_ledger;
create policy loyalty_ledger_self_read on public.loyalty_ledger for select to authenticated using (user_id = auth.uid());

-- Get loyalty balance for current student
create or replace function public.get_loyalty_balance(p_user_id uuid default null)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  target uuid := coalesce(p_user_id, auth.uid());
  total_pts integer;
  earned_pts integer;
  redeemed_pts integer;
  ratio integer;
  pts_per_cycle integer;
  min_pts integer;
  is_enabled boolean;
begin
  select coalesce(sum(points), 0)::integer,
         coalesce(sum(case when points > 0 then points else 0 end), 0)::integer,
         coalesce(sum(case when points < 0 then -points else 0 end), 0)::integer
  into total_pts, earned_pts, redeemed_pts
  from public.loyalty_ledger
  where user_id = target;

  select points_to_egp_ratio, points_per_cycle, min_redeem_points, enabled
  into ratio, pts_per_cycle, min_pts, is_enabled
  from public.loyalty_settings
  where id = 1;

  ratio := coalesce(ratio, 10);
  pts_per_cycle := coalesce(pts_per_cycle, 50);
  min_pts := coalesce(min_pts, 100);

  return jsonb_build_object(
    'points', total_pts,
    'earned_total', earned_pts,
    'redeemed_total', redeemed_pts,
    'egp_value', round((total_pts::numeric / ratio), 2),
    'ratio', ratio,
    'points_per_cycle', pts_per_cycle,
    'min_redeem_points', min_pts,
    'enabled', coalesce(is_enabled, true)
  );
end $$;

grant execute on function public.get_loyalty_balance(uuid) to authenticated, service_role, anon, postgres;


-- Student redeems points for wallet cash credit
create or replace function public.student_redeem_loyalty_points(p_points integer)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  actor uuid := auth.uid();
  current_pts integer;
  ratio integer;
  min_pts integer;
  is_enabled boolean;
  credit_cents integer;
  egp_val numeric;
  ref text;
  new_pts integer;
  new_bal integer;
  pen_status text;
  sus_until timestamptz;
begin
  -- Check penalty status
  select penalty_status, suspended_until into pen_status, sus_until
  from public.student_profiles where user_id = actor;

  if pen_status = 'blocked' or (pen_status = 'suspended' and (sus_until is null or now() < sus_until)) then
    raise exception 'Account is restricted from rewards redemption';
  end if;

  select points_to_egp_ratio, min_redeem_points, enabled
  into ratio, min_pts, is_enabled
  from public.loyalty_settings where id = 1;

  if not coalesce(is_enabled, true) then
    raise exception 'Loyalty rewards program is currently paused by administrator';
  end if;

  if p_points < coalesce(min_pts, 100) then
    raise exception 'Minimum redemption is % points', min_pts;
  end if;

  -- Lock loyalty balance
  select coalesce(sum(points), 0)::integer into current_pts
  from public.loyalty_ledger where user_id = actor;

  if current_pts < p_points then
    raise exception 'Insufficient loyalty points (Available: %, Requested: %)', current_pts, p_points;
  end if;

  egp_val := round((p_points::numeric / ratio), 2);
  credit_cents := round(egp_val * 100)::integer;

  if credit_cents <= 0 then
    raise exception 'Invalid redemption calculation';
  end if;

  ref := 'REWARD-' || Date_part('epoch', now())::bigint || '-' || substr(md5(random()::text), 1, 4);

  -- 1. Deduct points
  insert into public.loyalty_ledger(user_id, points, entry_type, reference, note)
  values(actor, -p_points, 'points_redeemed', ref, 'Converted ' || p_points || ' points to EGP ' || egp_val || ' wallet credit');

  -- 2. Credit wallet
  insert into public.wallet_ledger(user_id, amount_cents, entry_type, actor_user_id, reference, note)
  values(actor, credit_cents, 'admin_credit', actor, ref, 'Loyalty points reward conversion (' || p_points || ' pts)');

  -- 3. Notify student
  insert into public.notifications(user_id, title, body, category)
  values(
    actor,
    'Reward converted to cash!',
    'You converted ' || p_points || ' points into EGP ' || egp_val || ' added directly to your laundry wallet.',
    'payment'
  );

  -- 4. Audit
  insert into public.audit_events(actor_user_id, actor_role, action, entity_type, entity_id, details)
  values(actor, 'student', 'loyalty_redeemed', 'wallet', actor::text, jsonb_build_object(
    'points_spent', p_points, 'egp_amount', egp_val, 'reference', ref
  ));

  select coalesce(sum(points), 0)::integer into new_pts from public.loyalty_ledger where user_id = actor;
  select coalesce(sum(amount_cents), 0)::integer into new_bal from public.wallet_ledger where user_id = actor;

  return jsonb_build_object(
    'success', true,
    'points_redeemed', p_points,
    'credited_egp', egp_val,
    'remaining_points', new_pts,
    'new_wallet_balance_cents', new_bal
  );
end $$;

grant execute on function public.student_redeem_loyalty_points(integer) to authenticated, service_role, anon, postgres;


-- Admin RPCs for Loyalty Control
create or replace function public.admin_update_loyalty_settings(
  p_points_per_cycle integer,
  p_ratio integer,
  p_min_points integer,
  p_enabled boolean
)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  actor uuid := auth.uid();
begin
  if not exists(select 1 from public.role_assignments ra where ra.user_id = actor and ra.role = 'admin' and ra.active) then
    raise exception 'Admin role required';
  end if;

  update public.loyalty_settings
  set points_per_cycle = greatest(1, p_points_per_cycle),
      points_to_egp_ratio = greatest(1, p_ratio),
      min_redeem_points = greatest(10, p_min_points),
      enabled = p_enabled,
      updated_at = now(),
      updated_by = actor
  where id = 1;

  insert into public.audit_events(actor_user_id, actor_role, action, entity_type, entity_id, details)
  values(actor, 'admin', 'loyalty_settings_updated', 'system', '1', jsonb_build_object(
    'points_per_cycle', p_points_per_cycle, 'ratio', p_ratio, 'min_points', p_min_points, 'enabled', p_enabled
  ));

  return jsonb_build_object('success', true);
end $$;

grant execute on function public.admin_update_loyalty_settings(integer, integer, integer, boolean) to authenticated, service_role, anon, postgres;


-- Admin grant bonus points to student
create or replace function public.admin_grant_loyalty_points(
  p_student_id uuid,
  p_points integer,
  p_reason text
)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  actor uuid := auth.uid();
  ref text;
  new_tot integer;
begin
  if not exists(select 1 from public.role_assignments ra where ra.user_id = actor and ra.role = 'admin' and ra.active) then
    raise exception 'Admin role required';
  end if;

  if p_points = 0 then raise exception 'Points must not be zero'; end if;

  ref := 'ADMIN-PTS-' || Date_part('epoch', now())::bigint;

  insert into public.loyalty_ledger(user_id, points, entry_type, reference, note)
  values(p_student_id, p_points, 'admin_grant', ref, left(trim(p_reason), 300));

  insert into public.notifications(user_id, title, body, category)
  values(
    p_student_id,
    'Loyalty points adjustment',
    'An administrator granted you ' || p_points || ' reward points. Reason: ' || coalesce(p_reason, 'Bonus grant'),
    'service'
  );

  insert into public.audit_events(actor_user_id, actor_role, action, entity_type, entity_id, details)
  values(actor, 'admin', 'loyalty_admin_grant', 'student', p_student_id::text, jsonb_build_object(
    'points', p_points, 'reason', p_reason
  ));

  select coalesce(sum(points), 0)::integer into new_tot from public.loyalty_ledger where user_id = p_student_id;

  return jsonb_build_object('success', true, 'total_points', new_tot);
end $$;

grant execute on function public.admin_grant_loyalty_points(uuid, integer, text) to authenticated, service_role, anon, postgres;


-- Admin Loyalty Summary
create or replace function public.admin_get_loyalty_summary()
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  actor uuid := auth.uid();
  cfg public.loyalty_settings%rowtype;
  tot_points_issued integer;
  tot_points_redeemed integer;
  total_cash_granted_cents integer;
  active_participants integer;
begin
  if not exists(select 1 from public.role_assignments ra where ra.user_id = actor and ra.role = 'admin' and ra.active) then
    raise exception 'Admin role required';
  end if;

  select * into cfg from public.loyalty_settings where id = 1;

  select coalesce(sum(case when points > 0 then points else 0 end), 0)::integer,
         coalesce(sum(case when points < 0 then -points else 0 end), 0)::integer,
         count(distinct user_id)::integer
  into tot_points_issued, tot_points_redeemed, active_participants
  from public.loyalty_ledger;

  select coalesce(sum(amount_cents), 0)::integer into total_cash_granted_cents
  from public.wallet_ledger
  where reference like 'REWARD-%';

  return jsonb_build_object(
    'settings', jsonb_build_object(
      'points_per_cycle', cfg.points_per_cycle,
      'ratio', cfg.points_to_egp_ratio,
      'min_redeem_points', cfg.min_redeem_points,
      'enabled', cfg.enabled
    ),
    'stats', jsonb_build_object(
      'total_issued', tot_points_issued,
      'total_redeemed', tot_points_redeemed,
      'active_points_pool', tot_points_issued - tot_points_redeemed,
      'total_cash_paid_cents', total_cash_granted_cents,
      'active_participants', active_participants
    )
  );
end $$;

grant execute on function public.admin_get_loyalty_summary() to authenticated, service_role, anon, postgres;


-- Award loyalty points on booking completion
-- Trigger or logic: whenever a laundry ticket is confirmed and paid, award points
create or replace function public.on_ticket_paid_award_loyalty()
returns trigger language plpgsql security definer set search_path = public
as $$
declare
  cfg public.loyalty_settings%rowtype;
begin
  select * into cfg from public.loyalty_settings where id = 1;
  if cfg.enabled and new.status = 'confirmed' and (old is null or old.status <> 'confirmed') then
    insert into public.loyalty_ledger(user_id, points, entry_type, reference, note)
    values(new.user_id, cfg.points_per_cycle, 'wash_completed', 'TICKET-' || new.id::text, 'Points earned for confirmed laundry booking');
  end if;
  return new;
end $$;

drop trigger if exists trg_ticket_award_loyalty on public.laundry_tickets;
create trigger trg_ticket_award_loyalty
  after insert or update of status on public.laundry_tickets
  for each row execute function public.on_ticket_paid_award_loyalty();


-- =====================================================================
-- 3. ENHANCED SUPPORT TICKETS WITH TICKET ID & MACHINE
-- =====================================================================
alter table public.support_tickets drop constraint if exists support_tickets_category_check;
alter table public.support_tickets add constraint support_tickets_category_check
  check(category in ('washer', 'booking', 'payment', 'wallet', 'door_access', 'complaint', 'other'));

alter table public.support_tickets
  add column if not exists ticket_number text,
  add column if not exists machine_key text references public.laundry_machines(machine_key),
  add column if not exists urgency text default 'medium' check (urgency in ('low', 'medium', 'high'));

-- Trigger to auto-generate readable ticket_number like SUP-2026-1042
create or replace function public.generate_support_ticket_number()
returns trigger language plpgsql as $$
begin
  if new.ticket_number is null or new.ticket_number = '' then
    new.ticket_number := 'SUP-' || to_char(now(), 'YYYY') || '-' || lpad((floor(random() * 9000) + 1000)::text, 4, '0');
  end if;
  return new;
end $$;

drop trigger if exists trg_set_support_ticket_number on public.support_tickets;
create trigger trg_set_support_ticket_number
  before insert on public.support_tickets
  for each row execute function public.generate_support_ticket_number();

-- Update existing tickets if any have null ticket_number
update public.support_tickets
set ticket_number = 'SUP-' || to_char(created_at, 'YYYY') || '-' || lpad((floor(random() * 9000) + 1000)::text, 4, '0')
where ticket_number is null;

-- Update staff_list_support_tickets to return all enhanced columns
drop function if exists public.staff_list_support_tickets(text);
create or replace function public.staff_list_support_tickets(p_status text default null)
returns table(
  ticket_id uuid,
  ticket_number text,
  student_name text,
  student_email text,
  dorm_class text,
  category text,
  machine_key text,
  machine_name text,
  subject text,
  description text,
  status text,
  urgency text,
  created_at timestamptz,
  resolution text
)
language plpgsql stable security definer set search_path = public
as $$
begin
  return query
  select 
    t.id,
    coalesce(t.ticket_number, 'SUP-' || substr(t.id::text, 1, 6))::text,
    p.full_name::text,
    p.university_email::text,
    t.dorm_class::text,
    t.category::text,
    t.machine_key::text,
    m.display_name::text,
    t.subject::text,
    t.description::text,
    t.status::text,
    coalesce(t.urgency, 'medium')::text,
    t.created_at,
    t.resolution::text
  from public.support_tickets t
  join public.student_profiles p on p.user_id = t.user_id
  left join public.laundry_machines m on m.machine_key = t.machine_key
  where (p_status is null or t.status = p_status)
    and (
      exists (select 1 from public.role_assignments r where r.user_id = auth.uid() and r.role = 'admin' and r.active)
      or exists (select 1 from public.role_assignments r where r.user_id = auth.uid() and r.role = 'supervisor' and r.active and r.dorm_class = t.dorm_class)
    )
  order by t.created_at desc
  limit 200;
end $$;

grant execute on function public.staff_list_support_tickets(text) to authenticated, service_role, anon, postgres;


-- Student list own support tickets with resolution
create or replace function public.student_list_my_support_tickets()
returns table(
  ticket_id uuid,
  ticket_number text,
  category text,
  machine_name text,
  subject text,
  description text,
  status text,
  created_at timestamptz,
  resolution text
)
language plpgsql stable security definer set search_path = public
as $$
begin
  return query
  select 
    t.id,
    coalesce(t.ticket_number, 'SUP-' || substr(t.id::text, 1, 6))::text,
    t.category::text,
    m.display_name::text,
    t.subject::text,
    t.description::text,
    t.status::text,
    t.created_at,
    t.resolution::text
  from public.support_tickets t
  left join public.laundry_machines m on m.machine_key = t.machine_key
  where t.user_id = auth.uid()
  order by t.created_at desc
  limit 50;
end $$;

grant execute on function public.student_list_my_support_tickets() to authenticated, service_role, anon, postgres;


-- =====================================================================
-- 4. QR CODE EXPIRY WINDOW (SLOT START TO SLOT START + 10 MINS)
-- =====================================================================
drop function if exists public.student_issue_ticket_qr(uuid);
create or replace function public.student_issue_ticket_qr(p_ticket_id uuid)
returns jsonb
language plpgsql security definer set search_path = public, extensions
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

  time_remaining_seconds := extract(epoch from (valid_until - now_ts))::integer;

  -- 4. Generate verifiable signed QR payload
  payload := t.id::text || ':' || t.user_id::text || ':' || m.dorm_class || ':' || extract(epoch from valid_from)::bigint || ':' || extract(epoch from valid_until)::bigint;
  sig := extensions.encode(extensions.hmac(payload, secret, 'sha256'), 'hex');

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


-- =====================================================================
-- 5. SEED ACTIVE SLOTS FOR ALL DORMS (NEXT 7 DAYS)
-- =====================================================================
create or replace function public.seed_upcoming_slots_all_dorms()
returns void
language plpgsql security definer set search_path = public
as $$
declare
  d date;
  hr integer;
  m record;
  slot_ts timestamptz;
begin
  -- Loop over next 7 days
  for d in select generate_series(current_date, current_date + interval '7 days', interval '1 day')::date loop
    -- Operating hours: 09:00 to 21:00 (every hour)
    for hr in 9..20 loop
      slot_ts := (d || ' ' || lpad(hr::text, 2, '0') || ':00:00')::timestamptz;
      
      -- For every available machine in any dorm
      for m in select machine_key, dorm_class from public.laundry_machines where status = 'available' loop
        insert into public.laundry_slots(machine_key, starts_at, duration_minutes, status)
        values(m.machine_key, slot_ts, 45, 'open')
        on conflict do nothing;
      end loop;
    end loop;
  end loop;
end $$;

grant execute on function public.seed_upcoming_slots_all_dorms() to authenticated, service_role, anon, postgres;

-- Execute the seed now so all dorms immediately have live bookable slots
select public.seed_upcoming_slots_all_dorms();
