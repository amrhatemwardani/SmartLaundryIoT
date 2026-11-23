/* Shared Supabase browser client. Public URL/key only; user session is tab-scoped. */
(function(){
  let pending;
  function loadScript(src){return new Promise((resolve,reject)=>{const s=document.createElement('script');s.src=src;s.onload=resolve;s.onerror=()=>reject(new Error('Could not load secure account service.'));document.head.appendChild(s)})}
  async function ready(){
    if(window.ZC_SUPABASE_CLIENT)return window.ZC_SUPABASE_CLIENT;
    if(pending)return pending;
    pending=(async()=>{
      if(!window.ZC_SUPABASE_CONFIG)await loadScript('supabase-config.js');
      if(!window.supabase?.createClient)await loadScript('https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2');
      const cfg=window.ZC_SUPABASE_CONFIG||{};
      if(!cfg.url||!cfg.publishableKey)throw new Error('Supabase is not configured yet. Add the project URL and publishable key.');
      window.ZC_SUPABASE_CLIENT=window.supabase.createClient(cfg.url,cfg.publishableKey,{auth:{storage:window.sessionStorage,persistSession:true,autoRefreshToken:true,detectSessionInUrl:true}});
      return window.ZC_SUPABASE_CLIENT;
    })();
    try{return await pending}catch(error){pending=null;throw error}
  }
  window.ZCSupabase={ready};
})();
