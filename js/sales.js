// js/sales.js - شاشة المبيعات: كل طلب بتفاصيله (الأصناف، الإضافات، الملاحظات، الأوقات، الدفع، مين عمل إيه)
// وتحليل التأخير: كل مكان وكل صنف وكل ساعة، وأبطأ الطلبات.

const SALES_STATUS_NAMES = { draft: 'مسودة', open: 'مفتوح', sent: 'في المطبخ', preparing: 'بيتحضر', ready: 'جاهز', served: 'اتقدم',
    paid: 'مدفوع', closed: 'مدفوع', cancelled: 'ملغي' };
const SALES_ACTION_NAMES = { SEND_TO_KITCHEN: 'فتح الطلب وإرساله للمطبخ', ADD_ITEMS_TO_ORDER: 'إضافة أصناف', KITCHEN_STATUS: 'تحضير',
    APPLY_DISCOUNT: 'خصم', REMOVE_DISCOUNT: 'شيل الخصم', CHANGE_CHARGES: 'تغيير الضريبة / الخدمة', CANCEL_ORDER: 'إلغاء الطلب',
    CLOSE_ORDER: 'دفع وقفل', REFUND_ORDER: 'مرتجع', REFUND: 'مرتجع', MERGE_ORDERS: 'دمج طلب فيه', MERGED_INTO: 'اتدمج في طلب تاني',
    SPLIT_ORDER: 'تقسيم', SPLIT_FROM: 'طلب جاي من تقسيم', TRANSFER_TABLE: 'نقل طاولة', UPDATE_ORDER_INFO: 'تعديل بيانات الطلب',
    VOID_ITEM: 'إلغاء صنف', VOID_ITEM_CANCEL_ORDER: 'إلغاء صنف (الطلب اتلغى)' };
const SALES_STATION_NAMES = { kitchen: 'المطبخ', bar: 'البار', shisha: 'الشيشة' };

let salesState = { tab: 'orders', from: null, to: null, branch: '', branches: [], filters: { status: 'all', order_type: '', waiter_id: '', cashier_id: '', search: '', late_only: false },
    last: null, timing: null };

function salesTime(ts) {
    if (!ts) return '-';
    return new Date(ts).toLocaleTimeString('ar-EG', { hour: '2-digit', minute: '2-digit' });
}

function salesMin(v) {
    if (v === null || v === undefined || v === '') return '-';
    return `${Number(v)} د`;
}

async function loadSalesScreen() {
    const root = document.getElementById('sales-root');
    if (!root) return;
    if (!salesState.from) { salesState.from = uiToday(); salesState.to = uiToday(); }
    const isOwner = String(currentUser?.roles?.name || '') === 'owner';
    if (isOwner && !salesState.branches.length) {
        const { data } = await _supabase.from('branches').select('id, name').order('name');
        salesState.branches = data || [];
    }
    root.innerHTML = uiTabs('sales-tabs', [['orders', 'المبيعات 🧾'], ['timing', 'التأخير ⏱️']], salesState.tab, 'salesSwitchTab')
        + uiCard(salesState.tab === 'orders' ? 'المبيعات' : 'تحليل وقت التحضير', `
        <div class="flex flex-wrap items-end gap-2 mb-2">
            <label class="text-xs font-bold">من<br><input id="sales-from" type="date" value="${uiEsc(salesState.from)}" class="${uiInputClass()}"></label>
            <label class="text-xs font-bold">إلى<br><input id="sales-to" type="date" value="${uiEsc(salesState.to)}" class="${uiInputClass()}"></label>
            ${isOwner ? `<label class="text-xs font-bold">الفرع<br><select id="sales-branch" class="${uiInputClass()}"><option value="">كل الفروع</option>${salesState.branches.map(b => `<option value="${uiEsc(b.id)}" ${b.id === salesState.branch ? 'selected' : ''}>${uiEsc(b.name)}</option>`).join('')}</select></label>` : ''}
            ${uiBtn('النهارده', 'salesQuick(0)', 'gray')}${uiBtn('امبارح', "salesQuick('y')", 'gray')}${uiBtn('آخر ٧ أيام', 'salesQuick(6)', 'gray')}${uiBtn('الشهر ده', "salesQuick('month')", 'gray')}
        </div>
        ${salesState.tab === 'orders' ? salesFiltersHtml() : ''}
        <div class="mt-2">${uiBtn('عرض 🔍', 'salesRun()', 'blue')}</div>
        <div id="sales-result" class="mt-4"></div>`);
    salesRun();
}

function salesSwitchTab(tab) { salesReadPeriod(); salesState.tab = tab; loadSalesScreen(); }

function salesFiltersHtml() {
    const f = salesState.filters;
    const staff = (salesState.last && salesState.last.staff) || [];
    const opt = (list, val) => list.map(([v, l]) => `<option value="${uiEsc(v)}" ${String(val) === String(v) ? 'selected' : ''}>${uiEsc(l)}</option>`).join('');
    return `<div class="flex flex-wrap items-end gap-2">
        <label class="text-xs font-bold">الحالة<br><select id="sales-status" class="${uiInputClass()}">${opt([['all', 'الكل'], ['closed', 'مدفوع'], ['open', 'مفتوح'], ['cancelled', 'ملغي']], f.status)}</select></label>
        <label class="text-xs font-bold">النوع<br><select id="sales-type" class="${uiInputClass()}">${opt([['', 'الكل'], ...Object.entries(PRINT_TYPE_NAMES)], f.order_type)}</select></label>
        <label class="text-xs font-bold">الويتر<br><select id="sales-waiter" class="${uiInputClass()}">${opt([['', 'الكل'], ...staff.filter(s => s.role === 'waiter' || s.role === 'branch_manager').map(s => [s.id, s.name])], f.waiter_id)}</select></label>
        <label class="text-xs font-bold">الكاشير<br><select id="sales-cashier" class="${uiInputClass()}">${opt([['', 'الكل'], ...staff.filter(s => s.role !== 'waiter').map(s => [s.id, s.name])], f.cashier_id)}</select></label>
        <label class="text-xs font-bold">بحث<br><input id="sales-search" value="${uiEsc(f.search)}" placeholder="رقم الطلب / العميل / الموبايل / الطاولة" onkeydown="if(event.key==='Enter')salesRun()" class="${uiInputClass()} w-56"></label>
        <label class="text-xs font-bold flex items-center gap-1 pb-2"><input id="sales-late" type="checkbox" ${f.late_only ? 'checked' : ''}> المتأخر بس</label>
    </div>`;
}

function salesQuick(k) {
    const today = uiToday();
    let from = today, to = today;
    if (k === 'y') { from = uiToday(-1); to = from; }
    else if (k === 'month') from = today.slice(0, 8) + '01';
    else if (k) from = uiToday(-k);
    document.getElementById('sales-from').value = from;
    document.getElementById('sales-to').value = to;
    salesRun();
}

function salesReadPeriod() {
    salesState.from = document.getElementById('sales-from')?.value || salesState.from;
    salesState.to = document.getElementById('sales-to')?.value || salesState.to;
    salesState.branch = document.getElementById('sales-branch')?.value || '';
}

async function salesRun() {
    salesReadPeriod();
    const box = document.getElementById('sales-result');
    if (!box) return;
    box.innerHTML = '<p class="text-xs text-slate-400 font-bold">جاري التحميل...</p>';
    if (salesState.tab === 'timing') return salesRunTiming(box);
    const f = salesState.filters;
    if (document.getElementById('sales-status')) {
        f.status = document.getElementById('sales-status').value;
        f.order_type = document.getElementById('sales-type').value;
        f.waiter_id = document.getElementById('sales-waiter').value;
        f.cashier_id = document.getElementById('sales-cashier').value;
        f.search = document.getElementById('sales-search').value.trim();
        f.late_only = document.getElementById('sales-late').checked;
    }
    const hadStaff = !!(salesState.last && salesState.last.staff && salesState.last.staff.length);
    const res = await uiCall('sales_orders_secure', { p_from: salesState.from, p_to: salesState.to, p_branch_id: salesState.branch || null,
        p_filters: { ...f, late_only: f.late_only ? 'true' : 'false' } });
    if (!res) { box.innerHTML = ''; return; }
    salesState.last = res;
    if (!hadStaff && (res.staff || []).length) { loadSalesScreen(); return; }
    const s = res.summary || {};
    const card = (label, value, color) => `<div class="bg-${color}-50 p-3 rounded-2xl border border-${color}-200"><p class="text-[11px] font-bold text-${color}-700">${uiEsc(label)}</p><p class="text-lg font-black text-${color}-800">${value}</p></div>`;
    const rows = res.rows || [];
    box.innerHTML = `
        <div class="grid grid-cols-2 md:grid-cols-6 gap-2 mb-3">
            ${card('المبيعات المدفوعة', formatCurrency(s.closed_total), 'emerald')}
            ${card('عدد الطلبات المدفوعة', uiEsc(s.closed_count || 0), 'blue')}
            ${card('متوسط الفاتورة', formatCurrency(s.avg_ticket), 'sky')}
            ${card('مفتوح دلوقتي', uiEsc(s.open_count || 0), 'amber')}
            ${card('ملغي', uiEsc(s.cancelled_count || 0), 'red')}
            ${card('متأخر', `${uiEsc(s.late_count || 0)}${s.avg_prep !== null && s.avg_prep !== undefined ? ` <span class="text-xs">(متوسط التحضير ${uiEsc(s.avg_prep)} د)</span>` : ''}`, 'rose')}
        </div>
        <div class="flex flex-wrap justify-between items-center gap-2 mb-2">
            <p class="text-[11px] font-bold text-slate-500">${uiEsc(res.from)} إلى ${uiEsc(res.to)} | ${uiEsc(res.branch)} | ${rows.length} طلب${rows.length >= 1000 ? ' (أول ١٠٠٠ بس، ضيّق الفترة)' : ''} | دوس على أي طلب عشان تشوف تفاصيله</p>
            <div class="flex gap-2">${uiBtn('تصدير Excel 📗', 'exportReportExcel(salesExportRep())', 'green')}${uiBtn('PDF / طباعة 📄', 'printReportPdf(salesExportRep())', 'red')}</div>
        </div>
        ${rows.length ? `<div class="overflow-x-auto"><table class="w-full text-right"><thead><tr>${['رقم الطلب', 'الوقت', 'النوع', 'الطاولة', 'العميل', 'الويتر', 'الكاشير', 'الأصناف', 'الإجمالي', 'وقت التحضير', 'الدفع', 'الحالة']
            .map(h => `<th class="p-2 text-[11px] text-white bg-blue-700 font-black">${h}</th>`).join('')}</tr></thead><tbody>
            ${rows.map((r, i) => `<tr onclick="salesOpenOrder('${r.id}')" class="cursor-pointer text-xs font-bold hover:bg-blue-50 ${r.status === 'cancelled' ? 'text-slate-400 line-through' : ''} ${i % 2 ? 'bg-slate-50' : ''}">
                <td class="p-2 border-b text-blue-700">${uiEsc(r.order_number)}</td>
                <td class="p-2 border-b whitespace-nowrap">${uiEsc(uiDate(r.created_at))}</td>
                <td class="p-2 border-b">${uiEsc(PRINT_TYPE_NAMES[r.order_type] || r.order_type)}</td>
                <td class="p-2 border-b">${uiEsc(r.table_number || '-')}</td>
                <td class="p-2 border-b">${r.customer ? `${uiEsc(r.customer)}<br><span class="text-[10px] text-slate-400">${uiEsc(r.customer_phone || '')}</span>` : '-'}</td>
                <td class="p-2 border-b">${uiEsc(r.waiter || '-')}</td>
                <td class="p-2 border-b">${uiEsc(r.cashier || '-')}</td>
                <td class="p-2 border-b">${uiEsc(r.items_count)}</td>
                <td class="p-2 border-b">${formatCurrency(r.total_amount)}</td>
                <td class="p-2 border-b ${r.late ? 'text-red-600 font-black' : ''}">${r.late ? '⚠️ ' : ''}${salesMin(r.prep_minutes)}</td>
                <td class="p-2 border-b">${uiEsc((r.methods || '').split(',').filter(Boolean).map(m => PRINT_METHOD_NAMES[m] || m).join(' + ') || '-')}</td>
                <td class="p-2 border-b">${uiEsc(SALES_STATUS_NAMES[r.status] || r.status)}</td></tr>`).join('')}
            </tbody></table></div>` : '<p class="text-center text-slate-400 font-bold text-xs py-6">مفيش طلبات بالشروط دي</p>'}`;
}

function salesExportRep() {
    const res = salesState.last || { rows: [] };
    return { key: 'sales_orders', title: 'المبيعات بالتفصيل', from: res.from, to: res.to, branch: res.branch,
        columns: [{ key: 'order_number', label: 'رقم الطلب', type: 't' }, { key: 'time', label: 'الوقت', type: 't' }, { key: 'type', label: 'النوع', type: 't' },
            { key: 'table_number', label: 'الطاولة', type: 't' }, { key: 'customer', label: 'العميل', type: 't' }, { key: 'customer_phone', label: 'الموبايل', type: 't' },
            { key: 'waiter', label: 'الويتر', type: 't' }, { key: 'cashier', label: 'الكاشير', type: 't' }, { key: 'items_count', label: 'الأصناف', type: 'n' },
            { key: 'total_amount', label: 'الإجمالي', type: 'm' }, { key: 'avg_prep', label: 'وقت التحضير (دقيقة)', type: 'n' },
            { key: 'late_text', label: 'متأخر', type: 't' }, { key: 'pay', label: 'الدفع', type: 't' }, { key: 'state', label: 'الحالة', type: 't' }],
        rows: (res.rows || []).map(r => ({ ...r, time: uiDate(r.created_at), type: PRINT_TYPE_NAMES[r.order_type] || r.order_type,
            avg_prep: r.prep_minutes, late_text: r.late ? 'متأخر' : '', state: SALES_STATUS_NAMES[r.status] || r.status,
            total_amount: r.status === 'cancelled' ? 0 : r.total_amount,
            pay: (r.methods || '').split(',').filter(Boolean).map(m => PRINT_METHOD_NAMES[m] || m).join(' + ') })) };
}

// ---------------------------------------------------------------- one order
function salesModal(html) {
    let m = document.getElementById('sales-modal');
    if (!m) {
        m = document.createElement('div');
        m.id = 'sales-modal';
        m.className = 'fixed inset-0 bg-slate-900/60 z-50 flex items-start justify-center p-4 overflow-y-auto';
        m.onclick = e => { if (e.target === m) m.remove(); };
        document.body.appendChild(m);
    }
    m.innerHTML = `<div class="bg-white rounded-3xl shadow-2xl w-full max-w-4xl p-5 my-6 text-right" dir="rtl">${html}</div>`;
}

async function salesOpenOrder(orderId) {
    const res = await uiCall('sales_order_detail_secure', { p_order_id: orderId });
    if (!res) return;
    const o = res.order;
    const warn = res.warn || {};
    const items = res.items || [];
    const active = items.filter(i => i.status === 'active');
    const sent = active.map(i => i.sent_at).filter(Boolean).sort()[0];
    const ready = active.every(i => i.ready_at) ? active.map(i => i.ready_at).sort().slice(-1)[0] : null;
    const line = (label, value) => value ? `<div><span class="text-slate-400">${uiEsc(label)}:</span> ${value}</div>` : '';
    const itemRows = items.map(i => {
        const late = i.total_minutes !== null && i.total_minutes !== undefined && Number(i.total_minutes) > Number(warn[i.station] || 999);
        const off = i.status !== 'active';
        return `<tr class="border-b text-xs font-bold ${off ? 'text-slate-400' : ''}">
            <td class="p-2"><span class="${off ? 'line-through' : ''}">${uiEsc(i.name)}</span>${off ? ` <span class="text-red-500">(ملغي${i.void_reason ? ': ' + uiEsc(i.void_reason) : ''})</span>` : ''}
                ${(i.modifiers || []).length ? `<div class="text-[11px] text-amber-600">+ ${(i.modifiers || []).map(m => `${uiEsc(m.name)}${Number(m.price) ? ' (' + formatCurrency(m.price) + ')' : ''}`).join('، ')}</div>` : ''}
                ${i.notes ? `<div class="text-[11px] text-red-600">📝 ${uiEsc(i.notes)}</div>` : ''}</td>
            <td class="p-2">${uiEsc(i.quantity)}</td><td class="p-2">${formatCurrency(i.unit_price)}</td><td class="p-2">${formatCurrency(i.total_price)}</td>
            <td class="p-2">${uiEsc(SALES_STATION_NAMES[i.station] || i.station)}</td>
            <td class="p-2">${salesTime(i.sent_at)}</td><td class="p-2">${salesTime(i.prep_started_at)}</td><td class="p-2">${salesTime(i.ready_at)}</td><td class="p-2">${salesTime(i.served_at)}</td>
            <td class="p-2 ${late ? 'text-red-600 font-black' : ''}">${late ? '⚠️ ' : ''}${salesMin(i.total_minutes)}<div class="text-[10px] text-slate-400">انتظار ${salesMin(i.wait_minutes)} + تحضير ${salesMin(i.prep_minutes)}</div></td></tr>`;
    }).join('');
    const pays = (res.payments || []).map(p => `<tr class="border-b text-xs font-bold"><td class="p-2">${uiEsc(PRINT_METHOD_NAMES[p.method] || p.method)}</td>
        <td class="p-2">${formatCurrency(p.amount)}</td><td class="p-2">${Number(p.tip) ? formatCurrency(p.tip) : '-'}</td><td class="p-2">${uiEsc(uiDate(p.at))}</td><td class="p-2">${uiEsc(p.cashier || '-')}</td></tr>`).join('');
    const logs = (res.logs || []).map(l => `<tr class="border-b text-[11px] font-bold"><td class="p-1.5 whitespace-nowrap">${uiEsc(uiDate(l.at))}</td>
        <td class="p-1.5">${uiEsc(SALES_ACTION_NAMES[l.action] || l.action)}${l.action === 'KITCHEN_STATUS' && l.details ? ' - ' + uiEsc((SALES_STATION_NAMES[l.details.station] || l.details.station || '') + ': ' + (l.details.to === 'ready' ? 'جاهز' : 'بدأ')) : ''}</td>
        <td class="p-1.5">${uiEsc(l.by || '-')}</td></tr>`).join('');
    salesModal(`
        <div class="flex flex-wrap justify-between items-center gap-2 border-b pb-3 mb-3">
            <h3 class="font-black text-lg text-blue-700">طلب ${uiEsc(o.order_number)} <span class="text-xs bg-slate-100 text-slate-700 px-2 py-1 rounded-lg">${uiEsc(SALES_STATUS_NAMES[o.status] || o.status)}</span></h3>
            <div class="flex gap-2">${uiBtn('طباعة الفاتورة 🖨️', `printOrderReceipt('${o.id}')`, 'gray')}${uiBtn('قفل ✖', "document.getElementById('sales-modal').remove()", 'gray')}</div>
        </div>
        <div class="grid grid-cols-1 md:grid-cols-3 gap-3 text-xs font-bold mb-4">
            <div class="bg-slate-50 rounded-2xl p-3 space-y-1">
                ${line('الفرع', uiEsc(o.branch || ''))}${line('النوع', uiEsc(PRINT_TYPE_NAMES[o.order_type] || o.order_type))}
                ${line('الطاولة', uiEsc(o.table_number || ''))}${line('عدد الضيوف', uiEsc(o.guest_count || ''))}
                ${line('الويتر', uiEsc(o.waiter || ''))}${line('فتحه', uiEsc(o.created_by || ''))}
                ${line('العميل', o.customer ? `${uiEsc(o.customer.name)} - <a class="text-blue-600" href="tel:${uiEsc(o.customer.phone || '')}">${uiEsc(o.customer.phone || '')}</a>` : '')}
                ${line('ملاحظات الطلب', uiEsc(o.notes || ''))}
            </div>
            <div class="bg-slate-50 rounded-2xl p-3 space-y-1">
                ${line('اتفتح', uiEsc(uiDate(o.created_at)))}${line('أول إرسال للمطبخ', salesTime(sent))}
                ${line('آخر صنف جهز', ready ? salesTime(ready) : '<span class="text-amber-600">لسه</span>')}
                ${line('اتقفل', o.closed_at ? uiEsc(uiDate(o.closed_at)) : '<span class="text-amber-600">لسه مفتوح</span>')}
                ${line('من الإرسال للتجهيز', sent && ready ? salesMin(Math.round((new Date(ready) - new Date(sent)) / 6000) / 10) : '')}
                ${line('من الفتح للقفل', o.closed_at ? salesMin(Math.round((new Date(o.closed_at) - new Date(o.created_at)) / 6000) / 10) : '')}
            </div>
            <div class="bg-slate-50 rounded-2xl p-3 space-y-1">
                ${line('المجموع', formatCurrency(o.sub_total))}
                ${Number(o.discount_amount) ? line('الخصم', `${formatCurrency(o.discount_amount)}${o.discount_name ? ' (' + uiEsc(o.discount_name) + ')' : ''}${Number(o.discount_percent) ? ' ' + uiEsc(o.discount_percent) + '%' : ''}`) : ''}
                ${line('الخدمة', o.service_enabled === false ? 'متشالة' : formatCurrency(o.service_charge_amount))}
                ${line('الضريبة', o.vat_enabled === false ? 'متشالة' : formatCurrency(o.tax_amount))}
                <div class="text-base font-black text-blue-700 border-t pt-1">الإجمالي: ${formatCurrency(o.total_amount)}</div>
            </div>
        </div>
        <h4 class="font-black text-sm mb-1">الأصناف <span class="text-[11px] text-slate-400">(حد التأخير: المطبخ ${uiEsc(warn.kitchen)} د، البار ${uiEsc(warn.bar)} د، الشيشة ${uiEsc(warn.shisha)} د)</span></h4>
        <div class="overflow-x-auto mb-4"><table class="w-full text-right"><thead><tr class="text-[11px] text-slate-500">
            <th class="p-2">الصنف</th><th class="p-2">الكمية</th><th class="p-2">السعر</th><th class="p-2">الإجمالي</th><th class="p-2">المكان</th>
            <th class="p-2">اتبعت</th><th class="p-2">بدأ</th><th class="p-2">جهز</th><th class="p-2">اتقدم</th><th class="p-2">الوقت</th></tr></thead><tbody>${itemRows}</tbody></table></div>
        <h4 class="font-black text-sm mb-1">الدفع</h4>
        ${pays ? `<div class="overflow-x-auto mb-4"><table class="w-full text-right"><thead><tr class="text-[11px] text-slate-500"><th class="p-2">الطريقة</th><th class="p-2">المبلغ</th><th class="p-2">إكرامية</th><th class="p-2">الوقت</th><th class="p-2">الكاشير</th></tr></thead><tbody>${pays}</tbody></table></div>` : '<p class="text-xs text-slate-400 font-bold mb-4">لسه مدفعش</p>'}
        <h4 class="font-black text-sm mb-1">مين عمل إيه</h4>
        <div class="overflow-x-auto"><table class="w-full text-right"><tbody>${logs || '<tr><td class="text-xs text-slate-400 p-2">مفيش</td></tr>'}</tbody></table></div>`);
}

// ---------------------------------------------------------------- timing
async function salesRunTiming(box) {
    const res = await uiCall('sales_timing_secure', { p_from: salesState.from, p_to: salesState.to, p_branch_id: salesState.branch || null });
    if (!res) { box.innerHTML = ''; return; }
    salesState.timing = res;
    const st = res.by_station || [];
    const stationCards = st.map(s => `<div class="p-3 rounded-2xl border ${Number(s.late_pct) > 20 ? 'bg-red-50 border-red-200' : 'bg-emerald-50 border-emerald-200'}">
        <p class="font-black text-sm">${uiEsc(SALES_STATION_NAMES[s.station] || s.station)} <span class="text-[11px] text-slate-500">(الحد ${uiEsc(s.limit)} د)</span></p>
        <p class="text-xs font-bold mt-1">متوسط الوقت كله: <b>${salesMin(s.avg_total)}</b> | أطول وقت: ${salesMin(s.max_total)}</p>
        <p class="text-xs font-bold">انتظار لحد ما يبدأ: ${salesMin(s.avg_wait)} | التحضير نفسه: ${salesMin(s.avg_prep)}</p>
        <p class="text-xs font-bold">اتأخر: ${uiEsc(s.late_items)} من ${uiEsc(s.items)} صنف (${uiEsc(s.late_pct)}%)</p></div>`).join('');
    const tbl = (head, rows) => rows.length ? `<div class="overflow-x-auto"><table class="w-full text-right"><thead><tr>${head.map(h => `<th class="p-2 text-[11px] text-white bg-blue-700 font-black">${h}</th>`).join('')}</tr></thead><tbody>${rows.join('')}</tbody></table></div>` : '<p class="text-center text-slate-400 font-bold text-xs py-4">مفيش بيانات</p>';
    const prodRows = (res.by_product || []).map((p, i) => `<tr class="text-xs font-bold ${i % 2 ? 'bg-slate-50' : ''}"><td class="p-2 border-b">${uiEsc(p.product)}</td>
        <td class="p-2 border-b">${uiEsc(SALES_STATION_NAMES[p.station] || p.station)}</td><td class="p-2 border-b">${uiEsc(p.items)}</td>
        <td class="p-2 border-b">${salesMin(p.avg_total)}</td><td class="p-2 border-b">${salesMin(p.max_total)}</td>
        <td class="p-2 border-b ${Number(p.late_pct) > 20 ? 'text-red-600 font-black' : ''}">${uiEsc(p.late_items)} (${uiEsc(p.late_pct)}%)</td></tr>`);
    const hourRows = (res.by_hour || []).map((h, i) => `<tr class="text-xs font-bold ${i % 2 ? 'bg-slate-50' : ''}"><td class="p-2 border-b">${uiEsc(h.hour)}:00</td>
        <td class="p-2 border-b">${uiEsc(h.items)}</td><td class="p-2 border-b">${salesMin(h.avg_total)}</td><td class="p-2 border-b">${uiEsc(h.late_items)}</td></tr>`);
    const lateRows = (res.late_orders || []).map((l, i) => `<tr onclick="salesOpenOrder('${l.order_id}')" class="cursor-pointer text-xs font-bold hover:bg-blue-50 ${i % 2 ? 'bg-slate-50' : ''}">
        <td class="p-2 border-b text-blue-700">${uiEsc(l.order_number)}</td><td class="p-2 border-b">${uiEsc(uiDate(l.created_at))}</td>
        <td class="p-2 border-b">${uiEsc(l.table_number || '-')}</td><td class="p-2 border-b">${uiEsc(l.waiter || '-')}</td>
        <td class="p-2 border-b">${uiEsc(SALES_STATION_NAMES[l.station] || l.station)}</td><td class="p-2 border-b">${uiEsc(l.products)}</td>
        <td class="p-2 border-b text-red-600 font-black">${salesMin(l.minutes)} <span class="text-[10px] text-slate-400">(الحد ${uiEsc(l.limit)})</span></td></tr>`);
    box.innerHTML = `
        <p class="text-[11px] font-bold text-slate-500 mb-2">${uiEsc(res.from)} إلى ${uiEsc(res.to)} | ${uiEsc(res.branch)} | الحساب على الأصناف اللي اتعلّم عليها "جاهز" بس</p>
        <div class="grid grid-cols-1 md:grid-cols-3 gap-2 mb-4">${stationCards || '<p class="text-xs text-slate-400 font-bold">مفيش أصناف اتجهزت في الفترة دي</p>'}</div>
        <h4 class="font-black text-sm mb-1">أبطأ الطلبات (دوس على الطلب لتفاصيله)</h4>
        ${tbl(['الطلب', 'الوقت', 'الطاولة', 'الويتر', 'المكان', 'الأصناف', 'خد'], lateRows)}
        <h4 class="font-black text-sm mb-1 mt-4">كل صنف بياخد قد إيه (الأبطأ الأول)</h4>
        ${tbl(['الصنف', 'المكان', 'عدد مرات', 'المتوسط', 'أطول وقت', 'اتأخر'], prodRows)}
        <h4 class="font-black text-sm mb-1 mt-4">حسب ساعة اليوم</h4>
        ${tbl(['الساعة', 'عدد الأصناف', 'المتوسط', 'اتأخر'], hourRows)}`;
}
