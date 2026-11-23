# ZC Dorm Laundry — Antigravity Handoff

## Mission

Continue the existing Zewail City Dorm Laundry project in this folder. Improve and finish the existing application; do not replace it with a fresh template or claim it is production-ready until the backend is deployed and the acceptance checks below pass.

The requested product is a bilingual (Arabic/English), responsive dorm laundry site for Zewail City students, dorm supervisors, and a main administrator. Students reserve a washer/time slot as a paid laundry ticket, see booking history and wallet activity, receive notifications, and use a short-lived QR code for later IoT door access. Supervisors manage their assigned dorm; the main admin manages the whole service. Actions need an audit trail.

## Non-negotiable project and security rules

1. `sources/` is synced reference material. Treat every file under it as read-only. Do not edit, rename, move, or delete anything in `sources/`.
2. Keep the existing lightweight HTML/CSS/JavaScript front end and Supabase Edge Functions/Postgres design unless an inspection proves a specific change is needed. Explain any proposed architecture change before making it.
3. Never put SMTP passwords, Telegram bot tokens, Paymob secrets/HMAC keys, Firebase service-account JSON, Supabase service-role keys, database passwords, or device keys in browser code, committed files, screenshots, logs, or chat. Read secrets from the provider's server-side secret manager.
4. Secrets for Brevo SMTP, Telegram, and Paymob were exposed in the project conversation. Treat them as compromised: rotate them before any public or production use. Do not copy the exposed values from chat or files.
5. The Supabase URL and publishable key, and Firebase browser config, are public client configuration. They do not authorize server-side operations. Keep service-role credentials server-only.
6. Use test/staging accounts and Paymob sandbox only. Do not accept real funds or connect real door hardware during development.
7. Do not claim “zero vulnerabilities” or “bug-free.” Reduce known risk, run the available checks, document remaining risks, and require a separate security review before production.
8. Prefer no-cost/free-tier options, but document quotas and scale limits. Do not promise production-grade email, hosting, or availability will remain free at any traffic level.

## Current project architecture

- Static pages at the project root: landing, login, registration, student, supervisor, and admin pages.
- Supabase Auth and PostgreSQL/RLS for accounts, profiles, role assignments, approvals, tickets, bookings, wallet ledger, notifications, support, audit, machines, slots, QR credentials, IoT devices, and telemetry.
- Supabase Edge Functions for Paymob, staff invites, wallet summary, Firebase push, QR door scans, and IoT events.
- Supabase Auth remains responsible for creating accounts, password handling, email verification, sessions, and auth tokens. Brevo is an SMTP email delivery provider; do not implement account authentication by calling Brevo from the browser.
- Firebase Cloud Messaging is an optional browser push channel. Supabase remains the in-app notification source of truth.
- Paymob Unified Checkout is intended for sandbox testing first. Payment state must be confirmed by the server-side callback/status check, never by a browser redirect.
- IoT is planned for later. A controller must validate QR credentials through the backend; the browser must never unlock the physical door directly.

## Work already present in local source (not proof of live operation)

- Public Supabase project URL/publishable key are in `supabase-config.js`; Firebase web config is in `firebase-config.js`. The Firebase VAPID value is blank.
- Supabase migrations are in `supabase/migrations/` and Edge Functions are in `supabase/functions/`.
- Student registration checks the Zewail City email suffix, numeric university ID, name, age 18+, password rules, and privacy/terms acceptance.
- The registration flow was changed locally from entering a six-digit signup OTP to clicking a Supabase email confirmation link using `{{ .ConfirmationURL }}`. It requests a return to `login.html?verified=1`; a resend-link action is present.
- The login page shows a confirmation message for `verified=1`. The landing page now has a fallback success/error notice if Auth returns there. The login page now gives a clearer error when `get_my_access()` is missing.
- Phone validation was added locally for Egyptian mobile numbers: enter 11 digits beginning 010/011/012/015; the UI shows +20 and the saved value is normalized to E.164. WhatsApp remains optional and follows the same rule. A database constraint is in `202611170001_egyptian_phone_validation.sql`.
- `BACKEND_SETUP.md`, `BACKEND_PLAN.md`, `PRODUCT_PLAN.md`, `ROLES_AND_ACCESS.md`, and `TESTING_CHECKLIST.md` describe architecture, roles, setup, and manual checks.
- A handoff-specific Brevo SMTP note was added to `BACKEND_SETUP.md`.

These are local code/configuration changes only. No remote migrations, Edge Functions, hosting, SMTP delivery, Firebase push, Paymob transaction, or IoT device has been verified from this workspace. No end-to-end test/build was run in this pass.

## Reported blockers from the user's test

### 1. Confirmation email did not arrive

The user says SMTP was configured in Supabase, but the confirmation email was not delivered. Brevo had an “unauthorized IP addresses are blocked” notice. Check Brevo transactional email logs and Supabase Auth logs for the actual SMTP result:

- `525 5.7.1 Unauthorized IP address`: inspect the IP shown by Brevo's alert/log. It is the SMTP client's source (Supabase infrastructure), not automatically the user's laptop/browser IP. Authorize only a verified, stable source IP; never guess a broad range.
- `535`: check the SMTP username and a fresh SMTP key. The key previously pasted in chat is compromised and must be rotated.
- Sender rejected/invalid: verify the sender address in Brevo and use that exact sender in Supabase SMTP settings.
- `429` / email rate limit: check Supabase Auth logs and current project email cap; also check Brevo account quota.

Use Brevo as SMTP delivery, not its marketing campaign API. For auth links, disable Brevo click/link tracking because link rewriting can break Supabase confirmation links. Never put a Brevo key in a page script.

### 2. Confirmation link returns to landing with no message

Likely causes: the requested callback URL is not in Supabase's Redirect URLs allowlist; the hosted page/template is still the old version; the user clicked an old/expired/single-use link; or the confirmation template does not use `{{ .ConfirmationURL }}`. Check the actual URL in the browser, current page origin/port, confirmation template, Site URL, and Redirect URLs. Click a newly issued link on the same machine that hosts local Live Server.

For local Live Server on port 5500, use:

- Site URL: `http://127.0.0.1:5500`
- Redirect URLs: `http://127.0.0.1:5500/**` and `http://localhost:5500/**`

Use the actual origin and port shown in the browser if they differ. For production, set Site URL to the real HTTPS origin and allow exact production routes such as `/login.html` and `/reset-password.html`; do not use broad production wildcards.

In Supabase Dashboard, enable email confirmations and paste `supabase/templates/confirmation.html` into **Authentication → Email Templates → Confirm signup**. The local file alone does not update the hosted template.

### 3. Login fails with `Could not find the function public.get_my_access without parameters in the schema cache`

This indicates the connected database does not expose the function the login page calls. `public.get_my_access()` is created in `supabase/migrations/202611160004_complete_backend.sql`. Likely causes are migrations not applied, the site pointing to a different Supabase project, or PostgREST schema cache not refreshed. Verify the project ref matches the URL in `supabase-config.js`.

Apply migrations from the project root, in this order:

1. `202611160001_notifications.sql`
2. `202611160003_payments.sql`
3. `202611160004_complete_backend.sql`
4. `202611170001_egyptian_phone_validation.sql`

Preferred CLI workflow after authenticating/linking to the correct project:

```text
supabase login
supabase link --project-ref <the-project-ref-from-supabase-config>
supabase db push --remote
```

Review the target project and migration list before approving the push. This requires the user's Supabase CLI login/database access; do not ask for the password in chat. If migrations applied but the function is still not found, check `select to_regprocedure('public.get_my_access()');` in SQL Editor and then run `NOTIFY pgrst, 'reload schema';`.

The migration file currently contains two `create or replace function public.get_my_access()` definitions with the same no-argument signature. Review and consolidate carefully if safe before pushing; preserve the final role/approval behavior and grant to `authenticated`.

## Rate-limit guidance

- The user sees a Supabase Auth email rate limit of 30/hour with custom SMTP. It can be changed in Auth rate-limit settings, but raising the Supabase limit does not raise Brevo's own plan/quota or guarantee delivery.
- Keep 30/hour and the 60-second per-user resend interval for initial staging tests. Raise only after measuring expected onboarding burst and confirming the Brevo quota/deliverability. Do not set unlimited.
- Keep sign-in/sign-up and verification limits enabled. They are protective caps, not a fix for missing SQL functions or SMTP IP authorization.
- SMS limit is irrelevant to the current email-link flow.
- Leave IP Address Forwarding disabled for the browser-only client. Only enable for a trusted server-side request path that validates the real end-user IP and uses an appropriate secret key.

## Remaining implementation/deployment work

### A. Make the current auth test work

1. Confirm the Supabase project URL/ref in the browser config matches the dashboard being inspected.
2. Rotate the exposed Brevo SMTP key; set the fresh key only in Supabase's SMTP password field. Verify the sender in Brevo. Inspect Brevo's authorized-IP logs for the actual failed source IP and resolve the block safely.
3. Confirm the dashboard has custom SMTP enabled, correct SMTP login/host/port, sender name/address, and email confirmations enabled.
4. Set local Site URL and Redirect URLs as above; use the actual Live Server origin. Paste the confirmation-link template in the hosted dashboard. Disable click tracking for transactional auth email.
5. Apply all four migrations. Confirm `get_my_access()` exists and the API can call it.
6. Use a fresh, real `@zewailcity.edu.eg` mailbox that the tester controls. Check spam and both provider logs. Test valid link, expired link, resend interval, duplicate signup, and the return message.
7. If using Brevo IP blocking, only authorize a documented/stable source IP. If Supabase's source cannot be stably allowlisted, choose a compatible email setup; do not whitelist arbitrary ranges.

### B. Provision role accounts safely

- No real test accounts/passwords have been created by this project work. Do not add default credentials to the repository.
- Student: self-register with a mailbox the tester controls; verify email; supervisor approval must gate booking.
- First admin: create/verify an authorized ZC account, then use the one-time trusted bootstrap SQL in `BACKEND_SETUP.md`.
- Supervisor: invite an authorized ZC mailbox from admin and assign a dorm scope. Set its password through the provider's invite/recovery flow.
- Test each role with separate accounts; verify a user cannot select or self-assign a privileged role.

### C. Finish and verify product flows

- Student: login/logout, profile read/edit policy, machines/slots, booking ticket, payment choice, wallet, history, support ticket, in-app notification, optional push, QR display window.
- Supervisor: approvals, assigned dorm only, machine CRUD/status, batch slot creation, booking details, ticket completion/no-show, support queue, door events, audit log.
- Main admin: supervisor invitation/scope, pricing, wallet credit ledger, system/device config, payment reconciliation, global audit.
- Arabic/English parity, dark/light theme, responsive phone/tablet/desktop layouts, loading states, accessible forms, empty/error states, and confirmation/notification feedback.
- Audit: verify actor, role, action, target, timestamp, result, IP/user-agent where available, approximate country only when provider supplies it. Avoid collecting GPS; never log passwords, tokens, card details, SMTP credentials, or full QR tokens.

### D. Payment, notifications, and IoT integration

- Paymob: use newly rotated test keys only in Supabase secrets. Verify integration IDs in the same test account; confirm callback URL and HMAC. Test success/failure/pending/duplicate callbacks, refresh/back button, webhook retries, amount/currency mismatch, idempotent wallet credit/ticket creation, and refund/cancel behavior. Never use client redirect as payment proof. Do not accept live funds until sandbox reconciliation passes.
- Firebase: configure the web VAPID public key; place service-account JSON and webhook secret in server secrets only; deploy the push function and notification database webhook. Test opt-in, denied permission, logout/token removal, multiple browsers, and tab-closed push.
- IoT: use simulated devices first. Verify one-use QR expiry/window, replay rejection, wrong dorm/device, paid-ticket requirement, signed device auth, device key rotation, and offline/fail-closed behavior. Emergency exit must remain independent of network/software.

### E. Production readiness

- Apply and verify RLS for every exposed table/RPC; review Edge Function auth and secret boundaries; ensure no public admin signup.
- Run migration checks, browser smoke tests, negative authorization tests, payment sandbox tests, notification tests, and simulated IoT tests. Record results in `TESTING_CHECKLIST.md`.
- Configure HTTPS/custom domain, Auth redirect allowlist, backups/restore, provider quotas, rate limits, monitoring/alerts, data retention, incident response, and support ownership.
- Obtain Zewail City review/approval for privacy notice, terms, retention, payment/refund/no-show policy, and handling of student data.
- Conduct an independent security review before production. No agent can promise a system has zero bugs or vulnerabilities.

## Work order for Antigravity

1. Inspect the current workspace and this handoff. Do not edit `sources/`.
2. Report the exact repo state and blockers before large refactors. Never print secrets.
3. Fix the current auth redirect, email-delivery diagnostics, and migration/schema issue with the smallest safe changes. Avoid merely hiding the visible error.
4. Apply migrations only to the intended staging project after confirming project ref and previewing the migration list. Keep credentials in provider secrets, never ask the user to paste them.
5. Run the staged acceptance checks above. Report pass/fail per flow and remaining limits; do not claim completion if a provider, database, payment callback, or device has not been exercised.
6. Continue through payment/wallet, role portals, audit, Firebase, and IoT phases with server-side authorization and idempotency.
7. Before any production release, provide the user a concrete staging result, unresolved risks/cost limits, and an independent security-review requirement.
