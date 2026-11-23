-- Paymob-backed ticket reservations and wallet top-ups.
create extension if not exists pgcrypto with schema extensions;

create table if not exists public.student_profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null,
  university_email text not null unique,
  phone_number text not null,
  whatsapp_number text,
  dorm_class text not null check (dorm_class in ('A','B','C','D')),
  approved_at timestamptz,
  created_at timestamptz not null default now()
);
alter table public.student_profiles enable row level security;
revoke all on public.student_profiles from anon, authenticated;
grant select on public.student_profiles to authenticated;
grant update (whatsapp_number) on public.student_profiles to authenticated;
drop policy if exists "Students view their own profile" on public.student_profiles;
create policy "Students view their own profile" on public.student_profiles
  for select to authenticated using ((select auth.uid()) = user_id);
drop policy if exists "Students update only their WhatsApp" on public.student_profiles;
create policy "Students update only their WhatsApp" on public.student_profiles
  for update to authenticated using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

create table if not exists public.laundry_settings (
  id smallint primary key default 1 check (id = 1),
  ticket_price_cents integer not null default 2500 check (ticket_price_cents between 0 and 1000000),
  updated_at timestamptz not null default now()
);
insert into public.laundry_settings (id) values (1) on conflict (id) do nothing;
alter table public.laundry_settings enable row level security;
revoke all on public.laundry_settings from anon, authenticated;

create table if not exists public.laundry_machines (
  machine_key text primary key,
  display_name text not null,
  dorm_class text not null check (dorm_class in ('A','B','C','D')),
  status text not null default 'available' check (status in ('available','out_of_service','offline')),
  created_at timestamptz not null default now()
);
create table if not exists public.laundry_slots (
  id uuid primary key default gen_random_uuid(),
  machine_key text not null references public.laundry_machines(machine_key),
  starts_at timestamptz not null,
  duration_minutes smallint not null default 30 check (duration_minutes in (30,45,60)),
  status text not null default 'open' check (status in ('open','closed')),
  created_at timestamptz not null default now(),
  unique (machine_key, starts_at)
);
alter table public.laundry_machines enable row level security;
alter table public.laundry_slots enable row level security;
revoke all on public.laundry_machines, public.laundry_slots from anon, authenticated;

create table if not exists public.payment_attempts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete restrict,
  idempotency_key uuid not null unique,
  special_reference text not null unique,
  kind text not null check (kind in ('ticket','wallet_topup')),
  amount_cents integer not null check (amount_cents > 0),
  currency text not null default 'EGP' check (currency = 'EGP'),
  payment_method text not null check (payment_method in ('card','wallet')),
  status text not null default 'pending' check (status in ('pending','paid','failed','expired')),
  paymob_intention_id text unique,
  paymob_order_id text unique,
  paymob_client_secret text,
  paymob_transaction_id text unique,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists payment_attempts_user_created_idx on public.payment_attempts (user_id, created_at desc);
alter table public.payment_attempts enable row level security;
revoke all on public.payment_attempts from anon, authenticated;

create table if not exists public.laundry_tickets (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete restrict,
  slot_id uuid not null references public.laundry_slots(id),
  payment_attempt_id uuid not null unique references public.payment_attempts(id),
  status text not null default 'pending_payment' check (status in ('pending_payment','confirmed','failed','expired')),
  created_at timestamptz not null default now()
);
create unique index if not exists laundry_tickets_active_slot_idx on public.laundry_tickets (slot_id) where status in ('pending_payment','confirmed');
create index if not exists laundry_tickets_user_created_idx on public.laundry_tickets (user_id, created_at desc);
alter table public.laundry_tickets enable row level security;
revoke all on public.laundry_tickets from anon, authenticated;
grant select on public.laundry_tickets to authenticated;
drop policy if exists "Students read their own tickets" on public.laundry_tickets;
create policy "Students read their own tickets" on public.laundry_tickets
  for select to authenticated using ((select auth.uid()) = user_id);

create table if not exists public.wallet_ledger (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete restrict,
  payment_attempt_id uuid not null unique references public.payment_attempts(id),
  amount_cents integer not null check (amount_cents > 0),
  entry_type text not null check (entry_type = 'paymob_topup'),
  created_at timestamptz not null default now()
);
create index if not exists wallet_ledger_user_created_idx on public.wallet_ledger (user_id, created_at desc);
alter table public.wallet_ledger enable row level security;
revoke all on public.wallet_ledger from anon, authenticated;
grant select on public.wallet_ledger to authenticated;
drop policy if exists "Students read their own wallet entries" on public.wallet_ledger;
create policy "Students read their own wallet entries" on public.wallet_ledger
  for select to authenticated using ((select auth.uid()) = user_id);

create or replace function public.begin_payment_attempt(
  p_user_id uuid, p_idempotency_key uuid, p_kind text, p_payment_method text,
  p_amount_cents integer default null, p_machine_key text default null, p_slot_start timestamptz default null
) returns jsonb language plpgsql security definer set search_path = public, extensions
as $$
declare
  v_attempt public.payment_attempts%rowtype;
  v_slot public.laundry_slots%rowtype;
  v_amount integer;
  v_ticket_id uuid;
  v_reference text;
begin
  select * into v_attempt from public.payment_attempts where idempotency_key=p_idempotency_key;
  if found then
    if v_attempt.user_id<>p_user_id then raise exception 'idempotency key belongs to another account'; end if;
    return jsonb_build_object('attempt_id',v_attempt.id,'reference',v_attempt.special_reference,'amount_cents',v_attempt.amount_cents,'status',v_attempt.status,'client_secret',v_attempt.paymob_client_secret,'kind',v_attempt.kind,'reused',true);
  end if;
  if p_payment_method not in ('card','wallet') then raise exception 'unsupported payment method'; end if;
  if p_kind='wallet_topup' then
    if p_amount_cents is null or p_amount_cents<1000 or p_amount_cents>500000 then raise exception 'top-up must be between EGP 10 and EGP 5000'; end if;
    v_amount:=p_amount_cents;
  elsif p_kind='ticket' then
    if p_machine_key is null or p_slot_start is null then raise exception 'machine and slot are required'; end if;
    update public.laundry_tickets t set status='expired' from public.payment_attempts a
      where t.payment_attempt_id=a.id and t.status='pending_payment' and a.status='pending' and a.created_at<now()-interval '15 minutes';
    update public.payment_attempts set status='expired',updated_at=now() where status='pending' and created_at<now()-interval '15 minutes';
    select s.* into v_slot from public.laundry_slots s join public.laundry_machines m using(machine_key)
      where s.machine_key=p_machine_key and s.starts_at=p_slot_start and s.status='open' and m.status='available' for update of s;
    if not found then raise exception 'selected slot is not available'; end if;
    if exists(select 1 from public.laundry_tickets where slot_id=v_slot.id and status in ('pending_payment','confirmed')) then raise exception 'selected slot has already been reserved'; end if;
    select ticket_price_cents into v_amount from public.laundry_settings where id=1;
    if v_amount is null or v_amount<1 then raise exception 'ticket price is not configured'; end if;
  else
    raise exception 'unsupported payment type';
  end if;
  v_reference:='ZC-'||replace(gen_random_uuid()::text,'-','');
  insert into public.payment_attempts(user_id,idempotency_key,special_reference,kind,amount_cents,payment_method)
    values(p_user_id,p_idempotency_key,v_reference,p_kind,v_amount,p_payment_method) returning * into v_attempt;
  if p_kind='ticket' then
    insert into public.laundry_tickets(user_id,slot_id,payment_attempt_id) values(p_user_id,v_slot.id,v_attempt.id) returning id into v_ticket_id;
  end if;
  return jsonb_build_object('attempt_id',v_attempt.id,'reference',v_reference,'amount_cents',v_amount,'status','pending','kind',p_kind,'ticket_id',v_ticket_id,'reused',false);
end $$;

create or replace function public.attach_paymob_intention(p_reference text,p_intention_id text,p_order_id text,p_client_secret text)
returns void language plpgsql security definer set search_path=public
as $$
begin
  update public.payment_attempts set paymob_intention_id=p_intention_id,paymob_order_id=p_order_id,paymob_client_secret=p_client_secret,updated_at=now()
    where special_reference=p_reference and status='pending';
  if not found then raise exception 'payment attempt is no longer pending'; end if;
end $$;

create or replace function public.fail_payment_attempt(p_reference text)
returns void language plpgsql security definer set search_path=public
as $$
declare v_id uuid;
begin
  update public.payment_attempts set status='failed',updated_at=now() where special_reference=p_reference and status='pending' returning id into v_id;
  if v_id is not null then update public.laundry_tickets set status='failed' where payment_attempt_id=v_id and status='pending_payment'; end if;
end $$;

create or replace function public.apply_paymob_callback(p_reference text,p_order_id text,p_transaction_id text,p_amount_cents integer,p_currency text,p_success boolean)
returns jsonb language plpgsql security definer set search_path=public
as $$
declare v_attempt public.payment_attempts%rowtype;
begin
  select * into v_attempt from public.payment_attempts
    where (special_reference=p_reference and p_reference is not null) or (paymob_order_id=p_order_id and p_order_id is not null)
    order by created_at desc limit 1 for update;
  if not found then raise exception 'payment attempt was not found'; end if;
  if v_attempt.amount_cents<>p_amount_cents or v_attempt.currency<>p_currency then raise exception 'amount or currency mismatch'; end if;
  if v_attempt.status='paid' then
    if v_attempt.paymob_transaction_id=p_transaction_id then return jsonb_build_object('status','already_processed','reference',v_attempt.special_reference); end if;
    raise exception 'attempt was already paid by another transaction';
  end if;
  if v_attempt.status<>'pending' then return jsonb_build_object('status',v_attempt.status,'reference',v_attempt.special_reference); end if;
  if p_success then
    update public.payment_attempts set status='paid',paymob_transaction_id=p_transaction_id,updated_at=now() where id=v_attempt.id;
    if v_attempt.kind='wallet_topup' then
      insert into public.wallet_ledger(user_id,payment_attempt_id,amount_cents,entry_type) values(v_attempt.user_id,v_attempt.id,v_attempt.amount_cents,'paymob_topup') on conflict(payment_attempt_id) do nothing;
    else
      update public.laundry_tickets set status='confirmed' where payment_attempt_id=v_attempt.id and status='pending_payment';
      if not found then raise exception 'ticket reservation is missing'; end if;
    end if;
    return jsonb_build_object('status','paid','reference',v_attempt.special_reference);
  end if;
  update public.payment_attempts set status='failed',paymob_transaction_id=p_transaction_id,updated_at=now() where id=v_attempt.id;
  update public.laundry_tickets set status='failed' where payment_attempt_id=v_attempt.id and status='pending_payment';
  return jsonb_build_object('status','failed','reference',v_attempt.special_reference);
end $$;

create or replace function public.get_wallet_balance(p_user_id uuid)
returns integer language sql security definer set search_path=public
as $$
  select coalesce(sum(amount_cents),0)::integer from public.wallet_ledger where user_id=p_user_id;
$$;

revoke all on function public.begin_payment_attempt(uuid,uuid,text,text,integer,text,timestamptz) from public,anon,authenticated;
revoke all on function public.attach_paymob_intention(text,text,text,text) from public,anon,authenticated;
revoke all on function public.fail_payment_attempt(text) from public,anon,authenticated;
revoke all on function public.apply_paymob_callback(text,text,text,integer,text,boolean) from public,anon,authenticated;
revoke all on function public.get_wallet_balance(uuid) from public,anon,authenticated;
grant execute on function public.begin_payment_attempt(uuid,uuid,text,text,integer,text,timestamptz) to service_role;
grant execute on function public.attach_paymob_intention(text,text,text,text) to service_role;
grant execute on function public.fail_payment_attempt(text) to service_role;
grant execute on function public.apply_paymob_callback(text,text,text,integer,text,boolean) to service_role;
grant execute on function public.get_wallet_balance(uuid) to service_role;
