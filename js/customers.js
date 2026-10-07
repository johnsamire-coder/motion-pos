// js/customers.js - شاشة العملاء: البحث، صفحة كل عميل (طلباته وأكتر حاجة بيطلبها)، والمتابعة (كلمته وقلتله إيه، وإمتى تكلمه تاني)
// رقم الموبايل ميتكررش. الآجل للمدير والحسابات بس.

const CUST_TYPE_NAMES = { cash: 'كاش', registered: 'متسجّل', on_account: 'آجل' };
let custState = { search: '', filter: 'all', list: [], today: null, canCredit: false, profile: null, due: [] };

async function loadCustomersScreen() {
    const root = document.getElementById('customers-root');
    if (!root) return;
    const filters = [['all', 'الكل'], ['due', '📞 متابعات النهارده'], ['inactive', '😴 مجوش من ٣٠ يوم'], ['birthday', '🎂 عيد ميلادهم الشهر ده']];
    root.innerHTML = `<div id="cust-due"></div>` + uiCard('العملاء', `
        <div class="flex flex-wrap items-end gap-2 mb-3">
            <input id="cust-search" value="${uiEsc(custState.search)}" placeholder="دوّر بالاسم أو الموبايل" onkeydown="if(event.key==='Enter')custSearch()" class="${uiInputClass()} w-64">
            ${uiBtn('بحث 🔍', 'custSearch()', 'blue')}
        </div>
        <div class="flex flex-wrap gap-1.5 mb-3">${filters.map(([k, l]) => `<button onclick="custSetFilter('${k}')" class="px-3 py-1.5 rounded-xl text-xs font-black ${k === custState.filter ? 'bg-blue-600 text-white' : 'bg-slate-100 text-slate-600'}">${uiEsc(l)}</button>`).join('')}</div>
        <div id="cust-list"></div>`, uiBtn('عميل جديد ➕', 'custEdit(null)', 'green'));
    custLoadDue();
    custLoadList();
}

function custSearch() { custState.search = document.getElementById('cust-search').value.trim(); custLoadList(); }
function custSetFilter(f) { custState.filter = f; custState.search = document.getElementById('cust-search')?.value.trim() || ''; loadCustomersScreen(); }

async function custLoadDue() {
    const box = document.getElementById('cust-due');
    if (!box) return;
    const res = await uiCall('customer_followup_secure', { p_action: 'due', p_data: null });
    if (!res) return;
    custState.due = res.followups || [];
    if (!custState.due.length) { box.innerHTML = ''; return; }
    box.innerHTML = uiCard(`📞 متابعات (لحد ٧ أيام قدام): ${custState.due.length}`, uiTable(custState.due, [
        { label: 'الميعاد', render: f => `<span class="${f.next_date <= res.today ? 'text-red-600 font-black' : ''}">${uiEsc(f.next_date)}${f.next_date < res.today ? ' (فات)' : (f.next_date === res.today ? ' (النهارده)' : '')}</span>` },
        { label: 'العميل', render: f => `<button class="text-blue-700 underline" onclick="custOpen('${f.customer_id}')">${uiEsc(f.name)}</button>` },
        { label: 'الموبايل', render: f => custPhoneLinks(f.phone) },
        { label: 'آخر ملاحظة', key: 'note' }, { label: 'بواسطة', key: 'by' },
        { label: '', render: f => uiBtn('سجّل مكالمة', `custOpen('${f.customer_id}')`, 'blue') + ' ' + uiBtn('خلصت', `custFollowDone('${f.id}')`, 'gray') }]));
}

function custPhoneLinks(phone) {
    if (!phone) return '-';
    const wa = String(phone).replace(/^0/, '20');
    return `<span class="whitespace-nowrap"><a class="text-blue-600" href="tel:${uiEsc(phone)}">${uiEsc(phone)}</a> <a class="text-emerald-600" target="_blank" rel="noopener" href="https://wa.me/${uiEsc(wa)}" title="واتساب">💬</a></span>`;
}

async function custLoadList() {
    const box = document.getElementById('cust-list');
    if (!box) return;
    box.innerHTML = '<p class="text-xs text-slate-400 font-bold">جاري التحميل...</p>';
    const res = await uiCall('customers_list2_secure', { p_search: custState.search || null, p_filter: custState.filter });
    if (!res) { box.innerHTML = ''; return; }
    custState.list = res.customers || [];
    custState.today = res.today;
    custState.canCredit = !!res.can_credit;
    box.innerHTML = `<p class="text-[11px] text-slate-500 font-bold mb-2">${custState.list.length} عميل${custState.list.length >= 1000 ? ' (أول ١٠٠٠، دوّر بالاسم أو الرقم)' : ''}</p>` + uiTable(custState.list, [
        { label: 'الاسم', render: c => `<button class="text-blue-700 font-black underline" onclick="custOpen('${c.id}')">${uiEsc(c.name)}</button>${c.customer_type === 'on_account' ? ' <span class="text-[10px] bg-amber-100 text-amber-700 px-1.5 rounded">آجل</span>' : ''}` },
        { label: 'الموبايل', render: c => custPhoneLinks(c.phone) },
        { label: 'الطلبات', key: 'orders_count' },
        { label: 'صرف', render: c => formatCurrency(c.total_spent) },
        { label: 'آخر زيارة', render: c => c.last_visit ? uiEsc(uiDate(c.last_visit)) : '-' },
        { label: 'المتابعة الجاية', render: c => c.next_followup ? `<span class="${c.next_followup <= custState.today ? 'text-red-600 font-black' : ''}">${uiEsc(c.next_followup)}</span>` : '-' },
        { label: 'عليه (آجل)', render: c => Number(c.balance) ? `<span class="text-red-600">${formatCurrency(c.balance)}</span>` : '-' }
    ], 'مفيش عملاء');
}

// ---------------------------------------------------------------- one customer
function custModal(html) {
    let m = document.getElementById('cust-modal');
    if (!m) {
        m = document.createElement('div');
        m.id = 'cust-modal';
        m.className = 'fixed inset-0 bg-slate-900/60 z-50 flex items-start justify-center p-4 overflow-y-auto';
        m.onclick = e => { if (e.target === m) custCloseModal(); };
        document.body.appendChild(m);
    }
    m.innerHTML = `<div class="bg-white rounded-3xl shadow-2xl w-full max-w-3xl p-5 my-6 text-right" dir="rtl">${html}</div>`;
}
function custCloseModal() { const m = document.getElementById('cust-modal'); if (m) m.remove(); }

async function custOpen(id) {
    const res = await uiCall('customer_profile_secure', { p_customer_id: id });
    if (!res) return;
    custState.profile = res;
    custState.canCredit = !!res.can_credit;
    const c = res.customer, s = res.stats || {};
    const canSales = typeof canOpenTab === 'function' && canOpenTab('sales');
    const stat = (label, value) => `<div class="bg-slate-50 rounded-xl p-2"><p class="text-[10px] text-slate-400 font-bold">${uiEsc(label)}</p><p class="text-sm font-black">${value}</p></div>`;
    const follow = (res.followups || []).map(f => `<div class="border-b py-1.5 text-xs font-bold">
        <div class="flex justify-between gap-2"><span>${uiEsc(f.note)}</span><span class="text-[10px] text-slate-400 whitespace-nowrap">${uiEsc(uiDate(f.created_at))} - ${uiEsc(f.by || '')}</span></div>
        ${f.next_date ? `<div class="text-[11px] ${f.done_at ? 'text-slate-400' : 'text-blue-700'}">📅 المكالمة الجاية: ${uiEsc(f.next_date)}${f.done_at ? ' (خلصت)' : ` ${uiBtn('خلصت', `custFollowDone('${f.id}', '${c.id}')`, 'gray')}`}</div>` : ''}</div>`).join('');
    const orders = (res.orders || []).map(o => `<tr class="border-b text-xs font-bold ${canSales ? 'cursor-pointer hover:bg-blue-50' : ''}" ${canSales ? `onclick="salesOpenOrder('${o.id}')"` : ''}>
        <td class="p-1.5 text-blue-700">${uiEsc(o.order_number)}</td><td class="p-1.5">${uiEsc(uiDate(o.created_at))}</td>
        <td class="p-1.5">${uiEsc(PRINT_TYPE_NAMES[o.order_type] || o.order_type)}</td><td class="p-1.5">${formatCurrency(o.total_amount)}</td>
        <td class="p-1.5">${uiEsc((typeof SALES_STATUS_NAMES !== 'undefined' && SALES_STATUS_NAMES[o.status]) || o.status)}</td><td class="p-1.5">${uiEsc(o.branch || '')}</td></tr>`).join('');
    custModal(`
        <div class="flex flex-wrap justify-between items-start gap-2 border-b pb-3 mb-3">
            <div><h3 class="font-black text-lg">${uiEsc(c.name)} <span class="text-[11px] bg-slate-100 px-2 py-0.5 rounded-lg">${uiEsc(CUST_TYPE_NAMES[c.customer_type] || c.customer_type)}</span></h3>
                <div class="text-xs font-bold mt-1">${custPhoneLinks(c.phone)}${c.address ? ' | ' + uiEsc(c.address) : ''}${c.birthday ? ' | 🎂 ' + uiEsc(c.birthday) : ''}</div>
                ${c.notes ? `<div class="text-[11px] text-amber-700 font-bold mt-1">📝 ${uiEsc(c.notes)}</div>` : ''}
                <div class="text-[10px] text-slate-400 font-bold mt-1">اتسجّل ${uiEsc(uiDate(c.created_at))}${c.created_by ? ' بواسطة ' + uiEsc(c.created_by) : ''}</div></div>
            <div class="flex gap-2">${uiBtn('تعديل ✏️', `custEdit('${c.id}')`, 'gray')}${uiBtn('قفل ✖', 'custCloseModal()', 'gray')}</div>
        </div>
        <div class="grid grid-cols-2 md:grid-cols-6 gap-2 mb-4">
            ${stat('عدد الطلبات', uiEsc(s.orders_count || 0))}${stat('إجمالي اللي صرفه', formatCurrency(s.total_spent))}${stat('متوسط الفاتورة', formatCurrency(s.avg_ticket))}
            ${stat('أول زيارة', s.first_visit ? uiEsc(uiDate(s.first_visit)) : '-')}${stat('آخر زيارة', s.last_visit ? uiEsc(uiDate(s.last_visit)) : '-')}
            ${stat('عليه (آجل)', Number(s.balance) ? `<span class="text-red-600">${formatCurrency(s.balance)}</span>` : '-')}
        </div>
        ${(res.favorites || []).length ? `<p class="text-xs font-black mb-1">أكتر حاجة بيطلبها:</p><div class="flex flex-wrap gap-1 mb-4">${res.favorites.map(f => `<span class="bg-blue-50 text-blue-800 border border-blue-200 rounded-lg px-2 py-1 text-[11px] font-bold">${uiEsc(f.name)} ×${uiEsc(f.quantity)}</span>`).join('')}</div>` : ''}
        <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
            <div>
                <h4 class="font-black text-sm mb-2">المتابعة</h4>
                <textarea id="cust-fu-note" rows="2" placeholder="كلمته وقلتله إيه / قالك إيه" class="${uiInputClass()} w-full"></textarea>
                <div class="flex flex-wrap items-center gap-2 mt-1 text-xs font-bold">
                    <label>أكلمه تاني يوم <input id="cust-fu-date" type="date" class="${uiInputClass()}"></label>
                    ${uiBtn('+٣ أيام', "custFuQuick(3)", 'gray')}${uiBtn('+أسبوع', "custFuQuick(7)", 'gray')}${uiBtn('+شهر', "custFuQuick(30)", 'gray')}
                    ${uiBtn('حفظ', `custFollowAdd('${c.id}')`, 'green')}
                </div>
                <div class="mt-2 max-h-64 overflow-y-auto">${follow || '<p class="text-xs text-slate-400 font-bold py-2">مفيش متابعات لسه</p>'}</div>
            </div>
            <div>
                <h4 class="font-black text-sm mb-2">آخر الطلبات${canSales ? ' <span class="text-[10px] text-slate-400">(دوس على الطلب لتفاصيله)</span>' : ''}</h4>
                <div class="max-h-80 overflow-y-auto"><table class="w-full text-right"><tbody>${orders || '<tr><td class="text-xs text-slate-400 p-2">مطلبش حاجة لسه</td></tr>'}</tbody></table></div>
            </div>
        </div>`);
}

function custFuQuick(days) {
    const el = document.getElementById('cust-fu-date');
    if (el) el.value = uiToday(days);
}

async function custFollowAdd(customerId) {
    const note = document.getElementById('cust-fu-note').value.trim();
    const next = document.getElementById('cust-fu-date').value;
    if (!note) return showToast('اكتب الملاحظة الأول', 'error');
    if (await uiCall('customer_followup_secure', { p_action: 'add', p_data: { customer_id: customerId, note, next_date: next || null } }, 'تم الحفظ')) {
        custOpen(customerId);
        custLoadDue();
        custLoadList();
    }
}

async function custFollowDone(id, reopenCustomer) {
    if (await uiCall('customer_followup_secure', { p_action: 'done', p_data: { id } }, 'تم')) {
        custLoadDue();
        custLoadList();
        if (reopenCustomer) custOpen(reopenCustomer);
    }
}

// ---------------------------------------------------------------- add / edit
function custEdit(id) {
    const c = id ? ((custState.profile && custState.profile.customer && custState.profile.customer.id === id) ? custState.profile.customer
        : custState.list.find(x => x.id === id)) || {} : {};
    const credit = custState.canCredit ? `
        <div class="grid grid-cols-2 gap-2 border-t pt-2 mt-2">
            <label class="text-xs font-bold">النوع<br><select id="cust-e-type" class="${uiInputClass()} w-full">${Object.entries(CUST_TYPE_NAMES).map(([k, l]) => `<option value="${k}" ${(c.customer_type || 'registered') === k ? 'selected' : ''}>${l}</option>`).join('')}</select></label>
            <label class="text-xs font-bold">حد الآجل<br><input id="cust-e-limit" type="number" min="0" value="${uiEsc(c.credit_limit || 0)}" class="${uiInputClass()} w-full"></label>
        </div>` : '<p class="text-[11px] text-slate-400 font-bold mt-2">الآجل بيتحدد من المدير أو الحسابات.</p>';
    custModal(`
        <h3 class="font-black text-base mb-3">${id ? 'تعديل عميل' : 'عميل جديد'}</h3>
        <div class="grid grid-cols-1 md:grid-cols-2 gap-2">
            <label class="text-xs font-bold">الاسم *<br><input id="cust-e-name" value="${uiEsc(c.name || '')}" class="${uiInputClass()} w-full"></label>
            <label class="text-xs font-bold">الموبايل *<br><input id="cust-e-phone" type="tel" value="${uiEsc(c.phone || '')}" class="${uiInputClass()} w-full"></label>
            <label class="text-xs font-bold">العنوان / المنطقة<br><input id="cust-e-address" value="${uiEsc(c.address || '')}" class="${uiInputClass()} w-full"></label>
            <label class="text-xs font-bold">تاريخ الميلاد<br><input id="cust-e-birthday" type="date" value="${uiEsc(c.birthday || '')}" class="${uiInputClass()} w-full"></label>
        </div>
        <label class="text-xs font-bold block mt-2">ملاحظات ثابتة (بيحب إيه، حساسية من حاجة...)<br><textarea id="cust-e-notes" rows="2" class="${uiInputClass()} w-full">${uiEsc(c.notes || '')}</textarea></label>
        ${credit}
        <div class="flex gap-2 mt-4">${uiBtn('حفظ', `custSave(${id ? `'${id}'` : 'null'})`, 'green')}${uiBtn('إلغاء', id ? `custOpen('${id}')` : 'custCloseModal()', 'gray')}</div>`);
}

async function custSave(id) {
    const data = {
        id: id || null,
        name: document.getElementById('cust-e-name').value.trim(),
        phone: document.getElementById('cust-e-phone').value.trim(),
        address: document.getElementById('cust-e-address').value.trim(),
        birthday: document.getElementById('cust-e-birthday').value || null,
        notes: document.getElementById('cust-e-notes').value.trim()
    };
    if (custState.canCredit && document.getElementById('cust-e-type')) {
        data.customer_type = document.getElementById('cust-e-type').value;
        data.credit_limit = String(Number(document.getElementById('cust-e-limit').value) || 0);
    }
    if (!data.name || !data.phone) return showToast('الاسم والموبايل لازم يتكتبوا', 'error');
    try {
        const res = await serverRpc('customer_save2_secure', { p_data: data });
        if (!res || res.ok === false) {
            if (res && res.reason === 'phone_taken' && res.customer) {
                if (confirm(`الرقم ده متسجل باسم "${res.customer.name}". تفتح صفحته؟`)) custOpen(res.customer.id);
                return;
            }
            return showToast(serverReasonMessage(res, 'تعذر الحفظ'), 'error');
        }
        showToast('تم الحفظ');
        custLoadList();
        custOpen(res.id);
    } catch (err) {
        showToast(err.message || 'تعذر الحفظ', 'error');
    }
}
