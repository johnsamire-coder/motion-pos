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
        { type: 'note', label: 'اعدّ الفلوس اللي في الدرج كلها (من غير الإكراميات، السيستم هيصرفها).' },
        { key: 'counted', label: 'إجمالي الفلوس اللي عدّيتها', type: 'money', min: 0, required: true },
        { key: 'notes', label: 'ملاحظات (اختياري)', type: 'textarea' }], { ok: 'قفل الوردية', danger: true });
    if (!v) return;
    const res = await uiCall('shift_close_secure', { p_counted_cash: v.counted, p_notes: v.notes || '' }, 'تم قفل الوردية');
    if (!res) return;
    await loadShiftScreen();
    const box = document.getElementById('shift-last-report');
    if (box) box.innerHTML = renderShiftReport(res.report);
}

function renderShiftReport(r) {
    if (!r) return '';
    const diff = Number(r.difference) || 0;
    const diffText = diff === 0 ? 'مظبوط ✅' : (diff < 0 ? `عجز ${formatCurrency(-diff)} ❌` : `زيادة ${formatCurrency(diff)}`);
    const methods = Object.entries(r.payments_by_method || {}).map(([m, t]) => ({ m, t }));
    return uiCard(`تقرير وردية ${r.staff || ''}`, `
        <div class="grid grid-cols-2 lg:grid-cols-4 gap-3 text-xs font-bold mb-3">
            <div class="bg-slate-50 p-3 rounded-xl border">العهدة: ${formatCurrency(r.opening_float)}</div>
            <div class="bg-slate-50 p-3 rounded-xl border">المفروض: ${r.expected_cash === null ? '-' : formatCurrency(r.expected_cash)}</div>
            <div class="bg-slate-50 p-3 rounded-xl border">المعدود: ${r.counted_cash === null ? '-' : formatCurrency(r.counted_cash)}</div>
            <div class="p-3 rounded-xl border ${diff < 0 ? 'bg-red-50 text-red-700' : 'bg-emerald-50 text-emerald-700'}">${r.status === 'closed' ? diffText : 'لسه مفتوحة'}</div>
        </div>
        <p class="text-xs font-bold mb-2">الإكراميات المصروفة: ${formatCurrency(r.tips_paid)} | طلبات: ${uiEsc(r.orders_paid)}</p>
        ${uiTable(methods, [{ label: 'طريقة الدفع', key: 'm' }, { label: 'المبلغ', render: x => formatCurrency(x.t) }], 'مفيش مدفوعات')}
        <h4 class="font-black text-xs mt-3 mb-1">حركات الدرج</h4>
        ${uiTable(r.cash_moves, [{ label: 'النوع', key: 'type' }, { label: 'المبلغ', render: x => formatCurrency(x.amount) },
            { label: 'الجهة', render: x => uiEsc(UI_BOX_NAMES[x.destination] || x.destination || '') }, { label: 'السبب', key: 'reason' },
            { label: 'الوقت', render: x => uiEsc(uiDate(x.at)) }], 'مفيش حركات')}`);
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
    const tabs = uiTabs('treasury', [['balances', 'أرصدة الخزن'], ['shifts', 'الورديات'], ['day', 'تقرير وتقفيل اليوم']], treasuryTab, 'setTreasuryTab');
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
