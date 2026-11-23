/* Opt-in browser push & native desktop notifications.
   Supabase stores the account/device mapping; Firebase delivers pushes;
   Native Notification API provides immediate desktop alerts in open/background tabs. */
(function(){
  const config = () => window.ZC_FIREBASE_CONFIG || {};
  let foregroundHandlerInstalled = false;

  async function getBrowserToken() {
    const f = config();
    if (!f.apiKey || !f.projectId || !window.ZC_FIREBASE_VAPID_KEY) {
      throw new Error('Firebase web push VAPID key is not configured yet.');
    }
    if (!('Notification' in window) || !('serviceWorker' in navigator)) {
      throw new Error('This browser does not support web notifications.');
    }
    if (!window.isSecureContext && location.hostname !== 'localhost' && location.hostname !== '127.0.0.1') {
      throw new Error('Browser push notifications require HTTPS or localhost.');
    }
    if (typeof firebase !== 'undefined' && !firebase.apps.length) {
      firebase.initializeApp(f);
    }
    const messaging = firebase.messaging();
    const sw = await navigator.serviceWorker.register('/firebase-messaging-sw.js');
    const token = await messaging.getToken({
      vapidKey: window.ZC_FIREBASE_VAPID_KEY,
      serviceWorkerRegistration: sw
    });
    if (!token) throw new Error('Could not register this browser for notifications.');
    if (!foregroundHandlerInstalled) {
      foregroundHandlerInstalled = true;
      messaging.onMessage((payload) => {
        if (window.ZCNotify) {
          window.ZCNotify.show(payload.notification?.body || 'You have a new laundry update.', 'info');
        }
      });
    }
    return token;
  }

  async function bindCurrentUser(client, user) {
    if (!window.ZC_FIREBASE_VAPID_KEY) return null;
    const token = await getBrowserToken();
    const { error } = await client.rpc('student_register_fcm_token', { p_token: token });
    if (error) throw error;
    return token;
  }

  function updateNotificationButtons(enabled) {
    document.querySelectorAll('.notification-push-enable').forEach(btn => {
      if (enabled) {
        btn.textContent = '✓ Browser notifications active · الإشعارات مفعلة';
        btn.disabled = true;
        btn.style.background = '#e6f7ec';
        btn.style.color = '#137333';
        btn.style.borderColor = '#b7e1cd';
        btn.style.cursor = 'default';
      } else {
        btn.textContent = 'Enable browser notifications · تفعيل إشعارات المتصفح';
        btn.disabled = false;
        btn.style.background = '';
        btn.style.color = '';
      }
    });
  }

  window.enableFirebasePush = async function() {
    try {
      if (!('Notification' in window)) {
        throw new Error('This browser does not support desktop notifications.');
      }

      const permission = await Notification.requestPermission();
      if (permission !== 'granted') {
        throw new Error('Notification permission was not granted in your browser settings.');
      }

      updateNotificationButtons(true);

      // Fire a test desktop notification to confirm
      try {
        new Notification('ZC Dorm Laundry · إشعارات السكن', {
          body: 'Browser notifications are active! You will receive live updates on laundry bookings and payments.',
          icon: '/favicon.ico'
        });
      } catch (e) {
        console.warn('Native notification test failed:', e);
      }

      // Try binding Firebase FCM token if user is signed in and VAPID key is provided
      try {
        if (window.ZCSupabase) {
          const client = await window.ZCSupabase.ready();
          const { data: { user } } = await client.auth.getUser();
          if (user && window.ZC_FIREBASE_VAPID_KEY) {
            await bindCurrentUser(client, user);
          }
        }
      } catch (fcmErr) {
        console.warn('Firebase push registration notice:', fcmErr.message);
      }

      if (window.ZCNotify) {
        window.ZCNotify.show('Browser notifications enabled! / تم تفعيل إشعارات المتصفح بنجاح', 'success');
      } else {
        alert('Browser notifications enabled!');
      }
    } catch (error) {
      if (window.ZCNotify) {
        window.ZCNotify.show(error.message || 'Could not enable notifications.', 'error');
      } else {
        alert(error.message || 'Could not enable notifications.');
      }
    }
  };

  window.unregisterFirebasePush = async function(client, userId) {
    if (!client || !userId || !('Notification' in window) || Notification.permission !== 'granted' || !window.ZC_FIREBASE_VAPID_KEY) return;
    try {
      const token = await getBrowserToken();
      const { error } = await client.from('fcm_tokens').delete().eq('user_id', userId).eq('token', token);
      if (error) console.warn('Could not unregister FCM push token:', error.message);
    } catch (error) {
      console.warn('Could not unregister FCM push token:', error?.message || 'unknown error');
    }
  };

  document.addEventListener('DOMContentLoaded', async () => {
    if ('Notification' in window && Notification.permission === 'granted') {
      updateNotificationButtons(true);
      if (window.ZC_FIREBASE_VAPID_KEY) {
        try {
          const client = await window.ZCSupabase?.ready();
          if (!client) return;
          const { data: { user } } = await client.auth.getUser();
          if (user) await bindCurrentUser(client, user);
        } catch (error) {
          console.warn('Push permission sync notice:', error?.message || 'unknown error');
        }
      }
    }
  }, { once: true });
})();
