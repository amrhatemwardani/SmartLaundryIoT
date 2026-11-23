# Paymob test payment setup

The web app is prepared for Paymob's Intention API and Unified Checkout, with the Intention request initiated by the Supabase Edge Function. The customer redirect is not treated as proof of payment; only the HMAC-verified processed callback can confirm the ticket or credit a wallet.

Follow the full provider setup in `BACKEND_SETUP.md`, especially the Paymob and Supabase secret configuration steps.

## Credentials and integration IDs

The Paymob credentials previously pasted into the project conversation are considered exposed. Revoke and rotate them before use. This project contains none of those secret values. Keep fresh test credentials in the Supabase function secret manager only. The separate HMAC secret is required for callback verification.

The supplied card and wallet integration IDs are both recorded as `6062237` in `.env.example` for reference. Confirm both IDs in the same test account/environment as the new secret key; change the function secrets if Paymob uses different IDs. The supplied legacy iframe ID is not used in Unified Checkout.

## Callback and checkout behavior

- The Edge Function sends `notification_url` to `/functions/v1/paymob-webhook` and `redirection_url` to `/payment-result.html?reference=…` when it creates each Intention.
- Paymob's transaction-processed callback is verified against the HMAC secret, configured integration IDs, transaction ID, server-stored amount, currency, order ID, and merchant reference.
- Payment result page polls the authenticated status function. It cannot mark an attempt paid based on URL query parameters.
- A unique payment attempt and ledger constraints prevent repeated callbacks from crediting twice. Ticket slots are reserved transactionally before checkout.
- Wallet top-ups accept EGP 10–5,000. Prices and balances come from the database, never from browser-submitted totals.

## Still required

No provider project has been linked or deployed from this workspace. Configure Supabase, rotate Paymob credentials, set function secrets, deploy functions, and complete test-mode checkout scenarios before considering payment active. Use `BACKEND_SETUP.md` and `TESTING_CHECKLIST.md` as the setup path.
