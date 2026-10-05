// js/kds.js - موديول شاشة المطبخ KDS والتحديث اللحظي Realtime

let kdsOrders = [];
let kdsRealtimeChannel = null;

// الاشتراك اللحظي في جدول الطلبات بدعم WebSockets
function subscribeToKDSRealtime() {
    if (kdsRealtimeChannel) return;
    kdsRealtimeChannel = _supabase
        .channel('kds-realtime-channel')
        .on('postgres_changes', { event: '*', schema: 'public', table: 'orders' }, payload => {
            loadKDSOrders();
        })
        .subscribe();
}

async function loadKDSOrders() {
    if (!currentUser?.branch_id) {
        kdsOrders = [];
        renderKDSCards();
        return;
    }
    try {
        const { data: orders, error } = await _supabase
            .from('orders')
            .select('*, order_items(*, products(name), order_item_modifiers(*))')
            .eq('branch_id', currentUser.branch_id)
            .not('kitchen_status', 'eq', 'ready')
            .not('status', 'in', '("closed","cancelled")')
            .order('created_at', { ascending: true });

        if (error) {
            console.error('Error fetching KDS orders:', error);
            return;
        }

        kdsOrders = orders || [];
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
        const isPreparing = ord.kitchen_status === 'preparing';
        const cardBg = isPreparing ? 'bg-amber-50 border-amber-300' : 'bg-white border-slate-200';
        const statusBadge = isPreparing 
            ? '<span class="bg-amber-100 text-amber-800 text-[10px] px-2.5 py-1 rounded-lg font-extrabold">قيد التحضير 👨🍳</span>' 
            : '<span class="bg-blue-100 text-blue-800 text-[10px] px-2.5 py-1 rounded-lg font-extrabold">في الانتظار ⏳</span>';

        const itemsHtml = ord.order_items.map(i => {
            const modsText = (i.order_item_modifiers || []).map(m => m.modifier_name).join(', ');
            return `
                <div class="border-b border-slate-100 py-1.5 font-extrabold text-xs text-slate-800 flex justify-between items-center">
                    <div>
                        <span>${i.products ? i.products.name : 'صنف'}</span>
                        ${modsText ? `<p class="text-[10px] text-amber-600 font-bold">${modsText}</p>` : ''}
                    </div>
                    <span class="bg-slate-200 px-2 py-0.5 rounded-lg text-slate-800 text-[11px]">x${i.quantity}</span>
                </div>
            `;
        }).join('');

        return `
            <div class="p-5 rounded-3xl border ${cardBg} shadow-sm flex flex-col justify-between min-h-[280px]">
                <div>
                    <div class="flex justify-between items-center text-xs font-extrabold mb-2 pb-2 border-b">
                        <span class="text-slate-800">طلب ${ord.order_number || '#'+ord.id.substring(0,4)}</span>
                        <span class="text-blue-600 bg-blue-50 px-2 py-0.5 rounded-md">${ord.order_type}</span>
                    </div>
                    <div class="flex justify-between items-center mb-3">
                        ${statusBadge}
                        <span class="text-[10px] font-bold text-slate-400">⏰ ${time}</span>
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
        const { error } = await _supabase
            .from('orders')
            .update({ kitchen_status: newStatus })
            .eq('id', orderId);

        if (error) {
            showToast('خطأ في تحديث حالة المطبخ', 'error');
            return;
        }

        loadKDSOrders();
    } catch (err) {
        console.error('Error updating KDS status:', err);
    }
}
