// js/staff.js - الموظفين: القايمة، الرقم السري، السلف، الصلاحيات، الحضور، المرتبات، الأداء، الإعدادات

let stfState = { tab: 'list', staff: [], roles: [], branches: [], period: null, run: null };
function setStaffTab(tab) { stfState.tab = tab; renderStaffBody(); }

const STAFF_ROLE_NAMES = { owner: 'المالك', branch_manager: 'مدير فرع', cashier: 'كاشير', waiter: 'ويتر', storekeeper: 'أمين مخزن', kitchen: 'المطبخ' };
const PERM_NAMES = { pos: 'البيع', kds: 'المطبخ', shift: 'الوردية', inventory: 'المخازن', inventory_approve: 'موافقات المخازن',
    purchasing: 'المشتريات', treasury: 'الخزينة', expenses: 'المصروفات', staff: 'الموظفين', payroll: 'المرتبات',
    reports: 'التقارير', settings: 'الإعدادات', accounting: 'الحسابات', sales: 'المبيعات', customers: 'العملاء', dashboard: 'لوحة التحكم', feedback: 'الشكاوي والاقتراحات',
    // جوه الشاشات
    po_create: 'عمل أمر شراء (وإلغاؤه وقفله)', po_approve: 'اعتماد أو رفض أمر الشراء', po_receive: 'الاستلام الفعلي وصورة الفاتورة',
    po_post: 'الترحيل للمخازن', po_invoice: 'تسجيل فاتورة المورد', supplier_pay: 'الدفع للموردين', suppliers_manage: 'إضافة وتعديل الموردين',
    inv_waste: 'تسجيل هالك', inv_transfer: 'تحويل بين المخازن', inv_stocktake: 'الجرد',
    treasury_transfer: 'تحويل بين الخزن', day_close: 'قفل اليوم',
    exp_record: 'تسجيل مصروف', exp_recurring: 'المصروفات المتكررة (المرتبات والإيجار...)', exp_categories: 'بنود المصروفات', exp_custody: 'العهد',
    staff_manage: 'إضافة وتعديل الموظفين وأرقامهم السرية', payroll_approve: 'اعتماد المرتبات', payroll_pay: 'صرف المرتبات والسلف',
    acc_manual: 'قيود يدوية وعكس القيود', settings_menu: 'تعديل المنيو والوصفات والإضافات' };
const PERM_SUBS = new Set(['po_create', 'po_approve', 'po_receive', 'po_post', 'po_invoice', 'supplier_pay', 'suppliers_manage', 'inv_waste', 'inv_transfer',
    'inv_stocktake', 'treasury_transfer', 'day_close', 'exp_record', 'exp_recurring', 'exp_categories', 'exp_custody', 'staff_manage', 'payroll_approve',
    'payroll_pay', 'acc_manual', 'settings_menu']);

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
    const isOwner = String(currentUser?.roles?.name || '') === 'owner';
    const roles = stfState.roles.filter(r => isOwner || !['owner', 'branch_manager'].includes(r));
    const fields = [
        { key: 'name', label: 'اسم الموظف', value: s.name || '', required: true },
        { key: 'role', label: 'الدور', type: 'select', options: roles.map(r => [r, STAFF_ROLE_NAMES[r] || r]), value: s.role || '', placeholder: 'اختار الدور', required: true }];
    if (isOwner && stfState.branches.length > 1) fields.push({ key: 'branch', label: 'الفرع', type: 'select', options: stfState.branches.map(b => [b.id, b.name]), value: s.branch_id || currentUser?.branch_id || '', required: true });
    fields.push({ key: 'salary', label: 'المرتب الشهري (صفر لو مفيش)', type: 'money', min: 0, value: s.monthly_salary || 0 },
        { key: 'phone', label: 'التليفون', value: s.phone || '' });
    if (id) fields.push({ key: 'active', label: 'الموظف شغال (لو شيلت العلامة، تذكرته هتتلغي فوراً)', type: 'check', value: s.is_active !== false, full: true });
    else fields.push({ key: 'pin', label: 'الرقم السري (4 أرقام، مينفعش يتكرر)', type: 'pin', required: true });
    const v = await uiForm(id ? 'تعديل موظف' : 'موظف جديد', fields);
    if (!v) return;
    const branchId = v.branch || s.branch_id || currentUser?.branch_id;
    const res = await uiCall('staff_save_secure', { p_data: { id: id || null, name: v.name, role: v.role, branch_id: branchId, monthly_salary: String(v.salary || 0), phone: v.phone || '', is_active: String(id ? v.active : true) } }, id ? 'تم الحفظ' : null);
    if (!res) return;
    if (!id) {
        if (await uiCall('staff_set_pin_secure', { p_staff_id: res.id, p_pin: v.pin }, 'تم إضافة الموظف ورقمه السري')) { stfRenderList(); return; }
        showToast('الموظف اتضاف، بس الرقم السري متحفظش. دوس "رقم سري" جنب اسمه واكتب رقم تاني.', 'error');
    }
    stfRenderList();
}

async function stfSetPin(id) {
    const s = stfState.staff.find(x => x.id === id) || {};
    const v = await uiForm(`رقم سري جديد${s.name ? ' لـ ' + s.name : ''}`, [
        { key: 'pin', label: 'الرقم السري (4 أرقام، مينفعش يتكرر مع موظف تاني)', type: 'pin', required: true },
        { key: 'pin2', label: 'اكتبه تاني للتأكيد', type: 'pin', required: true }],
        { validate: x => x.pin !== x.pin2 ? { key: 'pin2', msg: 'الرقمين مش زي بعض' } : null });
    if (!v) return;
    if (await uiCall('staff_set_pin_secure', { p_staff_id: id, p_pin: v.pin }, 'تم حفظ الرقم السري')) stfRenderList();
}

async function stfAdvance(id) {
    const s = stfState.staff.find(x => x.id === id) || {};
    const v = await uiForm(`سلفة لـ ${s.name || ''}`, [
        { key: 'amount', label: 'المبلغ', type: 'money', min: 0.01, required: true },
        { key: 'source', label: 'الفلوس طالعة منين', type: 'select', options: UI_BOX_OPTIONS(['main_cash', 'bank', 'drawer']), required: true },
        { key: 'reason', label: 'السبب', value: 'سلفة', required: true },
        { key: 'pin', label: 'رقم المدير', type: 'pin', required: true }], { ok: 'صرف السلفة' });
    if (!v) return;
    if (await uiCall('staff_advance_secure', { p_staff_id: id, p_amount: v.amount, p_source: v.source, p_reason: v.reason, p_manager_pin: v.pin }, 'تم صرف السلفة')) stfRenderList();
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
    if (stfState.run && !(await uiConfirm('إعادة التجهيز هتمسح أي تعديلات عملتها على المسودة. موافق؟', 'إعادة التجهيز', true))) return;
    if (await uiCall('payroll_prepare_secure', { p_period: stfState.period + '-01' }, 'تم تجهيز المسودة')) stfRenderPayroll();
}

async function stfPayrollEdit(lineId) {
    const l = (stfState.run?.lines || []).find(x => x.id === lineId);
    if (!l) return;
    const v = await uiForm(`تعديل مرتب ${l.staff}`, [
        { key: 'absent', label: 'أيام الغياب', type: 'number', min: 0, max: 31, value: l.absent_days, required: true },
        { key: 'ledger', label: `خصم العجز والسلف (عليه ${formatCurrency(l.staff_balance)})`, type: 'money', min: 0, value: l.ledger_deduction, required: true },
        { key: 'other', label: 'أي خصم تاني (جزاء مثلاً)', type: 'money', min: 0, value: l.other_deduction, required: true },
        { key: 'bonus', label: 'مكافأة', type: 'money', min: 0, value: l.bonus, required: true },
        { key: 'notes', label: 'ملاحظة', type: 'textarea', value: l.notes || '', full: true }]);
    if (!v) return;
    const res = await uiCall('payroll_line_update_secure', { p_line_id: lineId, p_absent_days: v.absent, p_ledger_deduction: v.ledger,
        p_other_deduction: v.other, p_bonus: v.bonus, p_notes: v.notes || '' }, 'تم التعديل');
    if (res) stfRenderPayroll();
}

async function stfPayrollApprove() {
    const v = await uiForm('اعتماد المرتبات', [
        { type: 'note', label: 'هيتعمل القيد، والعجز والسلف هيتخصموا من رصيد كل موظف، ومش هينفع تتعدل بعدها.' },
        { key: 'pin', label: 'رقم المدير', type: 'pin', required: true }], { ok: 'اعتماد' });
    if (!v) return;
    if (await uiCall('payroll_approve_secure', { p_run_id: stfState.run.id, p_manager_pin: v.pin }, 'تم الاعتماد')) stfRenderPayroll();
}

async function stfPayrollPay() {
    const v = await uiForm(`صرف المرتبات: ${formatCurrency(stfState.run.total_net)}`, [
        { key: 'source', label: 'من فين', type: 'select', options: UI_BOX_OPTIONS(['main_cash', 'bank']), required: true },
        { key: 'pin', label: 'رقم المدير', type: 'pin', required: true }], { ok: 'صرف' });
    if (!v) return;
    if (await uiCall('payroll_pay_secure', { p_run_id: stfState.run.id, p_source: v.source, p_manager_pin: v.pin }, 'تم صرف المرتبات')) stfRenderPayroll();
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
    const isOwner = String(currentUser?.roles?.name || '') === 'owner';
    const builtin = ['owner', 'branch_manager', 'cashier', 'waiter', 'storekeeper'];
    const head = '<tr><th class="p-2 text-[11px] border-b">الصلاحية</th>' + roles.map(r => `<th class="p-2 text-[11px] border-b">${uiEsc(STAFF_ROLE_NAMES[r] || r)}${isOwner && !builtin.includes(r) ? ` <button onclick="stfDeleteRole('${uiEsc(r)}')" title="حذف الدور" class="text-red-600">🗑️</button>` : ''}</th>`).join('') + '</tr>';
    const body = (res.all_perms || []).map(p => (PERM_SUBS.has(p) ? '<tr class="border-b text-[11px] font-bold text-slate-600"><td class="p-2 pr-6">↳ ' : '<tr class="border-b text-xs font-black bg-slate-50"><td class="p-2">📂 ') + uiEsc(PERM_NAMES[p] || p) + '</td>'
        + roles.map(r => `<td class="p-2 text-center"><input type="checkbox" data-perm-role="${uiEsc(r)}" data-perm="${uiEsc(p)}" ${(res.roles[r] || []).includes(p) ? 'checked' : ''}></td>`).join('')
        + '</tr>').join('');
    document.getElementById('stf-body').innerHTML = uiCard('الصلاحيات (المالك عنده كل حاجة دايماً)',
        `<p class="text-[11px] font-bold text-slate-500 mb-2">📂 = الشاشة نفسها تفتح ولا لأ. ↳ = اللي يقدر يعمله جوه الشاشة. مثال: مدير الفرع يفتح المشتريات ويعمل أمر شراء ويستلم، والاعتماد والترحيل للمالك بس.</p><div class="overflow-x-auto"><table class="w-full text-right"><thead>${head}</thead><tbody>${body}</tbody></table></div>`,
        (isOwner ? uiBtn('➕ دور جديد', 'stfAddRole()', 'blue') : '') + uiBtn('حفظ', 'stfSavePerms()', 'green'));
}

async function stfAddRole() {
    const v = await uiForm('دور جديد', [{ key: 'name', label: 'اسم الدور (مثلاً: محاسب، مشرف صالة)', required: true },
        { type: 'note', label: 'بعد ما يتعمل، علّم صلاحياته في الجدول ودوس حفظ. وبعدها اختاره للموظف من شاشة الموظفين.' }], { ok: 'إضافة' });
    if (!v) return;
    if (await uiCall('role_admin_secure', { p_action: 'add', p_name: v.name }, 'اتعمل الدور')) { stfState.tab = 'perms'; renderStaffBody(); }
}

async function stfDeleteRole(name) {
    if (!(await uiConfirm(`تحذف الدور "${name}"؟ (مينفعش لو فيه موظفين عليه)`, 'حذف', true))) return;
    if (await uiCall('role_admin_secure', { p_action: 'delete', p_name: name }, 'اتحذف الدور')) { stfState.tab = 'perms'; renderStaffBody(); }
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
