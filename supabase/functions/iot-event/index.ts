import {createClient} from "https://esm.sh/@supabase/supabase-js@2";
const headers={"Access-Control-Allow-Headers":"content-type,x-device-key","Access-Control-Allow-Methods":"POST, OPTIONS","Cache-Control":"no-store"};
Deno.serve(async req=>{
 if(req.method==="OPTIONS")return new Response("ok",{headers});if(req.method!=="POST")return Response.json({error:"Method not allowed"},{status:405,headers});
 const url=Deno.env.get("SUPABASE_URL"),key=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY"),apiKey=req.headers.get("x-device-key")||"";if(!url||!key||apiKey.length<32)return Response.json({error:"Device authorization required"},{status:401,headers});
 let body:Record<string,unknown>;try{body=await req.json()}catch{return Response.json({error:"Invalid request"},{status:400,headers})}
 const deviceKey=typeof body.deviceKey==="string"?body.deviceKey:"",machineKey=typeof body.machineKey==="string"?body.machineKey:"",state=typeof body.state==="string"?body.state:"",details=body.details&&typeof body.details==="object"?body.details:{};if(!deviceKey||!machineKey||!['idle','running','fault','offline'].includes(state))return Response.json({error:"Invalid telemetry event"},{status:400,headers});
 const service=createClient(url,key,{auth:{persistSession:false,autoRefreshToken:false}});const {data:deviceId,error}=await service.rpc("iot_authenticate_device",{p_device_key:deviceKey,p_api_key:apiKey});if(error||!deviceId)return Response.json({error:"Device unauthorized"},{status:401,headers});
 const {error:writeError}=await service.rpc("iot_report_machine_state",{p_device_id:deviceId,p_machine_key:machineKey,p_state:state,p_details:details});if(writeError){console.error("IoT event rejected:",writeError.message);return Response.json({error:"Telemetry rejected"},{status:400,headers})}
 return Response.json({accepted:true},{headers});
});
