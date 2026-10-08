// js/purchasing.js - المشتريات والموردين: أوامر الشراء، الاستلام، فواتير الموردين، السداد، تاريخ الأسعار

let purState = { tab: 'orders', suppliers: [], warehouses: [], ingredients: [], lines: [] };
function setPurchasingTab(tab) { purState.tab = tab; renderPurchasingBody(); }

async function loadPurchasingScreen() {
    const root = document.getElementById('purchase-root');
    if (!root) return;
    const [sup, wh, ing] = await Promise.all([
        uiCall('suppliers_secure', { p_data: null }),
        uiCall('inv_warehouses_secure', {}),
        _supabase.from('ingredients').select('id, name, unit').order('name')
    ]);
    purState.suppliers = (sup && sup.suppliers) || [];
    purState.warehouses = ((wh && wh.warehouses) || []).filter(w => w.mine);
    purState.ingredients = ing.data || [];
    renderPurchasingBody();
}

function renderPurchasingBody() {
    const root = document.getElementById('purchase-root');
    if (!root) return;
    root.innerHTML = uiTabs('pur', [['orders', 'أوامر الشراء'], ['new', 'أمر شراء جديد'], ['receive', 'الاستلام الفعلي'], ['post', 'الترحيل للمخازن'],
        ['suppliers', 'الموردين'], ['prices', 'تاريخ الأسعار']], purState.tab, 'setPurchasingTab') + '<div id="pur-body"></div>';
    ({ orders: purRenderOrders, new: purRenderNew, receive: purRenderReceive, post: purRenderPost, suppliers: purRenderSuppliers, prices: purRenderPrices }[purState.tab] || purRenderOrders)();
}

const PUR_STATUS = { draft: 'مسودة (مستني موافقة)', approved: 'موافَق عليه', partially_received: 'استلام جزئي', fully_received: 'اتستلم كله', closed: 'مقفول', cancelled: 'ملغي' };

async function purRenderOrders() {
    const res = await uiCall('po_list_secure', {});
    if (!res) return;
    document.getElementById('pur-body').innerHTML = uiCard('أوامر الشراء (آخر 180 يوم)', uiTable(res.orders, [
        { label: 'الرقم', key: 'po_number' }, { label: 'التاريخ', render: o => uiEsc(uiDate(o.created_at)) },
        { label: 'المورد', key: 'supplier' }, { label: 'المخزن', key: 'warehouse' },
        { label: 'الحالة', render: o => uiEsc(PUR_STATUS[o.status] || o.status) },
        { label: 'الإجمالي', render: o => formatCurrency(o.total) },
        { label: 'المستلم', render: o => formatCurrency(o.received_value) },
        { label: 'بفاتورة', render: o => formatCurrency(o.invoiced_value) },
        { label: 'الخامات', render: o => (o.lines || []).map(l => `${uiEsc(l.ingredient)}: ${uiEsc(Number(l.qty_received))}/${uiEsc(Number(l.quantity))}`).join('<br>') },
        { label: '', render: o => purOrderButtons(o) }], 'مفيش أوامر شراء'));
    purState.orders = res.orders || [];
}

function purOrderButtons(o) {
    const b = [];
    if (o.status === 'draft') b.push(uiBtn('مراجعة وموافقة', `purReview('${o.id}')`, 'green'));
    if (['partially_received', 'fully_received', 'closed'].includes(o.status) && Number(o.received_value) > Number(o.invoiced_value)) b.push(uiBtn('فاتورة المورد', `purInvoice('${o.id}')`, 'amber'));
    if (o.status === 'partially_received' || o.status === 'fully_received') b.push(uiBtn('قفل', `purAction('${o.id}','close')`, 'gray'));
    if (o.status === 'draft' || o.status === 'approved') b.push(uiBtn('إلغاء', `purAction('${o.id}','cancel')`, 'gray'));
    return '<div class="flex flex-wrap gap-1">' + b.join('') + '</div>';
}

// المدير بيشوف أمر الشراء كامل (الخامات والكميات والأسعار) قبل ما يوافق أو يرفض
async function purReview(id) {
    const o = (purState.orders || []).find(x => x.id === id);
    if (!o) return;
    const lines = (o.lines || []).map(l => ({ ...l, total: Number(l.quantity) * Number(l.unit_price) }));
    const table = uiTable(lines, [{ label: 'الخامة', render: l => `${uiEsc(l.ingredient)} (${uiEsc(l.unit)})` }, { label: 'الكمية', render: l => uiEsc(Number(l.quantity)) },
        { label: 'سعر الوحدة', render: l => formatCurrency(l.unit_price) }, { label: 'الإجمالي', render: l => formatCurrency(l.total) }])
        + `<p class="text-sm font-black mt-2">الإجمالي: ${formatCurrency(o.total)} | المورد: ${uiEsc(o.supplier)} | المخزن: ${uiEsc(o.warehouse || '')}</p>`
        + (o.notes ? `<p class="text-[11px] text-slate-500 mt-1">ملاحظات: ${uiEsc(o.notes)}</p>` : '');
    const v = await uiForm(`مراجعة أمر الشراء ${o.po_number || ''}`, [
        { type: 'note', html: table },
        { key: 'decision', label: 'القرار', type: 'select', options: [['approve', 'موافقة ✅'], ['reject', 'رفض ❌']], value: 'approve', required: true },
        { key: 'reason', label: 'سبب الرفض (لو رفض)', type: 'textarea', full: true },
        { key: 'pin', label: 'رقم المدير', type: 'pin', required: true }],
        { ok: 'تنفيذ', validate: x => (x.decision === 'reject' && !String(x.reason || '').trim()) ? 'اكتب سبب الرفض' : null });
    if (!v) return;
    if (await uiCall('po_action_secure', { p_po_id: id, p_action: v.decision, p_manager_pin: v.pin, p_reason: v.reason || null },
        v.decision === 'approve' ? 'تمت الموافقة' : 'اترفض أمر الشراء')) purRenderOrders();
}

async function purAction(id, action) {
    let pin = null;
    if (action === 'approve') {
        const v = await uiForm('موافقة على أمر الشراء', [{ key: 'pin', label: 'رقم المدير', type: 'pin', required: true }], { ok: 'موافقة' });
        if (!v) return;
        pin = v.pin;
    } else if (!(await uiConfirm(action === 'cancel' ? 'إلغاء أمر الشراء؟' : 'قفل أمر الشراء؟ (الباقي مش هيتستلم)', action === 'cancel' ? 'إلغاء الأمر' : 'قفل', true))) {
        return;
    }
    if (await uiCall('po_action_secure', { p_po_id: id, p_action: action, p_manager_pin: pin, p_reason: null }, 'تم')) purRenderOrders();
}

async function purReceive(id) {
    const o = (purState.orders || []).find(x => x.id === id);
    if (!o) return;
    const open = (o.lines || []).map(l => ({ l, remaining: round2(Number(l.quantity) - Number(l.qty_received)) })).filter(x => x.remaining > 0);
    if (!open.length) return showToast('كل الكميات اتستلمت', 'error');
    const fields = [{ type: 'note', label: 'اكتب الكمية اللي وصلت فعلاً وسعرها (صفر = موصلش). الأرقام المكتوبة هي الباقي من الأمر.' }];
    open.forEach((x, i) => fields.push(
        { key: 'q' + i, label: `${x.l.ingredient} (${x.l.unit}): وصل كام؟ (الباقي ${x.remaining})`, type: 'number', min: 0, max: x.remaining, value: x.remaining, required: true },
        { key: 'c' + i, label: `${x.l.ingredient}: سعر الوحدة الفعلي`, type: 'money', min: 0, value: Number(x.l.unit_price), required: true }));
    fields.push({ key: 'notes', label: 'ملاحظات الاستلام (اختياري)', type: 'textarea', full: true });
    const v = await uiForm('استلام بضاعة', fields, { ok: 'استلام', validate: x => open.some((_, i) => x['q' + i] > 0) ? null : 'مفيش كميات اتستلمت' });
    if (!v) return;
    const lines = open.map((x, i) => ({ po_item_id: x.l.id, qty: Number(v['q' + i]), unit_cost: Number(v['c' + i]) })).filter(l => l.qty > 0);
    const res = await uiCall('po_receive_secure', { p_po_id: id, p_lines: lines, p_notes: v.notes || '' });
    if (res) { showToast(`اتسجل الاستلام ${res.grn_number} بقيمة ${formatCurrency(res.value)}. المخزن هيزيد بعد ما المدير يرحّله.`); purRenderReceive(); }
}

// ---------------------------------------------------------------- الاستلام الفعلي (أمين المخزن): بيكتب اللي وصل، والمخزن لسه ما اتحرّكش
async function purRenderReceive() {
    const res = await uiCall('po_list_secure', {});
    if (!res) return;
    purState.orders = res.orders || [];
    const open = purState.orders.filter(o => o.status === 'approved' || o.status === 'partially_received');
    document.getElementById('pur-body').innerHTML = uiCard('أوامر شراء مستنية الاستلام', uiTable(open, [
        { label: 'الرقم', key: 'po_number' }, { label: 'المورد', key: 'supplier' }, { label: 'المخزن', key: 'warehouse' },
        { label: 'الحالة', render: o => uiEsc(PUR_STATUS[o.status] || o.status) },
        { label: 'الخامات (وصل/المطلوب)', render: o => (o.lines || []).map(l => `${uiEsc(l.ingredient)}: ${uiEsc(Number(l.qty_received))}/${uiEsc(Number(l.quantity))}`).join('<br>') },
        { label: '', render: o => uiBtn('استلام', `purReceive('${o.id}')`, 'blue') }], 'مفيش أوامر شراء موافَق عليها مستنية استلام'))
        + '<p class="text-[11px] text-slate-500 font-bold">الاستلام بيسجّل الكميات اللي وصلت بس. المخزن والتكلفة والقيد بيتعملوا لما المدير يرحّل الاستلام من تبويب "الترحيل للمخازن".</p>';
}

// ---------------------------------------------------------------- الترحيل للمخازن (المدير): بيراجع الاستلام ويرحّله
async function purRenderPost(status) {
    purState.postFilter = status || purState.postFilter || 'pending';
    const res = await uiCall('gr_list_secure', { p_status: purState.postFilter });
    if (!res) return;
    const names = { pending: 'مستني ترحيل', posted: 'اترحّل', voided: 'اتلغى' };
    const cards = (res.receipts || []).map(g => uiCard(`${g.grn_number} | ${g.po_number || ''} | ${g.supplier}`,
        `<p class="text-[11px] font-bold text-slate-500 mb-2">المخزن: ${uiEsc(g.warehouse || '')} | استلمه: ${uiEsc(g.received_by || '-')} | ${uiEsc(uiDate(g.received_at))}${g.posted_by ? ' | رحّله: ' + uiEsc(g.posted_by) : ''}${g.notes ? ' | ' + uiEsc(g.notes) : ''}</p>`
        + uiTable(g.lines, [{ label: 'الخامة', render: l => `${uiEsc(l.ingredient)} (${uiEsc(l.unit)})` }, { label: 'المطلوب', render: l => uiEsc(Number(l.ordered)) },
            { label: 'وصل', render: l => uiEsc(Number(l.qty)) }, { label: 'سعر الوحدة', render: l => formatCurrency(l.unit_cost) }, { label: 'الإجمالي', render: l => formatCurrency(l.total) }])
        + `<p class="text-sm font-black mt-2">القيمة: ${formatCurrency(g.value)} | ${uiEsc(names[g.status] || g.status)}</p>`,
        g.status === 'pending' && res.can_post ? uiBtn('ترحيل للمخزن ✅', `purPostGrn('${g.id}','post')`, 'green') + uiBtn('إلغاء الاستلام', `purPostGrn('${g.id}','void')`, 'gray') : '')).join('');
    document.getElementById('pur-body').innerHTML =
        `<div class="flex gap-2 mb-3">${uiBtn('مستني ترحيل', "purRenderPost('pending')", purState.postFilter === 'pending' ? 'blue' : 'gray')}${uiBtn('الكل', "purRenderPost('all')", purState.postFilter === 'all' ? 'blue' : 'gray')}</div>`
        + (res.can_post ? '' : '<p class="text-[11px] text-amber-700 font-bold mb-2">الترحيل للمدير بس (صلاحية موافقات المخازن).</p>')
        + (cards || '<p class="text-center text-slate-400 font-bold text-xs py-6">مفيش استلامات هنا</p>');
}

async function purPostGrn(id, action) {
    const msg = action === 'post' ? 'ترحّل الاستلام ده؟ المخزن هيزيد، والتكلفة هتتحسب، والقيد هيتعمل.' : 'تلغي الاستلام ده؟ الكميات هترجع لأمر الشراء كأنها موصلتش.';
    if (!(await uiConfirm(msg, action === 'post' ? 'ترحيل' : 'إلغاء الاستلام', action !== 'post'))) return;
    if (await uiCall('gr_action_secure', { p_grn_id: id, p_action: action }, action === 'post' ? 'اترحّل للمخزن' : 'اتلغى الاستلام')) purRenderPost();
}

async function purInvoice(id) {
    const o = (purState.orders || []).find(x => x.id === id);
    if (!o) return;
    const uninvoiced = round2(Number(o.received_value) - Number(o.invoiced_value));
    const v = await uiForm('فاتورة المورد', [
        { type: 'note', label: `المستلم من غير فاتورة: ${formatCurrency(uninvoiced)}` },
        { key: 'num', label: 'رقم فاتورة المورد', required: true },
        { key: 'date', label: 'تاريخ الفاتورة', type: 'date', value: uiToday(), required: true },
        { key: 'amount', label: 'قيمة الفاتورة من غير الضريبة', type: 'money', min: 0, value: uninvoiced, required: true },
        { key: 'tax', label: 'ضريبة القيمة المضافة (صفر لو مفيش)', type: 'money', min: 0, value: 0, required: true }]);
    if (!v) return;
    const res = await uiCall('supplier_invoice_secure', { p_po_id: id, p_invoice_number: v.num, p_invoice_date: v.date, p_amount: v.amount, p_tax_amount: v.tax });
    if (!res) return;
    if (res.matched) showToast('تم تسجيل الفاتورة، ومطابقة للاستلام ✅');
    else showToast(`تم تسجيل الفاتورة، بس مش مطابقة: فرق ${formatCurrency(res.difference)} عن قيمة الاستلام ${formatCurrency(res.received_value)}`, 'error');
    purRenderOrders();
}

function purRenderNew() {
    document.getElementById('pur-body').innerHTML = uiCard('أمر شراء جديد', `
        <div class="grid grid-cols-1 md:grid-cols-2 gap-2 mb-3">
            <select id="pur-new-sup" class="${uiInputClass()}">${uiOptions(purState.suppliers.filter(s => s.is_active !== false), 'id', s => s.name, 'اختار المورد')}</select>
            <select id="pur-new-wh" class="${uiInputClass()}">${uiOptions(purState.warehouses, 'id', w => w.name, 'اختار المخزن')}</select>
        </div>
        <div class="flex flex-wrap gap-2 mb-2">
            <select id="pur-new-ing" onchange="purShowLastPrice()" class="${uiInputClass()}">${uiOptions(purState.ingredients, 'id', i => `${i.name} (${i.unit})`, 'اختار الخامة')}</select>
            <input id="pur-new-qty" type="number" min="0" step="any" placeholder="الكمية" class="${uiInputClass()} w-28">
            <input id="pur-new-price" type="number" min="0" step="0.0001" placeholder="سعر الوحدة" class="${uiInputClass()} w-28">
            ${uiBtn('إضافة', 'purAddLine()', 'gray')}
        </div>
        <div id="pur-last-price" class="text-[11px] font-bold text-slate-500 mb-2"></div>
        <div id="pur-new-lines"></div>
        <input id="pur-new-notes" type="text" placeholder="ملاحظات" class="${uiInputClass()} w-full mt-2">
        <div class="mt-3">${uiBtn('حفظ كمسودة', 'purSubmitNew()', 'blue')}</div>`);
    purRenderLines();
}

function purAddLine() {
    const ing = document.getElementById('pur-new-ing').value;
    const qty = Number(document.getElementById('pur-new-qty').value);
    const price = Number(document.getElementById('pur-new-price').value);
    if (!ing || !(qty > 0) || !(price >= 0) || document.getElementById('pur-new-price').value === '') return showToast('اختار الخامة واكتب الكمية والسعر', 'error');
    if (purState.lines.some(l => l.ingredient_id === ing)) return showToast('الخامة موجودة بالفعل', 'error');
    purState.lines.push({ ingredient_id: ing, qty, unit_price: price });
    // نفضّي الخانات عشان الخامة الجاية متاخدش كمية وسعر اللي قبلها
    document.getElementById('pur-new-ing').value = '';
    document.getElementById('pur-new-qty').value = '';
    document.getElementById('pur-new-price').value = '';
    document.getElementById('pur-new-ing').focus();
    const lp = document.getElementById('pur-last-price'); if (lp) lp.innerHTML = '';
    purRenderLines();
}

// آخر سعر شراء للخامة، وزرار لآخر ٥ استلامات
async function purShowLastPrice() {
    const ing = document.getElementById('pur-new-ing').value;
    const box = document.getElementById('pur-last-price');
    if (!box) return;
    if (!ing) { box.innerHTML = ''; return; }
    box.innerHTML = 'جاري التحميل...';
    let res = null;
    try { res = await serverRpc('price_history_secure', { p_ingredient_id: ing }); } catch (e) { res = null; }
    const hist = (res && res.history) || [];
    purState.lastHistory = hist;
    if (!hist.length) { box.innerHTML = 'مفيش شراء قبل كده للخامة دي.'; return; }
    const h = hist[0];
    box.innerHTML = `آخر سعر شراء: <b class="text-slate-800">${formatCurrency(h.unit_cost)}</b> من ${uiEsc(h.supplier)} يوم ${uiEsc(uiDate(h.at))} ${uiBtn('آخر ٥ فواتير', 'purShowLast5()', 'gray')}`;
    const price = document.getElementById('pur-new-price');
    if (price && price.value === '') price.value = Number(h.unit_cost);
}

async function purShowLast5() {
    const rows = (purState.lastHistory || []).slice(0, 5);
    await uiForm('آخر ٥ استلامات للخامة', [{ type: 'note', html: uiTable(rows, [{ label: 'التاريخ', render: x => uiEsc(uiDate(x.at)) },
        { label: 'المورد', key: 'supplier' }, { label: 'الكمية', key: 'qty' }, { label: 'سعر الوحدة', render: x => formatCurrency(x.unit_cost) },
        { label: 'الاستلام', key: 'grn' }], 'مفيش') }], { ok: 'قفل' });
}

async function purRemoveLine(idx) {
    if (!(await uiConfirm('تحذف السطر ده من أمر الشراء؟', 'حذف', true))) return;
    purState.lines.splice(idx, 1); purRenderLines();
}

async function purEditLine(idx) {
    const l = purState.lines[idx];
    if (!l) return;
    const v = await uiForm('تعديل السطر', [
        { key: 'qty', label: 'الكمية', type: 'number', value: l.qty, required: true },
        { key: 'price', label: 'سعر الوحدة', type: 'number', value: l.unit_price, required: true }]);
    if (!v) return;
    const qty = Number(v.qty), price = Number(v.price);
    if (!(qty > 0) || !(price >= 0)) return showToast('الكمية لازم أكبر من صفر والسعر صفر أو أكتر', 'error');
    l.qty = qty; l.unit_price = price; purRenderLines();
}

function purRenderLines() {
    const box = document.getElementById('pur-new-lines');
    if (!box) return;
    const names = Object.fromEntries(purState.ingredients.map(i => [i.id, `${i.name} (${i.unit})`]));
    const total = purState.lines.reduce((s, l) => s + l.qty * l.unit_price, 0);
    box.innerHTML = purState.lines.length ? uiTable(purState.lines.map((l, idx) => ({ ...l, idx })), [
        { label: 'الخامة', render: l => uiEsc(names[l.ingredient_id]) }, { label: 'الكمية', key: 'qty' },
        { label: 'السعر', render: l => formatCurrency(l.unit_price) }, { label: 'الإجمالي', render: l => formatCurrency(l.qty * l.unit_price) },
        { label: '', render: l => '<div class="flex gap-1">' + uiBtn('تعديل', `purEditLine(${l.idx})`, 'gray') + uiBtn('حذف', `purRemoveLine(${l.idx})`, 'red') + '</div>' }]) + `<p class="text-xs font-black mt-2">الإجمالي: ${formatCurrency(total)}</p>` : '';
}

async function purSubmitNew() {
    const sup = document.getElementById('pur-new-sup').value;
    const wh = document.getElementById('pur-new-wh').value;
    if (!sup || !wh || !purState.lines.length) return showToast('اختار المورد والمخزن وضيف خامة واحدة على الأقل', 'error');
    const res = await uiCall('po_create_secure', { p_supplier_id: sup, p_warehouse_id: wh, p_lines: purState.lines,
        p_notes: document.getElementById('pur-new-notes').value });
    if (res) { showToast(`تم حفظ أمر الشراء ${res.po_number}. محتاج موافقة المدير.`); purState.lines = []; setPurchasingTab('orders'); }
}

function purRenderSuppliers() {
    document.getElementById('pur-body').innerHTML = uiCard('الموردين', uiTable(purState.suppliers, [
        { label: 'الاسم', key: 'name' }, { label: 'التليفون', key: 'phone' }, { label: 'الشركة', key: 'company_name' },
        { label: 'الرصيد', render: s => `<b class="${Number(s.balance) > 0 ? 'text-red-600' : (Number(s.balance) < 0 ? 'text-emerald-700' : '')}">${formatCurrency(Math.abs(Number(s.balance) || 0))}${Number(s.balance) > 0 ? ' ليه' : (Number(s.balance) < 0 ? ' لينا' : '')}</b>` },
        { label: 'الحالة', render: s => s.is_active === false ? 'موقوف' : 'شغال' },
        { label: '', render: s => '<div class="flex flex-wrap gap-1">' + uiBtn('كشف حساب', `purStatement('${s.id}')`, 'gray')
            + uiBtn('سداد', `purPay('${s.id}')`, 'green') + uiBtn('تعديل', `purEditSupplier('${s.id}')`, 'gray') + '</div>' }], 'مفيش موردين'),
        uiBtn('إضافة مورد', 'purEditSupplier(null)', 'blue')) + '<div id="pur-statement"></div>';
}

async function purEditSupplier(id) {
    const s = id ? purState.suppliers.find(x => x.id === id) : {};
    const fields = [
        { key: 'name', label: 'اسم المورد', value: s.name || '', required: true },
        { key: 'phone', label: 'التليفون', value: s.phone || '' },
        { key: 'company', label: 'اسم الشركة (اختياري)', value: s.company_name || '' },
        { key: 'tax', label: 'الرقم الضريبي (اختياري)', value: s.tax_number || '' }];
    if (id) fields.push({ key: 'active', label: 'المورد شغال', type: 'check', value: s.is_active !== false });
    else fields.push({ type: 'note', label: 'رصيد سابق (اختياري): لو المورد ليه فلوس عندنا أو علينا من قبل البرنامج' },
        { key: 'opening', label: 'الرصيد السابق', type: 'money', min: 0, value: 0 },
        { key: 'side', label: 'الرصيد ده', type: 'select', options: [['we_owe', 'ليه علينا (احنا مديونين له)'], ['they_owe', 'لينا عنده (هو مديون لنا)']], value: 'we_owe' });
    const v = await uiForm(id ? 'تعديل مورد' : 'مورد جديد', fields);
    if (!v) return;
    const res = await uiCall('suppliers_secure', { p_data: { id: id || null, name: v.name, phone: v.phone, company_name: v.company, tax_number: v.tax, is_active: String(id ? v.active : true),
        opening_amount: id ? null : (Number(v.opening) || 0), opening_side: id ? null : v.side } }, 'تم الحفظ');
    if (res) { purState.suppliers = res.suppliers || []; purRenderSuppliers(); }
}

async function purStatement(id) {
    const res = await uiCall('supplier_statement_secure', { p_supplier_id: id });
    const s = purState.suppliers.find(x => x.id === id) || {};
    const names = { invoice: 'فاتورة', payment: 'سداد', adjustment: 'تسوية / رصيد أول المدة' };
    if (res) document.getElementById('pur-statement').innerHTML = uiCard(`كشف حساب ${s.name || ''}`, uiTable(res.entries, [
        { label: 'التاريخ', render: e => uiEsc(uiDate(e.at)) }, { label: 'النوع', render: e => uiEsc(names[e.type] || e.type) },
        { label: 'المبلغ', render: e => formatCurrency(e.amount) }, { label: 'الرصيد بعدها', render: e => formatCurrency(e.balance_after) },
        { label: 'المرجع', key: 'reference' }], 'مفيش حركات'));
}

async function purPay(id) {
    const s = purState.suppliers.find(x => x.id === id) || {};
    const v = await uiForm(`سداد للمورد ${s.name || ''}`, [
        { type: 'note', label: `المستحق: ${formatCurrency(s.balance)}` },
        { key: 'amount', label: 'المبلغ', type: 'money', min: 0.01, value: Math.max(0, Number(s.balance) || 0), required: true },
        { key: 'source', label: 'الفلوس طالعة منين', type: 'select', options: UI_BOX_OPTIONS(['main_cash', 'bank', 'drawer']), required: true },
        { key: 'ref', label: 'رقم الإيصال أو التحويل (اختياري)' }], { ok: 'سداد' });
    if (!v) return;
    const res = await uiCall('supplier_payment_secure', { p_supplier_id: id, p_amount: v.amount, p_source: v.source, p_reference: v.ref || '', p_notes: 'سداد مورد', p_owner_pin: null },
        'تم السداد', 'p_owner_pin');
    if (res) loadPurchasingScreen();
}

function purRenderPrices() {
    document.getElementById('pur-body').innerHTML = uiCard('تاريخ أسعار خامة', `
        <div class="flex gap-2 mb-3"><select id="pur-price-ing" class="${uiInputClass()}">${uiOptions(purState.ingredients, 'id', i => `${i.name} (${i.unit})`, 'اختار الخامة')}</select>
        ${uiBtn('عرض', 'purLoadPrices()', 'gray')}</div><div id="pur-price-table"></div>`);
}

async function purLoadPrices() {
    const ing = document.getElementById('pur-price-ing').value;
    if (!ing) return;
    const res = await uiCall('price_history_secure', { p_ingredient_id: ing });
    if (!res) return;
    document.getElementById('pur-price-table').innerHTML =
        '<h4 class="font-black text-xs mb-1">السعر الحالي عند كل مورد</h4>'
        + uiTable(res.current, [{ label: 'المورد', key: 'supplier' }, { label: 'السعر', render: x => formatCurrency(x.unit_price) }], 'مفيش')
        + '<h4 class="font-black text-xs mt-3 mb-1">كل الاستلامات</h4>'
        + uiTable(res.history, [{ label: 'التاريخ', render: x => uiEsc(uiDate(x.at)) }, { label: 'المورد', key: 'supplier' },
            { label: 'الكمية', key: 'qty' }, { label: 'سعر الوحدة', render: x => formatCurrency(x.unit_cost) }, { label: 'الاستلام', key: 'grn' }], 'مفيش');
}
