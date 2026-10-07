// js/kds.js - شاشة التحضير لكل مكان (مطبخ / بار / شيشة)
// كل مكان بيشوف أصنافه بس، وبيعلّم "بدء" و"جاهز". الطلب كله بيجهز لما كل أماكنه تجهز.

let kdsOrders = [];
let kdsPollTimer = null;
let kdsStation = 'kitchen';
let kdsKnownIds = new Set();
const KDS_STATION_NAMES = { kitchen: 'المطبخ 👨‍🍳', bar: 'البار 🍹', shisha: 'الشيشة 💨' };

function subscribeToKDSRealtime() {
    if (kdsPollTimer) return;
    const seconds = Math.max(5, Number(appSet('kds', 'refresh_seconds', 10)) || 10);
    kdsPollTimer = setInterval(() => {
        const view = document.getElementById('view-kds-workspace');
        if (!currentUser || !staffSessionToken) return;
        if (view && !view.classList.contains('hidden')) loadKDSOrders();
    }, seconds * 1000);
}

function setKDSStation(st) { kdsStation = st; kdsKnownIds = new Set(); loadKDSOrders(); }

function renderKDSStationTabs() {
    const box = document.getElementById('kds-station-tabs');
    if (!box) return;
    const stations = appSet('kds', 'stations', ['kitchen', 'bar', 'shisha']);
    if (!stations.includes(kdsStation)) kdsStation = stations[0] || 'kitchen';
    box.innerHTML = stations.map(st => `<button onclick="setKDSStation('${st}')" class="px-3 py-1.5 rounded-xl text-xs font-black ${st === kdsStation ? 'bg-blue-600 text-white' : 'bg-slate-100 text-slate-600'}">${uiEsc(KDS_STATION_NAMES[st] || st)}</button>`).join('');
}

function kdsBeep() {
    if (!appSet('kds', 'sound', true)) return;
    try {
        const ctx = new (window.AudioContext || window.webkitAudioContext)();
        const o = ctx.createOscillator(); const g = ctx.createGain();
        o.connect(g); g.connect(ctx.destination); o.frequency.value = 880; g.gain.value = 0.2;
        o.start(); setTimeout(() => { o.stop(); ctx.close(); }, 350);
    } catch (e) { /* no sound */ }
}

async function loadKDSOrders() {
    renderKDSStationTabs();
    if (!currentUser?.branch_id || !staffSessionToken) { kdsOrders = []; renderKDSCards(); return; }
    try {
        const res = await serverRpc('kds_station_list_secure', { p_station: kdsStation });
        if (!res || !res.ok) return;
        const fresh = (res.orders || []).filter(o => !kdsKnownIds.has(o.id));
        if (kdsKnownIds.size && fresh.length) kdsBeep();
        kdsOrders = res.orders || [];
        kdsKnownIds = new Set(kdsOrders.map(o => o.id));
        renderKDSCards();
    } catch (err) {
        console.error('KDS Exception:', err);
    }
}

function renderKDSCards() {
    const grid = document.getElementById('kds-cards-grid');
    if (!grid) return;
    if (kdsOrders.length === 0) {
        grid.innerHTML = `<div class="col-span-3 text-center py-16 bg-white rounded-3xl border border-slate-200"><p class="text-slate-400 font-extrabold text-base">🎉 لا توجد طلبات معلقة هنا الآن!</p></div>`;
        return;
    }
    const warn = Number(appSet('kds', 'warn_minutes', 15)) || 15;
    grid.innerHTML = kdsOrders.map(ord => {
        const minutes = Math.max(0, Math.floor((Date.now() - new Date(ord.created_at).getTime()) / 60000));
        const late = minutes >= warn;
        const isPreparing = ord.status === 'preparing';
        const cardBg = late ? 'bg-red-50 border-red-300' : (isPreparing ? 'bg-amber-50 border-amber-300' : 'bg-white border-slate-200');
        const itemsHtml = (ord.items || []).map(i => `
            <div class="border-b border-slate-100 py-1.5 font-extrabold text-sm text-slate-800 flex justify-between items-start gap-2">
                <div><span>${uiEsc(i.name)}</span>
                    ${(i.modifiers || []).length ? `<p class="text-[11px] text-amber-600 font-bold">+ ${uiEsc(i.modifiers.join('، '))}</p>` : ''}
                    ${i.item_notes ? `<p class="text-[11px] text-red-600 font-bold">📝 ${uiEsc(i.item_notes)}</p>` : ''}</div>
                <span class="bg-slate-800 text-white px-2 py-0.5 rounded-lg text-sm">×${uiEsc(i.quantity)}</span>
            </div>`).join('');
        return `
            <div class="p-5 rounded-3xl border ${cardBg} shadow-sm flex flex-col justify-between min-h-[260px]">
                <div>
                    <div class="flex justify-between items-center text-sm font-extrabold mb-2 pb-2 border-b">
                        <span>${uiEsc(ord.order_number || '')}${ord.table_number ? ' - طاولة ' + uiEsc(ord.table_number) : ''}</span>
                        <span class="text-blue-600 bg-blue-50 px-2 py-0.5 rounded-md text-[11px]">${uiEsc(PRINT_TYPE_NAMES[ord.order_type] || ord.order_type)}</span>
                    </div>
                    <div class="flex justify-between items-center mb-2 text-[11px] font-bold">
                        <span>${isPreparing ? '👨‍🍳 قيد التحضير' : '⏳ في الانتظار'}${ord.waiter ? ' | ' + uiEsc(ord.waiter) : ''}</span>
                        <span class="${late ? 'text-red-600 font-black' : 'text-slate-400'}">⏰ ${minutes} دقيقة</span>
                    </div>
                    <div class="space-y-1 mb-3">${itemsHtml}</div>
                </div>
                ${!isPreparing
                    ? `<button onclick="updateKDSStatus('${ord.id}', 'preparing')" class="w-full bg-amber-500 text-white py-2.5 rounded-xl font-extrabold text-xs">بدء التحضير</button>`
                    : `<button onclick="updateKDSStatus('${ord.id}', 'ready')" class="w-full bg-emerald-600 text-white py-2.5 rounded-xl font-extrabold text-xs">جاهز ✅</button>`}
            </div>`;
    }).join('');
}

async function updateKDSStatus(orderId, newStatus) {
    const res = await uiCall('kds_station_set_secure', { p_order_id: orderId, p_station: kdsStation, p_status: newStatus });
    if (res) loadKDSOrders();
}
