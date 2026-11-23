-- Complete application domain: identity, staff scope, approvals, operations, support, audit, and IoT.
-- Apply after 202611160001_notifications.sql and 202611160003_payments.sql.
create extension if not exists pgcrypto with schema extensions;

alter table public.student_profiles
  add column if not exists university_id text,
  add column if not exists major text,
  add column if not exists age smallint,
  add column if not exists approval_status text not null default 'pending',
  add column if not exists approved_by uuid references auth.users(id),
  add column if not exists approval_note text,
  add column if not exists terms_accepted_at timestamptz,
  add column if not exists privacy_accepted_at timestamptz;
alter table public.student_profiles drop constraint if exists student_profiles_approval_status_check;
alter table public.student_profiles add constraint student_profiles_approval_status_check check(approval_status in ('pending','approved','declined','suspended'));
alter table public.student_profiles drop constraint if exists student_profiles_university_id_check;
alter table public.student_profiles add constraint student_profiles_university_id_check check(university_id is null or university_id ~ '^[0-9]+$');
alter table public.student_profiles drop constraint if exists student_profiles_age_check;
alter table public.student_profiles add constraint student_profiles_age_check check(age is null or age between 18 and 120);

create table if not exists public.role_assignments (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null check(role in ('student','supervisor','admin')),
  dorm_class text check(dorm_class is null or dorm_class in ('A','B','C','D')),
  active boolean not null default true,
  assigned_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  unique(user_id,role,dorm_class)
);
create index if not exists role_assignments_user_idx on public.role_assignments(user_id,active);
alter table public.role_assignments enable row level security;
revoke all on public.role_assignments from anon,authenticated;
grant select on public.role_assignments to authenticated;
drop policy if exists role_assignments_self_read on public.role_assignments;
create policy role_assignments_self_read on public.role_assignments for select to authenticated using(user_id=(select auth.uid()));

create or replace function public.on_auth_user_created()
returns trigger language plpgsql security definer set search_path=public,extensions
as $$
declare m jsonb:=coalesce(new.raw_user_meta_data,'{}'::jsonb); em text:=lower(coalesce(new.email,'')); nm text:=trim(coalesce(m->>'full_name','')); sid text:=coalesce(m->>'university_id',''); age_value integer:=nullif(m->>'age','')::integer;
begin
 if em !~ '^[a-z0-9._%+-]+@zewailcity\.edu\.eg$' then raise exception 'Only verified Zewail City email addresses are accepted'; end if;
 if nm !~ '^[[:alpha:]ء-ي][[:alpha:]ء-ي .''-]{1,119}$' then raise exception 'A valid student name is required'; end if;
 if sid !~ '^[0-9]+$' then raise exception 'University ID must contain numbers only'; end if;
 if age_value is null or age_value<18 or age_value>120 then raise exception 'Student must be at least 18 years old'; end if;
 if coalesce(m->>'dorm_class','') not in ('A','B','C','D') then raise exception 'A valid dorm class is required'; end if;
 if coalesce(m->>'major','')='' or coalesce(m->>'phone_number','')='' then raise exception 'Major and phone number are required'; end if;
 if coalesce((m->>'privacy_accepted')::boolean,false) is not true or coalesce((m->>'terms_accepted')::boolean,false) is not true then raise exception 'Privacy notice and terms acceptance are required'; end if;
 insert into public.student_profiles(user_id,full_name,university_email,university_id,major,age,phone_number,whatsapp_number,dorm_class,approval_status,terms_accepted_at,privacy_accepted_at)
 values(new.id,nm,em,sid,trim(m->>'major'),age_value,trim(m->>'phone_number'),nullif(trim(m->>'whatsapp_number'),''),m->>'dorm_class','pending',now(),now());
 insert into public.role_assignments(user_id,role) values(new.id,'student') on conflict do nothing;
 return new;
end $$;
drop trigger if exists on_auth_user_created_student_profile on auth.users;
create trigger on_auth_user_created_student_profile after insert on auth.users for each row execute function public.on_auth_user_created();

-- NOTE: get_my_access() is defined in full later in this file (after all domain tables exist).
-- The earlier duplicate definition has been removed to avoid schema cache confusion.
-- See line ~536 for the authoritative definition.

-- Approved students and scoped staff can read availability for their dorm only.
grant select on public.laundry_machines,public.laundry_slots to authenticated;
drop policy if exists laundry_machines_room_read on public.laundry_machines;
create policy laundry_machines_room_read on public.laundry_machines for select to authenticated using (
 exists(select 1 from public.student_profiles p where p.user_id=auth.uid() and p.dorm_class=laundry_machines.dorm_class and p.approval_status='approved') or
 exists(select 1 from public.role_assignments r where r.user_id=auth.uid() and r.active and (r.role='admin' or (r.role='supervisor' and r.dorm_class=laundry_machines.dorm_class)))
);
drop policy if exists laundry_slots_room_read on public.laundry_slots;
create policy laundry_slots_room_read on public.laundry_slots for select to authenticated using (
 exists(select 1 from public.laundry_machines m join public.student_profiles p on p.dorm_class=m.dorm_class where m.machine_key=laundry_slots.machine_key and p.user_id=auth.uid() and p.approval_status='approved') or
 exists(select 1 from public.laundry_machines m join public.role_assignments r on r.dorm_class=m.dorm_class where m.machine_key=laundry_slots.machine_key and r.user_id=auth.uid() and r.active and r.role in ('admin','supervisor'))
);

-- Wallet supports top-ups, ticket debits, refunds, and staff credits as append-only signed entries.
alter table public.wallet_ledger alter column payment_attempt_id drop not null;
alter table public.wallet_ledger drop constraint if exists wallet_ledger_payment_attempt_id_key;
create unique index if not exists wallet_ledger_payment_attempt_unique on public.wallet_ledger(payment_attempt_id) where payment_attempt_id is not null;
alter table public.wallet_ledger drop constraint if exists wallet_ledger_entry_type_check;
alter table public.wallet_ledger drop constraint if exists wallet_ledger_amount_cents_check;
alter table public.wallet_ledger add constraint wallet_ledger_entry_type_check check(entry_type in ('paymob_topup','ticket_payment','refund','admin_credit','admin_debit'));
alter table public.wallet_ledger add constraint wallet_ledger_amount_cents_check check(amount_cents<>0);
alter table public.wallet_ledger add column if not exists actor_user_id uuid references auth.users(id);
alter table public.wallet_ledger add column if not exists ticket_id uuid references public.laundry_tickets(id);
alter table public.wallet_ledger add column if not exists reference text unique;
alter table public.wallet_ledger add column if not exists note text;

alter table public.laundry_tickets alter column payment_attempt_id drop not null;
alter table public.laundry_tickets drop constraint if exists laundry_tickets_payment_attempt_id_key;
create unique index if not exists laundry_tickets_payment_attempt_unique on public.laundry_tickets(payment_attempt_id) where payment_attempt_id is not null;

create or replace function public.get_wallet_balance(p_user_id uuid default auth.uid())
returns integer language sql stable security definer set search_path=public
as $$ select coalesce(sum(amount_cents),0)::integer from public.wallet_ledger where user_id=p_user_id and (p_user_id=auth.uid() or auth.role()='service_role' or exists(select 1 from public.role_assignments where user_id=auth.uid() and role='admin' and active)); $$;
revoke all on function public.get_wallet_balance(uuid) from public,anon,authenticated;
grant execute on function public.get_wallet_balance(uuid) to authenticated,service_role;

create table if not exists public.support_tickets(
 id uuid primary key default gen_random_uuid(), user_id uuid not null references auth.users(id) on delete cascade,
 dorm_class text not null check(dorm_class in ('A','B','C','D')), category text not null check(category in ('washer','booking','payment','complaint','other')),
 related_ticket_id uuid references public.laundry_tickets(id), subject text not null check(char_length(subject) between 3 and 160), description text not null check(char_length(description) between 10 and 5000),
 status text not null default 'open' check(status in ('open','in_progress','resolved','closed')), assigned_to uuid references auth.users(id), resolution text,
 created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create index if not exists support_tickets_user_created_idx on public.support_tickets(user_id,created_at desc);
create index if not exists support_tickets_dorm_status_idx on public.support_tickets(dorm_class,status,created_at desc);
alter table public.support_tickets enable row level security;
revoke all on public.support_tickets from anon,authenticated;
grant select,insert on public.support_tickets to authenticated;
drop policy if exists support_own_read on public.support_tickets;
create policy support_own_read on public.support_tickets for select to authenticated using(user_id=auth.uid());
drop policy if exists support_create_self on public.support_tickets;
create policy support_create_self on public.support_tickets for insert to authenticated with check(user_id=auth.uid() and exists(select 1 from public.student_profiles p where p.user_id=auth.uid() and p.approval_status='approved' and p.dorm_class=support_tickets.dorm_class));

create table if not exists public.audit_events(
 id bigint generated always as identity primary key, actor_user_id uuid references auth.users(id) on delete set null, actor_role text not null,
 action text not null, entity_type text, entity_id text, outcome text not null default 'success', reason text,
 source_ip inet, user_agent text, details jsonb not null default '{}'::jsonb, created_at timestamptz not null default now()
);
create index if not exists audit_events_created_idx on public.audit_events(created_at desc);
create index if not exists audit_events_actor_idx on public.audit_events(actor_user_id,created_at desc);
create index if not exists audit_events_entity_idx on public.audit_events(entity_type,entity_id,created_at desc);
alter table public.audit_events enable row level security;
revoke all on public.audit_events from anon,authenticated;
grant select on public.audit_events to authenticated;
drop policy if exists audit_student_own on public.audit_events;
create policy audit_student_own on public.audit_events for select to authenticated using(actor_user_id=auth.uid());
drop policy if exists audit_admin_all on public.audit_events;
create policy audit_admin_all on public.audit_events for select to authenticated using(exists(select 1 from public.role_assignments r where r.user_id=auth.uid() and r.role='admin' and r.active));
drop policy if exists audit_supervisor_dorm on public.audit_events;
create policy audit_supervisor_dorm on public.audit_events for select to authenticated using(exists(select 1 from public.role_assignments r where r.user_id=auth.uid() and r.role='supervisor' and r.active and r.dorm_class=details->>'dorm_class'));

create table if not exists public.access_credentials(
 id uuid primary key default gen_random_uuid(), ticket_id uuid not null unique references public.laundry_tickets(id) on delete cascade,
 token_hash bytea not null unique, valid_from timestamptz not null, valid_until timestamptz not null, used_at timestamptz, created_at timestamptz not null default now()
);
alter table public.access_credentials enable row level security;
revoke all on public.access_credentials from anon,authenticated;
create table if not exists public.iot_devices(
 id uuid primary key default gen_random_uuid(), device_key text not null unique, dorm_class text not null check(dorm_class in ('A','B','C','D')),
 api_key_hash bytea not null, active boolean not null default true, last_seen_at timestamptz, created_at timestamptz not null default now()
);
alter table public.iot_devices enable row level security;
revoke all on public.iot_devices from anon,authenticated;
create table if not exists public.device_events(
 id bigint generated always as identity primary key, device_id uuid not null references public.iot_devices(id), event_type text not null,
 machine_key text references public.laundry_machines(machine_key), details jsonb not null default '{}'::jsonb, created_at timestamptz not null default now()
);
create index if not exists device_events_device_created_idx on public.device_events(device_id,created_at desc);
alter table public.device_events enable row level security;
revoke all on public.device_events from anon,authenticated;
create table if not exists public.door_events(
 id bigint generated always as identity primary key, device_id uuid references public.iot_devices(id), ticket_id uuid references public.laundry_tickets(id),
 dorm_class text check(dorm_class is null or dorm_class in ('A','B','C','D')),
 outcome text not null check(outcome in ('granted','denied')), reason text, created_at timestamptz not null default now()
);
alter table public.door_events add column if not exists dorm_class text check(dorm_class is null or dorm_class in ('A','B','C','D'));
create index if not exists door_events_created_idx on public.door_events(created_at desc);
alter table public.door_events enable row level security;
revoke all on public.door_events from anon,authenticated;
grant select on public.door_events to authenticated;
create policy door_events_admin_read on public.door_events for select to authenticated using(exists(select 1 from public.role_assignments r where r.user_id=auth.uid() and r.active and (r.role='admin' or (r.role='supervisor' and r.dorm_class=door_events.dorm_class))));

create or replace function public.review_student_application(p_user_id uuid,p_decision text,p_note text default null)
returns void language plpgsql security definer set search_path=public
as $$
declare actor uuid:=auth.uid(); r public.role_assignments%rowtype; p public.student_profiles%rowtype;
begin
 select * into p from public.student_profiles where user_id=p_user_id for update;
 if not found then raise exception 'Student application not found'; end if;
 if p_decision not in ('approved','declined') then raise exception 'Invalid decision'; end if;
 if not exists(select 1 from public.role_assignments where user_id=actor and role='admin' and active) and not exists(select 1 from public.role_assignments where user_id=actor and role='supervisor' and active and dorm_class=p.dorm_class) then raise exception 'Not authorized for this dorm'; end if;
 if p.approval_status<>'pending' then raise exception 'Application is no longer pending'; end if;
 update public.student_profiles set approval_status=p_decision,approved_at=case when p_decision='approved' then now() else null end,approved_by=actor,approval_note=left(coalesce(p_note,''),1000) where user_id=p_user_id;
 insert into public.notifications(user_id,title,body,category) values(p_user_id,case when p_decision='approved' then 'Account approved' else 'Account application update' end,case when p_decision='approved' then 'Your student account is approved. You can now sign in and book laundry.' else 'Your student account was not approved. Contact support for details.' end,'service');
 insert into public.audit_events(actor_user_id,actor_role,action,entity_type,entity_id,reason,details) values(actor,case when exists(select 1 from public.role_assignments where user_id=actor and role='admin' and active) then 'admin' else 'supervisor' end,'student_application_'||p_decision,'student',p_user_id::text,left(p_note,1000),jsonb_build_object('dorm_class',p.dorm_class));
end $$;
revoke all on function public.review_student_application(uuid,text,text) from public,anon;
grant execute on function public.review_student_application(uuid,text,text) to authenticated;

create or replace function public.staff_set_machine_status(p_machine_key text,p_status text,p_reason text)
returns void language plpgsql security definer set search_path=public
as $$
declare m public.laundry_machines%rowtype; actor uuid:=auth.uid();
begin
 if p_status not in ('available','out_of_service','offline') or length(trim(coalesce(p_reason,'')))<3 then raise exception 'Valid state and reason required'; end if;
 select * into m from public.laundry_machines where machine_key=p_machine_key for update;
 if not found then raise exception 'Machine not found'; end if;
 if not exists(select 1 from public.role_assignments r where r.user_id=actor and r.active and (r.role='admin' or (r.role='supervisor' and r.dorm_class=m.dorm_class))) then raise exception 'Not authorized for this machine'; end if;
 update public.laundry_machines set status=p_status where machine_key=p_machine_key;
 insert into public.audit_events(actor_user_id,actor_role,action,entity_type,entity_id,reason,details) values(actor,'staff','machine_status_changed','machine',p_machine_key,left(p_reason,1000),jsonb_build_object('dorm_class',m.dorm_class,'new_status',p_status));
end $$;

create or replace function public.staff_publish_slots(p_machine_key text,p_slots jsonb)
returns integer language plpgsql security definer set search_path=public
as $$
declare m public.laundry_machines%rowtype; item jsonb; n integer:=0; starts timestamptz; dur integer; actor uuid:=auth.uid();
begin
 select * into m from public.laundry_machines where machine_key=p_machine_key;
 if not found then raise exception 'Machine not found'; end if;
 if not exists(select 1 from public.role_assignments r where r.user_id=actor and r.active and (r.role='admin' or (r.role='supervisor' and r.dorm_class=m.dorm_class))) then raise exception 'Not authorized for this machine'; end if;
 if jsonb_typeof(p_slots)<>'array' or jsonb_array_length(p_slots)<1 or jsonb_array_length(p_slots)>500 then raise exception 'Provide between 1 and 500 slots'; end if;
 for item in select value from jsonb_array_elements(p_slots) loop
   starts:=(item->>'starts_at')::timestamptz; dur:=coalesce((item->>'duration_minutes')::integer,30);
   if starts<now()+interval '5 minutes' or starts>now()+interval '60 days' or dur not in (30,45,60) then raise exception 'Slot date or duration is outside allowed range'; end if;
   insert into public.laundry_slots(machine_key,starts_at,duration_minutes,status) values(p_machine_key,starts,dur,'open') on conflict(machine_key,starts_at) do update set duration_minutes=excluded.duration_minutes,status='open' where not exists(select 1 from public.laundry_tickets t where t.slot_id=laundry_slots.id and t.status in ('pending_payment','confirmed'));
   n:=n+1;
 end loop;
 insert into public.audit_events(actor_user_id,actor_role,action,entity_type,entity_id,details) values(actor,'staff','slots_published','machine',p_machine_key,jsonb_build_object('count',n,'dorm_class',m.dorm_class));
 return n;
end $$;

create or replace function public.admin_set_ticket_price(p_price_cents integer)
returns void language plpgsql security definer set search_path=public
as $$
declare actor uuid:=auth.uid();
begin
 if not exists(select 1 from public.role_assignments where user_id=actor and role='admin' and active) then raise exception 'Admin role required'; end if;
 if p_price_cents<0 or p_price_cents>1000000 then raise exception 'Ticket price is outside allowed range'; end if;
 update public.laundry_settings set ticket_price_cents=p_price_cents,updated_at=now() where id=1;
 insert into public.audit_events(actor_user_id,actor_role,action,entity_type,entity_id,details) values(actor,'admin','ticket_price_changed','settings','laundry',jsonb_build_object('price_cents',p_price_cents));
end $$;

create or replace function public.admin_credit_wallet(p_student_id uuid,p_amount_cents integer,p_reason text,p_reference text)
returns void language plpgsql security definer set search_path=public
as $$
declare actor uuid:=auth.uid(); dorm text;
begin
 if not exists(select 1 from public.role_assignments where user_id=actor and role='admin' and active) then raise exception 'Admin role required'; end if;
 if p_amount_cents<1 or p_amount_cents>500000 or length(trim(coalesce(p_reason,'')))<5 or length(trim(coalesce(p_reference,'')))<8 then raise exception 'A valid amount, reason and idempotency reference are required'; end if;
 select dorm_class into dorm from public.student_profiles where user_id=p_student_id and approval_status='approved';
 if dorm is null then raise exception 'Approved student not found'; end if;
 insert into public.wallet_ledger(user_id,amount_cents,entry_type,actor_user_id,reference,note) values(p_student_id,p_amount_cents,'admin_credit',actor,p_reference,left(trim(p_reason),1000));
 insert into public.audit_events(actor_user_id,actor_role,action,entity_type,entity_id,reason,details) values(actor,'admin','wallet_credit','student',p_student_id::text,left(p_reason,1000),jsonb_build_object('amount_cents',p_amount_cents,'reference',p_reference,'dorm_class',dorm));
end $$;

create or replace function public.student_pay_ticket_from_wallet(p_slot_id uuid)
returns uuid language plpgsql security definer set search_path=public
as $$
declare actor uuid:=auth.uid(); p public.student_profiles%rowtype; s public.laundry_slots%rowtype; m public.laundry_machines%rowtype; price integer; balance integer; tid uuid; ref text;
begin
 select * into p from public.student_profiles where user_id=actor and approval_status='approved' and approved_at is not null;
 if not found then raise exception 'Approved student account required'; end if;
 select * into s from public.laundry_slots where id=p_slot_id and status='open' for update;
 if not found then raise exception 'Slot is not available'; end if;
 select * into m from public.laundry_machines where machine_key=s.machine_key and dorm_class=p.dorm_class and status='available';
 if not found then raise exception 'Machine is not available in your dorm'; end if;
 if exists(select 1 from public.laundry_tickets where slot_id=s.id and status in ('pending_payment','confirmed')) then raise exception 'Slot is already reserved'; end if;
 select ticket_price_cents into price from public.laundry_settings where id=1;
 select coalesce(sum(amount_cents),0)::integer into balance from public.wallet_ledger where user_id=actor;
 if balance<price then raise exception 'Insufficient wallet funds'; end if;
 tid:=gen_random_uuid(); ref:='wallet-ticket-'||tid::text;
 insert into public.laundry_tickets(id,user_id,slot_id,payment_attempt_id,status) values(tid,actor,s.id,null,'confirmed');
 insert into public.wallet_ledger(user_id,ticket_id,amount_cents,entry_type,actor_user_id,reference,note) values(actor,tid,-price,'ticket_payment',actor,ref,'Laundry ticket payment');
 insert into public.audit_events(actor_user_id,actor_role,action,entity_type,entity_id,details) values(actor,'student','wallet_ticket_payment','ticket',tid::text,jsonb_build_object('slot_id',s.id,'amount_cents',price));
 return tid;
end $$;

create or replace function public.student_issue_ticket_qr(p_ticket_id uuid)
returns text language plpgsql security definer set search_path=public,extensions
as $$
declare actor uuid:=auth.uid(); t public.laundry_tickets%rowtype; s public.laundry_slots%rowtype; token text; digest bytea;
begin
 select * into t from public.laundry_tickets where id=p_ticket_id and user_id=actor and status='confirmed';
 if not found then raise exception 'Confirmed ticket not found'; end if;
 select * into s from public.laundry_slots where id=t.slot_id;
 if now()<s.starts_at-interval '10 minutes' or now()>s.starts_at+(s.duration_minutes||' minutes')::interval+interval '10 minutes' then raise exception 'QR access is outside the ticket time window'; end if;
 select encode(extensions.gen_random_bytes(32),'hex') into token; digest:=extensions.digest(token,'sha256');
 insert into public.access_credentials(ticket_id,token_hash,valid_from,valid_until) values(t.id,digest,s.starts_at-interval '10 minutes',s.starts_at+(s.duration_minutes||' minutes')::interval+interval '10 minutes') on conflict(ticket_id) do update set token_hash=excluded.token_hash,valid_from=excluded.valid_from,valid_until=excluded.valid_until,used_at=null,created_at=now();
 return token;
end $$;

create or replace function public.iot_authenticate_device(p_device_key text,p_api_key text)
returns uuid language sql security definer set search_path=public,extensions
as $$ update public.iot_devices set last_seen_at=now() where device_key=p_device_key and active and api_key_hash=extensions.digest(p_api_key,'sha256') returning id; $$;
create or replace function public.iot_consume_door_qr(p_device_id uuid,p_token text)
returns jsonb language plpgsql security definer set search_path=public,extensions
as $$
declare c public.access_credentials%rowtype; d public.iot_devices%rowtype; t public.laundry_tickets%rowtype; result jsonb;
begin
 select * into d from public.iot_devices where id=p_device_id and active;
 if not found then return jsonb_build_object('granted',false,'reason','device_inactive'); end if;
 select * into c from public.access_credentials where token_hash=extensions.digest(p_token,'sha256') for update;
 if not found or c.used_at is not null or now()<c.valid_from or now()>c.valid_until then
   insert into public.door_events(device_id,dorm_class,outcome,reason) values(d.id,d.dorm_class,'denied','invalid_expired_or_replayed_qr');
   return jsonb_build_object('granted',false,'reason','invalid_expired_or_replayed_qr');
 end if;
 select * into t from public.laundry_tickets where id=c.ticket_id and status='confirmed';
 if not found then insert into public.door_events(device_id,ticket_id,dorm_class,outcome,reason) values(d.id,c.ticket_id,d.dorm_class,'denied','ticket_not_confirmed'); return jsonb_build_object('granted',false,'reason','ticket_not_confirmed'); end if;
 if not exists(select 1 from public.laundry_slots s join public.laundry_machines m using(machine_key) where s.id=t.slot_id and m.dorm_class=d.dorm_class and m.status='available') then
  insert into public.door_events(device_id,ticket_id,dorm_class,outcome,reason) values(d.id,t.id,d.dorm_class,'denied','wrong_dorm_or_machine_unavailable'); return jsonb_build_object('granted',false,'reason','wrong_dorm_or_machine_unavailable');
 end if;
 update public.access_credentials set used_at=now() where id=c.id;
 insert into public.door_events(device_id,ticket_id,dorm_class,outcome,reason) values(d.id,t.id,d.dorm_class,'granted','valid_ticket_qr');
 return jsonb_build_object('granted',true,'reason','valid_ticket_qr');
end $$;

revoke all on function public.review_student_application(uuid,text,text) from public,anon;
revoke all on function public.staff_set_machine_status(text,text,text) from public,anon;
revoke all on function public.staff_publish_slots(text,jsonb) from public,anon;
revoke all on function public.admin_set_ticket_price(integer) from public,anon;
revoke all on function public.admin_credit_wallet(uuid,integer,text,text) from public,anon;
revoke all on function public.student_pay_ticket_from_wallet(uuid) from public,anon;
revoke all on function public.student_issue_ticket_qr(uuid) from public,anon;
revoke all on function public.iot_authenticate_device(text,text) from public,anon,authenticated;
revoke all on function public.iot_consume_door_qr(uuid,text) from public,anon,authenticated;
grant execute on function public.staff_set_machine_status(text,text,text) to authenticated;
grant execute on function public.staff_publish_slots(text,jsonb) to authenticated;
grant execute on function public.admin_set_ticket_price(integer) to authenticated;
grant execute on function public.admin_credit_wallet(uuid,integer,text,text) to authenticated;
grant execute on function public.student_pay_ticket_from_wallet(uuid) to authenticated;
grant execute on function public.student_issue_ticket_qr(uuid) to authenticated;
grant execute on function public.iot_authenticate_device(text,text) to service_role;
grant execute on function public.iot_consume_door_qr(uuid,text) to service_role;

-- Firebase Cloud Messaging stores only per-browser registration tokens; Supabase remains the notification source of truth.
alter table public.notifications add column if not exists push_sent_at timestamptz;
create table if not exists public.fcm_tokens(
 id uuid primary key default gen_random_uuid(), user_id uuid not null references auth.users(id) on delete cascade,
 token text not null unique, platform text not null default 'web' check(platform='web'), created_at timestamptz not null default now(), last_seen_at timestamptz not null default now()
);
create index if not exists fcm_tokens_user_idx on public.fcm_tokens(user_id);
alter table public.fcm_tokens enable row level security;
revoke all on public.fcm_tokens from anon,authenticated;
grant select,insert,delete on public.fcm_tokens to authenticated;
revoke insert,update on public.fcm_tokens from authenticated;
drop policy if exists fcm_tokens_self_access on public.fcm_tokens;
create policy fcm_tokens_self_access on public.fcm_tokens for all to authenticated using(user_id=auth.uid()) with check(user_id=auth.uid());

create or replace function public.claim_notification_push(p_notification_id uuid,p_user_id uuid)
returns jsonb language plpgsql security definer set search_path=public
as $$
declare n public.notifications%rowtype; tok jsonb;
begin
 update public.notifications set push_sent_at=now() where id=p_notification_id and user_id=p_user_id and push_sent_at is null returning * into n;
 if not found then return null; end if;
 select coalesce(jsonb_agg(token),'[]'::jsonb) into tok from (select token from public.fcm_tokens where user_id=p_user_id order by last_seen_at desc limit 10) devices;
 return jsonb_build_object('id',n.id,'title',n.title,'body',n.body,'tokens',tok);
end $$;
revoke all on function public.claim_notification_push(uuid,uuid) from public,anon,authenticated;
grant execute on function public.claim_notification_push(uuid,uuid) to service_role;

-- Support requests are student-created; staff state changes are performed through the scoped RPC below.
revoke insert on public.support_tickets from authenticated;
grant insert(user_id,dorm_class,category,related_ticket_id,subject,description) on public.support_tickets to authenticated;
create or replace function public.staff_update_support_ticket(p_ticket_id uuid,p_status text,p_resolution text default null)
returns void language plpgsql security definer set search_path=public
as $$
declare t public.support_tickets%rowtype; actor uuid:=auth.uid();
begin
 select * into t from public.support_tickets where id=p_ticket_id for update;
 if not found then raise exception 'Support request not found'; end if;
 if p_status not in ('in_progress','resolved','closed') then raise exception 'Invalid support status'; end if;
 if not exists(select 1 from public.role_assignments r where r.user_id=actor and r.active and (r.role='admin' or (r.role='supervisor' and r.dorm_class=t.dorm_class))) then raise exception 'Not authorized for this dorm'; end if;
 update public.support_tickets set status=p_status,resolution=left(p_resolution,5000),updated_at=now() where id=t.id;
 if p_status in ('resolved','closed') then insert into public.notifications(user_id,title,body,category) values(t.user_id,'Support request updated',coalesce(nullif(trim(p_resolution),''),'Your support request has been resolved.'),'support'); end if;
 insert into public.audit_events(actor_user_id,actor_role,action,entity_type,entity_id,reason,details) values(actor,'staff','support_ticket_'||p_status,'support_ticket',t.id::text,left(p_resolution,1000),jsonb_build_object('dorm_class',t.dorm_class));
end $$;
revoke all on function public.staff_update_support_ticket(uuid,text,text) from public,anon;
grant execute on function public.staff_update_support_ticket(uuid,text,text) to authenticated;

alter table public.notifications add column if not exists push_claimed_at timestamptz;
create or replace function public.claim_notification_push(p_notification_id uuid,p_user_id uuid)
returns jsonb language plpgsql security definer set search_path=public
as $$
declare n public.notifications%rowtype; tok jsonb;
begin
 update public.notifications set push_claimed_at=now() where id=p_notification_id and user_id=p_user_id and push_sent_at is null and (push_claimed_at is null or push_claimed_at<now()-interval '5 minutes') returning * into n;
 if not found then return null; end if;
 select coalesce(jsonb_agg(token),'[]'::jsonb) into tok from (select token from public.fcm_tokens where user_id=p_user_id order by last_seen_at desc limit 10) devices;
 return jsonb_build_object('id',n.id,'title',n.title,'body',n.body,'tokens',tok);
end $$;
create or replace function public.finish_notification_push(p_notification_id uuid,p_user_id uuid,p_sent boolean)
returns void language sql security definer set search_path=public
as $$ update public.notifications set push_sent_at=case when p_sent then now() else null end,push_claimed_at=null where id=p_notification_id and user_id=p_user_id; $$;
revoke all on function public.finish_notification_push(uuid,uuid,boolean) from public,anon,authenticated;
grant execute on function public.finish_notification_push(uuid,uuid,boolean) to service_role;

-- Bind this browser's FCM token to the currently authenticated account without exposing token updates.
create or replace function public.student_register_fcm_token(p_token text)
returns void language plpgsql security definer set search_path=public
as $$
begin
 if auth.uid() is null then raise exception 'Sign in required'; end if;
 if p_token is null or length(p_token)<20 or length(p_token)>4096 then raise exception 'Invalid browser notification token'; end if;
 insert into public.fcm_tokens(user_id,token,platform,last_seen_at)
 values(auth.uid(),p_token,'web',now())
 on conflict(token) do update set user_id=excluded.user_id,platform='web',last_seen_at=now();
 delete from public.fcm_tokens where user_id=auth.uid() and id not in
  (select id from public.fcm_tokens where user_id=auth.uid() order by last_seen_at desc limit 10);
end $$;
revoke all on function public.student_register_fcm_token(text) from public,anon;
grant execute on function public.student_register_fcm_token(text) to authenticated;

-- Staff-safe list operations; staff roles are invitation-only and never assigned by the public signup form.
create or replace function public.staff_pending_applications()
returns table(user_id uuid,full_name text,university_email text,university_id text,major text,age smallint,phone_number text,dorm_class text,created_at timestamptz)
language plpgsql stable security definer set search_path=public
as $$
begin
 if not exists(select 1 from public.role_assignments where role='admin' and user_id=auth.uid() and active) and not exists(select 1 from public.role_assignments where role='supervisor' and user_id=auth.uid() and active) then raise exception 'Staff role required'; end if;
 return query select p.user_id,p.full_name,p.university_email,p.university_id,p.major,p.age,p.phone_number,p.dorm_class,p.created_at from public.student_profiles p
 where p.approval_status='pending' and (exists(select 1 from public.role_assignments a where a.user_id=auth.uid() and a.role='admin' and a.active) or exists(select 1 from public.role_assignments a where a.user_id=auth.uid() and a.role='supervisor' and a.active and a.dorm_class=p.dorm_class)) order by p.created_at asc;
end $$;
create or replace function public.admin_assign_staff(p_email text,p_role text,p_dorm_class text default null)
returns void language plpgsql security definer set search_path=public
as $$
declare actor uuid:=auth.uid(); target uuid;
begin
 if not exists(select 1 from public.role_assignments where user_id=actor and role='admin' and active) then raise exception 'Admin role required'; end if;
 if p_role not in ('supervisor','admin') or (p_role='supervisor' and p_dorm_class not in ('A','B','C','D')) or (p_role='admin' and p_dorm_class is not null) then raise exception 'Invalid staff role or dorm scope'; end if;
 select id into target from auth.users where lower(email)=lower(trim(p_email)) and email_confirmed_at is not null;
 if target is null then raise exception 'A verified account with that email must exist first'; end if;
 insert into public.role_assignments(user_id,role,dorm_class,active,assigned_by) values(target,p_role,p_dorm_class,true,actor)
 on conflict(user_id,role,dorm_class) do update set active=true,assigned_by=actor;
 insert into public.audit_events(actor_user_id,actor_role,action,entity_type,entity_id,details) values(actor,'admin','staff_role_assigned','user',target::text,jsonb_build_object('role',p_role,'dorm_class',p_dorm_class));
end $$;
create or replace function public.admin_disable_staff(p_user_id uuid,p_role text,p_dorm_class text default null)
returns void language plpgsql security definer set search_path=public
as $$
declare actor uuid:=auth.uid();
begin
 if not exists(select 1 from public.role_assignments where user_id=actor and role='admin' and active) then raise exception 'Admin role required'; end if;
 if p_user_id=actor and p_role='admin' then raise exception 'You cannot disable your own admin role'; end if;
 update public.role_assignments set active=false where user_id=p_user_id and role=p_role and dorm_class is not distinct from p_dorm_class;
 if not found then raise exception 'Staff assignment not found'; end if;
 insert into public.audit_events(actor_user_id,actor_role,action,entity_type,entity_id,details) values(actor,'admin','staff_role_disabled','user',p_user_id::text,jsonb_build_object('role',p_role,'dorm_class',p_dorm_class));
end $$;
create or replace function public.admin_list_staff()
returns table(user_id uuid,email text,role text,dorm_class text,active boolean,assigned_at timestamptz)
language plpgsql stable security definer set search_path=public
as $$
begin
 if not exists(select 1 from public.role_assignments where user_id=auth.uid() and role='admin' and active) then raise exception 'Admin role required'; end if;
 return query select r.user_id,u.email,r.role,r.dorm_class,r.active,r.created_at from public.role_assignments r join auth.users u on u.id=r.user_id where r.role in ('admin','supervisor') order by r.active desc,r.role,r.created_at desc;
end $$;
create or replace function public.admin_create_machine(p_machine_key text,p_display_name text,p_dorm_class text)
returns void language plpgsql security definer set search_path=public
as $$
declare actor uuid:=auth.uid();
begin
 if not exists(select 1 from public.role_assignments where user_id=actor and role='admin' and active) then raise exception 'Admin role required'; end if;
 if p_machine_key !~ '^[A-Za-z0-9_-]{2,40}$' or length(trim(p_display_name)) not between 2 and 80 or p_dorm_class not in ('A','B','C','D') then raise exception 'Invalid machine details'; end if;
 insert into public.laundry_machines(machine_key,display_name,dorm_class,status) values(p_machine_key,trim(p_display_name),p_dorm_class,'available') on conflict(machine_key) do update set display_name=excluded.display_name,dorm_class=excluded.dorm_class;
 insert into public.audit_events(actor_user_id,actor_role,action,entity_type,entity_id,details) values(actor,'admin','machine_created_or_updated','machine',p_machine_key,jsonb_build_object('dorm_class',p_dorm_class));
end $$;
create or replace function public.staff_list_bookings(p_from timestamptz default now()-interval '7 days',p_until timestamptz default now()+interval '60 days')
returns table(ticket_id uuid,student_id uuid,student_name text,student_email text,dorm_class text,machine_key text,machine_name text,starts_at timestamptz,duration_minutes smallint,status text,created_at timestamptz)
language plpgsql stable security definer set search_path=public
as $$
begin
 if not exists(select 1 from public.role_assignments where user_id=auth.uid() and active and role in ('supervisor','admin')) then raise exception 'Staff role required'; end if;
 return query select t.id,t.user_id,p.full_name,p.university_email,m.dorm_class,m.machine_key,m.display_name,s.starts_at,s.duration_minutes,t.status,t.created_at from public.laundry_tickets t join public.laundry_slots s on s.id=t.slot_id join public.laundry_machines m on m.machine_key=s.machine_key join public.student_profiles p on p.user_id=t.user_id
 where s.starts_at between p_from and p_until and (exists(select 1 from public.role_assignments a where a.user_id=auth.uid() and a.role='admin' and a.active) or exists(select 1 from public.role_assignments a where a.user_id=auth.uid() and a.role='supervisor' and a.active and a.dorm_class=m.dorm_class)) order by s.starts_at;
end $$;
create or replace function public.admin_finance_summary()
returns jsonb language plpgsql stable security definer set search_path=public
as $$
begin
 if not exists(select 1 from public.role_assignments where user_id=auth.uid() and role='admin' and active) then raise exception 'Admin role required'; end if;
 return jsonb_build_object('ticket_price_cents',(select ticket_price_cents from public.laundry_settings where id=1),'paid_attempts',(select count(*) from public.payment_attempts where status='paid'),'paid_total_cents',(select coalesce(sum(amount_cents),0) from public.payment_attempts where status='paid'),'wallet_liability_cents',(select coalesce(sum(amount_cents),0) from public.wallet_ledger),'pending_attempts',(select count(*) from public.payment_attempts where status='pending'));
end $$;
create or replace function public.admin_recent_audit(p_limit integer default 100)
returns setof public.audit_events language plpgsql stable security definer set search_path=public
as $$
begin
 if not exists(select 1 from public.role_assignments where user_id=auth.uid() and role='admin' and active) then raise exception 'Admin role required'; end if;
 return query select * from public.audit_events order by created_at desc limit greatest(1,least(p_limit,500));
end $$;

revoke all on function public.staff_pending_applications() from public,anon;
revoke all on function public.admin_assign_staff(text,text,text) from public,anon;
revoke all on function public.admin_disable_staff(uuid,text,text) from public,anon;
revoke all on function public.admin_list_staff() from public,anon;
revoke all on function public.admin_create_machine(text,text,text) from public,anon;
revoke all on function public.staff_list_bookings(timestamptz,timestamptz) from public,anon;
revoke all on function public.admin_finance_summary() from public,anon;
revoke all on function public.admin_recent_audit(integer) from public,anon;
grant execute on function public.staff_pending_applications() to authenticated;
grant execute on function public.admin_assign_staff(text,text,text) to authenticated;
grant execute on function public.admin_disable_staff(uuid,text,text) to authenticated;
grant execute on function public.admin_list_staff() to authenticated;
grant execute on function public.admin_create_machine(text,text,text) to authenticated;
grant execute on function public.staff_list_bookings(timestamptz,timestamptz) to authenticated;
grant execute on function public.admin_finance_summary() to authenticated;
grant execute on function public.admin_recent_audit(integer) to authenticated;

-- Callback effects are one atomic DB transaction and create durable in-app notices plus audit records.
create or replace function public.apply_paymob_callback(p_reference text,p_order_id text,p_transaction_id text,p_amount_cents integer,p_currency text,p_success boolean)
returns jsonb language plpgsql security definer set search_path=public
as $$
declare a public.payment_attempts%rowtype; ticket uuid;
begin
 select * into a from public.payment_attempts where (special_reference=p_reference and p_reference is not null) or (paymob_order_id=p_order_id and p_order_id is not null) order by created_at desc limit 1 for update;
 if not found then raise exception 'payment attempt was not found'; end if;
 if a.amount_cents<>p_amount_cents or a.currency<>p_currency then raise exception 'amount or currency mismatch'; end if;
 if a.status='paid' then if a.paymob_transaction_id=p_transaction_id then return jsonb_build_object('status','already_processed','reference',a.special_reference); end if; raise exception 'attempt was already paid by another transaction'; end if;
 if a.status<>'pending' then return jsonb_build_object('status',a.status,'reference',a.special_reference); end if;
 if p_success then
  update public.payment_attempts set status='paid',paymob_transaction_id=p_transaction_id,updated_at=now() where id=a.id;
  if a.kind='wallet_topup' then
   insert into public.wallet_ledger(user_id,payment_attempt_id,amount_cents,entry_type,reference,note) values(a.user_id,a.id,a.amount_cents,'paymob_topup','paymob-'||p_transaction_id,'Paymob wallet top-up') on conflict do nothing;
   insert into public.notifications(user_id,title,body,category) values(a.user_id,'Wallet top-up complete','EGP '||to_char(a.amount_cents/100.0,'FM999999990.00')||' was added to your wallet.','payment');
  else
   update public.laundry_tickets set status='confirmed' where payment_attempt_id=a.id and status='pending_payment' returning id into ticket;
   if ticket is null then raise exception 'ticket reservation is missing'; end if;
   insert into public.notifications(user_id,title,body,category) values(a.user_id,'Laundry ticket confirmed','Your payment is confirmed and your laundry ticket is ready.','booking');
  end if;
  insert into public.audit_events(actor_user_id,actor_role,action,entity_type,entity_id,details) values(null,'system','payment_confirmed','payment',a.special_reference,jsonb_build_object('user_id',a.user_id,'kind',a.kind,'amount_cents',a.amount_cents,'transaction_id',p_transaction_id));
  return jsonb_build_object('status','paid','reference',a.special_reference);
 end if;
 update public.payment_attempts set status='failed',paymob_transaction_id=p_transaction_id,updated_at=now() where id=a.id;
 update public.laundry_tickets set status='failed' where payment_attempt_id=a.id and status='pending_payment';
 insert into public.notifications(user_id,title,body,category) values(a.user_id,'Payment not completed','No ticket or wallet credit was created. You can try again or contact support.','payment');
 insert into public.audit_events(actor_user_id,actor_role,action,entity_type,entity_id,details) values(null,'system','payment_failed','payment',a.special_reference,jsonb_build_object('user_id',a.user_id,'kind',a.kind,'amount_cents',a.amount_cents,'transaction_id',p_transaction_id));
 return jsonb_build_object('status','failed','reference',a.special_reference);
end $$;
revoke all on function public.apply_paymob_callback(text,text,text,integer,text,boolean) from public,anon,authenticated;
grant execute on function public.apply_paymob_callback(text,text,text,integer,text,boolean) to service_role;

-- Reapply hardened read policies and access verification after the domain objects exist.
drop policy if exists door_events_admin_read on public.door_events;
create policy door_events_admin_read on public.door_events for select to authenticated using(exists(select 1 from public.role_assignments r where r.user_id=auth.uid() and r.active and (r.role='admin' or (r.role='supervisor' and r.dorm_class=door_events.dorm_class))));
drop policy if exists support_staff_read on public.support_tickets;
create policy support_staff_read on public.support_tickets for select to authenticated using(exists(select 1 from public.role_assignments r where r.user_id=auth.uid() and r.active and (r.role='admin' or (r.role='supervisor' and r.dorm_class=support_tickets.dorm_class))));
create or replace function public.get_my_access()
returns jsonb language plpgsql stable security definer set search_path=public
as $$
declare p public.student_profiles%rowtype; r text; scoped text; confirmed timestamptz;
begin
 select email_confirmed_at into confirmed from auth.users where id=auth.uid();
 if confirmed is null then return jsonb_build_object('allowed',false,'reason','email_unverified'); end if;
 select * into p from public.student_profiles where user_id=auth.uid();
 select role,dorm_class into r,scoped from public.role_assignments where user_id=auth.uid() and active order by case role when 'admin' then 1 when 'supervisor' then 2 else 3 end limit 1;
 if r is null then return jsonb_build_object('allowed',false,'reason','no_active_role'); end if;
 if r='student' and (p.user_id is null or p.approval_status<>'approved' or p.approved_at is null) then return jsonb_build_object('allowed',false,'reason',coalesce(p.approval_status,'profile_missing'),'role','student'); end if;
 return jsonb_build_object('allowed',true,'role',r,'dormClass',scoped,'name',coalesce(p.full_name,''),'email',(select email from auth.users where id=auth.uid()));
end $$;
revoke all on function public.get_my_access() from public,anon;
grant execute on function public.get_my_access() to authenticated;

-- Invitations are created only by the verified admin Edge Function. An untrusted signup that sets
-- staff_invite still receives no role assignment, so it cannot acquire staff access.
create or replace function public.on_auth_user_created()
returns trigger language plpgsql security definer set search_path=public,extensions
as $$
declare m jsonb:=coalesce(new.raw_user_meta_data,'{}'::jsonb); em text:=lower(coalesce(new.email,'')); nm text:=trim(coalesce(m->>'full_name','')); sid text:=coalesce(m->>'university_id',''); age_value integer:=nullif(m->>'age','')::integer;
begin
 if em !~ '^[a-z0-9._%+-]+@zewailcity\.edu\.eg$' then raise exception 'Only Zewail City email addresses are accepted'; end if;
 if m->>'staff_invite'='true' then return new; end if;
 if nm !~ '^[[:alpha:]ء-ي][[:alpha:]ء-ي .''-]{1,119}$' then raise exception 'A valid student name is required'; end if;
 if sid !~ '^[0-9]+$' then raise exception 'University ID must contain numbers only'; end if;
 if age_value is null or age_value<18 or age_value>120 then raise exception 'Student must be at least 18 years old'; end if;
 if coalesce(m->>'dorm_class','') not in ('A','B','C','D') then raise exception 'A valid dorm class is required'; end if;
 if coalesce(m->>'major','')='' or coalesce(m->>'phone_number','')='' then raise exception 'Major and phone number are required'; end if;
 if coalesce((m->>'privacy_accepted')::boolean,false) is not true or coalesce((m->>'terms_accepted')::boolean,false) is not true then raise exception 'Privacy notice and terms acceptance are required'; end if;
 insert into public.student_profiles(user_id,full_name,university_email,university_id,major,age,phone_number,whatsapp_number,dorm_class,approval_status,terms_accepted_at,privacy_accepted_at)
 values(new.id,nm,em,sid,trim(m->>'major'),age_value,trim(m->>'phone_number'),nullif(trim(m->>'whatsapp_number'),''),m->>'dorm_class','pending',now(),now());
 insert into public.role_assignments(user_id,role) values(new.id,'student') on conflict do nothing;
 return new;
end $$;

create or replace function public.student_available_slots(p_from timestamptz,p_until timestamptz,p_machine_key text default null)
returns table(slot_id uuid,machine_key text,machine_name text,starts_at timestamptz,duration_minutes smallint)
language plpgsql stable security definer set search_path=public
as $$
declare p public.student_profiles%rowtype;
begin
 select * into p from public.student_profiles where user_id=auth.uid() and approval_status='approved';
 if not found then raise exception 'Approved student account required'; end if;
 if p_until<=p_from or p_until>p_from+interval '8 days' then raise exception 'Invalid slot date range'; end if;
 return query select s.id,m.machine_key,m.display_name,s.starts_at,s.duration_minutes from public.laundry_slots s join public.laundry_machines m using(machine_key)
 where s.status='open' and m.status='available' and m.dorm_class=p.dorm_class and s.starts_at between p_from and p_until
 and (p_machine_key is null or s.machine_key=p_machine_key)
 and not exists(select 1 from public.laundry_tickets t where t.slot_id=s.id and t.status in ('pending_payment','confirmed')) order by s.starts_at;
end $$;
create or replace function public.student_ticket_price()
returns integer language sql stable security definer set search_path=public
as $$ select ticket_price_cents from public.laundry_settings where id=1 and exists(select 1 from public.student_profiles p where p.user_id=auth.uid() and p.approval_status='approved'); $$;
revoke all on function public.student_available_slots(timestamptz,timestamptz,text) from public,anon;
revoke all on function public.student_ticket_price() from public,anon;
grant execute on function public.student_available_slots(timestamptz,timestamptz,text) to authenticated;
grant execute on function public.student_ticket_price() to authenticated;

create or replace function public.admin_find_student(p_query text)
returns table(user_id uuid,full_name text,university_email text,university_id text)
language plpgsql stable security definer set search_path=public
as $$
begin
 if not exists(select 1 from public.role_assignments where user_id=auth.uid() and role='admin' and active) then raise exception 'Admin role required'; end if;
 return query select p.user_id,p.full_name,p.university_email,p.university_id from public.student_profiles p where p.approval_status='approved' and (lower(p.university_email)=lower(trim(p_query)) or p.university_id=trim(p_query)) limit 1;
end $$;
revoke all on function public.admin_find_student(text) from public,anon;
grant execute on function public.admin_find_student(text) to authenticated;

create or replace function public.staff_add_machine(p_machine_key text,p_display_name text,p_dorm_class text)
returns void language plpgsql security definer set search_path=public
as $$
declare actor uuid:=auth.uid();
begin
 if p_machine_key !~ '^[A-Za-z0-9_-]{2,40}$' or length(trim(p_display_name)) not between 2 and 80 or p_dorm_class not in ('A','B','C','D') then raise exception 'Invalid machine details'; end if;
 if not exists(select 1 from public.role_assignments r where r.user_id=actor and r.active and (r.role='admin' or (r.role='supervisor' and r.dorm_class=p_dorm_class))) then raise exception 'Not authorized for this dorm'; end if;
 insert into public.laundry_machines(machine_key,display_name,dorm_class,status) values(p_machine_key,trim(p_display_name),p_dorm_class,'available');
 insert into public.audit_events(actor_user_id,actor_role,action,entity_type,entity_id,details) values(actor,'staff','machine_added','machine',p_machine_key,jsonb_build_object('dorm_class',p_dorm_class));
end $$;
create or replace function public.staff_publish_slot_batch(p_slots jsonb)
returns integer language plpgsql security definer set search_path=public
as $$
declare item jsonb; m public.laundry_machines%rowtype; starts timestamptz; dur integer; count_slots integer:=0; actor uuid:=auth.uid();
begin
 if jsonb_typeof(p_slots)<>'array' or jsonb_array_length(p_slots)<1 or jsonb_array_length(p_slots)>500 then raise exception 'Provide between 1 and 500 slots'; end if;
 for item in select value from jsonb_array_elements(p_slots) loop
  select * into m from public.laundry_machines where machine_key=item->>'machine_key';if not found then raise exception 'Machine not found';end if;
  if not exists(select 1 from public.role_assignments r where r.user_id=actor and r.active and (r.role='admin' or (r.role='supervisor' and r.dorm_class=m.dorm_class))) then raise exception 'Not authorized for a selected dorm';end if;
  starts:=(item->>'starts_at')::timestamptz;dur:=coalesce((item->>'duration_minutes')::integer,30);
  if starts<now()+interval '5 minutes' or starts>now()+interval '60 days' or dur not in (30,45,60) then raise exception 'Slot date or duration is outside allowed range';end if;
  if exists(select 1 from public.laundry_slots s join public.laundry_tickets t on t.slot_id=s.id where s.machine_key=m.machine_key and s.starts_at=starts and t.status in ('pending_payment','confirmed')) then raise exception 'Cannot change a slot that is already reserved';end if;
  insert into public.laundry_slots(machine_key,starts_at,duration_minutes,status) values(m.machine_key,starts,dur,'open') on conflict(machine_key,starts_at) do update set duration_minutes=excluded.duration_minutes,status='open';
  count_slots:=count_slots+1;
 end loop;
 insert into public.audit_events(actor_user_id,actor_role,action,entity_type,entity_id,details) values(actor,'staff','slot_batch_published','schedule',actor::text,jsonb_build_object('count',count_slots));
 return count_slots;
end $$;
create or replace function public.admin_credit_wallet(p_student_id uuid,p_amount_cents integer,p_reason text,p_reference text)
returns void language plpgsql security definer set search_path=public
as $$
declare actor uuid:=auth.uid(); dorm text;
begin
 if not exists(select 1 from public.role_assignments where user_id=actor and role='admin' and active) then raise exception 'Admin role required'; end if;
 if p_amount_cents<1 or p_amount_cents>500000 or length(trim(coalesce(p_reason,'')))<5 or length(trim(coalesce(p_reference,'')))<8 then raise exception 'A valid amount, reason and idempotency reference are required'; end if;
 select dorm_class into dorm from public.student_profiles where user_id=p_student_id and approval_status='approved';if dorm is null then raise exception 'Approved student not found';end if;
 insert into public.wallet_ledger(user_id,amount_cents,entry_type,actor_user_id,reference,note) values(p_student_id,p_amount_cents,'admin_credit',actor,p_reference,left(trim(p_reason),1000));
 insert into public.notifications(user_id,title,body,category) values(p_student_id,'Wallet credit added','An administrator added EGP '||to_char(p_amount_cents/100.0,'FM999999990.00')||' to your wallet.','payment');
 insert into public.audit_events(actor_user_id,actor_role,action,entity_type,entity_id,reason,details) values(actor,'admin','wallet_credit','student',p_student_id::text,left(p_reason,1000),jsonb_build_object('amount_cents',p_amount_cents,'reference',p_reference,'dorm_class',dorm));
end $$;
revoke all on function public.staff_add_machine(text,text,text) from public,anon;
revoke all on function public.staff_publish_slot_batch(jsonb) from public,anon;
grant execute on function public.staff_add_machine(text,text,text) to authenticated;
grant execute on function public.staff_publish_slot_batch(jsonb) to authenticated;

alter table public.laundry_tickets drop constraint if exists laundry_tickets_status_check;
alter table public.laundry_tickets add constraint laundry_tickets_status_check check(status in ('pending_payment','confirmed','completed','cancelled','no_show','failed','expired'));
create or replace function public.student_cancel_ticket(p_ticket_id uuid)
returns void language plpgsql security definer set search_path=public
as $$
declare t public.laundry_tickets%rowtype; s public.laundry_slots%rowtype; price integer; ref text;
begin
 select * into t from public.laundry_tickets where id=p_ticket_id and user_id=auth.uid() and status='confirmed' for update;if not found then raise exception 'Confirmed ticket not found';end if;
 select * into s from public.laundry_slots where id=t.slot_id;
 if s.starts_at<now()+interval '2 hours' then raise exception 'Tickets can only be cancelled at least two hours before the slot';end if;
 if exists(select 1 from public.payment_attempts where id=t.payment_attempt_id and status='paid') then raise exception 'Contact support to request cancellation of an online payment';end if;
 select -amount_cents into price from public.wallet_ledger where ticket_id=t.id and entry_type='ticket_payment' limit 1;
 update public.laundry_tickets set status='cancelled' where id=t.id;
 if price is not null then ref:='refund-'||t.id::text;insert into public.wallet_ledger(user_id,ticket_id,amount_cents,entry_type,actor_user_id,reference,note) values(t.user_id,t.id,price,'refund',auth.uid(),ref,'Cancelled ticket wallet refund');end if;
 insert into public.notifications(user_id,title,body,category) values(t.user_id,'Laundry ticket cancelled',case when price is not null then 'Your wallet payment was returned.' else 'Your ticket was cancelled.' end,'booking');
 insert into public.audit_events(actor_user_id,actor_role,action,entity_type,entity_id,details) values(auth.uid(),'student','ticket_cancelled','ticket',t.id::text,jsonb_build_object('slot_id',t.slot_id,'wallet_refunded',price is not null));
end $$;
create or replace function public.staff_set_ticket_status(p_ticket_id uuid,p_status text,p_reason text default null)
returns void language plpgsql security definer set search_path=public
as $$
declare t public.laundry_tickets%rowtype; m public.laundry_machines%rowtype; s public.laundry_slots%rowtype; actor uuid:=auth.uid();
begin
 if p_status not in ('completed','no_show') then raise exception 'Invalid ticket status';end if;
 select * into t from public.laundry_tickets where id=p_ticket_id for update;if not found or t.status<>'confirmed' then raise exception 'Confirmed ticket not found';end if;
 select * into s from public.laundry_slots where id=t.slot_id;select * into m from public.laundry_machines where machine_key=s.machine_key;
 if not exists(select 1 from public.role_assignments r where r.user_id=actor and r.active and (r.role='admin' or (r.role='supervisor' and r.dorm_class=m.dorm_class))) then raise exception 'Not authorized for this dorm';end if;
 if p_status='completed' and now()<s.starts_at then raise exception 'A ticket cannot be completed before its slot begins';end if;
 if p_status='no_show' and now()<s.starts_at+(s.duration_minutes||' minutes')::interval+interval '10 minutes' then raise exception 'A no-show can only be recorded after the grace period';end if;
 update public.laundry_tickets set status=p_status where id=t.id;
 insert into public.notifications(user_id,title,body,category) values(t.user_id,case when p_status='completed' then 'Laundry ticket completed' else 'Laundry slot marked no-show' end,case when p_status='completed' then 'Your laundry ticket was marked complete.' else 'Your booking was marked as a no-show.' end,'booking');
 insert into public.audit_events(actor_user_id,actor_role,action,entity_type,entity_id,reason,details) values(actor,'staff','ticket_'||p_status,'ticket',t.id::text,left(p_reason,1000),jsonb_build_object('dorm_class',m.dorm_class));
end $$;
revoke all on function public.student_cancel_ticket(uuid) from public,anon;
revoke all on function public.staff_set_ticket_status(uuid,text,text) from public,anon;
grant execute on function public.student_cancel_ticket(uuid) to authenticated;
grant execute on function public.staff_set_ticket_status(uuid,text,text) to authenticated;

create unique index if not exists student_profiles_university_id_unique on public.student_profiles(university_id) where university_id is not null;
create or replace function public.student_pay_ticket_from_wallet(p_slot_id uuid)
returns uuid language plpgsql security definer set search_path=public
as $$
declare actor uuid:=auth.uid(); p public.student_profiles%rowtype; s public.laundry_slots%rowtype; m public.laundry_machines%rowtype; price integer; balance integer; tid uuid; ref text;
begin
 select * into p from public.student_profiles where user_id=actor and approval_status='approved' and approved_at is not null;if not found then raise exception 'Approved student account required';end if;
 select * into s from public.laundry_slots where id=p_slot_id and status='open' for update;if not found then raise exception 'Slot is not available';end if;
 select * into m from public.laundry_machines where machine_key=s.machine_key and dorm_class=p.dorm_class and status='available';if not found then raise exception 'Machine is not available in your dorm';end if;
 if exists(select 1 from public.laundry_tickets where slot_id=s.id and status in ('pending_payment','confirmed')) then raise exception 'Slot is already reserved';end if;
 select ticket_price_cents into price from public.laundry_settings where id=1;select coalesce(sum(amount_cents),0)::integer into balance from public.wallet_ledger where user_id=actor;if balance<price then raise exception 'Insufficient wallet funds';end if;
 tid:=gen_random_uuid();ref:='wallet-ticket-'||tid::text;
 insert into public.laundry_tickets(id,user_id,slot_id,payment_attempt_id,status) values(tid,actor,s.id,null,'confirmed');
 insert into public.wallet_ledger(user_id,ticket_id,amount_cents,entry_type,actor_user_id,reference,note) values(actor,tid,-price,'ticket_payment',actor,ref,'Laundry ticket payment');
 insert into public.notifications(user_id,title,body,category) values(actor,'Laundry ticket confirmed','Your ticket is paid from your wallet and confirmed.','booking');
 insert into public.audit_events(actor_user_id,actor_role,action,entity_type,entity_id,details) values(actor,'student','wallet_ticket_payment','ticket',tid::text,jsonb_build_object('slot_id',s.id,'amount_cents',price));return tid;
end $$;
revoke all on function public.student_pay_ticket_from_wallet(uuid) from public,anon;
grant execute on function public.student_pay_ticket_from_wallet(uuid) to authenticated;

create table if not exists public.machine_telemetry(
 machine_key text primary key references public.laundry_machines(machine_key) on delete cascade,
 device_id uuid not null references public.iot_devices(id), state text not null check(state in ('idle','running','fault','offline')),
 cycle_started_at timestamptz, expected_finish_at timestamptz, details jsonb not null default '{}'::jsonb, reported_at timestamptz not null default now()
);
alter table public.machine_telemetry enable row level security;
revoke all on public.machine_telemetry from anon,authenticated;
grant select on public.machine_telemetry to authenticated;
create policy machine_telemetry_staff_read on public.machine_telemetry for select to authenticated using(exists(select 1 from public.laundry_machines m join public.role_assignments r on r.dorm_class=m.dorm_class where m.machine_key=machine_telemetry.machine_key and r.user_id=auth.uid() and r.active and r.role in ('admin','supervisor')) or exists(select 1 from public.laundry_machines m join public.student_profiles p on p.dorm_class=m.dorm_class where m.machine_key=machine_telemetry.machine_key and p.user_id=auth.uid() and p.approval_status='approved'));
create or replace function public.admin_create_iot_device(p_device_key text,p_dorm_class text)
returns jsonb language plpgsql security definer set search_path=public,extensions
as $$
declare secret text; did uuid; actor uuid:=auth.uid();
begin
 if not exists(select 1 from public.role_assignments where user_id=actor and role='admin' and active) then raise exception 'Admin role required'; end if;
 if p_device_key !~ '^[A-Za-z0-9_-]{3,80}$' or p_dorm_class not in ('A','B','C','D') then raise exception 'Invalid device label or dorm'; end if;
 secret:=encode(extensions.gen_random_bytes(32),'hex');
 insert into public.iot_devices(device_key,dorm_class,api_key_hash) values(p_device_key,p_dorm_class,extensions.digest(secret,'sha256')) returning id into did;
 insert into public.audit_events(actor_user_id,actor_role,action,entity_type,entity_id,details) values(actor,'admin','iot_device_provisioned','device',did::text,jsonb_build_object('device_key',p_device_key,'dorm_class',p_dorm_class));
 return jsonb_build_object('deviceId',did,'deviceKey',secret,'warning','Copy this key to the device now. It is never shown again.');
end $$;
create or replace function public.iot_report_machine_state(p_device_id uuid,p_machine_key text,p_state text,p_details jsonb default '{}'::jsonb)
returns void language plpgsql security definer set search_path=public
as $$
declare d public.iot_devices%rowtype; m public.laundry_machines%rowtype; previous text;
begin
 select * into d from public.iot_devices where id=p_device_id and active;if not found then raise exception 'Device is inactive';end if;
 select * into m from public.laundry_machines where machine_key=p_machine_key and dorm_class=d.dorm_class;if not found then raise exception 'Machine is outside this device dorm';end if;
 if p_state not in ('idle','running','fault','offline') then raise exception 'Invalid machine telemetry state';end if;
 select state into previous from public.machine_telemetry where machine_key=p_machine_key;
 insert into public.machine_telemetry(machine_key,device_id,state,cycle_started_at,expected_finish_at,details,reported_at) values(p_machine_key,d.id,p_state,nullif(p_details->>'cycle_started_at','')::timestamptz,nullif(p_details->>'expected_finish_at','')::timestamptz,coalesce(p_details,'{}'::jsonb),now())
 on conflict(machine_key) do update set device_id=excluded.device_id,state=excluded.state,cycle_started_at=excluded.cycle_started_at,expected_finish_at=excluded.expected_finish_at,details=excluded.details,reported_at=now();
 insert into public.device_events(device_id,event_type,machine_key,details) values(d.id,'machine_'||p_state,p_machine_key,coalesce(p_details,'{}'::jsonb));
 if p_state='fault' and previous is distinct from 'fault' then
  insert into public.notifications(user_id,title,body,category) select r.user_id,'Machine needs attention',m.display_name||' reported a fault. Please inspect it.','machine' from public.role_assignments r where r.role='supervisor' and r.dorm_class=d.dorm_class and r.active;
 end if;
end $$;
revoke all on function public.admin_create_iot_device(text,text) from public,anon;
revoke all on function public.iot_report_machine_state(uuid,text,text,jsonb) from public,anon,authenticated;
grant execute on function public.admin_create_iot_device(text,text) to authenticated;
grant execute on function public.iot_report_machine_state(uuid,text,text,jsonb) to service_role;

alter table public.audit_events add column if not exists approximate_location text;
create or replace function public.capture_audit_request_context()
returns trigger language plpgsql security definer set search_path=public
as $$
declare h jsonb; raw_ip text; country text;
begin
 begin h:=coalesce(nullif(current_setting('request.headers',true),''),'{}')::jsonb; exception when others then h:='{}'::jsonb; end;
 if new.source_ip is null then
  raw_ip:=split_part(coalesce(h->>'x-forwarded-for',h->>'x-real-ip',h->>'cf-connecting-ip',''),',',1);
  begin new.source_ip:=nullif(trim(raw_ip),'')::inet; exception when others then new.source_ip:=null; end;
 end if;
 if new.user_agent is null then new.user_agent:=left(h->>'user-agent',500); end if;
 if new.approximate_location is null then
  country:=upper(regexp_replace(coalesce(h->>'cf-ipcountry',''),'[^A-Za-z0-9-]','','g'));
  if length(country) between 2 and 8 then new.approximate_location:='Country code: '||country; end if;
 end if;
 return new;
end $$;
revoke all on function public.capture_audit_request_context() from public,anon,authenticated;
drop trigger if exists audit_request_context on public.audit_events;
create trigger audit_request_context before insert on public.audit_events for each row execute function public.capture_audit_request_context();
drop policy if exists audit_actor_self_read on public.audit_events;
create policy audit_actor_self_read on public.audit_events for select to authenticated using(actor_user_id=auth.uid());
create or replace function public.record_user_audit(p_action text,p_details text default null)
returns void language plpgsql security definer set search_path=public
as $$
declare r text;
begin
 if p_action not in ('login','logout','password_changed','notification_read') then raise exception 'Action is not accepted'; end if;
 select role into r from public.role_assignments where user_id=auth.uid() and active order by case role when 'admin' then 1 when 'supervisor' then 2 else 3 end limit 1;
 if r is null then raise exception 'Active role required'; end if;
 insert into public.audit_events(actor_user_id,actor_role,action,entity_type,entity_id,details) values(auth.uid(),r,p_action,'account',auth.uid()::text,jsonb_build_object('note',left(coalesce(p_details,''),300)));
end $$;
revoke all on function public.record_user_audit(text,text) from public,anon;
grant execute on function public.record_user_audit(text,text) to authenticated;
create or replace function public.audit_whatsapp_change()
returns trigger language plpgsql security definer set search_path=public
as $$
declare r text;
begin
 if new.whatsapp_number is distinct from old.whatsapp_number then
  select role into r from public.role_assignments where user_id=auth.uid() and active order by case role when 'admin' then 1 when 'supervisor' then 2 else 3 end limit 1;
  insert into public.audit_events(actor_user_id,actor_role,action,entity_type,entity_id,details) values(auth.uid(),coalesce(r,'student'),'whatsapp_updated','student',new.user_id::text,jsonb_build_object('changed',true));
 end if;
 return new;
end $$;
drop trigger if exists student_profile_whatsapp_audit on public.student_profiles;
create trigger student_profile_whatsapp_audit after update of whatsapp_number on public.student_profiles for each row execute function public.audit_whatsapp_change();

create or replace function public.staff_list_support_tickets(p_status text default null)
returns table(ticket_id uuid,student_name text,student_email text,dorm_class text,category text,subject text,description text,status text,created_at timestamptz,resolution text)
language plpgsql stable security definer set search_path=public
as $$
begin
 if not exists(select 1 from public.role_assignments r where r.user_id=auth.uid() and r.active and r.role in ('supervisor','admin')) then raise exception 'Staff role required';end if;
 return query select t.id,p.full_name,p.university_email,t.dorm_class,t.category,t.subject,t.description,t.status,t.created_at,t.resolution from public.support_tickets t join public.student_profiles p on p.user_id=t.user_id
 where (p_status is null or t.status=p_status) and (exists(select 1 from public.role_assignments r where r.user_id=auth.uid() and r.role='admin' and r.active) or exists(select 1 from public.role_assignments r where r.user_id=auth.uid() and r.role='supervisor' and r.active and r.dorm_class=t.dorm_class)) order by t.created_at desc limit 200;
end $$;
revoke all on function public.staff_list_support_tickets(text) from public,anon;
grant execute on function public.staff_list_support_tickets(text) to authenticated;

-- Serialize balance-changing transactions per student to prevent concurrent wallet overspend.
create or replace function public.admin_credit_wallet(p_student_id uuid,p_amount_cents integer,p_reason text,p_reference text)
returns void language plpgsql security definer set search_path=public
as $$
declare actor uuid:=auth.uid(); dorm text; existing public.wallet_ledger%rowtype;
begin
 if not exists(select 1 from public.role_assignments where user_id=actor and role='admin' and active) then raise exception 'Admin role required';end if;
 if p_amount_cents<1 or p_amount_cents>500000 or length(trim(coalesce(p_reason,'')))<5 or length(trim(coalesce(p_reference,'')))<8 then raise exception 'A valid amount, reason and idempotency reference are required';end if;
 select * into existing from public.wallet_ledger where reference=p_reference for update;
 if found then if existing.user_id=p_student_id and existing.amount_cents=p_amount_cents and existing.entry_type='admin_credit' and existing.actor_user_id=actor then return;else raise exception 'Reference already used for a different wallet action';end if;end if;
 select dorm_class into dorm from public.student_profiles where user_id=p_student_id and approval_status='approved';if dorm is null then raise exception 'Approved student not found';end if;
 insert into public.wallet_ledger(user_id,amount_cents,entry_type,actor_user_id,reference,note) values(p_student_id,p_amount_cents,'admin_credit',actor,p_reference,left(trim(p_reason),1000));
 insert into public.notifications(user_id,title,body,category) values(p_student_id,'Wallet credit added','An administrator added EGP '||to_char(p_amount_cents/100.0,'FM999999990.00')||' to your wallet.','payment');
 insert into public.audit_events(actor_user_id,actor_role,action,entity_type,entity_id,reason,details) values(actor,'admin','wallet_credit','student',p_student_id::text,left(p_reason,1000),jsonb_build_object('amount_cents',p_amount_cents,'reference',p_reference,'dorm_class',dorm));
end $$;

create or replace function public.student_cancel_ticket(p_ticket_id uuid)
returns void language plpgsql security definer set search_path=public
as $$
declare t public.laundry_tickets%rowtype; s public.laundry_slots%rowtype; price integer; ref text;
begin
 select * into t from public.laundry_tickets where id=p_ticket_id and user_id=auth.uid() and status='confirmed' for update;if not found then raise exception 'Confirmed ticket not found';end if;
 perform pg_advisory_xact_lock(hashtextextended(t.user_id::text,0));
 select * into s from public.laundry_slots where id=t.slot_id;if s.starts_at<now()+interval '2 hours' then raise exception 'Tickets can only be cancelled at least two hours before the slot';end if;
 if exists(select 1 from public.payment_attempts where id=t.payment_attempt_id and status='paid') then raise exception 'Contact support to request cancellation of an online payment';end if;
 select -amount_cents into price from public.wallet_ledger where ticket_id=t.id and entry_type='ticket_payment' limit 1;
 update public.laundry_tickets set status='cancelled' where id=t.id;
 if price is not null then ref:='refund-'||t.id::text;insert into public.wallet_ledger(user_id,ticket_id,amount_cents,entry_type,actor_user_id,reference,note) values(t.user_id,t.id,price,'refund',auth.uid(),ref,'Cancelled ticket wallet refund');end if;
 insert into public.notifications(user_id,title,body,category) values(t.user_id,'Laundry ticket cancelled',case when price is not null then 'Your wallet payment was returned.' else 'Your ticket was cancelled.' end,'booking');
 insert into public.audit_events(actor_user_id,actor_role,action,entity_type,entity_id,details) values(auth.uid(),'student','ticket_cancelled','ticket',t.id::text,jsonb_build_object('slot_id',t.slot_id,'wallet_refunded',price is not null));
end $$;

create or replace function public.student_pay_ticket_from_wallet(p_slot_id uuid)
returns uuid language plpgsql security definer set search_path=public
as $$
declare actor uuid:=auth.uid(); p public.student_profiles%rowtype; s public.laundry_slots%rowtype; m public.laundry_machines%rowtype; price integer; balance integer; tid uuid; ref text;
begin
 select * into p from public.student_profiles where user_id=actor and approval_status='approved' and approved_at is not null;if not found then raise exception 'Approved student account required';end if;
 perform pg_advisory_xact_lock(hashtextextended(actor::text,0));
 select * into s from public.laundry_slots where id=p_slot_id and status='open' for update;if not found then raise exception 'Slot is not available';end if;
 select * into m from public.laundry_machines where machine_key=s.machine_key and dorm_class=p.dorm_class and status='available';if not found then raise exception 'Machine is not available in your dorm';end if;
 if exists(select 1 from public.laundry_tickets where slot_id=s.id and status in ('pending_payment','confirmed')) then raise exception 'Slot is already reserved';end if;
 select ticket_price_cents into price from public.laundry_settings where id=1;select coalesce(sum(amount_cents),0)::integer into balance from public.wallet_ledger where user_id=actor;if balance<price then raise exception 'Insufficient wallet funds';end if;
 tid:=gen_random_uuid();ref:='wallet-ticket-'||tid::text;
 insert into public.laundry_tickets(id,user_id,slot_id,payment_attempt_id,status) values(tid,actor,s.id,null,'confirmed');
 insert into public.wallet_ledger(user_id,ticket_id,amount_cents,entry_type,actor_user_id,reference,note) values(actor,tid,-price,'ticket_payment',actor,ref,'Laundry ticket payment');
 insert into public.notifications(user_id,title,body,category) values(actor,'Laundry ticket confirmed','Your ticket is paid from your wallet and confirmed.','booking');
 insert into public.audit_events(actor_user_id,actor_role,action,entity_type,entity_id,details) values(actor,'student','wallet_ticket_payment','ticket',tid::text,jsonb_build_object('slot_id',s.id,'amount_cents',price));return tid;
end $$;
revoke all on function public.admin_credit_wallet(uuid,integer,text,text) from public,anon;
revoke all on function public.student_cancel_ticket(uuid) from public,anon;
revoke all on function public.student_pay_ticket_from_wallet(uuid) from public,anon;
grant execute on function public.admin_credit_wallet(uuid,integer,text,text) to authenticated;
grant execute on function public.student_cancel_ticket(uuid) to authenticated;
grant execute on function public.student_pay_ticket_from_wallet(uuid) to authenticated;
