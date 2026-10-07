// js/accounting.js - الحسابات: الدليل، القيود، القيد اليدوي، الأرباح والخسائر، الميزانية، دفتر الأستاذ، ميزان المراجعة، الفترات، العملاء
// كل حاجة من السيرفر. القيد اليدوي للمدير والمالك ولازم يكون متوازن. العكس للقيود اليدوية بس. قفل الفترات للمالك.

let accState = { tab: 'journal', accounts: [], branches: [], manualLines: [], customers: [] };
const ACC_TYPE_NAMES = { asset: 'أصول', liability: 'خصوم', equity: 'حقوق ملكية', revenue: 'إيرادات', cogs: 'تكلفة', expense: 'مصروفات' };
const JE_TYPE_NAMES = { sales: 'مبيعات', purchase: 'مشتريات', payment: 'دفع', receipt: 'تحصيل', expense: 'مصروف', inventory: 'مخزون', adjustment: 'تسوية', manual: 'يدوي', tax: 'ضرايب' };

function setAccTab(tab) { accState.tab = tab; renderAccounting(); }

async function initAccountingModule() {
    const res = await uiCall('accounts_list_secure', {});
    accState.accounts = (res && res.accounts) || [];
    if (String(currentUser?.roles?.name || '') === 'owner' && !accState.branches.length) {
        const { data } = await _supabase.from('branches').select('id, name').order('name');
        accState.branches = data || [];
    }
    renderAccounting();
}

function accBranchSelect(id) {
    if (String(currentUser?.roles?.name || '') !== 'owner') return '';
    return `<select id="${id}" class="${uiInputClass()}"><option value="">كل الفروع</option>${accState.branches.map(b => `<option value="${uiEsc(b.id)}">${uiEsc(b.name)}</option>`).join('')}</select>`;
}

function accRange(prefix, fromDefault) {
    return `<input id="${prefix}-from" type="date" value="${uiEsc(document.getElementById(prefix + '-from')?.value || fromDefault)}" class="${uiInputClass()}">
            <input id="${prefix}-to" type="date" value="${uiEsc(document.getElementById(prefix + '-to')?.value || uiToday())}" class="${uiInputClass()}">`;
}

function renderAccounting() {
    const root = document.getElementById('view-accounting-workspace');
    if (!root) return;
    root.innerHTML = uiTabs('acc', [['journal', 'القيود'], ['manual', 'قيد يدوي'], ['pnl', 'الأرباح والخسائر'], ['bs', 'الميزانية'],
        ['gl', 'دفتر الأستاذ'], ['tb', 'ميزان المراجعة'], ['coa', 'دليل الحسابات'], ['periods', 'الفترات'], ['customers', 'العملاء'],
        ['expense', 'تسجيل مصروف']], accState.tab, 'setAccTab') + '<div id="acc-body"></div>';
    ({ journal: accJournal, manual: accManual, pnl: accPnl, bs: accBs, gl: accGl, tb: accTb, coa: accCoa, periods: accPeriods,
        customers: accCustomers, expense: accExpense }[accState.tab] || accJournal)();
}

async function accJournal() {
    const body = document.getElementById('acc-body');
    body.innerHTML = uiCard('دفتر القيود اليومية', `
        <div class="flex flex-wrap gap-2 mb-3">${accRange('accj', uiToday(-30))}${accBranchSelect('accj-branch')}
            <select id="accj-type" class="${uiInputClass()}"><option value="">كل الأنواع</option>${Object.entries(JE_TYPE_NAMES).map(([k, v]) => `<option value="${k}">${v}</option>`).join('')}</select>
            <input id="accj-search" type="text" placeholder="بحث بالوصف أو الرقم" class="${uiInputClass()}">${uiBtn('عرض', 'accJournalLoad()', 'gray')}</div>
        <div id="accj-table"></div><div id="accj-entry"></div>`);
    accJournalLoad();
}

async function accJournalLoad() {
    const res = await uiCall('journal_list_secure', { p_from: document.getElementById('accj-from').value, p_to: document.getElementById('accj-to').value,
        p_branch_id: document.getElementById('accj-branch')?.value || null, p_type: document.getElementById('accj-type').value || null,
        p_search: document.getElementById('accj-search').value || null });
    if (!res) return;
    accState.lastJournal = { title: 'دفتر القيود اليومية', from: document.getElementById('accj-from').value, to: document.getElementById('accj-to').value, branch: '',
        columns: [{ key: 'entry_number', label: 'الرقم', type: 't' }, { key: 'entry_date', label: 'التاريخ', type: 't' }, { key: 'type', label: 'النوع', type: 't' },
            { key: 'description', label: 'الوصف', type: 't' }, { key: 'total', label: 'المبلغ', type: 'm' }, { key: 'status', label: 'الحالة', type: 't' }],
        rows: (res.entries || []).map(e => ({ ...e, type: JE_TYPE_NAMES[e.journal_type] || e.journal_type, status: e.status === 'reversed' ? 'معكوس' : 'مرحّل' })) };
    document.getElementById('accj-table').innerHTML = `<div class="flex gap-2 mb-2">${uiBtn('Excel', 'exportReportExcel(accState.lastJournal)', 'green')}${uiBtn('PDF', 'printReportPdf(accState.lastJournal)', 'red')}</div>`
        + uiTable(res.entries, [{ label: 'الرقم', key: 'entry_number' }, { label: 'التاريخ', key: 'entry_date' },
            { label: 'النوع', render: e => uiEsc(JE_TYPE_NAMES[e.journal_type] || e.journal_type) }, { label: 'الوصف', key: 'description' },
            { label: 'الفرع', key: 'branch' }, { label: 'المبلغ', render: e => formatCurrency(e.total) },
            { label: 'الحالة', render: e => e.status === 'reversed' ? '<span class="text-red-600">معكوس</span>' : 'مرحّل' },
            { label: '', render: e => uiBtn('تفاصيل', `accShowEntry('${e.id}')`, 'gray') }], 'مفيش قيود');
}

async function accShowEntry(id) {
    const res = await uiCall('journal_get_secure', { p_id: id });
    if (!res) return;
    const e = res.entry;
    const td = (e.lines || []).reduce((s, l) => s + Number(l.debit), 0);
    const tc = (e.lines || []).reduce((s, l) => s + Number(l.credit), 0);
    document.getElementById('accj-entry').innerHTML = uiCard(`قيد ${e.entry_number} - ${e.entry_date}`, `
        <p class="text-xs font-bold mb-2">${uiEsc(e.description)} | ${uiEsc(JE_TYPE_NAMES[e.journal_type] || e.journal_type)} | ${uiEsc(e.branch || '')} | ${uiEsc(e.created_by || '')}</p>
        ${uiTable(e.lines, [{ label: 'الكود', key: 'code' }, { label: 'الحساب', key: 'account' }, { label: 'مدين', render: l => Number(l.debit) ? formatCurrency(l.debit) : '' },
            { label: 'دائن', render: l => Number(l.credit) ? formatCurrency(l.credit) : '' }, { label: 'البيان', key: 'description' }])}
        <p class="text-xs font-black mt-2">الإجمالي: مدين ${formatCurrency(td)} | دائن ${formatCurrency(tc)}</p>`,
        e.status === 'posted' && e.reference_type === 'manual' ? uiBtn('عكس القيد', `accReverse('${e.id}')`, 'red') : '');
}

async function accReverse(id) {
    const v = await uiForm('عكس القيد', [{ key: 'reason', label: 'السبب', required: true }, { key: 'pin', label: 'رقم المدير', type: 'pin', required: true }], { ok: 'عكس القيد', danger: true });
    if (!v) return;
    if (await uiCall('journal_reverse_secure', { p_id: id, p_reason: v.reason, p_manager_pin: v.pin }, 'تم عكس القيد بقيد عكسي')) accJournalLoad();
}

function accAccountOptions() {
    return uiOptions(accState.accounts, 'id', a => `${a.code} - ${a.name}`, 'اختار الحساب');
}

function accManual() {
    if (!accState.manualLines.length) accState.manualLines = [{ account_id: '', debit: '', credit: '', description: '' }, { account_id: '', debit: '', credit: '', description: '' }];
    const rows = accState.manualLines.map((l, i) => `<tr>
        <td class="p-1"><select data-ml="${i}" data-f="account_id" class="${uiInputClass()} w-full">${accAccountOptions()}</select></td>
        <td class="p-1"><input data-ml="${i}" data-f="debit" type="number" min="0" step="0.01" value="${uiEsc(l.debit)}" class="${uiInputClass()} w-28"></td>
        <td class="p-1"><input data-ml="${i}" data-f="credit" type="number" min="0" step="0.01" value="${uiEsc(l.credit)}" class="${uiInputClass()} w-28"></td>
        <td class="p-1"><input data-ml="${i}" data-f="description" type="text" value="${uiEsc(l.description)}" class="${uiInputClass()} w-full"></td>
        <td class="p-1">${uiBtn('✕', `accManualRemove(${i})`, 'gray')}</td></tr>`).join('');
    document.getElementById('acc-body').innerHTML = uiCard('قيد يدوي (للمدير والمالك، ولازم يكون متوازن)', `
        <div class="flex flex-wrap gap-2 mb-3"><input id="accm-date" type="date" value="${uiToday()}" class="${uiInputClass()}">
            <input id="accm-desc" type="text" placeholder="وصف القيد (إجباري)" class="${uiInputClass()} flex-1">${accBranchSelect('accm-branch')}</div>
        <div class="overflow-x-auto"><table class="w-full text-right"><thead><tr class="text-[11px] text-slate-500"><th>الحساب</th><th>مدين</th><th>دائن</th><th>البيان</th><th></th></tr></thead><tbody>${rows}</tbody></table></div>
        <p id="accm-totals" class="text-xs font-black my-2"></p>
        <div class="flex gap-2">${uiBtn('سطر جديد', 'accManualAdd()', 'gray')}${uiBtn('حفظ القيد', 'accManualSave()', 'blue')}</div>`);
    document.querySelectorAll('[data-ml]').forEach(el => {
        const l = accState.manualLines[el.dataset.ml];
        el.value = l[el.dataset.f] ?? '';
        el.oninput = el.onchange = () => { l[el.dataset.f] = el.value; accManualTotals(); };
    });
    accManualTotals();
}

function accManualTotals() {
    const d = round2(accState.manualLines.reduce((s, l) => s + (Number(l.debit) || 0), 0));
    const c = round2(accState.manualLines.reduce((s, l) => s + (Number(l.credit) || 0), 0));
    const el = document.getElementById('accm-totals');
    if (el) el.innerHTML = `مدين ${formatCurrency(d)} | دائن ${formatCurrency(c)} ${d === c && d > 0 ? '<span class="text-emerald-600">✅ متوازن</span>' : '<span class="text-red-600">❌ مش متوازن</span>'}`;
}
function accManualAdd() { accState.manualLines.push({ account_id: '', debit: '', credit: '', description: '' }); accManual(); }
function accManualRemove(i) { if (accState.manualLines.length > 2) { accState.manualLines.splice(i, 1); accManual(); } }

async function accManualSave() {
    const lines = accState.manualLines.filter(l => l.account_id && (Number(l.debit) > 0 || Number(l.credit) > 0))
        .map(l => ({ account_id: l.account_id, debit: round2(Number(l.debit) || 0), credit: round2(Number(l.credit) || 0), description: l.description }));
    const res = await uiCall('journal_manual_secure', { p_date: document.getElementById('accm-date').value, p_description: document.getElementById('accm-desc').value,
        p_lines: lines, p_branch_id: document.getElementById('accm-branch')?.value || null }, 'تم حفظ القيد');
    if (res) { accState.manualLines = []; setAccTab('journal'); }
}

async function accPnl() {
    const body = document.getElementById('acc-body');
    body.innerHTML = uiCard('الأرباح والخسائر', `<div class="flex flex-wrap gap-2 mb-3">${accRange('accp', uiToday().slice(0, 8) + '01')}${accBranchSelect('accp-branch')}${uiBtn('عرض', 'accPnlLoad()', 'gray')}</div><div id="accp-body"></div>`);
    accPnlLoad();
}

async function accPnlLoad() {
    const res = await uiCall('pnl_secure', { p_from: document.getElementById('accp-from').value, p_to: document.getElementById('accp-to').value, p_branch_id: document.getElementById('accp-branch')?.value || null });
    if (!res) return;
    const sec = t => res.rows.filter(r => r.type === t);
    const rows = [...sec('revenue').map(r => ({ ...r, g: 'الإيرادات' })), { name: 'إجمالي الإيرادات', amount: res.revenue, bold: true },
        ...sec('cogs').map(r => ({ ...r, g: 'التكلفة' })), { name: 'إجمالي التكلفة', amount: res.cogs, bold: true },
        { name: 'مجمل الربح', amount: res.gross_profit, bold: true },
        ...sec('expense').map(r => ({ ...r, g: 'المصروفات' })), { name: 'إجمالي المصروفات', amount: res.expenses, bold: true },
        { name: 'صافي الربح', amount: res.net_profit, bold: true }];
    accState.lastPnl = { title: 'الأرباح والخسائر', from: res.from, to: res.to, branch: res.branch, columns: [{ key: 'code', label: 'الكود', type: 't' }, { key: 'name', label: 'البند', type: 't' }, { key: 'amount', label: 'المبلغ', type: 'm' }], rows, key: 'sales_compare' };
    document.getElementById('accp-body').innerHTML = `<div class="flex gap-2 mb-2">${uiBtn('Excel', 'exportReportExcel(accState.lastPnl)', 'green')}${uiBtn('PDF', 'printReportPdf(accState.lastPnl)', 'red')}</div>`
        + uiTable(rows, [{ label: 'الكود', render: r => uiEsc(r.code || '') }, { label: 'البند', render: r => r.bold ? `<b>${uiEsc(r.name)}</b>` : uiEsc(r.name) },
            { label: 'المبلغ', render: r => r.bold ? `<b class="${Number(r.amount) < 0 ? 'text-red-600' : ''}">${formatCurrency(r.amount)}</b>` : formatCurrency(r.amount) }]);
}

async function accBs() {
    const body = document.getElementById('acc-body');
    body.innerHTML = uiCard('الميزانية', `<div class="flex gap-2 mb-3"><input id="accb-date" type="date" value="${uiToday()}" class="${uiInputClass()}">${uiBtn('عرض', 'accBsLoad()', 'gray')}</div><div id="accb-body"></div>`);
    accBsLoad();
}

async function accBsLoad() {
    const res = await uiCall('balance_sheet_secure', { p_as_of: document.getElementById('accb-date').value });
    if (!res) return;
    const sec = t => res.rows.filter(r => r.type === t);
    const rows = [...sec('asset'), { name: 'إجمالي الأصول', amount: res.assets, bold: true }, ...sec('liability'), { name: 'إجمالي الخصوم', amount: res.liabilities, bold: true },
        ...sec('equity'), { name: 'أرباح الفترة (لم ترحّل)', amount: res.profit_not_closed }, { name: 'إجمالي حقوق الملكية', amount: Number(res.equity) + Number(res.profit_not_closed), bold: true },
        { name: 'إجمالي الخصوم وحقوق الملكية', amount: res.liabilities_and_equity, bold: true }];
    accState.lastBs = { title: 'الميزانية', from: res.as_of, to: res.as_of, branch: 'كل الفروع', columns: [{ key: 'code', label: 'الكود', type: 't' }, { key: 'name', label: 'البند', type: 't' }, { key: 'amount', label: 'المبلغ', type: 'm' }], rows, key: 'sales_compare' };
    document.getElementById('accb-body').innerHTML = `<p class="text-xs font-black mb-2 ${res.balanced ? 'text-emerald-600' : 'text-red-600'}">${res.balanced ? '✅ الميزانية متوازنة' : '❌ الميزانية مش متوازنة، راجع القيود'}</p>
        <div class="flex gap-2 mb-2">${uiBtn('Excel', 'exportReportExcel(accState.lastBs)', 'green')}${uiBtn('PDF', 'printReportPdf(accState.lastBs)', 'red')}</div>`
        + uiTable(rows, [{ label: 'الكود', render: r => uiEsc(r.code || '') }, { label: 'البند', render: r => r.bold ? `<b>${uiEsc(r.name)}</b>` : uiEsc(r.name) },
            { label: 'المبلغ', render: r => r.bold ? `<b>${formatCurrency(r.amount)}</b>` : formatCurrency(r.amount) }]);
}

async function accGl() {
    const body = document.getElementById('acc-body');
    body.innerHTML = uiCard('دفتر الأستاذ', `<div class="flex flex-wrap gap-2 mb-3"><select id="accg-acc" class="${uiInputClass()}">${accAccountOptions()}</select>
        ${accRange('accg', uiToday().slice(0, 8) + '01')}${accBranchSelect('accg-branch')}${uiBtn('عرض', 'accGlLoad()', 'gray')}</div><div id="accg-body"></div>`);
}

async function accGlLoad() {
    const acc = document.getElementById('accg-acc').value;
    if (!acc) return showToast('اختار الحساب', 'error');
    const res = await uiCall('general_ledger_secure', { p_account_id: acc, p_from: document.getElementById('accg-from').value, p_to: document.getElementById('accg-to').value, p_branch_id: document.getElementById('accg-branch')?.value || null });
    if (!res) return;
    const rows = [{ date: '', entry_number: '', description: 'رصيد أول المدة', debit: null, credit: null, balance: res.opening }, ...res.lines];
    accState.lastGl = { title: 'دفتر الأستاذ: ' + res.account, from: document.getElementById('accg-from').value, to: document.getElementById('accg-to').value, branch: '',
        columns: [{ key: 'date', label: 'التاريخ', type: 't' }, { key: 'entry_number', label: 'القيد', type: 't' }, { key: 'description', label: 'البيان', type: 't' },
            { key: 'debit', label: 'مدين', type: 'm' }, { key: 'credit', label: 'دائن', type: 'm' }, { key: 'balance', label: 'الرصيد', type: 'm' }], rows, key: 'sales_compare' };
    document.getElementById('accg-body').innerHTML = `<div class="flex gap-2 mb-2">${uiBtn('Excel', 'exportReportExcel(accState.lastGl)', 'green')}${uiBtn('PDF', 'printReportPdf(accState.lastGl)', 'red')}</div>`
        + uiTable(rows, [{ label: 'التاريخ', key: 'date' }, { label: 'القيد', key: 'entry_number' }, { label: 'البيان', key: 'description' },
            { label: 'مدين', render: r => Number(r.debit) ? formatCurrency(r.debit) : '' }, { label: 'دائن', render: r => Number(r.credit) ? formatCurrency(r.credit) : '' },
            { label: 'الرصيد', render: r => `<b>${formatCurrency(r.balance)}</b>` }]);
}

async function accTb() {
    const body = document.getElementById('acc-body');
    body.innerHTML = uiCard('ميزان المراجعة', `<div class="flex flex-wrap gap-2 mb-3">${accRange('acct', uiToday().slice(0, 5) + '01-01')}${uiBtn('عرض', 'accTbLoad()', 'gray')}</div><div id="acct-body"></div>`);
    accTbLoad();
}

async function accTbLoad() {
    const res = await uiCall('trial_balance_secure', { p_from: document.getElementById('acct-from').value, p_to: document.getElementById('acct-to').value });
    if (!res) return;
    const rows = res.rows || [];
    accState.lastTb = { title: 'ميزان المراجعة', from: document.getElementById('acct-from').value, to: document.getElementById('acct-to').value, branch: 'كل الفروع',
        columns: [{ key: 'account_code', label: 'الكود', type: 't' }, { key: 'account_name_ar', label: 'الحساب', type: 't' },
            { key: 'ending_debit', label: 'مدين', type: 'm' }, { key: 'ending_credit', label: 'دائن', type: 'm' }], rows };
    const d = rows.reduce((s, r) => s + (Number(r.ending_debit) || 0), 0);
    const c = rows.reduce((s, r) => s + (Number(r.ending_credit) || 0), 0);
    document.getElementById('acct-body').innerHTML = `<div class="flex gap-2 mb-2">${uiBtn('Excel', 'exportReportExcel(accState.lastTb)', 'green')}${uiBtn('PDF', 'printReportPdf(accState.lastTb)', 'red')}</div>`
        + uiTable(rows, [{ label: 'الكود', key: 'account_code' }, { label: 'الحساب', key: 'account_name_ar' },
            { label: 'مدين', render: r => Number(r.ending_debit) ? formatCurrency(r.ending_debit) : '' }, { label: 'دائن', render: r => Number(r.ending_credit) ? formatCurrency(r.ending_credit) : '' }])
        + `<p class="text-xs font-black mt-2 ${Math.abs(d - c) < 0.01 ? 'text-emerald-600' : 'text-red-600'}">مدين ${formatCurrency(d)} | دائن ${formatCurrency(c)}</p>`;
}

function accCoa() {
    document.getElementById('acc-body').innerHTML = uiCard('دليل الحسابات', uiTable(accState.accounts, [{ label: 'الكود', key: 'code' }, { label: 'الحساب', key: 'name' },
        { label: 'النوع', render: a => uiEsc(ACC_TYPE_NAMES[a.type] || a.type) }]));
}

async function accPeriods(id, action) {
    const params = { p_period_id: id || null, p_action: action || null };
    if (id && !(await uiConfirm(action === 'close' ? 'قفل الفترة؟ مش هيتسجل أي قيد بتاريخ فيها بعد كده.' : 'إعادة فتح الفترة؟', action === 'close' ? 'قفل' : 'إعادة فتح', action === 'close'))) return;
    const res = await uiCall('fiscal_periods_secure', params, id ? 'تم' : null);
    if (!res) return;
    const isOwner = String(currentUser?.roles?.name || '') === 'owner';
    document.getElementById('acc-body').innerHTML = uiCard('الفترات المالية (القفل للمالك بس)', uiTable(res.periods, [{ label: 'الفترة', key: 'name' },
        { label: 'من', key: 'start' }, { label: 'إلى', key: 'end' }, { label: 'الحالة', render: p => p.status === 'closed' ? '<b class="text-red-600">مقفولة</b>' : 'مفتوحة' },
        { label: '', render: p => isOwner ? (p.status === 'open' ? uiBtn('قفل', `accPeriods('${p.id}','close')`, 'red') : uiBtn('إعادة فتح', `accPeriods('${p.id}','reopen')`, 'gray')) : '' }]));
}

async function accCustomers() {
    const res = await uiCall('customers_secure', { p_data: null });
    if (!res) return;
    accState.customers = res.customers || [];
    const typeNames = { cash: 'كاش', registered: 'متسجّل', on_account: 'آجل' };
    document.getElementById('acc-body').innerHTML = uiCard('العملاء', uiTable(accState.customers, [{ label: 'الاسم', key: 'name' }, { label: 'التليفون', key: 'phone' },
        { label: 'النوع', render: c => uiEsc(typeNames[c.customer_type] || c.customer_type) }, { label: 'الحد', render: c => formatCurrency(c.credit_limit) },
        { label: 'الرصيد عليه', render: c => `<b class="${Number(c.balance) > 0 ? 'text-red-600' : ''}">${formatCurrency(c.balance)}</b>` },
        { label: '', render: c => '<div class="flex flex-wrap gap-1">' + uiBtn('تعديل', `accEditCustomer('${c.id}')`, 'gray') + uiBtn('كشف', `accCustomerStatement('${c.id}')`, 'gray')
            + (Number(c.balance) > 0 ? uiBtn('تحصيل', `accCustomerReceive('${c.id}')`, 'green') : '') + '</div>' }], 'مفيش عملاء'),
        uiBtn('إضافة عميل', 'accEditCustomer(null)', 'blue')) + '<div id="acc-cust-statement"></div>';
}

async function accEditCustomer(id) {
    const c = id ? accState.customers.find(x => x.id === id) : {};
    const v = await uiForm(id ? 'تعديل عميل' : 'عميل جديد', [
        { key: 'name', label: 'اسم العميل', value: c.name || '', required: true },
        { key: 'phone', label: 'الموبايل', value: c.phone || '' },
        { key: 'type', label: 'النوع', type: 'select', options: [['cash', 'كاش'], ['registered', 'متسجّل'], ['on_account', 'آجل']], value: c.customer_type || 'registered', required: true },
        { key: 'limit', label: 'الحد المسموح في الآجل (صفر = من غير حد)', type: 'money', min: 0, value: c.credit_limit || 0 },
        { key: 'address', label: 'العنوان', value: c.address || '', full: true }]);
    if (!v) return;
    if (await uiCall('customers_secure', { p_data: { id: id || null, name: v.name, phone: v.phone, customer_type: v.type, credit_limit: String(v.limit || 0), address: v.address || '' } }, 'تم الحفظ')) accCustomers();
}

async function accCustomerStatement(id) {
    const res = await uiCall('customer_statement_secure', { p_customer_id: id });
    const c = accState.customers.find(x => x.id === id) || {};
    const names = { credit_sale: 'بيع آجل', payment_received: 'تحصيل', refund: 'مرتجع', adjustment: 'تسوية' };
    if (res) document.getElementById('acc-cust-statement').innerHTML = uiCard(`كشف حساب ${c.name || ''}`, uiTable(res.entries, [{ label: 'التاريخ', render: e => uiEsc(uiDate(e.at)) },
        { label: 'النوع', render: e => uiEsc(names[e.type] || e.type) }, { label: 'المبلغ', render: e => formatCurrency(e.amount) },
        { label: 'الرصيد بعدها', render: e => formatCurrency(e.balance_after) }, { label: 'المرجع', key: 'reference' }], 'مفيش حركات'));
}

async function accCustomerReceive(id) {
    const c = accState.customers.find(x => x.id === id) || {};
    const v = await uiForm(`تحصيل من ${c.name || ''}`, [
        { type: 'note', label: `عليه ${formatCurrency(c.balance)}` },
        { key: 'amount', label: 'المبلغ', type: 'money', min: 0.01, required: true, value: c.balance },
        { key: 'source', label: 'الفلوس هتدخل فين', type: 'select', options: UI_BOX_OPTIONS(['drawer', 'main_cash', 'bank']), required: true },
        { key: 'ref', label: 'رقم الإيصال (اختياري)' }], { ok: 'تحصيل' });
    if (!v) return;
    if (await uiCall('customer_receive_secure', { p_customer_id: id, p_amount: v.amount, p_source: v.source, p_reference: v.ref || '' }, 'تم التحصيل')) accCustomers();
}

async function accExpense() {
    const res = await uiCall('expense_categories_secure', { p_data: null });
    const cats = ((res && res.categories) || []).filter(c => c.is_active);
    document.getElementById('acc-body').innerHTML = uiCard('تسجيل مصروف (نفس قواعد شاشة المصروفات)', `
        <div class="grid grid-cols-1 md:grid-cols-2 gap-2 max-w-2xl">
            <select id="exp-account-select" class="${uiInputClass()}">${uiOptions(cats, 'id', c => c.name, 'اختار البند')}</select>
            <input id="exp-amount-input" type="number" min="0" step="0.01" placeholder="المبلغ" class="${uiInputClass()}">
            <select id="exp-method-select" class="${uiInputClass()}"><option value="cash">من الخزينة الرئيسية</option><option value="card">من البنك</option></select>
            <input id="exp-desc-input" type="text" placeholder="وصف المصروف" class="${uiInputClass()}">
        </div><div class="mt-3">${uiBtn('تسجيل المصروف', 'submitExpenseAction()', 'blue')}</div>`);
}

async function submitExpenseAction() {
    const catId = document.getElementById('exp-account-select')?.value;
    const amount = parseFloat(document.getElementById('exp-amount-input')?.value);
    const method = document.getElementById('exp-method-select')?.value || 'cash';
    const desc = document.getElementById('exp-desc-input')?.value;
    if (!catId || !amount || amount <= 0 || !desc) return showToast('يرجى ملء جميع بيانات المصروف والمبلغ بشكل صحيح', 'error');
    const res = await uiCall('expense_record_secure', { p_category_id: catId, p_amount: round2(amount), p_source: method === 'card' ? 'bank' : 'main_cash',
        p_description: desc, p_reference: '', p_vendor: '', p_recurring_id: null, p_owner_pin: null }, 'تم تسجيل المصروف وترحيل القيد ✅', 'p_owner_pin');
    if (res) accExpense();
}
