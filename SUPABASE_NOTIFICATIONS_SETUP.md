# Student notifications: Supabase and Firebase setup

Supabase stores each student's private notification history. The student portal reads only notifications allowed by Supabase Auth and row-level security, supports mark-as-read and live Realtime updates, and can register an opt-in browser for Firebase Cloud Messaging.

Follow `BACKEND_SETUP.md` for the full provider setup. In short:

1. Apply all migrations in `supabase/migrations/` in order. The notification table and RLS start in `202611160001_notifications.sql`; later migrations add server-created notices and FCM token management.
2. Fill only the Supabase project URL and publishable key in `supabase-config.js`.
3. Configure Firebase web app settings and the VAPID public key in `firebase-config.js`; keep service-account JSON in Supabase function secrets.
4. Deploy `firebase-push` and configure the Supabase Database Webhook on `public.notifications` inserts with the `x-webhook-secret` header.
5. Serve the website over HTTPS from the domain used in Firebase, Supabase Auth, and `APP_ORIGIN`. Students must sign in and grant browser notification permission.

The database webhook is needed for pushes while the website is closed. Realtime provides live updates while a portal is open. Neither notifications nor FCM tokens can be forged for another student through the student UI.

## Current limits

The Supabase and Firebase web settings are now filled locally, but the database migrations, Edge Functions, Firebase server credentials, and notification webhook still need deployment. Email/push delivery and Realtime behavior need end-to-end verification. Firebase Web Messaging requires HTTPS and a service worker; local `file://` opening is not sufficient.
