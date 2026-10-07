// js/staff.js - الموظفين: القايمة، الرقم السري، السلف، الصلاحيات، الحضور، المرتبات، الأداء، الإعدادات

let stfState = { tab: 'list', staff: [], roles: [], branches: [], period: null, run: null };
function setStaffTab(tab) { stfState.tab = tab; renderStaffBody(); }

const STAFF_ROLE_NAMES = { owner: 'المالك', branch_manager: 'مدير فرع', cashier: 'كاشير', waiter: 'ويتر', storekeeper: 'أمين مخزن' };
const PERM_NAMES = { pos: 'البيع', kds: 'المطبخ', shift: 'الوردية', inventory: 'المخازن', inventory_approve: 'موافقات المخازن',
    purchasing: 'المشتريات', treasury: 'الخزينة', expenses: 'المصروفات', staff: 'الموظفين', payroll: 'المرتبات',
    reports: 'التقارير', settings: 'الإعدادات', accounting: 'الحسابات', sales: 'المبيعات', customers: 'العملاء' };

async function loadStaffScreen() {
    renderStaffBody();
}

function renderStaffBody() {
    const root = document.getElementById('staff-root');
    if (!root) return;
    const isOwner = String(currentUser?.roles?.name || '') === 'owner';
    const tabs = [['list', 'الموظفين'], ['attendance', 'الحضور'], ['payroll', 'المرتبات'], ['performance', 'الأداء']];
    if (isOwner) tabs.push(['perms', 'الصلاحيات'], ['settings', 'إعدادات الشغل']);
    root.innerHTML = uiTabs('stf', tabs, stfState.tab, 'setStaffTab') + '<div id="stf-body"></div>';
    ({ list: stfRenderList, attendance: stfRenderAttendance, payroll: stfRenderPayroll, performance: stfRenderPerformance,
        perms: stfRenderPerms, settings: stfRenderSettings }[stfState.tab] || stfRenderList)();
}

async function stfRenderList() {
    const [res, br] = await Promise.all([uiCall('staff_list_secure', {}), _supabase.from('branches').select('id, name')]);
    if (!res) return;
    stfState.staff = res.staff || [];
    stfState.roles = res.roles || [];
    stfState.branches = br.data || [];
    document.getElementById('stf-body').innerHTML = uiCard('الموظفين', uiTable(stfState.staff, [
        { label: 'الاسم', key: 'name' }, { label: 'الدور', render: s => uiEsc(STAFF_ROLE_NAMES[s.role] || s.role) },
        { label: 'الفرع', key: 'branch' }, { label: 'المرتب', render: s => formatCurrency(s.monthly_salary) },
        { label: 'التليفون', key: 'phone' }, { label: 'رقم سري', render: s => s.has_pin ? '✅' : '<b class="text-red-600">مفيش</b>' },
        { label: 'عليه', render: s => `<b class="${Number(s.balance) > 0 ? 'text-red-600' : ''}">${formatCurrency(s.balance)}</b>` },
        { label: 'الحالة', render: s => s.is_active ? 'شغال' : '<span class="text-slate-400">موقوف</span>' },
        { label: '', render: s => '<div class="flex flex-wrap gap-1">' + uiBtn('تعديل', `stfEdit('${s.id}')`, 'gray')
            + uiBtn('الرقم السري', `stfSetPin('${s.id}')`, 'gray') + uiBtn('سلفة', `stfAdvance('${s.id}')`, 'amber')
            + uiBtn('كشف', `stfLedger('${s.id}')`, 'gray') + '</div>' }], 'مفيش موظفين'),
        uiBtn('إضافة موظف', 'stfEdit(null)', 'blue')) + '<div id="stf-ledger"></div>';
}

async function stfEdit(id) {
    const s = id ? stfState.staff.find(x => x.id === id) : {};
    const name = prompt('اسم الموظف:', s.name || '');
    if (!name) return;
    const isOwner = String(currentUser?.roles?.name || '') === 'owner';
    const roles = stfState.roles.filter(r => isOwner || !['owner', 'branch_manager'].includes(r));
    const rp = prompt('الدور:\n' + roles.map((r, i) => `${i + 1}. ${STAFF_ROLE_NAMES[r] || r}`).join('\n'),
        String(Math.max(1, roles.indexOf(s.role) + 1)));
    const role = roles[parseInt(rp, 10) - 1];
    if (!role) return showToast('دور غير صحيح', 'error');
    let branchId = s.branch_id || currentUser?.branch_id;
    if (isOwner && stfState.branches.length > 1) {
        const bp = prompt('الفرع:\n' + stfState.branches.map((b, i) => `${i + 1}. ${b.name}`).join('\n'),
            String(Math.max(1, stfState.branches.findIndex(b => b.id === branchId) + 1)));
        const b = stfState.branches[parseInt(bp, 10) - 1];
        if (!b) return showToast('فرع غير صحيح', 'error');
        branchId = b.id;
    }
    const salary = uiAskAmount('المرتب الشهري (صفر لو مفيش):', String(s.monthly_salary || 0));
    if (salary === null) return;
    const phone = prompt('التليفون:', s.phone || '') ?? '';
    const active = id ? confirm('الموظف شغال؟ (إلغاء = إيقافه، وتذكرته هتتلغي فوراً)') : true;
    const res = await uiCall('staff_save_secure', { p_data: { id: id || null, name, role, branch_id: branchId, monthly_salary: String(salary), phone, is_active: String(active) } }, 'تم الحفظ');
    if (!res) return;
    if (!id) {
        showToast('تم إضافة الموظف. دلوقتي حدد له رقم سري.');
        await stfSetPin(res.id);
    }
    stfRenderList();
}

async function stfSetPin(id) {
    const pin = prompt('الرقم السري الجديد (4 أرقام، ومينفعش يتكرر مع موظف تاني):');
    if (!pin) return;
    if (!/^[0-9]{4}$/.test(pin)) return showToast('الرقم السري لازم 4 أرقام', 'error');
    if (await uiCall('staff_set_pin_secure', { p_staff_id: id, p_pin: pin }, 'تم حفظ الرقم السري')) stfRenderList();
}

async function stfAdvance(id) {
    const s = stfState.staff.find(x => x.id === id) || {};
    const amount = uiAskAmount(`سلفة لـ ${s.name}. المبلغ:`);
    if (!amount) return;
    const source = uiPickBox('الفلوس طالعة منين؟', ['main_cash', 'bank', 'drawer']);
    if (!source) return;
    const reason = prompt('السبب:', 'سلفة') || 'سلفة';
    const pin = await uiAskPin('السلفة محتاجة موافقة المدير. أدخل رقم المدير:');
    if (!pin) return;
    if (await uiCall('staff_advance_secure', { p_staff_id: id, p_amount: amount, p_source: source, p_reason: reason, p_manager_pin: String(pin).trim() }, 'تم صرف السلفة')) stfRenderList();
}

async function stfLedger(id) {
    const s = stfState.staff.find(x => x.id === id) || {};
    const res = await uiCall('staff_ledger_secure', { p_staff_id: id });
    const names = { shortage: 'عجز وردية', advance: 'سلفة', deduction: 'خصم من المرتب', repayment: 'سداد', adjustment: 'تسوية' };
    if (res) document.getElementById('stf-ledger').innerHTML = uiCard(`كشف ${s.name || ''} (الموجب = عليه)`, uiTable(res.entries, [
        { label: 'التاريخ', render: e => uiEsc(uiDate(e.at)) }, { label: 'النوع', render: e => uiEsc(names[e.type] || e.type) },
        { label: 'المبلغ', render: e => formatCurrency(e.amount) }, { label: 'الرصيد بعدها', render: e => formatCurrency(e.balance_after) },
        { label: 'ملاحظة', key: 'notes' }], 'مفيش حركات'));
}

async function stfRenderAttendance() {
    const from = document.getElementById('stf-att-from')?.value || uiToday(-30);
    const to = document.getElementById('stf-att-to')?.value || uiToday();
    document.getElementById('stf-body').innerHTML = uiCard('الحضور والانصراف', `
        <p class="text-xs font-bold text-slate-500 mb-2">التسجيل نفسه بيتعمل من شاشة "الوردية" بالرقم السري لكل موظف.</p>
        <div class="flex flex-wrap gap-2 mb-3"><input id="stf-att-from" type="date" value="${uiEsc(from)}" class="${uiInputClass()}">
        <input id="stf-att-to" type="date" value="${uiEsc(to)}" class="${uiInputClass()}">${uiBtn('عرض', 'stfRenderAttendance()', 'gray')}</div>
        <div id="stf-att-body"></div>`);
    const res = await uiCall('attendance_report_secure', { p_from: from, p_to: to });
    if (!res) return;
    document.getElementById('stf-att-body').innerHTML = uiTable(res.summary, [{ label: 'الموظف', key: 'staff' }, { label: 'أيام', key: 'days' },
            { label: 'ساعات', key: 'hours' }, { label: 'موجود دلوقتي', render: x => x.open_now ? '✅' : '' }], 'مفيش تسجيلات')
        + '<h4 class="font-black text-xs mt-3 mb-1">كل التسجيلات</h4>'
        + uiTable(res.records, [{ label: 'الموظف', key: 'staff' }, { label: 'حضور', render: x => uiEsc(uiDate(x.clock_in)) },
            { label: 'انصراف', render: x => uiEsc(uiDate(x.clock_out)) }, { label: 'دقايق', key: 'minutes' }], 'مفيش');
}

async function stfRenderPayroll() {
    const period = document.getElementById('stf-pay-period')?.value || stfState.period || uiToday().slice(0, 7);
    stfState.period = period;
    const res = await uiCall('payroll_get_secure', { p_period: period + '-01' });
    if (!res) return;
    stfState.run = res.run;
    const run = res.run;
    const statusNames = { draft: 'مسودة', approved: 'معتمدة', paid: 'اتصرفت' };
    let actions = uiBtn(run ? 'إعادة تجهيز المسودة' : 'تجهيز المسودة', 'stfPayrollPrepare()', 'blue');
    if (run && run.status === 'draft') actions = uiBtn('إعادة تجهيز المسودة', 'stfPayrollPrepare()', 'gray') + uiBtn('اعتماد', 'stfPayrollApprove()', 'green');
    if (run && run.status === 'approved') actions = uiBtn('صرف المرتبات', 'stfPayrollPay()', 'green');
    if (run && run.status === 'paid') actions = '';
    const editable = run && run.status === 'draft';
    document.getElementById('stf-body').innerHTML = uiCard(`المرتبات ${run ? '(' + (statusNames[run.status] || run.status) + ' - أيام الشغل ' + run.working_days + ')' : ''}`, `
        <div class="flex flex-wrap gap-2 mb-3"><input id="stf-pay-period" type="month" value="${uiEsc(period)}" class="${uiInputClass()}">${uiBtn('عرض', 'stfRenderPayroll()', 'gray')}</div>
        ${run ? uiTable(run.lines, [
            { label: 'الموظف', key: 'staff' }, { label: 'المرتب', render: l => formatCurrency(l.base_salary) },
            { label: 'أيام حضور', key: 'days_worked' }, { label: 'غياب', key: 'absent_days' },
            { label: 'خصم الغياب', render: l => formatCurrency(l.absence_deduction) },
            { label: 'خصم عجز وسلف', render: l => formatCurrency(l.ledger_deduction) + ` <span class="text-[10px] text-slate-400">(عليه ${formatCurrency(l.staff_balance)})</span>` },
            { label: 'خصم تاني', render: l => formatCurrency(l.other_deduction) }, { label: 'مكافأة', render: l => formatCurrency(l.bonus) },
            { label: 'الصافي', render: l => `<b>${formatCurrency(l.net)}</b>` }, { label: 'ملاحظة', key: 'notes' },
            { label: '', render: l => editable ? uiBtn('تعديل', `stfPayrollEdit('${l.id}')`, 'gray') : '' }], 'مفيش موظفين ليهم مرتب')
            + `<p class="text-xs font-black mt-2">إجمالي الصافي: ${formatCurrency(run.total_net)}</p>`
          : '<p class="text-xs font-bold text-slate-400">لسه مفيش مسودة للشهر ده.</p>'}`, actions);
}

async function stfPayrollPrepare() {
    if (stfState.run && !confirm('إعادة التجهيز هتمسح أي تعديلات عملتها على المسودة. موافق؟')) return;
    if (await uiCall('payroll_prepare_secure', { p_period: stfState.period + '-01' }, 'تم تجهيز المسودة')) stfRenderPayroll();
}

async function stfPayrollEdit(lineId) {
    const l = (stfState.run?.lines || []).find(x => x.id === lineId);
    if (!l) return;
    const absent = uiAskAmount(`${l.staff}: أيام الغياب:`, String(l.absent_days));
    if (absent === null) return;
    const ledger = uiAskAmount(`خصم العجز والسلف (عليه ${formatCurrency(l.staff_balance)}):`, String(l.ledger_deduction));
    if (ledger === null) return;
    const other = uiAskAmount('أي خصم تاني (جزاء مثلاً):', String(l.other_deduction));
    if (other === null) return;
    const bonus = uiAskAmount('مكافأة:', String(l.bonus));
    if (bonus === null) return;
    const notes = prompt('ملاحظة:', l.notes || '') ?? '';
    const res = await uiCall('payroll_line_update_secure', { p_line_id: lineId, p_absent_days: absent, p_ledger_deduction: ledger,
        p_other_deduction: other, p_bonus: bonus, p_notes: notes }, 'تم التعديل');
    if (res) stfRenderPayroll();
}

async function stfPayrollApprove() {
    if (!confirm('اعتماد المرتبات؟ هيتعمل القيد، والعجز والسلف هيتخصموا من رصيد كل موظف، ومش هينفع تتعدل بعدها.')) return;
    const pin = await uiAskPin('الاعتماد محتاج رقم المدير:');
    if (!pin) return;
    if (await uiCall('payroll_approve_secure', { p_run_id: stfState.run.id, p_manager_pin: String(pin).trim() }, 'تم الاعتماد')) stfRenderPayroll();
}

async function stfPayrollPay() {
    const source = uiPickBox(`صرف ${formatCurrency(stfState.run.total_net)}. من فين؟`, ['main_cash', 'bank']);
    if (!source) return;
    const pin = await uiAskPin('الصرف محتاج رقم المدير:');
    if (!pin) return;
    if (await uiCall('payroll_pay_secure', { p_run_id: stfState.run.id, p_source: source, p_manager_pin: String(pin).trim() }, 'تم صرف المرتبات')) stfRenderPayroll();
}

async function stfRenderPerformance() {
    const from = document.getElementById('stf-perf-from')?.value || uiToday(-30);
    const to = document.getElementById('stf-perf-to')?.value || uiToday();
    document.getElementById('stf-body').innerHTML = uiCard('أداء الموظفين', `
        <div class="flex flex-wrap gap-2 mb-3"><input id="stf-perf-from" type="date" value="${uiEsc(from)}" class="${uiInputClass()}">
        <input id="stf-perf-to" type="date" value="${uiEsc(to)}" class="${uiInputClass()}">${uiBtn('عرض', 'stfRenderPerformance()', 'gray')}</div>
        <div id="stf-perf-body"></div>`);
    const res = await uiCall('staff_performance_secure', { p_from: from, p_to: to });
    if (!res) return;
    document.getElementById('stf-perf-body').innerHTML = uiTable(res.rows, [
        { label: 'الموظف', key: 'staff' }, { label: 'قبض (كاشير)', render: r => formatCurrency(r.sales) },
        { label: 'مبيعات (ويتر)', render: r => formatCurrency(r.waiter_sales) }, { label: 'إلغاءات', key: 'voids' },
        { label: 'خصومات', key: 'discounts' }, { label: 'مرتجعات', key: 'refunds' },
        { label: 'فرق الورديات', render: r => `<span class="${Number(r.shift_difference) < 0 ? 'text-red-600' : ''}">${formatCurrency(r.shift_difference)}</span>` },
        { label: 'إكراميات', render: r => formatCurrency(r.tips) }]);
}

async function stfRenderPerms() {
    const res = await uiCall('role_permissions_secure', { p_role: null, p_perms: null });
    if (!res) return;
    stfState.permData = res;
    const roles = Object.keys(res.roles || {});
    const head = '<tr><th class="p-2 text-[11px] border-b">الصلاحية</th>' + roles.map(r => `<th class="p-2 text-[11px] border-b">${uiEsc(STAFF_ROLE_NAMES[r] || r)}</th>`).join('') + '</tr>';
    const body = (res.all_perms || []).map(p => '<tr class="border-b text-xs font-bold"><td class="p-2">' + uiEsc(PERM_NAMES[p] || p) + '</td>'
        + roles.map(r => `<td class="p-2 text-center"><input type="checkbox" data-perm-role="${uiEsc(r)}" data-perm="${uiEsc(p)}" ${(res.roles[r] || []).includes(p) ? 'checked' : ''}></td>`).join('')
        + '</tr>').join('');
    document.getElementById('stf-body').innerHTML = uiCard('الصلاحيات (المالك عنده كل حاجة دايماً)',
        `<div class="overflow-x-auto"><table class="w-full text-right"><thead>${head}</thead><tbody>${body}</tbody></table></div>`,
        uiBtn('حفظ', 'stfSavePerms()', 'green'));
}

async function stfSavePerms() {
    const roles = Object.keys(stfState.permData?.roles || {});
    for (const r of roles) {
        const perms = [...document.querySelectorAll(`[data-perm-role="${CSS.escape(r)}"]`)].filter(el => el.checked).map(el => el.dataset.perm);
        const res = await uiCall('role_permissions_secure', { p_role: r, p_perms: perms });
        if (!res) return;
    }
    showToast('تم حفظ الصلاحيات. هتطبق من أول دخول جاي لكل موظف.');
    stfRenderPerms();
}

async function stfRenderSettings() {
    const res = await uiCall('pos_settings_list_secure', {});
    if (!res) return;
    document.getElementById('stf-body').innerHTML = uiCard('إعدادات الشغل', `
        <div class="grid grid-cols-1 md:grid-cols-2 gap-3 max-w-2xl text-xs font-bold">
            <label>أيام الشغل في الشهر (لحساب الغياب)<input id="stf-set-days" type="number" min="1" max="31" value="${uiEsc(res.working_days_per_month)}" class="${uiInputClass()} w-full mt-1"></label>
            <label>حد صرف المدير (فوقه رقم المالك)<input id="stf-set-limit" type="number" min="0" step="1" value="${uiEsc(res.expense_manager_limit)}" class="${uiInputClass()} w-full mt-1"></label>
        </div>
        <div class="mt-3">${uiBtn('حفظ', 'stfSaveSettings()', 'green')}</div>`);
}

async function stfSaveSettings() {
    const days = document.getElementById('stf-set-days').value;
    const limit = document.getElementById('stf-set-limit').value;
    const a = await uiCall('pos_setting_save_secure', { p_key: 'working_days_per_month', p_value: String(days) });
    if (!a) return;
    const b = await uiCall('pos_setting_save_secure', { p_key: 'expense_manager_limit', p_value: String(limit) });
    if (b) showToast('تم الحفظ');
}
