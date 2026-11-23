(function(){
  let rows=[];
  const note=m=>window.ZCNotify?ZCNotify.info(m):alert(m);
  async function client(){return window.ZCSupabase.ready()}

  function setupHeaderAndProfile(){
    const s = window.WashdayAuth ? window.WashdayAuth.currentSession() : null;
    if(s){
      // Update initials avatar
      const initials = (s.name || s.email || 'SV')
        .split(/\s+/)
        .map(w => w[0])
        .join('')
        .toUpperCase()
        .slice(0, 2);
      document.querySelectorAll('.avatar').forEach(el => el.textContent = initials);


    }

    const dateEl = document.getElementById('supervisorDate');
    if(dateEl){
      const today = new Date();
      dateEl.textContent = '◷   ' + today.toLocaleDateString('en-GB', {
        weekday: 'short',
        day: 'numeric',
        month: 'short',
        year: 'numeric'
      });
    }
  }

  async function load(){
    setupHeaderAndProfile();
    try{
      const c = await client();
      const from = new Date();
      from.setHours(0,0,0,0);
      const until = new Date(from);
      until.setDate(until.getDate()+8);

      // 1. Load supervisor metrics
      try{
        const {data:stats, error:statsErr} = await c.rpc('supervisor_dashboard_metrics');
        if(!statsErr && stats){
          drawMetrics(stats);
        }
      }catch(e){
        console.warn('Could not load supervisor metrics:', e);
      }

      // 2. Load bookings
      const b = await c.rpc('staff_list_bookings',{
        p_from: from.toISOString(),
        p_until: until.toISOString()
      });
      if(b.error) throw b.error;
      rows = b.data || [];
      drawBookings();

      // 3. Load laundry machines
      const m = await c.from('laundry_machines').select('machine_key,display_name,dorm_class,status').order('display_name');
      if(!m.error) drawMachines(m.data || []);

      // 4. Load door access events
      const d = await c.from('door_events').select('id,outcome,reason,created_at,ticket_id').order('created_at',{ascending:false}).limit(10);
      if(!d.error) drawDoorEvents(d.data || []);
    }catch(e){
      note('Could not load supervisor data: ' + (e.message || 'Backend not configured'));
    }
  }

  function drawMetrics(s){
    const b = document.getElementById('metricBookings');
    const bSub = document.getElementById('metricBookingsSub');
    if(b){
      b.textContent = s.today_bookings || 0;
      if(bSub) bSub.textContent = `Dorm ${s.dorm_class || 'C'} schedule`;
    }

    const cap = document.getElementById('metricCapacity');
    const capSub = document.getElementById('metricCapacitySub');
    if(cap){
      cap.innerHTML = `${s.free_capacity || 0} <span style="font-size:13px;color:#75837e;font-weight:600">of ${s.total_capacity || 0} free</span>`;
      if(capSub) capSub.textContent = s.free_capacity > 0 ? 'Ready for student cycles' : 'All machines in use';
    }

    const cyc = document.getElementById('metricCycles');
    const cycSub = document.getElementById('metricCyclesSub');
    if(cyc){
      cyc.textContent = s.active_cycles || 0;
      if(cycSub) cycSub.textContent = s.active_cycles > 0 ? 'Cycle in progress' : 'No active cycle right now';
    }

    const dev = document.getElementById('metricDevices');
    const devSub = document.getElementById('metricDevicesSub');
    if(dev){
      dev.textContent = `${s.online_devices || 0} / ${s.total_devices || 1}`;
      if(devSub) devSub.textContent = s.online_devices > 0 ? 'ESP32 scanner online' : 'Hardware node awaiting ping';
    }
  }

  function drawBookings(){
    const body=document.querySelector('#bookings tbody');
    if(!body)return;
    body.replaceChildren();

    if(!rows.length){
      const tr=document.createElement('tr'),td=document.createElement('td');
      td.colSpan=5;
      td.style.textAlign='center';
      td.style.padding='24px';
      td.textContent='No bookings in this 7-day date window.';
      tr.append(td);
      body.append(tr);
      return;
    }

    rows.forEach(x=>{
      const tr=document.createElement('tr'),
            student=document.createElement('td'),
            time=document.createElement('td'),
            arrival=document.createElement('td'),
            status=document.createElement('td'),
            actions=document.createElement('td'),
            avatar=document.createElement('span');

      avatar.className='mini-avatar';
      avatar.textContent=(x.student_name||'S').split(/\s+/).map(y=>y[0]).join('').slice(0,2);
      student.className='student';
      student.append(avatar,document.createTextNode(x.student_name||'Student'));

      const start=new Date(x.starts_at),end=new Date(start.getTime()+x.duration_minutes*60000);
      time.textContent=start.toLocaleDateString([],{month:'short',day:'numeric'}) + ' ' + start.toLocaleTimeString([],{hour:'2-digit',minute:'2-digit'})+' – '+end.toLocaleTimeString([],{hour:'2-digit',minute:'2-digit'});
      arrival.textContent=x.status==='confirmed'?'Expected':x.status==='completed'?'Checked in':'—';

      const pill=document.createElement('span');
      pill.className='pill '+(x.status==='confirmed'?'pending':x.status==='cancelled'?'cancelled':'');
      pill.textContent=x.status;
      status.append(pill);

      const view=document.createElement('button');
      view.className='row-action';
      view.textContent='View details';
      view.onclick=()=>show(x);
      actions.append(view);

      if(x.status==='confirmed'){
        for(const [label,state] of [['Complete','completed'],['No-show','no_show']]){
          const b=document.createElement('button');
          b.className='row-action';
          b.textContent=label;
          b.style.marginLeft='6px';
          b.onclick=()=>setStatus(x.ticket_id,state,b);
          actions.append(b);
        }
      }
      tr.append(student,time,arrival,status,actions);
      body.append(tr);
    });
  }

  function show(x){
    const start=new Date(x.starts_at),end=new Date(start.getTime()+x.duration_minutes*60000);
    [
      ['detailStudent',(x.student_name||'Student')+' · '+(x.student_email||'')],
      ['detailTime',start.toLocaleString()+' – '+end.toLocaleTimeString()],
      ['detailArrival',x.status==='completed'?'Arrived and validated':'Door access events recorded at physical lock'],
      ['detailStatus',x.status],
      ['detailTicket',x.ticket_id],
      ['detailMachine',x.machine_name||x.machine_key]
    ].forEach(([id,v])=>document.getElementById(id).textContent=v);

    document.getElementById('bookingModalSubtitle').textContent=`Assigned Dorm ${x.dorm_class||'C'} · live server record`;
    document.querySelector('.booking-demo-note').textContent='Student booking information is restricted to authorized staff for this dorm.';
    document.getElementById('bookingModal').hidden=false;
  }

  async function setStatus(id,state,b){
    const reason=state==='completed'?'Supervisor marked complete':'Supervisor marked no-show';
    b.disabled=true;
    try{
      const c=await client(),r=await c.rpc('staff_set_ticket_status',{p_ticket_id:id,p_status:state,p_reason:reason});
      if(r.error)throw r.error;
      note('Ticket updated and student notified.');
      load();
    }catch(e){
      note(e.message||'Could not update ticket.');
      b.disabled=false;
    }
  }

  function drawMachines(items){
    const section=document.querySelector('#machines');
    if(!section)return;
    const existing=[...section.querySelectorAll('.machine-row')],root=existing[0]?.parentElement||section;
    existing.forEach(x=>x.remove());

    if(!items.length){
      const empty = document.createElement('div');
      empty.className = 'machine-row';
      empty.innerHTML = '<div style="padding:10px;color:var(--muted)">No machines found for this dorm.</div>';
      root.append(empty);
      return;
    }

    items.forEach(m=>{
      const row=document.createElement('div');
      row.className='machine-row';
      const icon=document.createElement('div');
      icon.className='washer';
      icon.textContent='◉';
      const info=document.createElement('div'),name=document.createElement('b'),small=document.createElement('small');
      name.textContent=m.display_name;
      small.textContent='Dorm '+m.dorm_class+' · '+m.status.replaceAll('_',' ');
      info.append(name,small);
      const state=document.createElement('span');
      state.className=m.status==='available'?'online':'offline';
      state.textContent=m.status.toUpperCase();
      const action=document.createElement('button');
      action.className='toggle';
      action.textContent=m.status==='available'?'Mark out':'Restore';
      action.onclick=async()=>{
        const reason=prompt('Reason for machine status change:');
        if(!reason||reason.trim().length<3)return;
        try{
          const c=await client(),r=await c.rpc('staff_set_machine_status',{
            p_machine_key:m.machine_key,
            p_status:m.status==='available'?'out_of_service':'available',
            p_reason:reason
          });
          if(r.error)throw r.error;
          load();
        }catch(e){
          note(e.message||'Could not update machine');
        }
      };
      row.append(icon,info,state,action);
      root.append(row);
    });
  }

  function drawDoorEvents(items){
    const box=document.querySelector('#events .events');
    if(!box)return;
    box.replaceChildren();

    if(!items.length){
      box.innerHTML='<div style="padding:12px;color:var(--muted);font-size:11px">No door access events yet. Scans from the ESP32 scanner will appear here in real time.</div>';
      return;
    }

    items.forEach(x=>{
      const row=document.createElement('div');
      row.className='event';
      const icon=document.createElement('div');
      icon.className='event-icon'+(x.outcome==='denied'?' warn':'');
      icon.textContent=x.outcome==='granted'?'✓':'!';
      const copy=document.createElement('div'),title=document.createElement('b'),desc=document.createElement('p'),time=document.createElement('time');
      title.textContent='Access '+x.outcome;
      desc.textContent=x.reason||'Door event';
      time.textContent=new Date(x.created_at).toLocaleTimeString([],{hour:'2-digit',minute:'2-digit'});
      copy.append(title,desc);
      row.append(icon,copy,time);
      box.append(row);
    });
  }

  window.showBookingDetails=show;
  window.loadSupervisorData=load;
  document.addEventListener('DOMContentLoaded',load);
})();
