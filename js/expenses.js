// js/expenses.js - المصروفات: تسجيل مصروف، العهد، المصروفات المتكررة، التقرير، البنود
// المدير لحد الحد المسموح (الافتراضي 1000)، وفوقه رقم المالك. الكاشير ممنوع (السيرفر بيمنع).

let expState = { tab: 'new', categories: [], accounts: [], limit: 1000, staff: [] };
function setExpensesTab(tab) { expState.tab = tab; renderExpensesBody(); }

async function loadExpensesScreen() {
    const root = document.getElementById('expenses-root');
    if (!root) return;
    const res = await uiCall('expense_categories_secure', { p_data: null });
    if (!res) { root.innerHTML = ''; return; }
    expState.categories = res.categories || [];
    expState.accounts = res.accounts || [];
    expState.limit = Number(res.limit) || 1000;
    renderExpensesBody();
}

function renderExpensesBody() {
    const root = document.getElementById('expenses-root');
    if (!root) return;
    root.innerHTML = uiTabs('exp', [['new', 'تسجيل مصروف'], ['custody', 'العهد'], ['recurring', 'المصروفات المتكررة'],
        ['report', 'التقرير'], ['categories', 'البنود']], expState.tab, 'setExpensesTab') + '<div id="exp-body"></div>';
    ({ new: expRenderNew, custody: expRenderCustody, recurring: expRenderRecurring, report: expRenderReport, categories: expRenderCategories }[expState.tab] || expRenderNew)();
}

function expCategoryOptions() {
    return uiOptions(expState.categories.filter(c => c.is_active), 'id', c => c.name, 'اختار البند');
}

function expSourceSelect(id) {
    return `<select id="${id}" class="${uiInputClass()}"><option value="main_cash">الخزينة الرئيسية</option><option value="drawer">درج الكاشير (ورديتي)</option><option value="bank">البنك</option></select>`;
}

function expRenderNew() {
    document.getElementById('exp-body').innerHTML = uiCard(`تسجيل مصروف (حد المدير ${formatCurrency(expState.limit)}، وفوقه رقم المالك)`, `
        <div class="grid grid-cols-1 md:grid-cols-3 gap-2 max-w-4xl">
            <select id="exp-cat" class="${uiInputClass()}">${expCategoryOptions()}</select>
            <input id="exp-amount" type="number" min="0" step="0.01" placeholder="المبلغ" class="${uiInputClass()}">
            ${expSourceSelect('exp-source')}
            <input id="exp-desc" type="text" placeholder="الوصف (إجباري)" class="${uiInputClass()} md:col-span-3">
            <input id="exp-ref" type="text" placeholder="رقم الإيصال" class="${uiInputClass()}">
            <input id="exp-vendor" type="text" placeholder="اسم المورد / المحل" class="${uiInputClass()}">
        </div>
        <div class="mt-3">${uiBtn('تسجيل المصروف', 'expSubmit()', 'blue')}</div>`);
}

async function expSubmit(recurringId = null, preset = null) {
    const p = preset || {
        cat: document.getElementById('exp-cat').value, amount: Number(document.getElementById('exp-amount').value),
        source: document.getElementById('exp-source').value, desc: document.getElementById('exp-desc').value.trim(),
        ref: document.getElementById('exp-ref').value, vendor: document.getElementById('exp-vendor').value
    };
    if (!p.cat || !(p.amount > 0) || !p.desc) return showToast('اختار البند واكتب المبلغ والوصف', 'error');
    const res = await uiCall('expense_record_secure', { p_category_id: p.cat, p_amount: round2(p.amount), p_source: p.source, p_description: p.desc,
        p_reference: p.ref || '', p_vendor: p.vendor || '', p_recurring_id: recurringId, p_owner_pin: null }, 'تم تسجيل المصروف', 'p_owner_pin');
    if (res) renderExpensesBody();
}

async function expLoadStaff() {
    if (expState.staff.length) return expState.staff;
    try {
        const { data } = await _supabase.rpc('list_branch_staff', { p_token: staffSessionToken });
        expState.staff = data || [];
    } catch (err) { expState.staff = []; }
    return expState.staff;
}

async function expRenderCustody() {
    const [res, staff] = await Promise.all([uiCall('custody_list_secure', {}), expLoadStaff()]);
    if (!res) return;
    const typeNames = { give: 'صرف عهدة', settle_expense: 'مصروف من العهدة', return: 'رد باقي' };
    document.getElementById('exp-body').innerHTML = uiCard('صرف عهدة لموظف', `
            <div class="flex flex-wrap gap-2">
                <select id="cus-staff" class="${uiInputClass()}">${uiOptions(staff, 'id', s => s.name, 'اختار الموظف')}</select>
                <input id="cus-amount" type="number" min="0" step="0.01" placeholder="المبلغ" class="${uiInputClass()} w-28">
                ${expSourceSelect('cus-source')}
                <input id="cus-notes" type="text" placeholder="الغرض" class="${uiInputClass()}">
                ${uiBtn('صرف العهدة', 'expCustodyGive()', 'amber')}
            </div>`)
        + uiCard('العهد المفتوحة', uiTable(res.balances, [{ label: 'الموظف', key: 'staff' }, { label: 'الرصيد معاه', render: b => formatCurrency(b.balance) },
            { label: '', render: b => uiBtn('تسوية', `expCustodySettle('${b.staff_id}', ${Number(b.balance)})`, 'blue') }], 'مفيش عهد مفتوحة'))
        + uiCard('حركات العهد (آخر 90 يوم)', uiTable(res.entries, [{ label: 'التاريخ', render: e => uiEsc(uiDate(e.at)) }, { label: 'الموظف', key: 'staff' },
            { label: 'النوع', render: e => uiEsc(typeNames[e.type] || e.type) }, { label: 'المبلغ', render: e => formatCurrency(e.amount) },
            { label: 'الرصيد بعدها', render: e => formatCurrency(e.balance_after) }, { label: 'ملاحظة', key: 'notes' }], 'مفيش حركات'));
}

async function expCustodyGive() {
    const staff = document.getElementById('cus-staff').value;
    const amount = Number(document.getElementById('cus-amount').value);
    if (!staff || !(amount > 0)) return showToast('اختار الموظف واكتب المبلغ', 'error');
    const res = await uiCall('custody_give_secure', { p_staff_id: staff, p_amount: round2(amount), p_source: document.getElementById('cus-source').value,
        p_notes: document.getElementById('cus-notes').value, p_owner_pin: null }, 'تم صرف العهدة', 'p_owner_pin');
    if (res) expRenderCustody();
}

async function expCustodySettle(staffId, balance) {
    const lines = [];
    let total = 0;
    alert(`العهدة اللي معاه: ${formatCurrency(balance)}. هتكتب المصروفات واحدة واحدة، ولما تخلص اكتب صفر في المبلغ.`);
    const catList = expState.categories.filter(c => c.is_active);
    while (true) {
        const amt = uiAskAmount(`مصروف رقم ${lines.length + 1}: المبلغ (صفر = خلصت). المتبقي ${formatCurrency(balance - total)}:`, '0');
        if (amt === null) return;
        if (amt === 0) break;
        const pick = prompt('البند:\n' + catList.map((c, i) => `${i + 1}. ${c.name}`).join('\n'), '1');
        const cat = catList[parseInt(pick, 10) - 1];
        if (!cat) return showToast('بند غير صحيح', 'error');
        const desc = prompt('وصف المصروف / رقم الإيصال:');
        if (!desc) return;
        lines.push({ category_id: cat.id, amount: amt, description: desc });
        total = round2(total + amt);
    }
    const returned = uiAskAmount(`الفلوس اللي رجعها (الباقي المتوقع ${formatCurrency(balance - total)}):`, String(round2(balance - total)));
    if (returned === null) return;
    let returnTo = 'main_cash';
    if (returned > 0) {
        returnTo = uiPickBox('الفلوس الراجعة هتدخل فين؟', ['main_cash', 'drawer']);
        if (!returnTo) return;
    }
    const res = await uiCall('custody_settle_secure', { p_staff_id: staffId, p_lines: lines, p_returned_cash: returned, p_return_to: returnTo });
    if (res) { showToast(`تمت التسوية. الباقي معاه: ${formatCurrency(res.balance)}`); expRenderCustody(); }
}

async function expRenderRecurring() {
    const res = await uiCall('recurring_secure', { p_data: null });
    if (!res) return;
    expState.recurring = res.items || [];
    const due = expState.recurring.filter(r => r.due);
    document.getElementById('exp-body').innerHTML =
        (due.length ? `<div class="bg-amber-50 border border-amber-200 text-amber-800 p-3 rounded-xl text-xs font-black mb-3">🔔 ${due.length} مصروف مستحق الشهر ده</div>` : '')
        + uiCard('المصروفات المتكررة', uiTable(expState.recurring, [
            { label: 'الوصف', key: 'description' }, { label: 'البند', key: 'category' }, { label: 'المبلغ', render: r => formatCurrency(r.amount) },
            { label: 'يوم الشهر', key: 'day_of_month' }, { label: 'آخر صرف', render: r => uiEsc(r.last_period || '-') },
            { label: 'الحالة', render: r => r.due ? '<b class="text-amber-600">مستحق</b>' : (r.is_active ? 'مش مستحق دلوقتي' : 'موقوف') },
            { label: '', render: r => '<div class="flex flex-wrap gap-1">' + (r.due ? uiBtn('صرف', `expPayRecurring('${r.id}')`, 'green') : '')
                + uiBtn('تعديل', `expEditRecurring('${r.id}')`, 'gray') + '</div>' }], 'مفيش مصروفات متكررة'),
            uiBtn('إضافة مصروف متكرر', 'expEditRecurring(null)', 'blue'));
}

async function expEditRecurring(id) {
    const r = id ? expState.recurring.find(x => x.id === id) : {};
    const catList = expState.categories.filter(c => c.is_active);
    const desc = prompt('الوصف (مثلاً: إيجار المحل):', r.description || '');
    if (!desc) return;
    const pick = prompt('البند:\n' + catList.map((c, i) => `${i + 1}. ${c.name}`).join('\n'),
        String(Math.max(1, catList.findIndex(c => c.id === r.category_id) + 1)));
    const cat = catList[parseInt(pick, 10) - 1];
    if (!cat) return showToast('بند غير صحيح', 'error');
    const amount = uiAskAmount('المبلغ الشهري:', String(r.amount || ''));
    if (!amount) return;
    const day = prompt('يوم الاستحقاق في الشهر (1 لـ 28):', String(r.day_of_month || 1));
    if (!day) return;
    const active = id ? confirm('شغال؟ (إلغاء = إيقافه)') : true;
    if (await uiCall('recurring_secure', { p_data: { id: id || null, description: desc, category_id: cat.id, amount: String(amount), day_of_month: String(day), is_active: String(active) } }, 'تم الحفظ')) expRenderRecurring();
}

async function expPayRecurring(id) {
    const r = expState.recurring.find(x => x.id === id);
    if (!r) return;
    const amount = uiAskAmount(`صرف "${r.description}". المبلغ:`, String(r.amount));
    if (!amount) return;
    const source = uiPickBox('الفلوس طالعة منين؟', ['main_cash', 'bank', 'drawer']);
    if (!source) return;
    await expSubmit(id, { cat: r.category_id, amount, source, desc: r.description, ref: '', vendor: '' });
    expState.tab = 'recurring';
    renderExpensesBody();
}

async function expRenderReport() {
    const from = document.getElementById('exp-rep-from')?.value || uiToday(-30);
    const to = document.getElementById('exp-rep-to')?.value || uiToday();
    document.getElementById('exp-body').innerHTML = uiCard('تقرير المصروفات', `
        <div class="flex flex-wrap gap-2 mb-3"><input id="exp-rep-from" type="date" value="${uiEsc(from)}" class="${uiInputClass()}">
        <input id="exp-rep-to" type="date" value="${uiEsc(to)}" class="${uiInputClass()}">${uiBtn('عرض', 'expRenderReport()', 'gray')}</div>
        <div id="exp-rep-body"></div>`);
    const res = await uiCall('expenses_report_secure', { p_from: from, p_to: to });
    if (!res) return;
    const total = (res.by_category || []).reduce((s, x) => s + Number(x.total || 0), 0);
    const sources = { drawer: 'الدرج', main_cash: 'الخزينة', bank: 'البنك', custody: 'عهدة' };
    document.getElementById('exp-rep-body').innerHTML = `<p class="text-xs font-black mb-2">الإجمالي: ${formatCurrency(total)}</p>`
        + uiTable(res.by_category, [{ label: 'البند', key: 'category' }, { label: 'الفرع', key: 'branch' }, { label: 'الإجمالي', render: x => formatCurrency(x.total) }], 'مفيش مصروفات')
        + '<h4 class="font-black text-xs mt-3 mb-1">التفاصيل</h4>'
        + uiTable(res.items, [{ label: 'التاريخ', render: x => uiEsc(uiDate(x.at)) }, { label: 'البند', key: 'category' },
            { label: 'المبلغ', render: x => formatCurrency(x.amount) }, { label: 'من', render: x => uiEsc(sources[x.source] || x.source || '') },
            { label: 'الوصف', key: 'description' }, { label: 'إيصال', key: 'reference' }, { label: 'بواسطة', key: 'by' }], 'مفيش');
}

function expRenderCategories() {
    document.getElementById('exp-body').innerHTML = uiCard('بنود المصروفات', uiTable(expState.categories, [
        { label: 'البند', key: 'name' }, { label: 'الحساب', key: 'account' }, { label: 'الحالة', render: c => c.is_active ? 'شغال' : 'موقوف' },
        { label: '', render: c => uiBtn('تعديل', `expEditCategory('${c.id}')`, 'gray') }]), uiBtn('إضافة بند', 'expEditCategory(null)', 'blue'));
}

async function expEditCategory(id) {
    const c = id ? expState.categories.find(x => x.id === id) : {};
    const name = prompt('اسم البند:', c.name || '');
    if (!name) return;
    const pick = prompt('الحساب في دليل الحسابات:\n' + expState.accounts.map((a, i) => `${i + 1}. ${a.name}`).join('\n'),
        String(Math.max(1, expState.accounts.findIndex(a => a.id === c.account_id) + 1)));
    const acc = expState.accounts[parseInt(pick, 10) - 1];
    if (!acc) return showToast('حساب غير صحيح', 'error');
    const active = id ? confirm('البند شغال؟ (إلغاء = إيقافه)') : true;
    const res = await uiCall('expense_categories_secure', { p_data: { id: id || null, name, account_id: acc.id, is_active: String(active) } }, 'تم الحفظ');
    if (res) { expState.categories = res.categories || []; expRenderCategories(); }
}
