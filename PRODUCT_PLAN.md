# Zewail City Laundry for Dorms website — product plan

This is a working product note for the web prototype. The files under `sources/` remain reference-only.

## Product shape

Zewail City Laundry for Dorms has three role-based areas:

1. **Public landing page** — explain the service and link to student sign-in and registration.
2. **Student portal** — buy and manage laundry tickets, see machine status, receive notices, and show a door QR when eligible.
3. **Supervisor and main admin portals** — manage daily operations and platform-wide configuration, with access and audit records.

Student portal enhancements requested: bilingual Arabic/English with right-to-left layout, light/dark theme, separate completed and incomplete ticket history, a trackable support/complaint form, editable profile and password, a personal wallet view, and a loyalty program.

- Use a small set of built-in avatar choices stored as an avatar key, not uploaded image files.
- Store language and theme as small preferences.
- Wallet transactions and balance must come from the server; show clear payment/refund records.
- Loyalty points should be awarded for completed tickets. Define points and redemption policy before presenting points as having cash value.

## Account and role rules

- Student registration accepts only `@zewailcity.edu.eg` addresses and verifies ownership before activating an account.
- Registration validates a full name, digits-only university ID, exact `@zewailcity.edu.eg` email domain, and age 18 or older. Password creation asks for confirmation and shows live requirements.
- Account lifecycle: pending email-link verification → pending dorm supervisor approval → active. Pending accounts cannot sign in to reserve tickets.
- Student registration collects name, university ID, email, major, dorm class (A/B/C/D), phone, optional WhatsApp, and age as currently requested.
- **Recommendation to review:** collect age only if the university or project has a clear need for it. Make WhatsApp optional or reuse the phone number when it is the same; avoid collecting duplicate personal data without a use.
- A Supabase email confirmation link is the recommended primary email-ownership check. WhatsApp authentication templates are not guaranteed to be free; consider them only if the project has budget and an approved business account. WhatsApp can be an optional notification channel later.
- Students must read and accept separate privacy and terms documents before registration continues. The final documents require university review and approval; prototype text is not legal approval.
- Supervisor accounts are invited/created by an administrator. They do not use the public student registration form.
- Main admin manages roles and permissions. Student, supervisor, and admin permissions are distinct and checked by the server, not only hidden in the interface.
- Password reset uses a verified email link. Sign-in and reset responses should not reveal whether an email is registered.

## Laundry ticket lifecycle

One ticket reserves **one specific washer for one time slot**. Admin-configured price is shown before checkout and copied onto the ticket at purchase time, so later price changes do not alter old tickets.

Suggested ticket states: `held`, `payment pending`, `confirmed`, `cancelled`, `refunded`, `expired`, `used`, `no-show`.

1. Student chooses a washer and an available time slot.
2. Student reviews laundry instructions, safety information, privacy notice, cancellation/no-show policy, and acknowledges them before payment.
3. Server places a short hold on that washer/slot and creates one payment attempt.
4. Payment is confirmed only by a verified provider callback or server-side transaction inquiry. A unique payment reference/idempotency key prevents duplicate confirmation. Refreshing or returning from checkout retrieves the existing booking/payment state; it must not create another charge.
5. On verified payment, the server confirms the ticket, stores the price paid, and sends an in-app notification and email receipt.
6. A signed, short-lived, single-use QR is shown for the confirmed ticket. The QR should contain an opaque token, not student personal information. Suggested access rule: it becomes usable at the booked start time and expires 10 minutes after the start if no entry was recorded. Show a countdown to that deadline; after the window the booking is marked no-show and the QR is rejected. Confirm this exact policy with the team.
7. Door scanner/node sends the QR token to a backend endpoint over an authenticated connection. The backend checks signature, ticket payment, target door, time window, and whether the token was already used, then returns allow/deny. The node reports the result and door state. The web page never directly unlocks the physical door.
8. Door entry, QR use, machine state changes, cancellation, refund, and staff overrides are recorded against the ticket and in the audit log.

### IoT integration requirements

- Keep the website, backend, door ESP32, and machine sensing node as separate components connected through authenticated backend APIs.
- Payment confirmation creates a paid ticket first; only then may the backend issue the QR credential.
- Reject expired, replayed, wrong-door, unpaid, cancelled, or already-used QR tokens. Record both allowed and denied scans.
- Use HTTPS/TLS and per-device credentials. If backend verification is unavailable, remote access fails closed; physical emergency exit remains independent of the network and firmware.
- Door-node unlock reports and machine sensor state changes flow back to the backend and then to student/supervisor views.

The UI must show explicit states for payment pending, confirmed, declined, expired, and refunded. After a payment redirect or page refresh, it should query the server for the current attempt before offering retry. A client-side “paid” message is never sufficient proof of payment.

## Supervisor portal

- View bookings and ticket states for the managed laundry room.
- Add/edit/disable washer records and mark a washer out of order; unavailable machines reduce bookable capacity immediately.
- View device health, machine state, door events, no-shows, and operational alerts.
- View or suspend student access when authorized; do not expose passwords or allow silent identity edits.
- Any manual action (override, status change, suspension, price/configuration change) records actor, time, target, reason, and before/after values.

## Main admin portal

- Invite/disable supervisor accounts and assign room-level permissions.
- Set ticket price, slot length, booking horizon, cancellation/no-show rules, and room configuration.
- Issue audited wallet credits to a student for an approved reason; the server appends a ledger entry instead of directly changing a balance.
- Review payment reconciliation, ticket audit records, usage analytics, and system/device status.
- Keep a protected audit history. Ordinary supervisors must not be able to erase or rewrite audit entries.

## Useful additions (prioritize after the core flow)

- Booking reminder before the slot, plus a payment receipt and ticket email.
- Waitlist for a full slot and a clear sensor-offline state that never claims the washer is free.
- Student ticket history and a help/report-a-problem action.
- Refund/cancellation policy shown before payment and reflected in the ticket status.
- Later only: prepaid bundles, discount codes, multiple laundry rooms, and extra analytics.

## Prototype boundary

Current HTML pages are UI mockups. They do not authenticate users, persist bookings, take payments, send email, create real QR credentials, enforce roles, write audit logs, or operate the door. Those require backend services and integration with the chosen payment provider and hardware.

The demo includes a tab-scoped `sessionStorage` login preview and local browser audit sample for navigation review only. This is not secure production authentication or an authoritative audit log. Production should use server-managed session cookies, Supabase Auth email confirmation links, RLS on all exposed tables, server-side account approval, rate-limited requests, and a protected audit trail. No absolute “unhackable” guarantee is possible; release requires security review and deployment configuration.

