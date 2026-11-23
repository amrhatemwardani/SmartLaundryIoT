-- Migration 202611170013: Paymob Sandbox & Browser Notifications support
-- Allows student read access to their own payment attempts, provides sandbox payment simulation,
-- and ensures all booking & wallet actions emit private student notifications.

grant select on public.payment_attempts to authenticated;
drop policy if exists "Students read their own payment attempts" on public.payment_attempts;
create policy "Students read their own payment attempts" on public.payment_attempts
  for select to authenticated using ((select auth.uid()) = user_id);

-- Secure sandbox simulation for Paymob payments in development/testing
create or replace function public.student_simulate_paymob_sandbox(
  p_reference text,
  p_success boolean default true
) returns jsonb language plpgsql security definer set search_path = public
as $$
declare
  actor uuid := auth.uid();
  a public.payment_attempts%rowtype;
  ticket uuid;
  sim_txn text;
begin
  if actor is null then
    raise exception 'Authentication required';
  end if;

  select * into a from public.payment_attempts
    where special_reference = p_reference and user_id = actor
    for update;

  if not found then
    raise exception 'Payment attempt not found or not owned by your account';
  end if;

  if a.status <> 'pending' then
    return jsonb_build_object('status', a.status, 'reference', a.special_reference, 'already_finished', true);
  end if;

  sim_txn := 'sim_' || replace(gen_random_uuid()::text, '-', '');

  if p_success then
    update public.payment_attempts
      set status = 'paid', paymob_transaction_id = sim_txn, updated_at = now()
      where id = a.id;

    if a.kind = 'wallet_topup' then
      insert into public.wallet_ledger(user_id, payment_attempt_id, amount_cents, entry_type, actor_user_id, reference, note)
      values(a.user_id, a.id, a.amount_cents, 'paymob_topup', actor, 'paymob-sim-' || sim_txn, 'Paymob sandbox wallet top-up')
      on conflict do nothing;

      insert into public.notifications(user_id, title, body, category)
      values(a.user_id, 'Wallet top-up complete / تم شحن المحفظة',
             'EGP ' || to_char(a.amount_cents / 100.0, 'FM999999990.00') || ' was credited to your wallet via Paymob sandbox.', 'payment');
    else
      update public.laundry_tickets
        set status = 'confirmed'
        where payment_attempt_id = a.id and status = 'pending_payment'
        returning id into ticket;

      if ticket is null then
        raise exception 'Ticket reservation is missing';
      end if;

      insert into public.notifications(user_id, title, body, category)
      values(a.user_id, 'Laundry ticket confirmed / تم تأكيد تذكرة الغسيل',
             'Your laundry ticket is confirmed and your door access QR code is ready.', 'booking');
    end if;

    insert into public.audit_events(actor_user_id, actor_role, action, entity_type, entity_id, details)
    values(actor, 'student', 'paymob_sandbox_payment_confirmed', 'payment', a.special_reference,
           jsonb_build_object('amount_cents', a.amount_cents, 'kind', a.kind, 'simulated_txn', sim_txn));

    return jsonb_build_object('status', 'paid', 'reference', a.special_reference, 'kind', a.kind, 'amount_cents', a.amount_cents);
  else
    update public.payment_attempts
      set status = 'failed', paymob_transaction_id = 'sim_declined_' || sim_txn, updated_at = now()
      where id = a.id;

    if a.kind = 'ticket' then
      update public.laundry_tickets
        set status = 'failed'
        where payment_attempt_id = a.id and status = 'pending_payment';
    end if;

    insert into public.notifications(user_id, title, body, category)
    values(a.user_id, 'Payment declined / لم تكتمل عملية الدفع',
           'The payment simulation was marked as declined. No funds were charged.', 'payment');

    insert into public.audit_events(actor_user_id, actor_role, action, entity_type, entity_id, details)
    values(actor, 'student', 'paymob_sandbox_payment_declined', 'payment', a.special_reference,
           jsonb_build_object('amount_cents', a.amount_cents, 'kind', a.kind));

    return jsonb_build_object('status', 'failed', 'reference', a.special_reference, 'kind', a.kind);
  end if;
end $$;

revoke all on function public.student_simulate_paymob_sandbox(text, boolean) from public, anon;
grant execute on function public.student_simulate_paymob_sandbox(text, boolean) to authenticated, service_role;

-- Ensure student_pay_ticket_from_wallet notifies the student immediately
create or replace function public.student_pay_ticket_from_wallet(p_slot_id uuid)
returns uuid language plpgsql security definer set search_path=public
as $$
declare
  actor uuid := auth.uid();
  p public.student_profiles%rowtype;
  s public.laundry_slots%rowtype;
  m public.laundry_machines%rowtype;
  price integer;
  balance integer;
  tid uuid;
  ref text;
begin
  select * into p from public.student_profiles where user_id = actor and approval_status = 'approved' and approved_at is not null;
  if not found then raise exception 'Approved student account required'; end if;
  select * into s from public.laundry_slots where id = p_slot_id and status = 'open' for update;
  if not found then raise exception 'Slot is not available'; end if;
  select * into m from public.laundry_machines where machine_key = s.machine_key and dorm_class = p.dorm_class and status = 'available';
  if not found then raise exception 'Machine is not available in your dorm'; end if;
  if exists(select 1 from public.laundry_tickets where slot_id = s.id and status in ('pending_payment','confirmed')) then raise exception 'Slot is already reserved'; end if;
  select ticket_price_cents into price from public.laundry_settings where id = 1;
  select coalesce(sum(amount_cents),0)::integer into balance from public.wallet_ledger where user_id = actor;
  if balance < price then raise exception 'Insufficient wallet funds'; end if;
  tid := gen_random_uuid();
  ref := 'wallet-ticket-' || tid::text;
  insert into public.laundry_tickets(id, user_id, slot_id, payment_attempt_id, status) values(tid, actor, s.id, null, 'confirmed');
  insert into public.wallet_ledger(user_id, ticket_id, amount_cents, entry_type, actor_user_id, reference, note) values(actor, tid, -price, 'ticket_payment', actor, ref, 'Laundry ticket payment');
  insert into public.notifications(user_id, title, body, category)
  values(actor, 'Ticket confirmed from wallet / تم حجز التذكرة من المحفظة',
         'Your laundry ticket is confirmed and paid from your wallet. Your access QR code is now ready.', 'booking');
  insert into public.audit_events(actor_user_id, actor_role, action, entity_type, entity_id, details) values(actor, 'student', 'wallet_ticket_payment', 'ticket', tid::text, jsonb_build_object('slot_id', s.id, 'amount_cents', price));
  return tid;
end $$;

revoke all on function public.student_pay_ticket_from_wallet(uuid) from public, anon;
grant execute on function public.student_pay_ticket_from_wallet(uuid) to authenticated, service_role;
