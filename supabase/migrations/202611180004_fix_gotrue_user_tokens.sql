-- Migration: Fix GoTrue "Database error querying schema" by ensuring all string token columns
--             in auth.users are non-null empty strings ('') instead of NULL, matching GoTrue's sql.Scan contract.
-- File: supabase/migrations/202611180004_fix_gotrue_user_tokens.sql

-- 1. Patch auth.users tokens for all accounts so GoTrue can scan without "converting NULL to string" error
update auth.users
set 
  confirmation_token          = coalesce(confirmation_token, ''),
  recovery_token              = coalesce(recovery_token, ''),
  email_change_token_new      = coalesce(email_change_token_new, ''),
  email_change_token_current  = coalesce(email_change_token_current, ''),
  email_change                = coalesce(email_change, ''),
  phone_change                = coalesce(phone_change, ''),
  phone_change_token          = coalesce(phone_change_token, ''),
  reauthentication_token      = coalesce(reauthentication_token, ''),
  email_change_confirm_status = coalesce(email_change_confirm_status, 0),
  is_anonymous                = coalesce(is_anonymous, false),
  is_sso_user                 = coalesce(is_sso_user, false),
  email_confirmed_at          = coalesce(email_confirmed_at, now());

-- 2. Update auth.identities so identity_data includes standard GoTrue fields (email, sub, email_verified)
-- Note: auth.identities.email is a generated column from identity_data->>'email'
update auth.identities i
set 
  identity_data = coalesce(i.identity_data, '{}'::jsonb)
    || jsonb_build_object(
      'sub', u.id::text,
      'email', u.email,
      'email_verified', true,
      'phone_verified', false
    )
from auth.users u
where i.user_id = u.id;
