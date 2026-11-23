/* Supabase Auth is the authority. The tab-scoped cache is display data only; every protected page revalidates it. */
(function(){
  const SESSION_KEY='zcLaundrySession',AUDIT_KEY='zcLaundryAudit',IDLE_LIMIT_MS=30*60*1000;
  const rolePages={student:'student.html',supervisor:'supervisor.html',admin:'admin.html'};
  /**
   * Formats an email local-part into a readable display name.
   * Strips leading "s-" / "u-" student prefix, replaces separators with spaces,
   * and title-cases every word.  e.g. "s-amr.farouk" → "Amr Farouk"
   */
  function formatEmailName(localPart){if(!localPart)return '';let s=localPart.replace(/^[su]-/i,'');s=s.replace(/[._\-]+/g,' ').trim();return s.split(' ').filter(Boolean).map(w=>w.charAt(0).toUpperCase()+w.slice(1).toLowerCase()).join(' ')}
  function readSession(){try{return JSON.parse(sessionStorage.getItem(SESSION_KEY)||'null')}catch{return null}}
  function writeAudit(role,actor,action,detail=''){let events=[];try{events=JSON.parse(localStorage.getItem(AUDIT_KEY)||'[]')}catch{}events.unshift({id:`AUD-${Date.now()}`,time:new Date().toISOString(),role,actor,action,detail});try{localStorage.setItem(AUDIT_KEY,JSON.stringify(events.slice(0,500)))}catch{}}
  function loadClientScript(){if(window.ZCSupabase)return Promise.resolve();const existing=[...document.scripts].find(script=>script.src.includes('/supabase-client.js'));return new Promise((resolve,reject)=>{const script=existing||document.createElement('script');script.addEventListener('load',resolve,{once:true});script.addEventListener('error',()=>reject(new Error('Account service unavailable')),{once:true});if(!existing){script.src='supabase-client.js';document.head.appendChild(script)}})}
  function currentSession(){const s=readSession();if(!s)return null;if(Date.now()-s.lastActivity>IDLE_LIMIT_MS){sessionStorage.removeItem(SESSION_KEY);return null}return s}
  function touch(){const s=readSession();if(s){s.lastActivity=Date.now();sessionStorage.setItem(SESSION_KEY,JSON.stringify(s))}}
  function redirectFor(role){return rolePages[role]||'login.html'}
  function startSession(role,email,name,roles=[]){const s={role,email,name:name||formatEmailName(email.split('@')[0]),roles:roles||[role],startedAt:Date.now(),lastActivity:Date.now(),sessionId:crypto.randomUUID()};sessionStorage.setItem(SESSION_KEY,JSON.stringify(s));return s}
  async function validatePage(required,file){
    try{
      if(!window.ZCSupabase)await loadClientScript();
      const client=await window.ZCSupabase.ready();
      const {data:{session},error}=await client.auth.getSession();
      if(error||!session){sessionStorage.removeItem(SESSION_KEY);location.replace(`login.html?next=${encodeURIComponent(file)}`);return}
      const {data:access,error:accessError}=await client.rpc('get_my_access');
      if(accessError||!access?.allowed){sessionStorage.removeItem(SESSION_KEY);location.replace('login.html?access='+encodeURIComponent(access?.reason||'account_review'));return}
      const s=startSession(access.role,session.user.email,access.name||formatEmailName(session.user.email.split('@')[0]),access.roles||[access.role]);
      
      // Strict role isolation: users can NEVER access pages outside their designated role
      if(required!=='any'){
        if(required==='student' && s.role!=='student'){
          console.warn(`[Strict Security Guard] Blocked ${s.role} (${s.email}) from student page ${file}`);
          location.replace(redirectFor(s.role));
          return;
        }
        if(required==='supervisor' && s.role!=='supervisor'){
          console.warn(`[Strict Security Guard] Blocked ${s.role} (${s.email}) from supervisor page ${file}`);
          location.replace(redirectFor(s.role));
          return;
        }
        if(required==='admin' && s.role!=='admin'){
          console.warn(`[Strict Security Guard] Blocked ${s.role} (${s.email}) from admin page ${file}`);
          location.replace(redirectFor(s.role));
          return;
        }
        if(required==='staff' && !['admin','supervisor'].includes(s.role)){
          console.warn(`[Strict Security Guard] Blocked student (${s.email}) from staff page ${file}`);
          location.replace('student.html');
          return;
        }
      }
      document.documentElement.dataset.userRole=s.role;document.documentElement.dataset.userEmail=s.email;
      ['click','keydown','pointerdown'].forEach(evt=>document.addEventListener(evt,touch,{passive:true}));
      const idleTimer=window.setInterval(()=>{if(!currentSession()){window.clearInterval(idleTimer);logout()}},15000);
      const hydrate=()=>{document.querySelectorAll('[data-session-name]').forEach(el=>el.textContent=s.name);document.querySelectorAll('[data-logout]').forEach(el=>el.addEventListener('click',event=>{event.preventDefault();logout()}))};
      if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',hydrate,{once:true});else hydrate();
    }catch(error){sessionStorage.removeItem(SESSION_KEY);console.error('Secure sign-in could not be checked:',error);location.replace('login.html?auth=setup')}
  }
  function guardPage(){
    const file=location.pathname.split('/').pop().toLowerCase();
    const required=(file==='student.html'||file==='payment-result.html')?'student'
      : (file==='supervisor.html'||file==='supervisor-schedule.html')?'supervisor'
      : (file==='approvals.html'||file==='support-admin.html')?'supervisor'
      : (file==='admin.html'||file.startsWith('admin-'))?'admin'
      : file==='audit.html'?'any':null;
    if(required)validatePage(required,file);
  }
  async function logout(){const s=readSession();try{if(!window.ZCSupabase)await loadClientScript();const client=await window.ZCSupabase?.ready();if(client){const {data:{user}}=await client.auth.getUser();try{await window.unregisterFirebasePush?.(client,user?.id)}catch{}/* audit is best-effort: missing role or network error must not block signOut */try{await client.rpc('record_user_audit',{p_action:'logout',p_details:'Signed out'})}catch{}await client.auth.signOut()}}catch{}sessionStorage.removeItem(SESSION_KEY);location.href=`logout.html${s?`?role=${encodeURIComponent(s.role)}`:''}`}
  function auditLog(role,actor,action,detail){writeAudit(role,actor,action,detail)}
  function getAudit(){try{return JSON.parse(localStorage.getItem(AUDIT_KEY)||'[]')}catch{return[]}}
  window.WashdayAuth={readSession,currentSession,startSession,logout,auditLog,getAudit,redirectFor};
  guardPage();
})();
