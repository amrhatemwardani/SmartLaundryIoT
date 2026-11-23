# Staging test checklist

Use this only after completing `BACKEND_SETUP.md` in a separate staging project. Use test payment credentials and simulated IoT devices. Do not use real student data, real funds, or live door hardware during the first pass.

## Before opening the website

- [ ] Supabase migrations are applied in the documented order and Edge Functions are deployed.
- [ ] `supabase-config.js` contains only the project URL and publishable key; no service-role or secret key appears in browser files.
- [ ] Supabase Auth has the Zewail email confirmation link template, password policy, allowed HTTPS URLs, and custom SMTP configured.
- [ ] Firebase web config and VAPID public key are set in the client; service-account JSON and webhook secret are only in server secrets.
- [ ] A Supabase database webhook targets the Firebase push function for notification inserts.
- [ ] New Paymob test credentials and HMAC secret are in Supabase secrets, and Paymob is pointed at the server callback URL.
- [ ] The first main admin has been granted its role through the one-time trusted bootstrap step.
- [ ] Website is served over HTTPS from the exact configured origin.

## Public site and account flows

- [ ] Landing page, student sign-in, student registration, forgot-password, and reset-password open as separate pages.
- [ ] Registration rejects public email domains, malformed university IDs, names containing numbers, and ages below 18.
- [ ] Password checks require 12 or more characters, uppercase, lowercase, a digit, and a symbol; confirmation mismatch is blocked.
- [ ] Privacy and terms windows must be read to the end and accepted. Confirm notices are still clearly marked as project drafts.
- [ ] Registration sends a single-use confirmation link to the university email. The link returns to the configured login page; invalid or expired links fail. Resend obeys provider rate limits.
- [ ] A verified student remains pending until an assigned supervisor approves them. Pending/declined students cannot reach booking or payment APIs.
- [ ] Forgot-password sends a reset link only for the university domain, and a valid link allows password update.
- [ ] Login with an incorrect role selection is rejected. Unconfirmed and unapproved accounts cannot enter a portal.
- [ ] Session is isolated to the browser tab, expires on inactivity, and ends after explicit logout. Closing the tab and opening a fresh tab requires sign-in again.

## Supervisor and main administrator

- [ ] Main admin can invite a supervisor and assign dorm scope. The invitee must verify their email before sign-in.
- [ ] Supervisor can only see students, machines, bookings, support cases, slots, and door events for assigned dorms.
- [ ] Supervisor can review pending student applications with a decision/reason and create scoped machines/slots.
- [ ] Batch slot creation handles several dates/machines and refuses invalid, past, duplicate, or occupied slots.
- [ ] Machine status changes, ticket completion/no-show, support updates, approvals, invitations, price changes, and wallet credits create server audit records.
- [ ] Main admin can disable staff access, update ticket price, find an approved student, and apply an idempotent wallet credit.
- [ ] Students and supervisors cannot access global finance, staff management, or audit data outside their allowed scope.

## Student portal, wallet, and checkout

- [ ] Student sees only their profile, notifications, wallet, support requests, and ticket history.
- [ ] Verified identity fields remain read-only; WhatsApp can be updated and the change is audited.
- [ ] Student can open a support request; only scoped staff can update its status. Student receives the resulting in-app notice.
- [ ] Wallet balance is computed from the signed server ledger. Client-side attempts to change the balance or price are rejected.
- [ ] Admin wallet credits are reflected once even if the same request is repeated. Ticket payment serializes balance changes to prevent overspend.
- [ ] Test wallet payment confirms only one ticket for a slot and debits once. Eligible cancellation returns wallet funds once.
- [ ] Test Paymob card and wallet checkout. The browser return alone must never show a confirmed payment.
- [ ] Confirm a valid processed callback verifies HMAC and confirms the ticket/top-up. Invalid signature, wrong amount/currency/integration/order, duplicate callback, and failed payment must not issue an extra credit or ticket.
- [ ] Refresh, reopen, or revisit the payment result URL; the server state remains authoritative and the same transaction is not charged or credited twice.
- [ ] Confirm student receives in-app and email/provider notices after the configured events; no card number or payment secret is stored by this app.

## Firebase push, QR, IoT, and audit

- [ ] Student can opt into Firebase browser notifications over HTTPS; a browser that declines permission remains usable.
- [ ] A newly inserted database notification appears in the portal and sends push through the server webhook. Check push while the tab is closed.
- [ ] Student can get a QR only for their own confirmed ticket and only within the configured access window.
- [ ] Device rejects invalid, expired, replayed, wrong-dorm, cancelled, or unpaid QR tokens; one valid scan is granted once and creates a door event.
- [ ] Device can report telemetry only with its own credential; invalid device key, wrong dorm, and invalid machine state are rejected.
- [ ] Audit log shows actor, role, action, timestamp, target, safe details, and the request IP when Supabase provides it. Approximate location should show only a country code when available; server-originated events may have no end-user IP.
- [ ] Emergency door egress and manual operation work with the website and network unavailable.

## Operational readiness

- [ ] Review provider logs and database rows for the entire signup, booking, payment, notification, and device flows.
- [ ] Confirm backups and restore procedure; review rate limits, alerting, log retention, and operational ownership.
- [ ] Conduct role/RLS, payment replay, booking concurrency, and IoT security review in staging.
- [ ] Replace draft privacy/terms with university-approved policies and document support, refunds, retention, and incident contact.
- [ ] Rotate any credential that has appeared in a chat, screenshot, or repository before production.

