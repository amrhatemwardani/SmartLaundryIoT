import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
const cors=(origin:string)=>({"Access-Control-Allow-Origin":origin||Deno.env.get("APP_ORIGIN")||"*","Access-Control-Allow-Headers":"authorization, apikey, content-type, x-client-info, x-webhook-secret","Access-Control-Allow-Methods":"POST, OPTIONS","Cache-Control":"no-store","Vary":"Origin"});
const response=(body:unknown,status=200,origin="")=>Response.json(body,{status,headers:cors(origin)});
function b64url(bytes:Uint8Array){let binary="";for(const byte of bytes)binary+=String.fromCharCode(byte);return btoa(binary).replace(/=/g,"").replace(/\+/g,"-").replace(/\//g,"_")}
function utf8b64url(value:string){return b64url(new TextEncoder().encode(value))}
function sameSecret(a:string,b:string){if(!a||a.length!==b.length)return false;let diff=0;for(let i=0;i<a.length;i++)diff|=a.charCodeAt(i)^b.charCodeAt(i);return diff===0}
async function googleAccessToken(account:Record<string,string>){
 const now=Math.floor(Date.now()/1000),header=utf8b64url(JSON.stringify({alg:"RS256",typ:"JWT"}));
 const claim=utf8b64url(JSON.stringify({iss:account.client_email,scope:"https://www.googleapis.com/auth/firebase.messaging",aud:account.token_uri||"https://oauth2.googleapis.com/token",iat:now,exp:now+3600}));
 const unsigned=header+"."+claim;const pem=account.private_key.replace(/-----BEGIN PRIVATE KEY-----|-----END PRIVATE KEY-----|\s/g,"");
 const der=Uint8Array.from(atob(pem),c=>c.charCodeAt(0));const key=await crypto.subtle.importKey("pkcs8",der,{name:"RSASSA-PKCS1-v1_5",hash:"SHA-256"},false,["sign"]);
 const sig=await crypto.subtle.sign("RSASSA-PKCS1-v1_5",key,new TextEncoder().encode(unsigned));const assertion=unsigned+"."+b64url(new Uint8Array(sig));
 const form=new URLSearchParams({grant_type:"urn:ietf:params:oauth:grant-type:jwt-bearer",assertion});const oauth=await fetch(account.token_uri||"https://oauth2.googleapis.com/token",{method:"POST",headers:{"Content-Type":"application/x-www-form-urlencoded"},body:form});
 const data=await oauth.json();if(!oauth.ok||!data.access_token)throw new Error("Google service authentication failed");return String(data.access_token);
}
Deno.serve(async req=>{
 const origin=req.headers.get("origin")||"";if(req.method==="OPTIONS")return new Response("ok",{headers:cors(origin)});if(req.method!=="POST")return response({error:"Method not allowed"},405,origin);
 const url=Deno.env.get("SUPABASE_URL"),anon=Deno.env.get("SUPABASE_ANON_KEY"),serviceKey=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY"),firebaseProject=Deno.env.get("FIREBASE_PROJECT_ID"),serviceAccountRaw=Deno.env.get("FIREBASE_SERVICE_ACCOUNT_JSON");
 if(!url||!anon||!serviceKey||!firebaseProject||!serviceAccountRaw)return response({error:"Push service is not configured"},503,origin);
 let body:Record<string,unknown>;try{body=await req.json()}catch{return response({error:"Invalid request"},400,origin)}
 const webhookSecret=Deno.env.get("FIREBASE_WEBHOOK_SECRET")||"",presented=req.headers.get("x-webhook-secret")||"",fromWebhook=sameSecret(presented,webhookSecret);
 let userId:string|null=null;
 if(fromWebhook&&body.type==="INSERT"&&body.table==="notifications"&&body.schema==="public"){const record=body.record as Record<string,unknown>|undefined;userId=typeof record?.user_id==="string"?record.user_id:null}
 else{const bearer=(req.headers.get("authorization")||"").match(/^Bearer\s+(.+)$/i)?.[1];if(!bearer)return response({error:"Notification webhook or signed-in user required"},401,origin);const auth=createClient(url,anon,{auth:{persistSession:false,autoRefreshToken:false}});const {data:{user},error:authError}=await auth.auth.getUser(bearer);if(authError||!user)return response({error:"Sign in required"},401,origin);userId=user.id}
 const rawId=typeof body.notificationId==="string"?body.notificationId:(body.record as Record<string,unknown>|undefined)?.id;const notificationId=typeof rawId==="string"&&/^[0-9a-f-]{36}$/i.test(rawId)?rawId:null;if(!notificationId||!userId)return response({error:"Notification reference required"},400,origin);
 const service=createClient(url,serviceKey,{auth:{persistSession:false,autoRefreshToken:false}});const {data:claim,error:claimError}=await service.rpc("claim_notification_push",{p_notification_id:notificationId,p_user_id:userId});
 if(claimError){console.error("FCM notification claim failed:",claimError.message);return response({error:"Notification unavailable"},503,origin)}if(!claim)return response({sent:0},200,origin);
 const tokens=Array.isArray(claim.tokens)?claim.tokens.filter((token):token is string=>typeof token==="string"&&token.length>0):[];if(!tokens.length){await service.rpc("finish_notification_push",{p_notification_id:notificationId,p_user_id:userId,p_sent:false});return response({sent:0},200,origin)}
 let account:Record<string,string>;try{account=JSON.parse(serviceAccountRaw)}catch{return response({error:"Firebase server credentials are invalid"},503,origin)}
 try{
  const access=await googleAccessToken(account);let sent=0;const expired:string[]=[];
  await Promise.all(tokens.map(async token=>{
   const result=await fetch(`https://fcm.googleapis.com/v1/projects/${encodeURIComponent(firebaseProject)}/messages:send`,{method:"POST",headers:{Authorization:`Bearer ${access}`,"Content-Type":"application/json"},body:JSON.stringify({message:{token,notification:{title:String(claim.title).slice(0,140),body:String(claim.body).slice(0,1000)},webpush:{fcm_options:{link:(origin||Deno.env.get("APP_ORIGIN")||"")+"/student.html"}}}})});
   if(result.ok){sent++;return}const issue=await result.json().catch(()=>({}));const errorName=issue?.error?.details?.find((item:Record<string,string>)=>item.errorCode)?.errorCode;if(result.status===404||errorName==="UNREGISTERED")expired.push(token);else console.warn("FCM delivery failed:",result.status,errorName||"delivery_error");
  }));
  if(expired.length)await service.from("fcm_tokens").delete().in("token",expired);
  await service.rpc("finish_notification_push",{p_notification_id:notificationId,p_user_id:userId,p_sent:sent>0});
  return response({sent},200,origin);
 }catch(error){await service.rpc("finish_notification_push",{p_notification_id:notificationId,p_user_id:userId,p_sent:false});console.error("Firebase notification delivery failed:",error instanceof Error?error.message:"unknown");return response({error:"Push delivery is temporarily unavailable"},502,origin)}
});
