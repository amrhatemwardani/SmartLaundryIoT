import {createClient} from "https://esm.sh/@supabase/supabase-js@2";
const cors={"Access-Control-Allow-Headers":"content-type,x-device-key","Access-Control-Allow-Methods":"POST, OPTIONS","Cache-Control":"no-store"};
Deno.serve(async req=>{
 if(req.method==="OPTIONS")return new Response("ok",{headers:cors});if(req.method!=="POST")return Response.json({error:"Method not allowed"},{status:405,headers:cors});
 const url=Deno.env.get("SUPABASE_URL"),serviceKey=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY"),apiKey=req.headers.get("x-device-key")||"";if(!url||!serviceKey||apiKey.length<32)return Response.json({error:"Device authorization required"},{status:401,headers:cors});
 let body:Record<string,unknown>;try{body=await req.json()}catch{return Response.json({error:"Invalid request"},{status:400,headers:cors})}
 const deviceKey=typeof body.deviceKey==="string"?body.deviceKey:"",qrToken=typeof body.qrToken==="string"?body.qrToken:"";if(!deviceKey||!/^[a-f0-9]{64}$/i.test(qrToken))return Response.json({error:"Invalid scan request"},{status:400,headers:cors});
 const service=createClient(url,serviceKey,{auth:{persistSession:false,autoRefreshToken:false}});const {data:deviceId,error:authError}=await service.rpc("iot_authenticate_device",{p_device_key:deviceKey,p_api_key:apiKey});if(authError||!deviceId)return Response.json({granted:false,reason:"device_unauthorized"},{status:401,headers:cors});
 const {data,error:resultError}=await service.rpc("iot_consume_door_qr",{p_device_id:deviceId,p_token:qrToken});if(resultError){console.error("Door scan failed:",resultError.message);return Response.json({granted:false,reason:"validation_unavailable"},{status:503,headers:cors})}
 return Response.json(data||{granted:false,reason:"validation_unavailable"},{headers:cors});
});
