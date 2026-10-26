// js/purchase_print.js - الطباعة والتصدير في موديول المشتريات
// قوائم التبويبات: نفس آلة التقارير (طباعة/PDF من المتصفح + إكسل بلوجو الشركة).
// الورق الرسمي: أمر شراء، إشعار استلام، كشف حساب مورد — أوراق تمشي مع المورد والمخزن وتتوقع.

const PUR_PRINT_CSS = `@page { size: A4 portrait; margin: 12mm; } body { font-size: 12px; }
 .hdr { display: flex; align-items: center; justify-content: space-between; gap: 12px; border-bottom: 3px solid #1d4ed8; padding-bottom: 8px; margin-bottom: 10px; }
 .hdr img { max-height: 60px; max-width: 160px; } .co { font-size: 20px; font-weight: bold; color: #1e3a8a; } .sub { color: #555; }
 h1 { font-size: 17px; margin: 4px 0 2px; color: #1e3a8a; } .docno { font-size: 14px; font-weight: bold; }
 .box { display: flex; flex-wrap: wrap; gap: 4px 24px; background: #f3f6fb; border: 1px solid #dbe3f0; border-radius: 6px; padding: 7px 10px; margin: 8px 0; }
 .box div { min-width: 30%; } .box b { color: #1e3a8a; }
 table { width: 100%; border-collapse: collapse; } th { background: #1d4ed8; color: #fff; padding: 5px; border: 1px solid #1d4ed8; font-size: 11px; }
 td { padding: 4px 6px; border: 1px solid #ddd; } tr:nth-child(even) td { background: #f3f6fb; }
 .num { text-align: left; white-space: nowrap; } .tot td { font-weight: bold; background: #e0e7ff !important; }
 .sig { display: flex; justify-content: space-between; gap: 16px; margin-top: 18mm; } .sig div { flex: 1; text-align: center; border-top: 1px solid #000; padding-top: 4px; }
 .foot { margin-top: 10px; color: #555; font-size: 10px; display: flex; justify-content: space-between; }
 thead { display: table-header-group; }`;

const PUR_LEDGER_NAMES = { invoice: 'فاتورة', payment: 'سداد', adjustment: 'تسوية / رصيد أول المدة' };
const PUR_GRN_STATUS = { pending: 'بانتظار الترحيل', posted: 'تم ترحيله', voided: 'تم إلغاؤه' };

function purCompany() { return (typeof appSettings !== 'undefined' && appSettings && appSettings.general) || {}; }
function purUserName() { return (typeof currentUser !== 'undefined' && currentUser && currentUser.name) || ''; }
function purBranchName() { return (typeof currentBranch !== 'undefined' && currentBranch && currentBranch.name) || ''; }
function purMoney(v) { return (Number(v) || 0).toFixed(2); }
function purNum(v) { const n = Number(v); return Number.isFinite(n) ? String(n) : ''; }

// ورقة رسمية: ترويسة الشركة + بيانات العملية + جدول + إجماليات + توقيعات
function purDocHtml(doc) {
    const g = purCompany();
    const info = (doc.info || []).filter(x => x && String(x[1] || '').trim() !== '')
        .map(x => `<div>${uiEsc(x[0])}: <b>${uiEsc(x[1])}</b></div>`).join('');
    const numeric = doc.numeric || [];
    const cols = doc.cols || [];
    const head = cols.map(c => `<th>${uiEsc(c)}</th>`).join('');
    const body = (doc.rows || []).map(r => '<tr>' + r.map((cell, i) => `<td class="${numeric[i] ? 'num' : ''}">${uiEsc(cell)}</td>`).join('') + '</tr>').join('');
    const totals = (doc.totals || []).map(t => `<tr class="tot"><td colspan="${Math.max(1, cols.length - 1)}">${uiEsc(t[0])}</td><td class="num">${uiEsc(t[1])}</td></tr>`).join('');
    const sig = (doc.sig || []).map(l => `<div>${uiEsc(l)}</div>`).join('');
    return `
        <div class="hdr">
            <div>${g.logo ? `<img src="${uiEsc(g.logo)}">` : ''}</div>
            <div class="sub" style="text-align:left">${uiEsc([g.address, g.phone, g.tax_number ? 'رقم ضريبي ' + g.tax_number : ''].filter(Boolean).join(' | '))}</div>
        </div>
        <div class="co">${uiEsc(g.company_name || '')}</div>
        <h1>${uiEsc(doc.title)}</h1>
        ${doc.docNo ? `<div class="docno">${uiEsc(doc.docNo)}</div>` : ''}
        <div class="box">${info || '<div>بدون بيانات</div>'}</div>
        <table><thead><tr>${head}</tr></thead><tbody>${body || `<tr><td colspan="${cols.length}">لا توجد بيانات</td></tr>`}${totals}</tbody></table>
        ${doc.note ? `<p style="margin-top:6px">ملاحظات: ${uiEsc(doc.note)}</p>` : ''}
        <div class="sig">${sig}</div>
        <div class="foot"><span>طُبعت في ${uiEsc(uiDate(new Date().toISOString()))}</span><span>بواسطة: ${uiEsc(purUserName())}</span></div>`;
}

function printPurDoc(doc) { printHtml(purDocHtml(doc), PUR_PRINT_CSS); }

// شريط الأزرار فوق كل تبويب: طباعة القائمة (ومنھا حفظ PDF) + إكسل
function purBar(repFnName) {
    return uiBtn('🖨️ طباعة / حفظ PDF', `printReportPdf(${repFnName}())`, 'red')
        + uiBtn('📗 تصدير الإكسل', `exportReportExcel(${repFnName}())`, 'green');
}

function purPeriod(list, dateKey) {
    const today = purTodayLabel();
    const dates = (list || []).map(x => x && x[dateKey]).filter(Boolean).sort();
    if (!dates.length) return { from: today, to: today };
    return { from: uiDate(dates[0]).split(' ')[0], to: uiDate(dates[dates.length - 1]).split(' ')[0] };
}

function purTodayLabel() { return uiDate(new Date().toISOString()).split(' ')[0]; }

// ---------------------------------------------------------------- أوامر الشراء
function purOrdersCols(onlyOpen) {
    const c = [{ key: 'po_number', label: 'رقم الأمر', type: 't' }, { key: 'date', label: 'التاريخ', type: 't' },
        { key: 'supplier', label: 'المورد', type: 't' }, { key: 'warehouse', label: 'المخزن', type: 't' },
        { key: 'state', label: 'الحالة', type: 't' }, { key: 'ingredient', label: onlyOpen ? 'الخامة الناقصة' : 'الخامة', type: 't' },
        { key: 'unit', label: 'الوحدة', type: 't' }, { key: 'quantity', label: 'المطلوب', type: 'n' }];
    if (!onlyOpen) c.push({ key: 'qty_received', label: 'اللي وصل', type: 'n' });
    c.push({ key: 'remaining', label: 'الباقي', type: 'n' }, { key: 'unit_price', label: 'سعر الوحدة', type: 'm' },
        { key: 'line_total', label: 'إجمالي السطر', type: 'm' }, { key: 'total', label: 'إجمالي الأمر', type: 'm' },
        { key: 'received_value', label: 'قيمة المستلم', type: 'm' }, { key: 'invoiced_value', label: 'قيمة المفوتَر', type: 'm' },
        { key: 'notes', label: 'ملاحظات', type: 't' });
    return c;
}

function purOrdersRows(orders, onlyOpen) {
    const rows = [];
    (orders || []).forEach(o => {
        const lines = (o.lines || []).filter(l => !onlyOpen || round2(Number(l.quantity) - Number(l.qty_received)) > 0);
        if (onlyOpen && !lines.length) return;
        // إجماليات الأمر بتتكتب على أول سطر بس، عشان مجموع العمود في الإكسل والـ PDF يطلع صح من غير تكرار
        const head = { po_number: o.po_number || '', date: uiDate(o.created_at), supplier: o.supplier || '', warehouse: o.warehouse || '',
            state: PUR_STATUS[o.status] || o.status, total: Number(o.total) || 0, received_value: Number(o.received_value) || 0,
            invoiced_value: Number(o.invoiced_value) || 0, notes: o.notes || '', qty_received: null };
        const rest = { ...head, total: null, received_value: null, invoiced_value: null, notes: '' };
        if (!lines.length) return rows.push({ ...head, ingredient: '', unit: '', quantity: null, remaining: null, unit_price: null, line_total: null });
        lines.forEach((l, i) => rows.push({ ...(i ? rest : head), ingredient: l.ingredient || '', unit: l.unit || '', quantity: Number(l.quantity) || 0,
            qty_received: onlyOpen ? null : (Number(l.qty_received) || 0), remaining: round2(Number(l.quantity) - Number(l.qty_received)),
            unit_price: Number(l.unit_price) || 0, line_total: round2(Number(l.quantity) * Number(l.unit_price)) }));
    });
    return rows;
}

function purOrdersRep() {
    const p = purPeriod(purState.orders, 'created_at');
    return { title: 'أوامر الشراء', from: p.from, to: p.to, branch: purBranchName(), columns: purOrdersCols(false), rows: purOrdersRows(purState.orders, false) };
}

function purReceiveRep() {
    const open = (purState.orders || []).filter(o => o.status === 'approved' || o.status === 'partially_received');
    const p = purPeriod(open, 'created_at');
    return { title: 'أوامر بانتظار الاستلام', from: p.from, to: p.to, branch: purBranchName(), columns: purOrdersCols(true), rows: purOrdersRows(open, true) };
}

// ---------------------------------------------------------------- استلام البضاعة
function purGrnRep() {
    const list = purState.grns || [];
    const rows = [];
    list.forEach(g => {
        const head = { grn_number: g.grn_number || '', po_number: g.po_number || '', supplier: g.supplier || '', warehouse: g.warehouse || '',
            received_at: uiDate(g.received_at), received_by: g.received_by || '-', state: PUR_GRN_STATUS[g.status] || g.status,
            posted_by: g.posted_by || '', posted_at: g.posted_at ? uiDate(g.posted_at) : '', files: Number(g.files) || 0,
            value: Number(g.value) || 0, notes: g.notes || '' };
        // قيمة الاستلام وعدد الصور على أول سطر بس (زي إجمالي الأمر) عشان المجاميع تطلع صح
        const rest = { ...head, value: null, files: null };
        const lines = g.lines || [];
        if (!lines.length) return rows.push({ ...head, ingredient: '', unit: '', ordered: null, qty: null, short: null, unit_cost: null, total: null });
        lines.forEach((l, i) => rows.push({ ...(i ? rest : head), ingredient: l.ingredient || '', unit: l.unit || '', ordered: Number(l.ordered) || 0,
            qty: Number(l.qty) || 0, short: round2(Number(l.ordered) - Number(l.qty)), unit_cost: Number(l.unit_cost) || 0, total: Number(l.total) || 0 }));
    });
    const p = purPeriod(list, 'received_at');
    return { title: 'عمليات استلام البضاعة', from: p.from, to: p.to, branch: purBranchName(),
        columns: [{ key: 'grn_number', label: 'رقم الاستلام', type: 't' }, { key: 'po_number', label: 'رقم أمر الشراء', type: 't' },
            { key: 'supplier', label: 'المورد', type: 't' }, { key: 'warehouse', label: 'المخزن', type: 't' },
            { key: 'received_at', label: 'وقت الاستلام', type: 't' }, { key: 'received_by', label: 'اللي استلم', type: 't' },
            { key: 'state', label: 'الحالة', type: 't' }, { key: 'ingredient', label: 'الخامة', type: 't' },
            { key: 'unit', label: 'الوحدة', type: 't' }, { key: 'ordered', label: 'المطلوب', type: 'n' },
            { key: 'qty', label: 'اللي وصل', type: 'n' }, { key: 'short', label: 'الناقص', type: 'n' },
            { key: 'unit_cost', label: 'سعر الوحدة', type: 'm' }, { key: 'total', label: 'إجمالي السطر', type: 'm' },
            { key: 'value', label: 'قيمة الاستلام', type: 'm' }, { key: 'posted_by', label: 'اللي رحّله', type: 't' },
            { key: 'posted_at', label: 'وقت الترحيل', type: 't' }, { key: 'files', label: 'عدد صور الفاتورة', type: 'n' },
            { key: 'notes', label: 'ملاحظات', type: 't' }],
        rows };
}

// ---------------------------------------------------------------- الموردين وكشف الحساب
function purSuppliersRep() {
    const today = purTodayLabel();
    return { title: 'الموردين والأرصدة', from: today, to: today, branch: purBranchName(),
        columns: [{ key: 'name', label: 'المورد', type: 't' }, { key: 'phone', label: 'التليفون', type: 't' },
            { key: 'company_name', label: 'الشركة', type: 't' }, { key: 'tax_number', label: 'الرقم الضريبي', type: 't' },
            { key: 'state', label: 'الحالة', type: 't' }, { key: 'balance', label: 'الرصيد', type: 'm' },
            { key: 'side', label: 'الرصيد ليه أو لينا', type: 't' }],
        rows: (purState.suppliers || []).map(s => ({ name: s.name || '', phone: s.phone || '', company_name: s.company_name || '',
            tax_number: s.tax_number || '', state: s.is_active === false ? 'موقوف' : 'يعمل', balance: Number(s.balance) || 0,
            side: Number(s.balance) > 0 ? 'علينا للمورد' : (Number(s.balance) < 0 ? 'لنا عند المورد' : 'مسدّد') })) };
}

function purStatementRep() {
    const st = purState.lastStatement || { entries: [] };
    const p = purPeriod(st.entries, 'at');
    return { title: `كشف حساب ${st.supplier || ''}`.trim(), from: p.from, to: p.to, branch: purBranchName(),
        columns: [{ key: 'at', label: 'التاريخ', type: 't' }, { key: 'type', label: 'النوع', type: 't' },
            { key: 'reference', label: 'المرجع', type: 't' }, { key: 'amount', label: 'المبلغ', type: 'm' },
            { key: 'balance_after', label: 'الرصيد بعده', type: 'm' }],
        rows: (st.entries || []).map(e => ({ at: uiDate(e.at), type: PUR_LEDGER_NAMES[e.type] || e.type, reference: e.reference || '',
            amount: Number(e.amount) || 0, balance_after: Number(e.balance_after) || 0 })) };
}

// ---------------------------------------------------------------- تاريخ الأسعار
function purPricesRep() {
    const pr = purState.lastPrices || { current: [], history: [] };
    const p = purPeriod(pr.history, 'at');
    return { title: `تاريخ أسعار ${pr.ingredient || ''}`.trim(), from: p.from, to: p.to, branch: purBranchName(),
        columns: [{ key: 'part', label: 'القسم', type: 't' }, { key: 'at', label: 'التاريخ', type: 't' },
            { key: 'supplier', label: 'المورد', type: 't' }, { key: 'qty', label: 'الكمية', type: 'n' },
            { key: 'unit_cost', label: 'سعر الوحدة', type: 'm' }, { key: 'grn', label: 'رقم الاستلام', type: 't' }],
        rows: [...(pr.current || []).map(c => ({ part: 'السعر الحالي', at: '', supplier: c.supplier || '', qty: null, unit_cost: Number(c.unit_price) || 0, grn: '' })),
            ...(pr.history || []).map(h => ({ part: 'استلام سابق', at: uiDate(h.at), supplier: h.supplier || '', qty: Number(h.qty) || 0,
                unit_cost: Number(h.unit_cost) || 0, grn: h.grn || '' }))] };
}

// ---------------------------------------------------------------- الورق الرسمي
function purSupplierOf(o) { return (purState.suppliers || []).find(s => s.id === (o && o.supplier_id)) || {}; }

function purOrderDocRows(lines) {
    return (lines || []).map((l, i) => [String(i + 1), l.ingredient || '', l.unit || '', purNum(l.quantity), purNum(l.unit_price),
        purMoney(Number(l.quantity) * Number(l.unit_price))]);
}

// أمر شراء: ورقة تمشي مع المورد
function purPrintOrder(id) {
    const o = (purState.orders || []).find(x => x.id === id);
    if (!o) return showToast('اقفل شاشة المشتريات وارجع افتحها', 'error');
    const s = purSupplierOf(o);
    printPurDoc({
        title: 'أمر شراء', docNo: o.po_number || '',
        info: [['التاريخ', uiDate(o.created_at)], ['المورد', o.supplier || ''], ['تليفون المورد', s.phone || ''],
            ['الشركة', s.company_name || ''], ['الرقم الضريبي', s.tax_number || ''], ['المخزن', o.warehouse || ''],
            ['الحالة', PUR_STATUS[o.status] || o.status]],
        cols: ['#', 'الخامة', 'الوحدة', 'الكمية', 'سعر الوحدة', 'الإجمالي'],
        numeric: [true, false, false, true, true, true],
        rows: purOrderDocRows(o.lines),
        totals: [['الإجمالي', formatCurrency(o.total)], ['اللي وصل', formatCurrency(o.received_value)], ['اللي اتفوتر', formatCurrency(o.invoiced_value)]],
        note: o.notes || '',
        sig: ['المورد', 'المشتري', 'مدير الفرع'] });
}

// مسودة أمر شراء وأنت لسه بتكتبها (قبل الحفظ)
function purPrintDraft() {
    const supSel = document.getElementById('pur-new-sup'), whSel = document.getElementById('pur-new-wh');
    if (!supSel || !supSel.value) return showToast('اختر المورد الأول', 'error');
    if (!purState.lines.length) return showToast('أضف خامة واحدة على الأقل', 'error');
    const s = (purState.suppliers || []).find(x => x.id === supSel.value) || {};
    const total = purState.lines.reduce((sum, l) => sum + Number(l.qty) * Number(l.unit_price), 0);
    printPurDoc({
        title: 'أمر شراء (مسودة)', docNo: '',
        info: [['التاريخ', uiDate(new Date().toISOString())], ['المورد', s.name || ''], ['تليفون المورد', s.phone || ''],
            ['الرقم الضريبي', s.tax_number || ''], ['المخزن', whSel && whSel.value ? whSel.options[whSel.selectedIndex].text : '']],
        cols: ['#', 'الخامة', 'الوحدة', 'الكمية', 'سعر الوحدة', 'الإجمالي'],
        numeric: [true, false, false, true, true, true],
        rows: purState.lines.map((l, i) => { const ing = purIng(l.ingredient_id) || {};
            return [String(i + 1), ing.name || '', ing.unit || '', purNum(l.qty), purNum(l.unit_price), purMoney(Number(l.qty) * Number(l.unit_price))]; }),
        totals: [['الإجمالي', formatCurrency(total)]],
        note: (document.getElementById('pur-new-notes') || {}).value || '',
        sig: ['المورد', 'المشتري', 'مدير الفرع'] });
}

// إشعار استلام بضاعة (من تبويب الترحيل)
function purPrintGrn(id) {
    const g = (purState.grns || []).find(x => x.id === id);
    if (!g) return showToast('اقفل شاشة المشتريات وارجع افتحها', 'error');
    printPurDoc({
        title: 'إشعار استلام بضاعة', docNo: g.grn_number || '',
        info: [['رقم أمر الشراء', g.po_number || ''], ['المورد', g.supplier || ''], ['المخزن', g.warehouse || ''],
            ['وقت الاستلام', uiDate(g.received_at)], ['اللي استلم', g.received_by || ''], ['الحالة', PUR_GRN_STATUS[g.status] || g.status],
            ['اللي رحّله', g.posted_by || ''], ['وقت الترحيل', g.posted_at ? uiDate(g.posted_at) : '']],
        cols: ['#', 'الخامة', 'الوحدة', 'المطلوب', 'اللي وصل', 'الناقص', 'سعر الوحدة', 'الإجمالي'],
        numeric: [true, false, false, true, true, true, true, true],
        rows: (g.lines || []).map((l, i) => [String(i + 1), l.ingredient || '', l.unit || '', purNum(l.ordered), purNum(l.qty),
            purNum(round2(Number(l.ordered) - Number(l.qty))), purNum(l.unit_cost), purMoney(l.total)]),
        totals: [['قيمة الاستلام', formatCurrency(g.value)], ['صور فاتورة المورد', `${Number(g.files) || 0} صورة`]],
        note: g.notes || '',
        sig: ['أمين المخزن', 'المورد', 'مدير الفرع'] });
}

// كشف حساب رسمي لمورد
async function purPrintStatement(id) {
    const res = await uiCall('supplier_statement_secure', { p_supplier_id: id });
    if (!res) return;
    const s = (purState.suppliers || []).find(x => x.id === id) || {};
    const entries = res.entries || [];
    const last = entries.length ? entries[entries.length - 1] : null;
    const sumBy = type => Math.abs(entries.filter(e => e.type === type).reduce((t, e) => t + (Number(e.amount) || 0), 0));
    printPurDoc({
        title: 'كشف حساب مورد', docNo: s.name || '',
        info: [['تليفون المورد', s.phone || ''], ['الشركة', s.company_name || ''], ['الرقم الضريبي', s.tax_number || ''],
            ['عدد الحركات', String(entries.length)], ['الفرع', purBranchName()]],
        cols: ['#', 'التاريخ', 'النوع', 'المرجع', 'المبلغ', 'الرصيد بعده'],
        numeric: [true, false, false, false, true, true],
        rows: entries.map((e, i) => [String(i + 1), uiDate(e.at), PUR_LEDGER_NAMES[e.type] || e.type, e.reference || '', purMoney(e.amount), purMoney(e.balance_after)]),
        totals: [['إجمالي الفواتير', formatCurrency(sumBy('invoice'))], ['إجمالي المسدّد', formatCurrency(sumBy('payment'))],
            ['الرصيد الأخير', formatCurrency((last ? last.balance_after : s.balance) || 0)]],
        sig: ['المورد', 'المحاسب', 'مدير الفرع'] });
}
