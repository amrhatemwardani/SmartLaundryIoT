# ZC Dorm Laundry backend setup

This guide prepares the backend for your own testing. The public Supabase and Firebase web settings you supplied are saved in local client configuration. The database, Edge Functions, SMTP, Firebase server credentials, Paymob, and hosting are not deployed yet. Never paste private credentials into chat or commit them to this repository.

## 1. Create a Supabase project

1. Create a Supabase project and save the database password securely.
2. In Supabase project settings, copy the **Project URL** and **publishable key** into `supabase-config.js`. These two browser values are public. Never put the service-role/secret key in this file.
3. Link this project folder to the Supabase project with the Supabase CLI (`supabase login`, then `supabase link --project-ref <project-ref>`), and apply the migrations with `supabase db push`. The order is `202611160001_notifications.sql`, `202611160003_payments.sql`, `202611160004_complete_backend.sql`, then `202611170001_egyptian_phone_validation.sql`.
4. In Auth settings, enable email signups and email confirmations. Set the password minimum to 12 characters and require uppercase, lowercase, a number, and a symbol. Set sensible email-send and login rate limits. The local CLI config sets a 30-minute inactivity timeout and a 12-hour session timebox; set the same limits in hosted Auth session settings.
5. Copy the confirmation template from `supabase/templates/confirmation.html` into the hosted project's **Authentication → Email Templates → Confirm signup** template. The signup screen uses the `{{ .ConfirmationURL }}` link, not a code.
6. For local Live Server testing, set Site URL to `http://127.0.0.1:5500` and add `http://127.0.0.1:5500/**` plus `http://localhost:5500/**` to Redirect URLs. When deployed, change Site URL to your real HTTPS origin and allow only the exact `login.html` and `reset-password.html` routes on that domain.
7. Configure custom SMTP before testing with general student accounts. Supabase's default email sender is restricted and is not intended for production delivery. For Brevo, use the SMTP host `smtp-relay.brevo.com`, port `587`, the SMTP login shown in Brevo, and an SMTP key as the password. Set the sender email to an address verified in Brevo; the Brevo campaign API example is unrelated to Supabase Auth SMTP.
8. If Brevo blocks the connection with `525 5.7.1 Unauthorized IP address`, inspect Brevo's Authorized IP alert/log and authorize only the observed SMTP client IP if it is stable and recognized. Supabase Auth sends from Supabase infrastructure, not the student's browser or your laptop, so your personal IP is not the right entry. Do not guess or broadly whitelist address ranges. Brevo documents that SMTP clients must be authorized when unknown-IP blocking is enabled.

For the first staging test, keep Supabase's email limit at 30/hour and the per-user resend interval at 60 seconds. Custom SMTP makes the project email rate configurable, but raising it does not raise Brevo's own account quota. Keep the sign-up/sign-in and token-verification limits enabled; they protect shared campus IPs from abuse. Leave IP address forwarding disabled for this browser-only client because it is intended for trusted server requests using a secret API key.
9. Create your first administrator only after signing up and verifying the project-owner's Zewail City account. In the Supabase SQL editor, substitute that verified email in this one-time block:

```sql
do $$
declare target_user uuid;
begin
  select id into target_user
  from auth.users
  where lower(email) = lower('your-admin@zewailcity.edu.eg')
    and email_confirmed_at is not null;

  if target_user is null then
    raise exception 'Create and verify the administrator account first';
  end if;

  if not exists (
    select 1 from public.role_assignments
    where user_id = target_user and role = 'admin' and active
  ) then
    insert into public.role_assignments(user_id, role, active)
    values(target_user, 'admin', true);
  end if;
end $$;
```

Keep this SQL editor access limited to trusted project owners. There is no public administrator signup.

## 2. Deploy Supabase Edge Functions

Deploy each function in `supabase/functions/` with `supabase functions deploy <function-name>`: `create-paymob-intention`, `paymob-webhook`, `payment-status`, `wallet-summary`, `invite-staff`, `firebase-push`, `door-scan`, and `iot-event`.

Set the server-side function secrets in the Supabase project secret manager. Use fresh, rotated Paymob credentials and never store real values in `.env.example`, website JavaScript, or source control:

- `APP_ORIGIN` — the website's exact HTTPS origin, with no trailing slash.
- `PAYMOB_SECRET_KEY`, `PAYMOB_PUBLIC_KEY`, `PAYMOB_HMAC_SECRET`.
- `PAYMOB_CARD_INTEGRATION_ID` and `PAYMOB_WALLET_INTEGRATION_ID` — verify the IDs in the same Paymob test account and environment as the secret key.
- `FIREBASE_PROJECT_ID`, `FIREBASE_SERVICE_ACCOUNT_JSON`, `FIREBASE_WEBHOOK_SECRET`.
- Supabase runtime values `SUPABASE_URL`, `SUPABASE_ANON_KEY`, and `SUPABASE_SERVICE_ROLE_KEY`. The service-role key is server-only.

The Paymob values previously pasted into the project conversation must be considered exposed and rotated before use, even though they were test credentials. Keep Paymob in test mode for initial end-to-end testing.

## 3. Configure Paymob test checkout

The payment code creates a Paymob Intention on the server, then sends the student to Unified Checkout. It does not use the old iframe URL. The intention request sets a transaction-processed callback to:

`https://<project-ref>.supabase.co/functions/v1/paymob-webhook`

and sends the student back to `/payment-result.html`. Confirm Paymob accepts these URLs and that both payment integrations match the configured test secret key. The webhook checks HMAC and reconciles transaction reference, order, amount, currency, integration, and duplicate transaction handling before updating the database.

The configured card and wallet IDs were both supplied as `6062237`; verify each in the Paymob dashboard before testing. If Paymob assigns different IDs, update only the function secrets.

## 4. Configure Firebase push notifications

1. Create a Firebase project and register a web app.
2. Put the Firebase **web app config** and **VAPID public key** in `firebase-config.js`. These are public browser values.
3. Enable Firebase Cloud Messaging and create a service account with permission to send FCM messages. Store the full service-account JSON only in `FIREBASE_SERVICE_ACCOUNT_JSON` in Supabase secrets.
4. Generate a long random value for `FIREBASE_WEBHOOK_SECRET` and save it only in Supabase secrets and the webhook configuration.
5. In Supabase Database Webhooks, create an `INSERT` webhook for `public.notifications` targeting `https://<project-ref>.supabase.co/functions/v1/firebase-push`. Send the webhook secret as the `x-webhook-secret` request header.
6. Serve `firebase-messaging-sw.js` from the website root over HTTPS. A student must sign in and opt in to browser notifications; in-app notifications continue to use Supabase.

The webhook is what delivers a push while the website tab is closed. The in-page Firebase call alone is not enough for that case.

## 5. Prepare machines, supervisors, and devices

1. Sign in as the main administrator, open **People & access**, and invite a supervisor using a verified Zewail City email and dorm assignment.
2. The supervisor creates machines and publishes slots for their dorm. Set a test ticket price in **Pricing & wallet**.
3. Create a test student account, click the email confirmation link, and approve the account from the supervisor approval queue.
4. For IoT staging, provision a device from **System & audit**. Copy its generated key once into the controller's protected storage. The controller calls `/functions/v1/door-scan` with its key and a QR token, or `/functions/v1/iot-event` to report machine state. Do not put the Supabase service-role key on an IoT device.
5. Keep the door's emergency egress and manual operation independent of the website, cloud, and Wi-Fi.

## 6. Before inviting real students

- Use HTTPS and set Supabase Auth's Site URL/redirect allowlist and allowed origins to the deployed website.
- Configure production SMTP and a domain you control. Keep confirmation-email, login, resend, and recovery limits enabled.
- Confirm the university has approved the final privacy notice, terms, data retention period, support contact, and payment/cancellation rules. Current notices in the signup screen are marked as project drafts.
- Review Supabase RLS, backups, database recovery, function logs, payment reconciliation, alerts, and operational ownership. Audit events capture the IP and user agent from Supabase request headers; approximate location is country-code level only when the gateway provides it. Some server-originated events, including payment callbacks, may not have an end-user IP.
- Run the manual scenarios in `TESTING_CHECKLIST.md` in a separate staging project with test Paymob credentials and simulated IoT devices. Do not connect real door hardware or collect real student funds until those checks and an independent security review are complete.

## Important limits

This repository contains application code and setup instructions only. It does not create provider accounts, apply migrations to your cloud, deliver email, send Firebase pushes, process live transactions, or control a physical door until those external steps are completed. The project has not yet been deployed or verified against your accounts.

