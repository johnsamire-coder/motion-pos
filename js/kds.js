// js/kds.js - موديول شاشة المطبخ KDS
// الطلبات بتتقري من السيرفر بتذكرة الوردية، والشاشة بتتحدث لوحدها كل 10 ثواني وهي مفتوحة.

let kdsOrders = [];
let kdsPollTimer = null;

// الاسم ده بيتنادى من index.html لما تفتح شاشة المطبخ: بيبدأ التحديث التلقائي
function subscribeToKDSRealtime() {
    if (kdsPollTimer) return;
    kdsPollTimer = setInterval(() => {
        const view = document.getElementById('view-kds-workspace');
        if (!currentUser || !staffSessionToken) return;
        if (view && !view.classList.contains('hidden')) loadKDSOrders();
    }, 10000);
}

async function loadKDSOrders() {
    if (!currentUser?.branch_id || !staffSessionToken) {
        kdsOrders = [];
        renderKDSCards();
        return;
    }
    try {
        const res = await serverRpc('kds_list_orders_secure');
        if (!res || !res.ok) {
            console.error('KDS load refused:', res);
            return;
        }
        kdsOrders = res.orders || [];
        renderKDSCards();
    } catch (err) {
        console.error('KDS Exception:', err);
    }
}

function renderKDSCards() {
    const grid = document.getElementById('kds-cards-grid');
    if (!grid) return;

    if (kdsOrders.length === 0) {
        grid.innerHTML = `
            <div class="col-span-3 text-center py-16 bg-white rounded-3xl border border-slate-200">
                <p class="text-slate-400 font-extrabold text-base">🎉 لا توجد طلبات معلقة في المطبخ الآن!</p>
            </div>
        `;
        return;
    }

    grid.innerHTML = kdsOrders.map(ord => {
        const time = new Date(ord.created_at).toLocaleTimeString('ar-EG', { hour: '2-digit', minute: '2-digit' });
        const minutes = Math.max(0, Math.floor((Date.now() - new Date(ord.created_at).getTime()) / 60000));
        const isPreparing = ord.kitchen_status === 'preparing';
        const cardBg = isPreparing ? 'bg-amber-50 border-amber-300' : 'bg-white border-slate-200';
        const statusBadge = isPreparing
            ? '<span class="bg-amber-100 text-amber-800 text-[10px] px-2.5 py-1 rounded-lg font-extrabold">قيد التحضير 👨🍳</span>'
            : '<span class="bg-blue-100 text-blue-800 text-[10px] px-2.5 py-1 rounded-lg font-extrabold">في الانتظار ⏳</span>';

        const itemsHtml = (ord.items || []).map(i => {
            const modsText = (i.modifiers || []).join(', ');
            return `
                <div class="border-b border-slate-100 py-1.5 font-extrabold text-xs text-slate-800 flex justify-between items-center">
                    <div>
                        <span>${i.name || 'صنف'}</span>
                        ${modsText ? `<p class="text-[10px] text-amber-600 font-bold">${modsText}</p>` : ''}
                        ${i.item_notes ? `<p class="text-[10px] text-red-600 font-bold">📝 ${i.item_notes}</p>` : ''}
                    </div>
                    <span class="bg-slate-200 px-2 py-0.5 rounded-lg text-slate-800 text-[11px]">x${i.quantity}</span>
                </div>
            `;
        }).join('');

        return `
            <div class="p-5 rounded-3xl border ${cardBg} shadow-sm flex flex-col justify-between min-h-[280px]">
                <div>
                    <div class="flex justify-between items-center text-xs font-extrabold mb-2 pb-2 border-b">
                        <span class="text-slate-800">طلب ${ord.order_number || '#' + String(ord.id).substring(0, 4)}${ord.table_number ? ' - طاولة ' + ord.table_number : ''}</span>
                        <span class="text-blue-600 bg-blue-50 px-2 py-0.5 rounded-md">${ord.order_type}</span>
                    </div>
                    <div class="flex justify-between items-center mb-3">
                        ${statusBadge}
                        <span class="text-[10px] font-bold ${minutes >= 15 ? 'text-red-600' : 'text-slate-400'}">⏰ ${time} (${minutes} دقيقة)</span>
                    </div>
                    <div class="space-y-1 mb-3">${itemsHtml}</div>
                </div>
                <div class="pt-3 border-t">
                    ${!isPreparing ?
                        `<button onclick="updateKDSStatus('${ord.id}', 'preparing')" class="w-full bg-amber-500 text-white py-2.5 rounded-xl font-extrabold text-xs hover:bg-amber-600 shadow">بدء التحضير 👨🍳</button>` :
                        `<button onclick="updateKDSStatus('${ord.id}', 'ready')" class="w-full bg-emerald-600 text-white py-2.5 rounded-xl font-extrabold text-xs hover:bg-emerald-700 shadow">جاهز للتقديم ✅</button>`
                    }
                </div>
            </div>
        `;
    }).join('');
}

async function updateKDSStatus(orderId, newStatus) {
    try {
        const res = await serverRpc('kds_set_status_secure', { p_order_id: orderId, p_status: newStatus });
        if (!res || !res.ok) {
            showToast(serverReasonMessage(res, 'خطأ في تحديث حالة المطبخ'), 'error');
            return;
        }
        loadKDSOrders();
    } catch (err) {
        console.error('Error updating KDS status:', err);
        showToast('خطأ في تحديث حالة المطبخ: ' + (err.message || ''), 'error');
    }
}
