# Backend architecture and implementation status

## Selected architecture

- **Website:** Existing lightweight HTML/CSS/JavaScript pages. The shared Supabase browser client stores Auth sessions in `sessionStorage`, so each browser tab has its own session.
- **Identity and database:** Supabase Auth and PostgreSQL. Auth verifies email; database constraints enforce student information; `role_assignments` and RLS enforce student, dorm-scoped supervisor, and main administrator access.
- **Server operations:** Supabase Edge Functions and restricted Postgres RPCs handle payment creation, Paymob callbacks, staff invitations, wallet operations, support workflows, notifications, and IoT requests.
- **Payment:** Paymob Unified Checkout. The browser redirect never confirms a payment. A verified HMAC callback updates the attempt, ticket or wallet ledger exactly once.
- **Push:** Firebase Cloud Messaging. Supabase remains the notification database; Firebase delivers opt-in browser push notifications.
- **Door and machine devices:** Each controller has a unique key. The backend stores only its hash and validates one-time QR credentials; the browser never opens the door directly.

## Backend code present in this project

- Supabase migrations for Auth profiles, role assignments, student approvals, machines and slots, payment attempts, signed wallet ledger, support tickets, in-app notifications, audit events, QR credentials, IoT devices, and telemetry.
- Supabase Edge Functions for Paymob intention creation/callback/status, wallet summary, staff invitations, Firebase push, door QR scans, and machine telemetry.
- Frontend connections for registration and email confirmation links, sign-in and role guards, payment, student tickets and wallet, supervisor operations, admin operations, approvals, support, audit views, and push opt-in.
- Setup templates and empty public configuration files. No private credentials are stored in the repository.

## What still requires external configuration

This is backend **source code**, not a deployed service. The Supabase URL/publishable key and Firebase web settings you supplied are now in local client configuration files. Database migrations, Edge Functions, SMTP delivery, Firebase server credentials, Paymob secrets, and website hosting still need to be configured and deployed before end-to-end testing. Follow `BACKEND_SETUP.md`.

Production use also requires test-mode payment verification, real email delivery, domain and HTTPS settings, a security review, backup and recovery setup, operational alerts, and university approval of the privacy notice and service terms. The draft privacy/terms shown during signup are not final legal notices.

## Security boundaries

1. Browser values are untrusted. Roles, account approval, ticket prices, wallet balances, bookings, and payment state are decided by the server.
2. Only `@zewailcity.edu.eg` accounts can be created. Email confirmation and supervisor approval are both required for students to book.
3. Student records, tickets, wallet entries, notifications, machine data, and staff actions are protected by RLS and role/dorm checks.
4. Supabase service keys, Paymob secret/HMAC keys, Firebase service-account JSON, and device credentials stay on servers or devices. They must never be placed in browser JavaScript.
5. Payment attempts have stable idempotency references. Callback HMAC, transaction ID, amount, currency, order, and integration are checked before a ledger credit or ticket confirmation.
6. Wallets use an append-only signed ledger. Device QR tokens are short-lived and one-use. Emergency door egress must function independently of software and network access.
7. The database audit trail records application actions and captures the request IP and user agent from Supabase API headers. Where Supabase supplies a Cloudflare country header, it records only a country code as approximate location; it does not collect GPS or city-level location.

## Verification status

The code has been reviewed for integration points, but it has not been connected to real service projects, deployed, or exercised against real payment, email, push, or device callbacks. No test suite or build has been run in this pass. Complete the checklist in `BACKEND_SETUP.md` before relying on it.

