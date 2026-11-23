/* Student notification center. Reads only rows allowed by Supabase Auth + RLS. */
(function () {
  const table = 'notifications';
  let client = null;
  let userId = null;
  let channel = null;
  let loaded = false;

  const el = (id) => document.getElementById(id);
  const panel = () => el('notificationPanel');

  window.openNotifications = function () {
    if (!panel()) return;
    panel().hidden = false;
    el('notificationButton')?.setAttribute('aria-expanded', 'true');
    if (!loaded) loadNotifications();
  };

  window.closeNotifications = function () {
    if (!panel()) return;
    panel().hidden = true;
    el('notificationButton')?.setAttribute('aria-expanded', 'false');
  };

  function setStatus(message) {
    const status = el('notificationStatus');
    if (status) status.textContent = message;
  }

  function renderEmpty(message) {
    const list = el('notificationItems');
    if (!list) return;
    list.replaceChildren();
    const p = document.createElement('p');
    p.className = 'notification-empty';
    p.textContent = message;
    list.appendChild(p);
  }

  function render(rows) {
    const list = el('notificationItems');
    if (!list) return;
    list.replaceChildren();
    if (!rows.length) {
      renderEmpty('You’re all caught up. New booking, payment, and service updates will appear here.');
      return;
    }

    for (const row of rows) {
      const item = document.createElement('article');
      item.className = `notification-item${row.read_at ? '' : ' unread'}`;
      const symbol = document.createElement('span');
      symbol.className = 'notification-symbol';
      symbol.setAttribute('aria-hidden', 'true');
      symbol.textContent = row.category === 'payment' ? '₤' : row.category === 'booking' ? '▣' : '•';

      const copy = document.createElement('div');
      copy.className = 'notification-copy';
      const title = document.createElement('b');
      title.textContent = row.title;
      const body = document.createElement('p');
      body.textContent = row.body;
      const date = document.createElement('time');
      date.dateTime = row.created_at;
      date.textContent = new Date(row.created_at).toLocaleString();
      copy.append(title, body, date);

      item.append(symbol, copy);
      if (!row.read_at) {
        const read = document.createElement('button');
        read.type = 'button';
        read.textContent = 'Mark read';
        read.addEventListener('click', () => markRead(row.id));
        item.appendChild(read);
      }
      list.appendChild(item);
    }
  }

  async function loadNotifications() {
    if (!client) {
      try { client = await window.ZCSupabase.ready(); }
      catch {
        setStatus('Supabase setup required');
        renderEmpty('Add the Supabase project URL and publishable key, then deploy the backend migrations.');
        return;
      }
    }

    setStatus('Checking secure student session…');
    const { data: { user }, error: authError } = await client.auth.getUser();
    if (authError || !user) {
      setStatus('Supabase student sign-in required');
      renderEmpty('Your current prototype sign-in is not connected to Supabase Auth yet. Sign-in must use the verified Supabase account before personal notifications can load.');
      return;
    }

    userId = user.id;
    const { data, error } = await client.from(table)
      .select('id,title,body,category,created_at,read_at')
      .eq('user_id', userId)
      .order('created_at', { ascending: false })
      .limit(30);

    if (error) {
      setStatus('Could not load notifications');
      renderEmpty('The notifications table or its access policies are not set up yet.');
      console.error('Supabase notifications query failed:', error.message);
      return;
    }

    loaded = true;
    setStatus(`${data.filter((item) => !item.read_at).length} unread · live updates on`);
    updateBadge(data.filter((item) => !item.read_at).length);
    render(data);
    subscribe();
  }

  function updateBadge(count) {
    const badge = el('notificationCount');
    if (!badge) return;
    badge.hidden = count < 1;
    badge.textContent = count > 9 ? '9+' : String(count);
  }

  function subscribe() {
    if (channel || !client || !userId) return;
    channel = client.channel(`student-notifications-${userId}`)
      .on('postgres_changes', {
        event: '*', schema: 'public', table, filter: `user_id=eq.${userId}`
      }, (payload) => {
        if (payload.eventType === 'INSERT' && payload.new?.id) {
          // Fire native desktop notification if user granted browser permission
          if (typeof Notification !== 'undefined' && Notification.permission === 'granted') {
            try {
              new Notification(payload.new.title || 'ZC Dorm Laundry', {
                body: payload.new.body || 'New laundry update received',
                icon: '/favicon.ico'
              });
            } catch (e) {
              console.warn('Native notification display error:', e);
            }
          }
          sendPush(payload.new.id);
        }
        loaded = false;
        loadNotifications();
      })
      .subscribe((status) => {
        if (status === 'CHANNEL_ERROR' || status === 'TIMED_OUT') {
          setStatus('Live updates disconnected');
        }
      });
  }

  async function sendPush(notificationId) {
    try {
      const { data: { session } } = await client.auth.getSession();
      if (!session) return;
      await client.functions.invoke('firebase-push', { body: { notificationId } });
    } catch (error) { console.warn('Firebase push send was unavailable:', error?.message || 'unknown error'); }
  }

  async function markRead(id) {
    if (!client || !userId) return;
    const { error } = await client.from(table)
      .update({ read_at: new Date().toISOString() })
      .eq('id', id)
      .eq('user_id', userId)
      .is('read_at', null);
    if (error) {
      setStatus('Could not update notification');
      return;
    }
    loaded = false;
    await loadNotifications();
  }

  document.addEventListener('click', (event) => {
    if (panel() && !panel().hidden && !panel().contains(event.target) && !el('notificationButton')?.contains(event.target)) {
      window.closeNotifications();
    }
  });
  document.addEventListener('keydown', (event) => {
    if (event.key === 'Escape') window.closeNotifications();
  });
})();
