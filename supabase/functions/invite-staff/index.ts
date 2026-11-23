import {createClient} from "https://esm.sh/@supabase/supabase-js@2";
const cors=(o:string)=>({"Access-Control-Allow-Origin":Deno.env.get("APP_ORIGIN")||o||"null","Access-Control-Allow-Headers":"authorization, apikey, content-type, x-client-info","Access-Control-Allow-Methods":"POST, OPTIONS","Cache-Control":"no-store","Vary":"Origin"});
const json=(v:unknown,s=200,o="")=>Response.json(v,{status:s,headers:cors(o)});
Deno.serve(async req=>{
 const origin=req.headers.get("origin")||"";if(req.method==="OPTIONS")return new Response("ok",{headers:cors(origin)});if(req.method!=="POST")return json({error:"Method not allowed"},405,origin);
 if(origin&&Deno.env.get("APP_ORIGIN")&&origin!==Deno.env.get("APP_ORIGIN"))return json({error:"Origin not allowed"},403,origin);
 const url=Deno.env.get("SUPABASE_URL"),anon=Deno.env.get("SUPABASE_ANON_KEY"),serviceKey=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");if(!url||!anon||!serviceKey)return json({error:"Staff invitation is not configured"},503,origin);
 const token=(req.headers.get("authorization")||"").match(/^Bearer\s+(.+)$/i)?.[1];if(!token)return json({error:"Sign in as an administrator"},401,origin);
 const auth=createClient(url,anon,{auth:{persistSession:false,autoRefreshToken:false},global:{headers:{Authorization:`Bearer ${token}`}}});const {data:{user},error}=await auth.auth.getUser(token);if(error||!user)return json({error:"Sign in as an administrator"},401,origin);
 const {data:access,error:accessError}=await auth.rpc("get_my_access");if(accessError||!access?.allowed||access.role!=="admin")return json({error:"Main administrator role required"},403,origin);
 let body:Record<string,unknown>;try{body=await req.json()}catch{return json({error:"Invalid request"},400,origin)}
 const email=typeof body.email==="string"?body.email.trim().toLowerCase():"",dorm=String(body.dormClass||"");if(!/^[a-z0-9._%+-]+@zewailcity\.edu\.eg$/.test(email)||!['A','B','C','D'].includes(dorm))return json({error:"Enter a Zewail City email and dorm class A–D"},400,origin);
 const service=createClient(url,serviceKey,{auth:{persistSession:false,autoRefreshToken:false}});
 try{
  const {data:invited,error:inviteError}=await service.auth.admin.inviteUserByEmail(email,{data:{staff_invite:true}});
  if(inviteError)throw inviteError;
  const target=invited.user;if(!target)throw new Error("Invite did not create an account");
  const {error:roleError}=await service.from("role_assignments").insert({user_id:target.id,role:"supervisor",dorm_class:dorm,active:true,assigned_by:user.id});if(roleError)throw roleError;
  await service.from("audit_events").insert({actor_user_id:user.id,actor_role:"admin",action:"staff_invited",entity_type:"user",entity_id:target.id,details:{email,role:"supervisor",dorm_class:dorm}});
  return json({sent:true,email,role:"supervisor",dormClass:dorm},200,origin);
 }catch(e){console.error("Staff invitation failed:",e instanceof Error?e.message:"unknown");return json({error:e instanceof Error?e.message:"Could not send invitation"},409,origin)}
});
