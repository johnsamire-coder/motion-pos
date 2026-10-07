// js/inventory.js - المخازن: الأرصدة، دفتر الحركات، الهالك، الجرد الأعمى، المفروض والفعلي، التحويلات
// كل حاجة بتتقري وبتتسجل على السيرفر بتذكرة الوردية.

let invState = { tab: 'stock', warehouses: [], ingredients: [], warehouseId: null, transferLines: [] };

function setInventoryTab(tab) { invState.tab = tab; renderInventoryBody(); }
function setInventoryWarehouse(id) { invState.warehouseId = id || null; renderInventoryBody(); }

async function loadInventoryScreen() {
    const root = document.getElementById('inventory-root');
    if (!root) return;
    const [wh, ing] = await Promise.all([
        uiCall('inv_warehouses_secure', {}),
        _supabase.from('ingredients').select('id, name, unit').order('name')
    ]);
    if (!wh) return;
    invState.warehouses = wh.warehouses || [];
    invState.ingredients = ing.data || [];
    const mine = invState.warehouses.filter(w => w.mine);
    if (!invState.warehouseId || !mine.some(w => w.id === invState.warehouseId)) {
        invState.warehouseId = (mine.find(w => !w.is_main) || mine[0] || {}).id || null;
    }
    renderInventoryBody();
}

function renderInventoryBody() {
    const root = document.getElementById('inventory-root');
    if (!root) return;
    const mine = invState.warehouses.filter(w => w.mine);
    const whSelect = `<select onchange="setInventoryWarehouse(this.value)" class="${uiInputClass()}">`
        + mine.map(w => `<option value="${uiEsc(w.id)}" ${w.id === invState.warehouseId ? 'selected' : ''}>${uiEsc(w.name)}${w.branch_name ? ' - ' + uiEsc(w.branch_name) : ''}</option>`).join('')
        + '</select>';
    const tabs = uiTabs('inv', [['stock', 'الأرصدة'], ['ledger', 'دفتر الحركات'], ['waste', 'تسجيل هالك'], ['count', 'جرد (أعمى)'],
        ['variance', 'المفروض والفعلي'], ['transfers', 'التحويلات']], invState.tab, 'setInventoryTab');
    root.innerHTML = `<div class="flex flex-wrap items-center gap-3 mb-2"><span class="text-xs font-black">المخزن:</span>${whSelect}</div>${tabs}<div id="inv-body"></div>`;
    const loaders = { stock: invRenderStock, ledger: invRenderLedger, waste: invRenderWaste, count: invRenderCount,
        variance: invRenderVariance, transfers: invRenderTransfers };
    (loaders[invState.tab] || invRenderStock)();
}

function invIngredientOptions(placeholder) {
    return uiOptions(invState.ingredients, 'id', i => `${i.name} (${i.unit})`, placeholder);
}

async function invRenderStock() {
    const body = document.getElementById('inv-body');
    if (!invState.warehouseId) { body.innerHTML = '<p class="text-xs font-bold text-slate-400">مفيش مخزن متاح</p>'; return; }
    const res = await uiCall('inv_stock_secure', { p_warehouse_id: invState.warehouseId });
    if (!res) return;
    const items = res.items || [];
    const low = items.filter(i => i.low);
    const total = items.reduce((s, i) => s + (Number(i.value) || 0), 0);
    body.innerHTML = (low.length ? `<div class="bg-red-50 border border-red-200 text-red-700 p-3 rounded-xl text-xs font-black mb-3">⚠️ ${low.length} خامة تحت الحد الأدنى: ${low.map(i => uiEsc(i.name)).join('، ')}</div>` : '')
        + uiCard(`الأرصدة (إجمالي القيمة ${formatCurrency(total)})`, uiTable(items, [
            { label: 'الخامة', key: 'name' }, { label: 'الوحدة', key: 'unit' },
            { label: 'الرصيد', render: i => `<b class="${i.low ? 'text-red-600' : 'text-blue-700'}">${uiEsc(Number(i.quantity))}</b>` },
            { label: 'الحد الأدنى', key: 'min_stock_alert' }, { label: 'تكلفة الوحدة', render: i => formatCurrency(i.cost_per_unit) },
            { label: 'القيمة', render: i => formatCurrency(i.value) }]));
}

async function invRenderLedger() {
    const body = document.getElementById('inv-body');
    const prev = { ing: document.getElementById('inv-ledger-ing')?.value || '', from: document.getElementById('inv-ledger-from')?.value || uiToday(-30), to: document.getElementById('inv-ledger-to')?.value || uiToday() };
    body.innerHTML = uiCard('دفتر حركات المخزن', `
        <div class="flex flex-wrap gap-2 mb-3">
            <select id="inv-ledger-ing" class="${uiInputClass()}">${invIngredientOptions('كل الخامات')}</select>
            <input id="inv-ledger-from" type="date" value="${uiEsc(prev.from)}" class="${uiInputClass()}">
            <input id="inv-ledger-to" type="date" value="${uiEsc(prev.to)}" class="${uiInputClass()}">
            ${uiBtn('عرض', 'invRenderLedger()', 'gray')}
        </div><div id="inv-ledger-table"></div>`);
    document.getElementById('inv-ledger-ing').value = prev.ing;
    const res = await uiCall('inv_ledger_secure', { p_warehouse_id: invState.warehouseId, p_ingredient_id: prev.ing || null, p_from: prev.from, p_to: prev.to });
    if (!res) return;
    const typeNames = { sale: 'بيع', waste: 'هالك', purchase: 'شراء', adjustment: 'تسوية جرد', transfer_in: 'تحويل وارد', transfer_out: 'تحويل صادر', return: 'مرتجع', opening: 'رصيد أول' };
    document.getElementById('inv-ledger-table').innerHTML = uiTable(res.moves, [
        { label: 'الوقت', render: m => uiEsc(uiDate(m.created_at)) }, { label: 'الخامة', key: 'ingredient' },
        { label: 'الحركة', render: m => uiEsc(typeNames[m.type] || m.type) },
        { label: 'الكمية', render: m => `<span class="${Number(m.quantity) < 0 ? 'text-red-600' : 'text-emerald-600'}">${uiEsc(Number(m.quantity))}</span>` },
        { label: 'الرصيد بعدها', render: m => uiEsc(Number(m.balance_after)) }, { label: 'القيمة', render: m => formatCurrency(m.total_cost) },
        { label: 'ملاحظة', key: 'notes' }, { label: 'بواسطة', key: 'by' }], 'مفيش حركات في الفترة دي');
}

function invRenderWaste() {
    document.getElementById('inv-body').innerHTML = uiCard('تسجيل هالك / تالف (بموافقة المدير)', `
        <div class="grid grid-cols-1 md:grid-cols-3 gap-2 max-w-3xl">
            <select id="inv-waste-ing" class="${uiInputClass()}">${invIngredientOptions('اختار الخامة')}</select>
            <input id="inv-waste-qty" type="number" min="0" step="any" placeholder="الكمية" class="${uiInputClass()}">
            <input id="inv-waste-reason" type="text" placeholder="السبب (انتهاء صلاحية / وقع / ...)" class="${uiInputClass()}">
        </div>
        <div class="mt-3">${uiBtn('تسجيل الهالك', 'invSubmitWaste()', 'red')}</div>`);
}

async function invSubmitWaste() {
    const ing = document.getElementById('inv-waste-ing').value;
    const qty = Number(document.getElementById('inv-waste-qty').value);
    const reason = document.getElementById('inv-waste-reason').value.trim();
    if (!ing || !(qty > 0) || !reason) return showToast('اختار الخامة واكتب الكمية والسبب', 'error');
    const pin = await uiAskPin('الهالك محتاج موافقة المدير. أدخل رقم المدير:');
    if (!pin) return;
    const res = await uiCall('inv_waste_secure', { p_warehouse_id: invState.warehouseId, p_ingredient_id: ing, p_quantity: qty, p_reason: reason, p_manager_pin: String(pin).trim() });
    if (res) { showToast(`تم تسجيل الهالك بتكلفة ${formatCurrency(res.cost)}`); invRenderWaste(); }
}

function invRenderCount() {
    document.getElementById('inv-body').innerHTML = uiCard('جرد أعمى: اكتب اللي عدّيته بس (الرصيد مش ظاهر قصداً)', `
        <p class="text-xs font-bold text-slate-500 mb-3">سيب الخانة فاضية للخامة اللي مش هتجردها. بعد الحفظ هيظهر الفرق لكل خامة، ويتعمل بيه قيد.</p>
        ${uiTable(invState.ingredients, [{ label: 'الخامة', key: 'name' }, { label: 'الوحدة', key: 'unit' },
            { label: 'الكمية المعدودة', render: i => `<input type="number" min="0" step="any" data-count-ing="${uiEsc(i.id)}" class="${uiInputClass()} w-32">` }])}
        <input id="inv-count-notes" type="text" placeholder="ملاحظات" class="${uiInputClass()} w-full mt-3">
        <div class="mt-3">${uiBtn('حفظ الجرد', 'invSubmitCount()', 'blue')}</div>
        <div id="inv-count-result" class="mt-4"></div>`);
}

async function invSubmitCount() {
    const lines = [...document.querySelectorAll('[data-count-ing]')]
        .filter(el => el.value !== '')
        .map(el => ({ ingredient_id: el.dataset.countIng, actual_qty: Number(el.value) }));
    if (!lines.length) return showToast('اكتب كمية خامة واحدة على الأقل', 'error');
    if (lines.some(l => !(l.actual_qty >= 0))) return showToast('في كمية غلط', 'error');
    const pin = await uiAskPin('الجرد محتاج موافقة المدير. أدخل رقم المدير:');
    if (!pin) return;
    const res = await uiCall('inv_stocktake_secure', { p_warehouse_id: invState.warehouseId, p_lines: lines,
        p_notes: document.getElementById('inv-count-notes').value, p_manager_pin: String(pin).trim() }, 'تم حفظ الجرد');
    if (!res) return;
    const names = Object.fromEntries(invState.ingredients.map(i => [i.id, i.name]));
    document.getElementById('inv-count-result').innerHTML = uiCard(`نتيجة الجرد: عجز ${formatCurrency(res.shortage_value)} | زيادة ${formatCurrency(res.overage_value)}`,
        uiTable(res.lines, [{ label: 'الخامة', render: l => uiEsc(names[l.ingredient_id] || '') },
            { label: 'على السيستم', render: l => uiEsc(Number(l.system_qty)) }, { label: 'المعدود', render: l => uiEsc(Number(l.actual_qty)) },
            { label: 'الفرق', render: l => `<b class="${Number(l.variance_qty) < 0 ? 'text-red-600' : 'text-emerald-600'}">${uiEsc(Number(l.variance_qty))}</b>` },
            { label: 'قيمة الفرق', render: l => formatCurrency(l.variance_cost) }]));
}

async function invRenderVariance() {
    const body = document.getElementById('inv-body');
    const from = document.getElementById('inv-var-from')?.value || uiToday(-30);
    const to = document.getElementById('inv-var-to')?.value || uiToday();
    body.innerHTML = uiCard('المفروض والفعلي', `
        <p class="text-xs font-bold text-slate-500 mb-2">المفروض = اللي اتصرف في البيع حسب الوصفات + الهالك المتسجل. الفعلي = المفروض + اللي طلع ناقص في الجرد.</p>
        <div class="flex flex-wrap gap-2 mb-3">
            <input id="inv-var-from" type="date" value="${uiEsc(from)}" class="${uiInputClass()}">
            <input id="inv-var-to" type="date" value="${uiEsc(to)}" class="${uiInputClass()}">
            ${uiBtn('عرض', 'invRenderVariance()', 'gray')}
        </div><div id="inv-var-table"></div>`);
    const res = await uiCall('inv_variance_secure', { p_warehouse_id: invState.warehouseId, p_from: from, p_to: to });
    if (!res) return;
    document.getElementById('inv-var-table').innerHTML = uiTable(res.rows, [
        { label: 'الخامة', key: 'ingredient' }, { label: 'الوحدة', key: 'unit' }, { label: 'بيع', key: 'sales_qty' }, { label: 'هالك', key: 'waste_qty' },
        { label: 'المفروض', key: 'expected_qty' }, { label: 'الفعلي', key: 'actual_qty' },
        { label: 'الفرق', render: r => `<b class="${Number(r.difference_qty) > 0 ? 'text-red-600' : ''}">${uiEsc(r.difference_qty)}</b>` },
        { label: 'قيمة الفرق', render: r => formatCurrency(r.difference_value) }], 'مفيش حركات في الفترة دي');
}

async function invRenderTransfers() {
    const body = document.getElementById('inv-body');
    const res = await uiCall('inv_transfers_list_secure', {});
    if (!res) return;
    const statusNames = { requested: 'مطلوب', approved: 'موافَق عليه', shipped: 'في الطريق', received: 'اتستلم', cancelled: 'ملغي' };
    const others = invState.warehouses.filter(w => w.id !== invState.warehouseId);
    body.innerHTML = uiCard('طلب تحويل جديد من المخزن الحالي', `
            <div class="flex flex-wrap gap-2 mb-2">
                <span class="text-xs font-black self-center">إلى:</span>
                <select id="inv-tr-to" class="${uiInputClass()}">${uiOptions(others, 'id', w => w.name + (w.branch_name ? ' - ' + w.branch_name : ''), 'اختار المخزن')}</select>
                <select id="inv-tr-ing" class="${uiInputClass()}">${invIngredientOptions('اختار الخامة')}</select>
                <input id="inv-tr-qty" type="number" min="0" step="any" placeholder="الكمية" class="${uiInputClass()} w-28">
                ${uiBtn('إضافة للطلب', 'invTransferAddLine()', 'gray')}
            </div>
            <div id="inv-tr-lines"></div>
            <input id="inv-tr-notes" type="text" placeholder="ملاحظات" class="${uiInputClass()} w-full mt-2">
            <div class="mt-3">${uiBtn('إرسال الطلب', 'invTransferSubmit()', 'blue')}</div>`)
        + uiCard('التحويلات (آخر 90 يوم)', uiTable(res.transfers, [
            { label: 'الرقم', key: 'transfer_number' }, { label: 'التاريخ', render: t => uiEsc(uiDate(t.created_at)) },
            { label: 'من', key: 'from_warehouse' }, { label: 'إلى', key: 'to_warehouse' },
            { label: 'الحالة', render: t => uiEsc(statusNames[t.status] || t.status) },
            { label: 'الخامات', render: t => (t.lines || []).map(l => `${uiEsc(l.ingredient)}: ${uiEsc(Number(l.qty_requested))}${t.status === 'received' ? ' / وصل ' + uiEsc(Number(l.qty_received)) : ''}`).join('<br>') },
            { label: '', render: t => invTransferButtons(t) }]));
    invTransferRenderLines();
}

function invTransferButtons(t) {
    const b = [];
    if (t.status === 'requested') b.push(uiBtn('موافقة', `invTransferAction('${t.id}','approve')`, 'green'));
    if (t.status === 'approved') b.push(uiBtn('شحن', `invTransferAction('${t.id}','ship')`, 'amber'));
    if (t.status === 'shipped') b.push(uiBtn('استلام', `invTransferAction('${t.id}','receive')`, 'blue'));
    if (t.status === 'requested' || t.status === 'approved') b.push(uiBtn('إلغاء', `invTransferAction('${t.id}','cancel')`, 'gray'));
    return '<div class="flex flex-wrap gap-1">' + b.join('') + '</div>';
}

function invTransferAddLine() {
    const ing = document.getElementById('inv-tr-ing').value;
    const qty = Number(document.getElementById('inv-tr-qty').value);
    if (!ing || !(qty > 0)) return showToast('اختار الخامة واكتب الكمية', 'error');
    if (invState.transferLines.some(l => l.ingredient_id === ing)) return showToast('الخامة موجودة في الطلب', 'error');
    invState.transferLines.push({ ingredient_id: ing, qty });
    document.getElementById('inv-tr-qty').value = '';
    invTransferRenderLines();
}

function invTransferRemoveLine(idx) {
    invState.transferLines.splice(idx, 1);
    invTransferRenderLines();
}

function invTransferRenderLines() {
    const box = document.getElementById('inv-tr-lines');
    if (!box) return;
    const names = Object.fromEntries(invState.ingredients.map(i => [i.id, `${i.name} (${i.unit})`]));
    box.innerHTML = invState.transferLines.length ? uiTable(invState.transferLines.map((l, idx) => ({ ...l, idx })), [
        { label: 'الخامة', render: l => uiEsc(names[l.ingredient_id]) }, { label: 'الكمية', key: 'qty' },
        { label: '', render: l => uiBtn('شيل', `invTransferRemoveLine(${l.idx})`, 'gray') }]) : '';
}

async function invTransferSubmit() {
    const to = document.getElementById('inv-tr-to').value;
    if (!to || !invState.transferLines.length) return showToast('اختار المخزن وضيف خامة واحدة على الأقل', 'error');
    const res = await uiCall('inv_transfer_request_secure', { p_from_warehouse_id: invState.warehouseId, p_to_warehouse_id: to,
        p_lines: invState.transferLines, p_notes: document.getElementById('inv-tr-notes').value }, 'تم إرسال طلب التحويل');
    if (res) { invState.transferLines = []; invRenderTransfers(); }
}

async function invTransferAction(id, action) {
    let pin = null;
    let lines = null;
    if (action === 'approve') {
        pin = await uiAskPin('الموافقة على التحويل محتاجة رقم المدير:');
        if (!pin) return;
    }
    if (action === 'receive') {
        if (!confirm('هل الكميات وصلت كاملة؟ (لو لأ، دوس إلغاء وهتكتب اللي وصل لكل خامة)')) {
            const res = await uiCall('inv_transfers_list_secure', {});
            const t = res && (res.transfers || []).find(x => x.id === id);
            if (!t) return;
            lines = [];
            for (const l of (t.lines || [])) {
                const v = prompt(`${l.ingredient}: اتشحن ${Number(l.qty_shipped)}. وصل كام؟`, String(Number(l.qty_shipped)));
                if (v === null) return;
                lines.push({ ingredient_id: l.ingredient_id, qty: Number(v) });
            }
        }
    }
    if (action === 'cancel' && !confirm('إلغاء طلب التحويل؟')) return;
    const res = await uiCall('inv_transfer_action_secure', { p_transfer_id: id, p_action: action, p_lines: lines, p_manager_pin: pin ? String(pin).trim() : null }, 'تم');
    if (res) {
        if (Number(res.missing_value) > 0) showToast(`العجز في الاستلام اتسجل بقيمة ${formatCurrency(res.missing_value)}`, 'error');
        invRenderTransfers();
    }
}
