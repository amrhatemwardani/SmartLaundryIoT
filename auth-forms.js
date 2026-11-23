/* Student signup with a Supabase email confirmation link, and password recovery. */
(function(){
 const byId=id=>document.getElementById(id);
 const msg=(id,text,isError=false)=>{const el=byId(id);if(!el)return;el.innerHTML=text;el.classList.remove('success','error');el.classList.add(isError?'error':'success','show')};
 const egyptianPhoneE164=(raw,optional=false)=>{const digits=String(raw||'').replace(/\D/g,'');if(optional&&!digits)return '';if(!/^01[0125]\d{8}$/.test(digits))throw new Error('Enter an Egyptian mobile number with 11 digits, starting 010, 011, 012, or 015.');return '+20'+digits.slice(1)};
 const authErrorText=error=>{const code=String(error?.code||'').toLowerCase(),detail=String(error?.message||'').toLowerCase();if(detail.includes('525')||detail.includes('unauthorized ip address'))return 'Brevo blocked the SMTP connection. Check the Brevo Authorized IP alert for the source IP used by Supabase, then retry.';if(detail.includes('535')||detail.includes('authentication failed'))return 'Brevo rejected the SMTP credentials. Verify the SMTP login and replace the exposed SMTP key in Supabase settings.';if(detail.includes('sender')&&(detail.includes('invalid')||detail.includes('verify')||detail.includes('reject')))return 'Brevo rejected the sender address. Verify that sender in Brevo and select it in Supabase SMTP settings.';if(code==='email_address_not_authorized'||detail.includes('email address not authorized'))return 'Supabase default email can only reach project team addresses. Configure custom SMTP to send confirmation links to student addresses.';if(code==='over_email_send_rate_limit'||detail.includes('email rate limit')||error?.status===429)return 'Supabase email limit reached. Wait before retrying, then check the project email limit and Brevo sending quota.';return error?.message||'Could not complete the request. Please try again.'};
 const signup=byId('signupForm');
 if(signup)signup.addEventListener('submit',async e=>{
  e.preventDefault();const button=signup.querySelector('[type=submit]');button.disabled=true;
  try{
   const d=new FormData(signup),email=String(d.get('email')).trim().toLowerCase();
   if(!/^[a-z0-9._%+-]+@zewailcity\.edu\.eg$/i.test(email))throw new Error('Use your @zewailcity.edu.eg email.');
   const phone=egyptianPhoneE164(d.get('phone')),whatsapp=egyptianPhoneE164(d.get('whatsapp'),true);
   if(String(d.get('password'))!==String(byId('confirm').value))throw new Error('Passwords do not match.');
   if(!byId('privacyAccepted').checked||!byId('termsAccepted').checked)throw new Error('Read and accept both notices.');
   const client=await ZCSupabase.ready();const {error}=await client.auth.signUp({email,password:String(d.get('password')),options:{emailRedirectTo:location.origin+'/login.html?verified=1',data:{full_name:String(d.get('name')).trim(),university_id:String(d.get('university_id')).trim(),major:String(d.get('major')).trim(),age:Number(d.get('age')),dorm_class:String(d.get('dorm')),phone_number:phone,whatsapp_number:whatsapp,privacy_accepted:true,terms_accepted:true}}});
   if(error)throw error;window.signupEmail=email;sessionStorage.setItem('zcSignupEmail',email);byId('maskedEmail').textContent=email.replace(/^(.{2}).*(@.*)$/,'$1••••$2');msg('signupStatus','Confirmation link sent. Open your university inbox and click the link to verify your email.');activateStep(2);
  }catch(error){msg('signupStatus',authErrorText(error))}finally{button.disabled=false}
 });
 window.sendConfirmationAgain=async function(){const button=byId('resendConfirmation');if(button)button.disabled=true;try{const email=window.signupEmail||sessionStorage.getItem('zcSignupEmail');if(!email)throw new Error('Return to the account form and submit it again.');const client=await ZCSupabase.ready();const {error}=await client.auth.resend({type:'signup',email,options:{emailRedirectTo:location.origin+'/login.html?verified=1'}});if(error)throw error;msg('verifyStatus','A new confirmation link was sent. Use the newest email.')}catch(error){msg('verifyStatus',authErrorText(error))}finally{if(button)button.disabled=false}};
 const recovery=byId('form');if(recovery&&byId('email'))recovery.addEventListener('submit',async e=>{
   e.preventDefault();
   const button=recovery.querySelector('button, [type=submit]');
   if(button){ button.disabled=true; button.textContent='Sending... / جاري الإرسال...'; }
   try{
     const email=byId('email').value.trim().toLowerCase();
     if(!email.endsWith('@zewailcity.edu.eg'))throw new Error('Enter your Zewail City university email (@zewailcity.edu.eg). / يرجى إدخال البريد الجامعي لمدينة زويل.');
     const client=await ZCSupabase.ready();
     const {error}=await client.auth.resetPasswordForEmail(email,{redirectTo:location.origin+'/reset-password.html'});
     if(error)throw error;
     msg('msg','✅ If an account exists for that address, password reset instructions were sent to your university inbox. Please check your email and spam folder.<br><span style="display:block;margin-top:4px">تم إرسال رابط إعادة تعيين كلمة المرور إلى بريدك الجامعي. يرجى مراجعة البريد والـ Spam.</span>',false);
   }catch(error){
     msg('msg',authErrorText(error)||error.message||'Could not send reset instructions.',true);
   }finally{
     if(button){ button.disabled=false; button.textContent='Send reset instructions / إرسال الرابط'; }
   }
 });
 const reset=byId('resetPasswordForm');if(reset)reset.addEventListener('submit',async e=>{
   e.preventDefault();
   const button=reset.querySelector('button, [type=submit]');
   if(button)button.disabled=true;
   try{
     const password=byId('newPassword').value;
     if(password!==byId('confirmPassword').value)throw new Error('Passwords do not match.');
     const client=await ZCSupabase.ready();
     const {error}=await client.auth.updateUser({password});
     if(error)throw error;
     msg('resetMessage','Password updated successfully! Redirecting to sign in...');
     setTimeout(()=>location.assign('login.html?reset=1'),1500);
   }catch(error){
     msg('resetMessage',authErrorText(error)||error.message||'Could not update your password.');
   }finally{
     if(button)button.disabled=false;
   }
 });
})();
