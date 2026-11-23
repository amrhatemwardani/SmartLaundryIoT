-- Enhance get_my_access() to return student's full name and dorm_class even when pending approval.
-- This allows the login UI to display clear student details and dorm-specific supervisor contact guidance.

create or replace function public.get_my_access()
returns jsonb language plpgsql stable security definer set search_path=public
as $$
declare p public.student_profiles%rowtype; r text; scoped text; confirmed timestamptz;
begin
 select email_confirmed_at into confirmed from auth.users where id=auth.uid();
 if confirmed is null then return jsonb_build_object('allowed',false,'reason','email_unverified'); end if;
 select * into p from public.student_profiles where user_id=auth.uid();
 select role,dorm_class into r,scoped from public.role_assignments where user_id=auth.uid() and active order by case role when 'admin' then 1 when 'supervisor' then 2 else 3 end limit 1;
 if r is null then return jsonb_build_object('allowed',false,'reason','no_active_role'); end if;
 if r='student' and (p.user_id is null or p.approval_status<>'approved' or p.approved_at is null) then
   return jsonb_build_object(
     'allowed', false,
     'reason', coalesce(p.approval_status,'profile_missing'),
     'role', 'student',
     'dormClass', coalesce(p.dorm_class, 'A'),
     'name', coalesce(p.full_name, '')
   );
 end if;
 return jsonb_build_object('allowed',true,'role',r,'dormClass',scoped,'name',coalesce(p.full_name,''),'email',(select email from auth.users where id=auth.uid()));
end $$;
revoke all on function public.get_my_access() from public,anon;
grant execute on function public.get_my_access() to authenticated;
