// js/reports2.js - شاشة التقارير: ٤١ تقرير بفلتر الفترة والفرع، وتصدير Excel و PDF بلوجو الشركة

const REPORT_CATALOG = [
    ['المبيعات', [['sales_daily', 'المبيعات اليومية'], ['sales_monthly', 'المبيعات الشهرية'], ['sales_hourly', 'أوقات الذروة (بالساعة)'],
        ['sales_weekday', 'بأيام الأسبوع'], ['sales_payment_method', 'بطريقة الدفع'], ['sales_order_type', 'بنوع الطلب'],
        ['sales_category', 'بالقسم'], ['sales_item', 'بالصنف'], ['sales_modifiers', 'أكتر الإضافات'], ['sales_waiter', 'بالويتر'],
        ['sales_cashier', 'بالكاشير'], ['sales_compare', 'مقارنة بالفترة اللي قبلها']]],
    ['الربحية', [['item_profit', 'ربحية الأصناف وتصنيف المنيو'], ['category_profit', 'ربحية الأقسام'], ['daily_profit', 'الربح اليومي']]],
    ['الخصومات والإلغاءات', [['discounts_detail', 'الخصومات بالتفصيل'], ['voids_detail', 'الإلغاءات بالتفصيل'], ['refunds_detail', 'المرتجعات والطلبات الملغية']]],
    ['مؤشرات السرقة', [['theft_indicators', 'مؤشرات السرقة لكل موظف'], ['long_open_orders', 'طلبات مفتوحة من وقت طويل'], ['manager_approvals', 'موافقات المديرين']]],
    ['المخازن', [['stock_valuation', 'تقييم المخزون'], ['waste_by_reason', 'الهالك بالسبب'], ['count_variances', 'فروقات الجرد'],
        ['low_stock', 'خامات تحت الحد'], ['stock_turnover', 'دوران المخزون'], ['transfers', 'التحويلات']]],
    ['المشتريات', [['purchases_by_supplier', 'بالمورد'], ['purchases_by_ingredient', 'بالخامة'], ['price_changes', 'تغيّر الأسعار'],
        ['unmatched_invoices', 'فواتير مش مطابقة'], ['supplier_aging', 'أعمار ديون الموردين']]],
    ['الخزينة', [['cash_movements', 'حركة النقدية'], ['shifts', 'الورديات وفروقها'], ['expenses_by_category', 'المصروفات بالبند']]],
    ['العملاء', [['customer_balances', 'أرصدة الآجل'], ['top_customers', 'أكتر العملاء شراء']]],
    ['الموظفين', [['attendance', 'الحضور والتأخير'], ['tips_by_staff', 'الإكراميات'], ['staff_balances', 'أرصدة العجز والسلف']]],
    ['الضرايب', [['vat_monthly', 'ضريبة القيمة المضافة الشهرية']]]
];

let rptState = { key: 'sales_daily', from: null, to: null, branch: '', branches: [], last: null };

async function loadReportsScreen() {
    const root = document.getElementById('reports-root');
    if (!root) return;
    if (!rptState.from) { rptState.from = uiToday(-30); rptState.to = uiToday(); }
    const isOwner = String(currentUser?.roles?.name || '') === 'owner';
    if (isOwner && !rptState.branches.length) {
        const { data } = await _supabase.from('branches').select('id, name').order('name');
        rptState.branches = data || [];
    }
    const catalog = REPORT_CATALOG.map(([group, items]) => `<div class="mb-3"><p class="text-[11px] font-black text-slate-400 mb-1">${uiEsc(group)}</p>
        <div class="flex flex-wrap gap-1">${items.map(([k, label]) => `<button onclick="runReport('${k}')" class="px-2.5 py-1 rounded-lg text-[11px] font-bold ${k === rptState.key ? 'bg-blue-600 text-white' : 'bg-slate-100 text-slate-700 hover:bg-slate-200'}">${uiEsc(label)}</button>`).join('')}</div></div>`).join('');
    root.innerHTML = uiCard('التقارير', `
        <div class="flex flex-wrap items-end gap-2 mb-4">
            <label class="text-xs font-bold">من<br><input id="rpt-from" type="date" value="${uiEsc(rptState.from)}" class="${uiInputClass()}"></label>
            <label class="text-xs font-bold">إلى<br><input id="rpt-to" type="date" value="${uiEsc(rptState.to)}" class="${uiInputClass()}"></label>
            ${isOwner ? `<label class="text-xs font-bold">الفرع<br><select id="rpt-branch" class="${uiInputClass()}"><option value="">كل الفروع</option>${rptState.branches.map(b => `<option value="${uiEsc(b.id)}" ${b.id === rptState.branch ? 'selected' : ''}>${uiEsc(b.name)}</option>`).join('')}</select></label>` : ''}
            ${uiBtn('اليوم', "rptQuick(0)", 'gray')}${uiBtn('آخر ٧ أيام', "rptQuick(6)", 'gray')}${uiBtn('الشهر ده', "rptQuick('month')", 'gray')}${uiBtn('آخر ٣٠ يوم', "rptQuick(29)", 'gray')}
        </div>
        ${catalog}
        <div id="rpt-result" class="mt-4"></div>`);
    runReport(rptState.key);
}

function rptQuick(days) {
    const to = uiToday();
    let from;
    if (days === 'month') { from = to.slice(0, 8) + '01'; } else { from = uiToday(-days); }
    document.getElementById('rpt-from').value = from;
    document.getElementById('rpt-to').value = to;
    runReport(rptState.key);
}

function rptFormat(col, v) {
    if (v === null || v === undefined || v === '') return '<span class="text-slate-300">-</span>';
    if (col.type === 'm') return `<span class="${Number(v) < 0 ? 'text-red-600' : ''}">${formatCurrency(v)}</span>`;
    if (col.type === 'p') return `${(Number(v) || 0).toFixed(1)}%`;
    if (col.type === 'n') return uiEsc(Number(v));
    return uiEsc(v);
}

async function runReport(key) {
    rptState.key = key;
    rptState.from = document.getElementById('rpt-from')?.value || rptState.from;
    rptState.to = document.getElementById('rpt-to')?.value || rptState.to;
    rptState.branch = document.getElementById('rpt-branch')?.value || '';
    document.querySelectorAll('#reports-root button[onclick^="runReport"]').forEach(b => {
        const on = b.getAttribute('onclick') === `runReport('${key}')`;
        b.className = `px-2.5 py-1 rounded-lg text-[11px] font-bold ${on ? 'bg-blue-600 text-white' : 'bg-slate-100 text-slate-700 hover:bg-slate-200'}`;
    });
    const box = document.getElementById('rpt-result');
    if (!box) return;
    box.innerHTML = '<p class="text-xs text-slate-400 font-bold">جاري التحميل...</p>';
    const res = await uiCall('report_secure', { p_key: key, p_from: rptState.from, p_to: rptState.to, p_branch_id: rptState.branch || null });
    if (!res) { box.innerHTML = ''; return; }
    rptState.last = res;
    const totals = typeof reportTotals === 'function' ? reportTotals(res) : null;
    const head = res.columns.map(c => `<th class="p-2 text-[11px] text-white bg-blue-700 font-black">${uiEsc(c.label)}</th>`).join('');
    const body = res.rows.map((r, i) => `<tr class="text-xs font-bold ${i % 2 ? 'bg-slate-50' : ''}">${res.columns.map(c => `<td class="p-2 border-b">${rptFormat(c, r[c.key])}</td>`).join('')}</tr>`).join('');
    const foot = totals ? `<tr class="text-xs font-black bg-blue-50">${res.columns.map((c, i) => `<td class="p-2">${i === 0 ? 'الإجمالي' : (totals[c.key] !== undefined ? rptFormat(c, totals[c.key]) : '')}</td>`).join('')}</tr>` : '';
    box.innerHTML = `
        <div class="flex flex-wrap justify-between items-center gap-2 mb-2">
            <div><h3 class="font-black text-sm text-blue-800">${uiEsc(res.title)}</h3>
            <p class="text-[11px] font-bold text-slate-500">${uiEsc(res.from)} إلى ${uiEsc(res.to)} | ${uiEsc(res.branch)} | ${res.rows.length} سطر</p></div>
            <div class="flex gap-2">${uiBtn('تصدير Excel 📗', 'exportReportExcel(rptState.last)', 'green')}${uiBtn('PDF / طباعة 📄', 'printReportPdf(rptState.last)', 'red')}</div>
        </div>
        ${res.rows.length ? `<div class="overflow-x-auto"><table class="w-full text-right"><thead><tr>${head}</tr></thead><tbody>${body}${foot}</tbody></table></div>`
            : '<p class="text-center text-slate-400 font-bold text-xs py-6">مفيش بيانات في الفترة دي</p>'}`;
}
