// js/waiter.js - جرس الويتر: الطلبات اللي جهزت + نداءات الزبائن من الـ QR
// بيشتغل لأي حد عنده صلاحية البيع. الويتر بيشوف طلباته هو بس، والمدير والكاشير بيشوفوا الكل.

let waiterFeed = { ready: [], calls: [] };
let waiterTimer = null;
let waiterSeen = new Set();

function startWaiterFeed() {
    if (waiterTimer) return;
    loadWaiterFeed();
    waiterTimer = setInterval(() => { if (currentUser && staffSessionToken) loadWaiterFeed(); }, 15000);
}

function stopWaiterFeed() {
    if (waiterTimer) clearInterval(waiterTimer);
    waiterTimer = null;
    waiterSeen = new Set();
}

async function loadWaiterFeed() {
    if (!Array.isArray(currentUser?.perms) || !currentUser.perms.includes('pos')) return;
    try {
        const res = await serverRpc('waiter_feed_secure');
        if (!res || !res.ok) return;
        waiterFeed = { ready: res.ready || [], calls: res.calls || [] };
        const keys = [...waiterFeed.ready.map(r => 'r' + r.order_id + r.station), ...waiterFeed.calls.map(c => 'c' + c.id)];
        const fresh = keys.filter(k => !waiterSeen.has(k));
        if (waiterSeen.size && fresh.length && typeof kdsBeep === 'function') kdsBeep();
        waiterSeen = new Set(keys);
        const bell = document.getElementById('waiter-bell');
        const count = document.getElementById('waiter-bell-count');
        if (bell) bell.classList.toggle('hidden', keys.length === 0);
        if (count) count.textContent = String(keys.length);
        if (!document.getElementById('waiter-feed-modal')?.classList.contains('hidden')) renderWaiterFeed();
    } catch (err) {
        console.error('Waiter feed error:', err);
    }
}

function openWaiterFeed() {
    let modal = document.getElementById('waiter-feed-modal');
    if (!modal) {
        modal = document.createElement('div');
        modal.id = 'waiter-feed-modal';
        modal.className = 'fixed inset-0 bg-slate-900/60 z-50 flex items-center justify-center p-4';
        modal.onclick = e => { if (e.target === modal) modal.classList.add('hidden'); };
        document.body.appendChild(modal);
    }
    modal.classList.remove('hidden');
    renderWaiterFeed();
}

function renderWaiterFeed() {
    const modal = document.getElementById('waiter-feed-modal');
    if (!modal) return;
    const stationNames = { kitchen: 'المطبخ', bar: 'البار', shisha: 'الشيشة' };
    const ready = waiterFeed.ready.map(r => `<div class="flex justify-between items-center bg-emerald-50 border border-emerald-200 p-3 rounded-xl">
        <span class="text-sm font-black">✅ ${uiEsc(r.order_number)}${r.table_number ? ' - طاولة ' + uiEsc(r.table_number) : ''} (${uiEsc(stationNames[r.station] || r.station)})</span>
        ${uiBtn('اتقدّم', `waiterAck('ready','${r.order_id}','${r.station}')`, 'green')}</div>`).join('');
    const calls = waiterFeed.calls.map(c => `<div class="flex justify-between items-center bg-amber-50 border border-amber-200 p-3 rounded-xl">
        <span class="text-sm font-black">${c.type === 'bill' ? '🧾 طلب الحساب' : '🙋 نداء ويتر'} - طاولة ${uiEsc(c.table_number)} <small class="text-slate-500">${uiEsc(uiDate(c.created_at))}</small></span>
        ${uiBtn('تم', `waiterAck('call','${c.id}','')`, 'amber')}</div>`).join('');
    modal.innerHTML = `<div class="bg-white rounded-2xl p-5 w-full max-w-md shadow-xl space-y-2 max-h-[80vh] overflow-y-auto" dir="rtl">
        <div class="flex justify-between items-center border-b pb-2 mb-2"><h3 class="font-black text-sm">🔔 التنبيهات</h3>
        <button onclick="document.getElementById('waiter-feed-modal').classList.add('hidden')" class="text-slate-400 font-black">✕</button></div>
        ${ready || calls ? ready + calls : '<p class="text-center text-slate-400 text-xs font-bold py-6">مفيش تنبيهات</p>'}</div>`;
}

async function waiterAck(kind, id, station) {
    const res = await uiCall('waiter_ack_secure', { p_kind: kind, p_id: id, p_station: station || null });
    if (res) loadWaiterFeed();
}
