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
    const tabs = uiTabs('inv', [['stock', 'الأرصدة'], ['buy', '🛒 محتاج شراء'], ['ledger', 'دفتر الحركات'], ['waste', 'تسجيل هالك'], ['count', 'جرد (أعمى)'],
        ['variance', 'المفروض والفعلي'], ['transfers', 'التحويلات']], invState.tab, 'setInventoryTab');
    root.innerHTML = `<div class="flex flex-wrap items-center gap-3 mb-2"><span class="text-xs font-black">المخزن:</span>${whSelect}</div>${tabs}<div id="inv-body"></div>`;
    const loaders = { stock: invRenderStock, buy: invRenderBuy, ledger: invRenderLedger, waste: invRenderWaste, count: invRenderCount,
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
        const res = await uiCall('inv_transfers_list_secure', {});
        const t = res && (res.transfers || []).find(x => x.id === id);
        if (!t) return;
        const v = await uiForm('استلام التحويل: اكتب اللي وصل فعلاً', (t.lines || []).map((l, i) => ({ key: 'q' + i,
            label: `${l.ingredient} (اتشحن ${Number(l.qty_shipped)})`, type: 'number', min: 0, value: Number(l.qty_shipped), required: true })), { ok: 'استلام' });
        if (!v) return;
        lines = (t.lines || []).map((l, i) => ({ ingredient_id: l.ingredient_id, qty: Number(v['q' + i]) }));
    }
    if (action === 'cancel' && !(await uiConfirm('إلغاء طلب التحويل؟', 'إلغاء الطلب', true))) return;
    const res = await uiCall('inv_transfer_action_secure', { p_transfer_id: id, p_action: action, p_lines: lines, p_manager_pin: pin ? String(pin).trim() : null }, 'تم');
    if (res) {
        if (Number(res.missing_value) > 0) showToast(`العجز في الاستلام اتسجل بقيمة ${formatCurrency(res.missing_value)}`, 'error');
        invRenderTransfers();
    }
}

// -----------------------------------------
// محتاج شراء: الخامات اللي داخلة في المنيو ومالهاش رصيد في المخزن (أو وصلت للحد الأدنى)
// -----------------------------------------
let invBuyItems = [];

async function invRenderBuy() {
    const body = document.getElementById('inv-body');
    if (!invState.warehouseId) { body.innerHTML = '<p class="text-xs font-bold text-slate-400">مفيش مخزن متاح</p>'; return; }
    const res = await uiCall('inv_shopping_secure', { p_warehouse_id: invState.warehouseId });
    if (!res) return;
    invBuyItems = res.items || [];
    const none = invBuyItems.filter(i => i.reason === 'none').length, low = invBuyItems.length - none;
    const noPrice = invBuyItems.filter(i => !Number(i.cost_per_unit)).length;
    const rows = invBuyItems.map((i, idx) => `<tr class="border-b border-slate-100 text-xs font-bold hover:bg-slate-50">
        <td class="p-2"><input type="checkbox" class="inv-buy-chk w-4 h-4" data-i="${idx}" checked></td>
        <td class="p-2"><b>${uiEsc(i.name)}</b>${Number(i.no_amounts) ? `<br><span class="text-[10px] text-amber-700">في ${uiEsc(i.no_amounts)} صنف لسه من غير كمية</span>` : ''}</td>
        <td class="p-2">${uiEsc(i.unit)}</td>
        <td class="p-2">${i.reason === 'none' ? '<span class="text-red-600">مش موجودة</span>' : `<span class="text-amber-700">${uiEsc(Number(i.quantity))} (الحد ${uiEsc(Number(i.min_stock_alert))})</span>`}</td>
        <td class="p-2">${Number(i.cost_per_unit) ? formatCurrency(i.cost_per_unit) : '<span class="text-slate-400">من غير سعر</span>'}</td>
        <td class="p-2 text-[11px] text-slate-600">${uiEsc(i.used_in)} صنف${i.products ? ': ' + uiEsc(i.products) + (Number(i.used_in) > 6 ? '...' : '') : ''}</td>
        <td class="p-2"><input type="number" min="0" step="any" id="inv-buy-q-${idx}" placeholder="الكمية" class="${uiInputClass()} w-24"></td></tr>`).join('');
    body.innerHTML = uiCard(`🛒 محتاج شراء (${invBuyItems.length} خامة)`, invBuyItems.length ? `
        <div class="grid grid-cols-1 sm:grid-cols-3 gap-3 text-xs font-bold mb-3">
            <div class="bg-red-50 text-red-700 p-3 rounded-xl border">مش موجودة خالص: <b>${none}</b></div>
            <div class="bg-amber-50 text-amber-800 p-3 rounded-xl border">قربت تخلص (وصلت للحد الأدنى): <b>${low}</b></div>
            <div class="bg-slate-50 p-3 rounded-xl border">من غير سعر لسه: <b>${noPrice}</b> (السعر بيتسجل لوحده أول ما تتشتري)</div>
        </div>
        <p class="text-[11px] font-bold text-slate-500 mb-2">دي الخامات اللي داخلة في وصفات المنيو ومالهاش رصيد في المخزن ده. علّم على اللي هتشتريه واكتب الكمية، وحوّلهم لأمر شراء مرة واحدة.</p>
        <div class="overflow-x-auto"><table class="w-full text-right"><thead><tr>
            <th class="p-2"><input type="checkbox" checked onchange="document.querySelectorAll('.inv-buy-chk').forEach(x => x.checked = this.checked)" class="w-4 h-4"></th>
            ${['الخامة', 'الوحدة', 'الرصيد', 'آخر سعر', 'داخلة في', 'هتشتري كام'].map(h => `<th class="p-2 text-[11px] text-slate-500 font-black border-b">${h}</th>`).join('')}</tr></thead>
            <tbody>${rows}</tbody></table></div>` : '<p class="text-center text-emerald-700 font-black text-sm py-6">كل الخامات اللي في المنيو موجودة ✅</p>',
        invBuyItems.length ? (canDo('po_create') ? uiBtn('🛒 حوّل المختار لأمر شراء', 'invBuyToPo()', 'green') : '') + uiBtn('🖨️ طباعة القايمة', 'invBuyPrint()', 'gray') : '');
}

function invBuyChosen() {
    return [...document.querySelectorAll('.inv-buy-chk:checked')].map(x => {
        const idx = Number(x.dataset.i);
        return { ...invBuyItems[idx], want: Number(document.getElementById('inv-buy-q-' + idx)?.value) || 0 };
    });
}

async function invBuyToPo() {
    const chosen = invBuyChosen();
    if (!chosen.length) return showToast('علّم على خامة واحدة على الأقل', 'error');
    const withQty = chosen.filter(x => x.want > 0);
    if (!withQty.length) return showToast('اكتب الكمية اللي هتشتريها قدام كل خامة', 'error');
    if (withQty.length < chosen.length && !(await uiConfirm(`${chosen.length - withQty.length} خامة من غير كمية مش هتدخل في أمر الشراء. نكمّل؟`, 'كمّل'))) return;
    if (typeof purState === 'undefined') return showToast('شاشة المشتريات مش متاحة', 'error');
    purState.lines = withQty.map(x => ({ ingredient_id: x.ingredient_id, qty: x.want, unit_price: Number(x.cost_per_unit) || 0 }));
    purState.tab = 'new';
    switchMainTab('purchase');
    showToast(`اتحطت ${withQty.length} خامة في أمر شراء جديد. اختار المورد واكتب الأسعار واحفظ.`);
}

function invBuyPrint() {
    const chosen = invBuyChosen();
    if (!chosen.length) return showToast('علّم على خامة واحدة على الأقل', 'error');
    const g = (typeof appSettings !== 'undefined' && appSettings && appSettings.general) || {};
    const wh = (invState.warehouses.find(w => w.id === invState.warehouseId) || {}).name || '';
    printHtml(`${g.logo ? `<div style="text-align:center"><img src="${uiEsc(g.logo)}" style="max-height:60px"></div>` : ''}
        <h2 style="text-align:center;margin:4px 0">${uiEsc(g.company_name || '')}</h2>
        <h3 style="text-align:center;margin:4px 0">قايمة مشتريات - ${uiEsc(wh)} - ${uiEsc(uiDate(new Date().toISOString()))}</h3>
        <table border="1" cellpadding="6" style="font-size:13px"><tr><th>#</th><th>الخامة</th><th>الوحدة</th><th>الرصيد</th><th>الكمية المطلوبة</th><th>السعر</th><th>ملاحظات</th></tr>
        ${chosen.map((x, i) => `<tr><td>${i + 1}</td><td>${uiEsc(x.name)}</td><td>${uiEsc(x.unit)}</td><td>${x.reason === 'none' ? 'مش موجودة' : uiEsc(Number(x.quantity))}</td>
            <td>${x.want ? uiEsc(x.want) : ''}</td><td></td><td></td></tr>`).join('')}</table>`, '@page { size: A4; margin: 12mm; } body { font-size: 13px; }');
}
