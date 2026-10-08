// js/treasury.js - الوردية (للكاشير) والخزينة (للمدير)
// الكاشير مبيشوفش المفروض يكون في الدرج كام. بيعدّ ويكتب، والسيرفر بيطلع الفرق.

// -----------------------------------------
// شاشة الوردية
// -----------------------------------------
async function loadShiftScreen() {
    const root = document.getElementById('shift-root');
    if (!root) return;
    root.innerHTML = '<p class="text-xs text-slate-400 font-bold p-4">جاري التحميل...</p>';
    const res = await uiCall('shift_current_secure', {});
    if (!res) { root.innerHTML = ''; return; }

    let shiftHtml;
    if (!res.open) {
        shiftHtml = uiCard('ورديتي', `<p class="text-xs font-bold text-slate-500 mb-3">مفيش وردية مفتوحة. لازم تفتح وردية قبل ما تقبض أي فلوس.</p>`
            + uiBtn('فتح وردية جديدة', 'shiftOpen()', 'green'));
    } else {
        shiftHtml = uiCard('ورديتي (مفتوحة)', `
            <div class="grid grid-cols-1 sm:grid-cols-3 gap-3 text-xs font-bold mb-4">
                <div class="bg-slate-50 p-3 rounded-xl border">فتحت: <b>${uiEsc(uiDate(res.opened_at))}</b></div>
                <div class="bg-slate-50 p-3 rounded-xl border">العهدة (الفكة): <b>${formatCurrency(res.opening_float)}</b></div>
                <div class="bg-slate-50 p-3 rounded-xl border">طلبات اتدفعت: <b>${uiEsc(res.orders_paid)}</b></div>
            </div>
            <div class="flex flex-wrap gap-2">
                ${uiBtn('توريد من الدرج (خزينة / بنك / صاحب المحل)', 'shiftDrop()', 'amber')}
                ${uiBtn('فكة زيادة للدرج', 'shiftCashIn()', 'gray')}
                ${uiBtn('قفل الوردية', 'shiftClose()', 'red')}
            </div>`);
    }

    const attendanceHtml = uiCard('الحضور والانصراف', `
        <p class="text-xs font-bold text-slate-500 mb-2">أي موظف يكتب رقمه السري هنا: أول مرة حضور، والتانية انصراف.</p>
        <div class="flex gap-2 max-w-sm">
            <input id="attendance-pin" type="password" inputmode="numeric" maxlength="4" placeholder="الرقم السري" class="${uiInputClass()} flex-1 text-center">
            ${uiBtn('تسجيل', 'attendancePunch()', 'blue')}
        </div>`);

    root.innerHTML = shiftHtml + attendanceHtml + '<div id="shift-last-report"></div>';
}

async function shiftOpen() {
    const v = await uiForm('فتح وردية', [{ key: 'amount', label: 'العهدة (الفكة) اللي استلمتها في الدرج', type: 'money', min: 0, required: true, value: appSet('shift', 'default_float', 0) }], { ok: 'فتح الوردية' });
    if (!v) return;
    if (await uiCall('shift_open_secure', { p_opening_float: v.amount }, 'تم فتح الوردية')) loadShiftScreen();
}

async function shiftDrop() {
    const v = await uiForm('توريد فلوس من الدرج', [
        { key: 'dest', label: 'الفلوس هتروح فين', type: 'select', options: UI_BOX_OPTIONS(['main_cash', 'bank', 'owner']), required: true },
        { key: 'amount', label: 'المبلغ', type: 'money', min: 0.01, required: true },
        { key: 'reason', label: 'السبب أو اسم المستلم', required: true, full: true }, { key: 'pin', label: 'رقم المدير', type: 'pin', required: true }], { ok: 'توريد' });
    if (!v) return;
    if (await uiCall('shift_cash_move_secure', { p_move_type: 'drop', p_amount: v.amount, p_destination: v.dest, p_reason: v.reason, p_manager_pin: v.pin }, 'تم التوريد')) loadShiftScreen();
}

async function shiftCashIn() {
    const v = await uiForm('فكة داخلة للدرج من الخزينة', [
        { key: 'amount', label: 'المبلغ', type: 'money', min: 0.01, required: true },
        { key: 'reason', label: 'السبب', value: 'فكة', required: true }, { key: 'pin', label: 'رقم المدير', type: 'pin', required: true }], { ok: 'تسجيل' });
    if (!v) return;
    if (await uiCall('shift_cash_move_secure', { p_move_type: 'cash_in', p_amount: v.amount, p_destination: null, p_reason: v.reason, p_manager_pin: v.pin }, 'تم تسجيل الفكة')) loadShiftScreen();
}

async function shiftClose() {
    const v = await uiForm('قفل الوردية', [
        { type: 'note', label: 'اعدّ كل الفلوس اللي في الدرج (والإكراميات الكاش معاها). الإكراميات بتروح لصندوق الإكراميات، ولو فيه عجز بيتغطّى منه الأول.' },
        { key: 'counted', label: 'إجمالي الفلوس اللي عدّيتها', type: 'money', min: 0, required: true },
        { key: 'notes', label: 'ملاحظات (اختياري)', type: 'textarea' }], { ok: 'قفل الوردية', danger: true });
    if (!v) return;
    const res = await uiCall('shift_close_secure', { p_counted_cash: v.counted, p_notes: v.notes || '' }, 'تم قفل الوردية');
    if (!res) return;
    await loadShiftScreen();
    const box = document.getElementById('shift-last-report');
    if (box) box.innerHTML = renderShiftReport(res.report);
}

const SHIFT_METHODS = [['cash', 'نقدي'], ['card', 'فيزا / كارت'], ['instapay', 'إنستاباي'], ['wallet', 'محفظة'], ['on_account', 'آجل (على الحساب)']];
let shiftLastReport = null;

// بيان قفل الوردية: المبيعات بكل طريقة دفع + الإكراميات + الدرج + العجز اتغطّى منين
function renderShiftReport(r) {
    if (!r) return '';
    shiftLastReport = r;
    const diff = Number(r.difference) || 0;
    const closed = r.status === 'closed';
    const pm = r.payments_by_method || {}, tm = r.tips_by_method || {};
    const known = SHIFT_METHODS.map(([k]) => k);
    const others = Object.keys(pm).filter(k => !known.includes(k)).map(k => [k, k]);
    const rows = SHIFT_METHODS.concat(others).map(([k, label]) => ({ label, sales: Number(pm[k]) || 0, tips: Number(tm[k]) || 0 }));
    const tipsTotal = rows.reduce((s, x) => s + x.tips, 0);
    const fromTips = Number(r.shortage_from_tips) || 0, onCashier = Number(r.shortage_on_cashier) || 0;
    const diffBox = !closed ? '<div class="p-3 rounded-xl border bg-slate-50">لسه مفتوحة</div>'
        : diff === 0 ? '<div class="p-3 rounded-xl border bg-emerald-50 text-emerald-700">الدرج مظبوط ✅</div>'
        : diff > 0 ? `<div class="p-3 rounded-xl border bg-emerald-50 text-emerald-700">زيادة ${formatCurrency(diff)}</div>`
        : `<div class="p-3 rounded-xl border bg-red-50 text-red-700">عجز ${formatCurrency(-diff)} ❌</div>`;
    const shortageHtml = closed && diff < 0 ? `
        <div class="grid grid-cols-1 sm:grid-cols-2 gap-3 text-xs font-bold mb-3">
            <div class="p-3 rounded-xl border bg-amber-50 text-amber-800">اتغطّى من صندوق الإكراميات: <b>${formatCurrency(fromTips)}</b></div>
            <div class="p-3 rounded-xl border ${onCashier > 0 ? 'bg-red-50 text-red-700' : 'bg-emerald-50 text-emerald-700'}">على الكاشير: <b>${formatCurrency(onCashier)}</b></div>
        </div>` : '';
    return uiCard(`بيان وردية ${r.staff || ''}`, `
        <p class="text-[11px] font-bold text-slate-500 mb-2">من ${uiEsc(uiDate(r.opened_at))}${r.closed_at ? ' لحد ' + uiEsc(uiDate(r.closed_at)) : ''} | طلبات اتدفعت: ${uiEsc(r.orders_paid)}</p>
        ${uiTable(rows, [{ label: 'طريقة الدفع', key: 'label' }, { label: 'المبيعات', render: x => formatCurrency(x.sales) },
            { label: 'الإكراميات', render: x => formatCurrency(x.tips) }, { label: 'الإجمالي', render: x => `<b>${formatCurrency(x.sales + x.tips)}</b>` }])}
        <div class="grid grid-cols-2 gap-3 text-xs font-black my-3">
            <div class="bg-emerald-50 p-3 rounded-xl border">إجمالي المبيعات: ${formatCurrency(r.sales_total)}</div>
            <div class="bg-amber-50 p-3 rounded-xl border">إجمالي الإكراميات: ${formatCurrency(tipsTotal)}</div>
        </div>
        <h4 class="font-black text-xs mb-1">الدرج (الكاش بس)</h4>
        <div class="grid grid-cols-2 lg:grid-cols-4 gap-3 text-xs font-bold mb-3">
            <div class="bg-slate-50 p-3 rounded-xl border">العهدة (الفكة): ${formatCurrency(r.opening_float)}</div>
            <div class="bg-slate-50 p-3 rounded-xl border">المفروض يكون: ${r.expected_cash === null ? '-' : formatCurrency(r.expected_cash)}</div>
            <div class="bg-slate-50 p-3 rounded-xl border">اللي اتعدّ: ${r.counted_cash === null ? '-' : formatCurrency(r.counted_cash)}</div>
            ${diffBox}
        </div>
        ${shortageHtml}
        <p class="text-xs font-bold text-amber-700 mb-2">💰 صندوق الإكراميات دلوقتي: ${formatCurrency(r.tips_pool)}</p>
        <h4 class="font-black text-xs mt-3 mb-1">حركات الدرج</h4>
        ${uiTable(r.cash_moves, [{ label: 'النوع', render: x => uiEsc(SHIFT_MOVE_NAMES[x.type] || x.type) }, { label: 'المبلغ', render: x => formatCurrency(x.amount) },
            { label: 'الجهة', render: x => uiEsc(UI_BOX_NAMES[x.destination] || x.destination || '') }, { label: 'السبب', key: 'reason' },
            { label: 'الوقت', render: x => uiEsc(uiDate(x.at)) }], 'مفيش حركات')}`,
        uiBtn('🖨️ طباعة البيان', 'printShiftStatement()', 'gray'));
}

const SHIFT_MOVE_NAMES = { float: 'عهدة', cash_in: 'فكة داخلة', drop: 'توريد', tips_payout: 'صرف إكراميات', expense: 'مصروف', close_handover: 'تسليم آخر الوردية',
    shortage: 'عجز', overage: 'زيادة', supplier_payment: 'دفع مورد', custody: 'عهدة موظف', advance: 'سلفة', payroll: 'مرتبات' };

function printShiftStatement() {
    const r = shiftLastReport;
    if (!r) return;
    const g = (typeof appSettings !== 'undefined' && appSettings && appSettings.general) || {};
    const m = v => (Number(v) || 0).toFixed(2);
    const pm = r.payments_by_method || {}, tm = r.tips_by_method || {};
    const diff = Number(r.difference) || 0;
    const rows = SHIFT_METHODS.map(([k, l]) => `<tr><td>${uiEsc(l)}</td><td class="num">${m(pm[k])}</td><td class="num">${m(tm[k])}</td></tr>`).join('');
    const tips = Object.values(tm).reduce((s, v) => s + (Number(v) || 0), 0);
    printHtml(`
        ${g.logo ? `<div class="c"><img class="logo" src="${uiEsc(g.logo)}"></div>` : ''}
        <div class="c b big">${uiEsc(g.company_name || '')}</div>
        <div class="c b">بيان قفل وردية</div>
        <div>الكاشير: ${uiEsc(r.staff || '')}</div>
        <div>من: ${uiEsc(uiDate(r.opened_at))}</div><div>لحد: ${uiEsc(uiDate(r.closed_at))}</div>
        <div class="line"></div>
        <table><tr class="b"><td>الطريقة</td><td class="num">مبيعات</td><td class="num">إكرامية</td></tr>${rows}</table>
        <div class="line"></div>
        <table><tr class="b"><td>إجمالي المبيعات</td><td class="num">${m(r.sales_total)}</td></tr>
            <tr class="b"><td>إجمالي الإكراميات</td><td class="num">${m(tips)}</td></tr></table>
        <div class="line"></div>
        <table><tr><td>العهدة</td><td class="num">${m(r.opening_float)}</td></tr>
            <tr><td>المفروض في الدرج</td><td class="num">${m(r.expected_cash)}</td></tr>
            <tr><td>اللي اتعدّ</td><td class="num">${m(r.counted_cash)}</td></tr>
            <tr class="b"><td>${diff < 0 ? 'العجز' : diff > 0 ? 'الزيادة' : 'الفرق'}</td><td class="num">${m(Math.abs(diff))}</td></tr>
            ${diff < 0 ? `<tr><td>اتغطّى من الإكراميات</td><td class="num">${m(r.shortage_from_tips)}</td></tr>
            <tr class="b"><td>على الكاشير</td><td class="num">${m(r.shortage_on_cashier)}</td></tr>` : ''}</table>
        <div class="line"></div>
        <div>صندوق الإكراميات دلوقتي: ${m(r.tips_pool)}</div>
        <div class="line"></div><div>توقيع الكاشير: ..............</div><div>توقيع المدير: ..............</div>`, receiptPageCss());
}

async function attendancePunch() {
    const input = document.getElementById('attendance-pin');
    const pin = input ? input.value.trim() : '';
    if (input) input.value = '';
    if (!/^[0-9]{4}$/.test(pin)) return showToast('الرقم السري 4 أرقام', 'error');
    const res = await uiCall('attendance_punch_secure', { p_pin: pin });
    if (res) showToast(`${res.name}: ${res.action === 'in' ? 'تم تسجيل الحضور ✅' : 'تم تسجيل الانصراف 👋'} ${uiDate(res.at)}`);
}

// -----------------------------------------
// شاشة الخزينة (للمدير)
// -----------------------------------------
let treasuryTab = 'balances';
function setTreasuryTab(tab) { treasuryTab = tab; loadTreasuryScreen(); }

async function loadTreasuryScreen() {
    const root = document.getElementById('treasury-root');
    if (!root) return;
    const list = [['balances', 'أرصدة الخزن'], ['shifts', 'الورديات'], ['day', 'تقرير وتقفيل اليوم']];
    if (canDo('tips_distribute')) list.push(['tips', 'الإكراميات 💰']);
    if (!list.some(t => t[0] === treasuryTab)) treasuryTab = 'balances';
    const tabs = uiTabs('treasury', list, treasuryTab, 'setTreasuryTab');
    root.innerHTML = tabs + '<div id="treasury-body"><p class="text-xs text-slate-400 font-bold">جاري التحميل...</p></div>';
    const body = document.getElementById('treasury-body');

    if (treasuryTab === 'balances') {
        const res = await uiCall('treasury_balances_secure', {});
        if (!res) return;
        body.innerHTML = uiCard('أرصدة الخزن والحسابات', uiTable(res.balances, [
            { label: 'الكود', key: 'code' }, { label: 'الحساب', key: 'name' }, { label: 'الرصيد', render: x => formatCurrency(x.balance) }]),
            uiBtn('تحويل بين الخزينة والبنك وصاحب المحل', 'treasuryTransfer()', 'blue'));
    } else if (treasuryTab === 'shifts') {
        const res = await uiCall('shifts_list_secure', { p_from: uiToday(-7), p_to: uiToday() });
        if (!res) return;
        body.innerHTML = uiCard('ورديات آخر 7 أيام', uiTable(res.shifts, [
            { label: 'الموظف', key: 'staff' }, { label: 'فتح', render: x => uiEsc(uiDate(x.opened_at)) },
            { label: 'قفل', render: x => uiEsc(uiDate(x.closed_at)) }, { label: 'الحالة', key: 'status' },
            { label: 'المفروض', render: x => x.expected_cash === null ? '-' : formatCurrency(x.expected_cash) },
            { label: 'المعدود', render: x => x.counted_cash === null ? '-' : formatCurrency(x.counted_cash) },
            { label: 'الفرق', render: x => x.difference === null ? '-' : `<span class="${Number(x.difference) < 0 ? 'text-red-600' : 'text-emerald-600'}">${formatCurrency(x.difference)}</span>` },
            { label: '', render: x => uiBtn('التقرير', `treasuryShowShift('${x.id}')`, 'gray') }]))
            + '<div id="treasury-shift-report"></div>';
    } else if (treasuryTab === 'tips') {
        await tipsRender(body);
    } else {
        const date = (document.getElementById('treasury-day-date')?.value) || uiToday();
        const res = await uiCall('day_report_secure', { p_date: date });
        if (!res) return;
        const r = res.report;
        const methods = Object.entries(r.payments_by_method || {}).map(([m, t]) => ({ m, t }));
        const drops = Object.entries(r.drops || {}).map(([d, t]) => ({ d, t }));
        body.innerHTML = uiCard(`تقرير يوم ${date} ${res.closed ? '(مقفول ✅)' : ''}`, `
            <div class="flex gap-2 mb-3"><input id="treasury-day-date" type="date" value="${uiEsc(date)}" class="${uiInputClass()}">${uiBtn('عرض', 'loadTreasuryScreen()', 'gray')}</div>
            <div class="grid grid-cols-2 lg:grid-cols-4 gap-3 text-xs font-bold mb-3">
                <div class="bg-emerald-50 p-3 rounded-xl border">المبيعات: ${formatCurrency(r.sales_total)}</div>
                <div class="bg-slate-50 p-3 rounded-xl border">طلبات مقفولة: ${uiEsc(r.orders_closed)}</div>
                <div class="bg-slate-50 p-3 rounded-xl border">الإكراميات: ${formatCurrency(r.tips)}</div>
                <div class="bg-amber-50 p-3 rounded-xl border">إلغاءات: ${uiEsc(r.voided_items)} | خصومات: ${uiEsc(r.discounts)} | مرتجع: ${uiEsc(r.refunds)}</div>
            </div>
            ${uiTable(methods, [{ label: 'طريقة الدفع', key: 'm' }, { label: 'المبلغ', render: x => formatCurrency(x.t) }], 'مفيش مبيعات')}
            <h4 class="font-black text-xs mt-3 mb-1">التوريدات</h4>
            ${uiTable(drops, [{ label: 'الجهة', render: x => uiEsc(UI_BOX_NAMES[x.d] || x.d) }, { label: 'المبلغ', render: x => formatCurrency(x.t) }], 'مفيش توريدات')}
            <h4 class="font-black text-xs mt-3 mb-1">الورديات</h4>
            ${uiTable(r.shifts, [{ label: 'الموظف', key: 'staff' }, { label: 'الحالة', key: 'status' },
                { label: 'المعدود', render: x => x.counted_cash === null ? '-' : formatCurrency(x.counted_cash) },
                { label: 'الفرق', render: x => x.difference === null ? '-' : formatCurrency(x.difference) }], 'مفيش ورديات')}`,
            res.closed ? '' : uiBtn('تقفيل اليوم', `treasuryCloseDay('${date}')`, 'red'));
    }
}

async function treasuryShowShift(id) {
    const res = await uiCall('shift_report_secure', { p_shift_id: id });
    const box = document.getElementById('treasury-shift-report');
    if (res && box) box.innerHTML = renderShiftReport(res.report);
}

async function treasuryCloseDay(date) {
    if (!(await uiConfirm(`تقفيل يوم ${date}؟ لازم كل الورديات تكون اتقفلت.`, 'تقفيل اليوم'))) return;
    if (await uiCall('day_close_secure', { p_date: date }, 'تم تقفيل اليوم')) loadTreasuryScreen();
}

async function treasuryTransfer() {
    const boxes = UI_BOX_OPTIONS(['main_cash', 'bank', 'owner']);
    const v = await uiForm('تحويل بين الخزن', [
        { key: 'from', label: 'الفلوس طالعة منين', type: 'select', options: boxes, required: true },
        { key: 'to', label: 'رايحة فين', type: 'select', options: boxes, required: true, value: 'bank' },
        { key: 'amount', label: 'المبلغ', type: 'money', min: 0.01, required: true },
        { key: 'reason', label: 'السبب (مثلاً: إيداع إيراد اليوم في البنك)', required: true }, { key: 'pin', label: 'رقم المدير', type: 'pin', required: true }],
        { ok: 'تحويل', validate: x => x.from === x.to ? { key: 'to', msg: 'لازم يبقى مكان تاني' } : null });
    if (!v) return;
    if (await uiCall('treasury_transfer_secure', { p_from: v.from, p_to: v.to, p_amount: v.amount, p_reason: v.reason, p_manager_pin: v.pin }, 'تم التحويل')) loadTreasuryScreen();
}

// -----------------------------------------
// صندوق الإكراميات: بيتجمع من كل الفواتير، ويتوزع بالتساوي على اللي المدير يختارهم
// -----------------------------------------
let tipsState = null;

async function tipsRender(body) {
    const res = await uiCall('tips_secure', { p_action: 'status', p_data: {} });
    if (!res) return;
    tipsState = res;
    const anyCame = (res.staff || []).some(s => s.came_today);
    const staffHtml = (res.staff || []).map(s => `
        <label class="flex items-center gap-2 bg-slate-50 border rounded-xl px-3 py-2 text-xs font-bold cursor-pointer">
            <input type="checkbox" class="tips-staff" value="${uiEsc(s.id)}" ${(!anyCame || s.came_today) ? 'checked' : ''} onchange="tipsPreview()">
            ${uiEsc(s.name)} ${s.came_today ? '<span class="text-emerald-600">(حضر النهارده)</span>' : ''}
        </label>`).join('') || '<p class="text-xs text-slate-400 font-bold">مفيش موظفين في الفرع</p>';
    body.innerHTML = uiCard('صندوق الإكراميات', `
        <div class="grid grid-cols-1 sm:grid-cols-3 gap-3 text-xs font-bold mb-4">
            <div class="bg-amber-50 p-3 rounded-xl border border-amber-200 text-amber-900">في الصندوق دلوقتي<div class="text-xl font-black">${formatCurrency(res.pool)}</div></div>
            <div class="bg-slate-50 p-3 rounded-xl border">اتجمع النهارده<div class="text-lg font-black">${formatCurrency(res.collected_today)}</div></div>
            <div class="bg-red-50 p-3 rounded-xl border text-red-700">اتغطّى منه عجز النهارده<div class="text-lg font-black">${formatCurrency(res.covered_shortages_today)}</div></div>
        </div>
        <h4 class="font-black text-xs mb-2">هتتوزع على مين؟ (بالتساوي)</h4>
        <div class="grid grid-cols-2 lg:grid-cols-4 gap-2 mb-3">${staffHtml}</div>
        <div class="flex flex-wrap items-end gap-3 mb-2">
            <label class="text-xs font-bold">المبلغ اللي هيتوزع
                <input id="tips-amount" type="number" min="0" step="0.01" value="${uiEsc(Number(res.pool) || 0)}" oninput="tipsPreview()" class="${uiInputClass()} w-32 block mt-1"></label>
            <label class="text-xs font-bold">الفلوس هتطلع منين
                <select id="tips-source" class="${uiInputClass()} block mt-1"><option value="main_cash">الخزينة الرئيسية</option><option value="drawer">درج ورديتي</option></select></label>
            ${uiBtn('توزيع 💰', 'tipsDistribute()', 'green')}
        </div>
        <p id="tips-preview" class="text-xs font-black text-emerald-700"></p>
        <p class="text-[11px] font-bold text-slate-400 mt-1">الكسور اللي ماتتقسمش بالتساوي بتفضل في الصندوق للمرة الجاية.</p>`)
        + uiCard('آخر التوزيعات', uiTable(res.history, [
            { label: 'الوقت', render: x => uiEsc(uiDate(x.at)) }, { label: 'الإجمالي', render: x => formatCurrency(x.total) },
            { label: 'لكل واحد', render: x => formatCurrency(x.each) }, { label: 'العدد', key: 'count' }, { label: 'الأسماء', key: 'names' },
            { label: 'من', render: x => x.source === 'drawer' ? 'الدرج' : 'الخزينة' }, { label: 'وزّعها', key: 'by' }], 'لسه مفيش توزيع'));
    tipsPreview();
}

function tipsSelected() { return [...document.querySelectorAll('.tips-staff:checked')].map(x => x.value); }

function tipsPreview() {
    const box = document.getElementById('tips-preview');
    if (!box) return;
    const n = tipsSelected().length;
    const amount = Number(document.getElementById('tips-amount')?.value) || 0;
    const each = n ? Math.floor(amount * 100 / n) / 100 : 0;
    box.textContent = n && each > 0 ? `كل واحد هياخد ${formatCurrency(each)} (${n} موظف)` : 'اختار الموظفين واكتب المبلغ';
}

async function tipsDistribute() {
    const ids = tipsSelected();
    const amount = Number(document.getElementById('tips-amount')?.value) || 0;
    const source = document.getElementById('tips-source')?.value || 'main_cash';
    if (!ids.length) return showToast('اختار موظف واحد على الأقل', 'error');
    if (amount <= 0 || amount > (Number(tipsState?.pool) || 0) + 0.001) return showToast('المبلغ لازم يكون أكبر من صفر ومش أكتر من اللي في الصندوق', 'error');
    const each = Math.floor(amount * 100 / ids.length) / 100;
    if (!(await uiConfirm(`توزيع ${formatCurrency(each * ids.length)} على ${ids.length} موظف؟\nكل واحد ${formatCurrency(each)}.`, 'توزيع'))) return;
    const res = await uiCall('tips_secure', { p_action: 'distribute', p_data: { staff_ids: ids, amount, source } }, 'تم توزيع الإكراميات ✅');
    if (res) loadTreasuryScreen();
}
