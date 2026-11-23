-- Migration: Grant execute permissions to all roles including supabase_read_only_user
-- File: supabase/migrations/202611170009_grant_execute_to_public.sql

grant execute on function public.get_my_access(text) to authenticated, service_role, anon, supabase_read_only_user;
grant execute on function public.admin_dashboard_metrics() to authenticated, service_role, anon, supabase_read_only_user;
grant execute on function public.supervisor_dashboard_metrics(text) to authenticated, service_role, anon, supabase_read_only_user;
grant execute on function public.staff_pending_applications() to authenticated, service_role, anon, supabase_read_only_user;
grant execute on function public.review_student_application(uuid,text,text) to authenticated, service_role, anon, supabase_read_only_user;
grant execute on function public.admin_list_staff() to authenticated, service_role, anon, supabase_read_only_user;
grant execute on function public.admin_assign_staff(text,text,text) to authenticated, service_role, anon, supabase_read_only_user;
grant execute on function public.admin_disable_staff(uuid,text,text) to authenticated, service_role, anon, supabase_read_only_user;
grant execute on function public.staff_list_bookings(timestamptz,timestamptz) to authenticated, service_role, anon, supabase_read_only_user;
grant execute on function public.staff_set_ticket_status(uuid,text,text) to authenticated, service_role, anon, supabase_read_only_user;
grant execute on function public.staff_set_machine_status(text,text,text) to authenticated, service_role, anon, supabase_read_only_user;
grant execute on function public.staff_publish_slot_batch(jsonb) to authenticated, service_role, anon, supabase_read_only_user;
grant execute on function public.staff_list_support_tickets(text) to authenticated, service_role, anon, supabase_read_only_user;
grant execute on function public.staff_update_support_ticket(uuid,text,text) to authenticated, service_role, anon, supabase_read_only_user;
grant execute on function public.admin_finance_summary() to authenticated, service_role, anon, supabase_read_only_user;
grant execute on function public.admin_recent_audit(integer) to authenticated, service_role, anon, supabase_read_only_user;
