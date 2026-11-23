# Zewail City Dorm Laundry — roles and responsibilities

## Recommended role split

| Role | Main purpose | Can do | Must not do |
|---|---|---|---|
| Student | Use laundry service | Manage own profile, buy/cancel own tickets under policy, pay, view own wallet/history, submit support request, review own activity | See other students' personal data, change prices, mark machines out of order, approve accounts, open doors without a valid paid ticket |
| Dorm supervisor | Operate assigned dorm laundry | Review verified student applications, approve/decline with a reason, see assigned-room bookings and device status, mark washer out of order, resolve support requests, perform logged access override if authorized | Change global payment secrets, assign main-admin role, erase audit logs, see passwords/card data, override emergency egress |
| Main admin | Own platform configuration | Invite/disable supervisors, assign room scope, set ticket price and rules, manage machine/room inventory, view global financial reconciliation and audit history | Directly assert a payment was received from the browser, view passwords/card numbers, delete/alter audit entries |

## Registration approval path

`Student submits details → university email confirmation link used → account waits for dorm supervisor → supervisor approves or declines with a reason → approved student may sign in and book`

Public student registration never offers admin/supervisor role assignment. Staff accounts are invitation-only. The server/database must enforce the role and room scope; hiding buttons in the browser is not access control.

## Audit record fields

For login/logout, account decisions, profile changes, price changes, machine status, support handling, wallet top-up, payment, refund, ticket changes, QR scans, door override, and device events, store: actor user ID and role, timestamp, action, target record, outcome, reason, and safe before/after values. Never write passwords, OTPs, access tokens, or full payment data to logs.

## First release visual responsibilities

- Student portal: upcoming ticket, washer/time picker, checkout path, ticket history, wallet, support, profile, and personal activity log.
- Supervisor portal: pending student approvals, assigned-room bookings, washer state, device health, access events, support queue, and supervisor activity log.
- Main admin portal: staff and room configuration, ticket price/rules, payment reconciliation, service-level overview, and global audit log.

## Backend status

The project now contains Supabase Auth, RLS, role-scoped database functions, approval and staff workflows, wallet/payment records, notifications, support, audit, and IoT endpoints. These source files are not active until a Supabase project is configured and migrations/functions are deployed. See `BACKEND_SETUP.md`; do not treat front-end visibility or an unconnected local page as server authorization.

