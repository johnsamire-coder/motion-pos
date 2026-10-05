// js/pos.js - موديول الكاشير المكتمل (Split Bill, Tips, Multiple Payments, Secure Void)

let posState = {
    selectedOrderType: 'dine_in',
    selectedAreaId: null,
    selectedTable: null,
    areas: [], tables: [], categories: [], products: [], waiters: [], customers: [], cancelReasons: [], discounts: [],
    activeCategory: null, pendingModifierProduct: null, selectedModifiers: [],
    
    cart: {
        id: null, order_number: 'طلب جديد', status: 'draft', kitchen_status: 'pending',
        items: [], guest_count: 1, waiter_id: null, customer_id: null,
        discount_amount: 0, discount_type: 'fixed', enable_vat: true, enable_service: true
    },
    paymentsList: [],
    currentTip: 0,
    tipStaffId: null,
    splits: [] // بيانات التقسيم المؤقتة
};

async function initPOSModule() {
    if (!currentUser || !currentUser.branch_id) return;
    posState.cart.enable_vat = taxSettings.enable_vat;
    posState.cart.enable_service = taxSettings.enable_service;
    await loadPOSMasterData();
    renderPOSTerminal();
}

async function loadPOSMasterData() {
    const branchId = currentUser.branch_id;
    try {
        const [waitersRes, custRes, catRes, prodRes, reasonRes, discRes] = await Promise.all([
            _supabase.from('staff').select('*').eq('branch_id', branchId),
            _supabase.from('customers').select('*'),
            _supabase.from('categories').select('*'),
            _supabase.from('products').select('*'),
            _supabase.from('cancel_reasons').select('*'),
            _supabase.from('discounts').select('*')
        ]);
        
        posState.waiters = waitersRes.data || [];
        posState.customers = custRes.data || [];
        posState.categories = catRes.data || [];
        posState.products = prodRes.data || [];
        posState.cancelReasons = reasonRes.data || [];
        posState.discounts = discRes.data || [];

        if (currentBranch && currentBranch.has_tables) {
            const { data: areasData } = await _supabase.from('areas').select('*').eq('branch_id', branchId);
            posState.areas = areasData || [];
            if (posState.areas.length > 0) {
                posState.selectedAreaId = posState.areas[0].id;
                await fetchBranchTables();
            }
        }
    } catch (err) { console.error(err); }
}

async function fetchBranchTables() {
    if (!posState.selectedAreaId) return;
    const { data } = await _supabase.from('tables').select('*').eq('area_id', posState.selectedAreaId);
    posState.tables = data || [];
}

function renderPOSTerminal() {
    renderAreaAndTables(); renderCategoriesPills(); renderProductsGrid(); renderWaitersAndCustomersDropdowns(); renderOrderCartTicket();
}

function renderAreaAndTables() {
    const areaContainer = document.getElementById('area-selector-container');
    const floorSection = document.getElementById('tables-floor-section');

    if (!currentBranch || !currentBranch.has_tables || posState.selectedOrderType !== 'dine_in') {
        if (areaContainer) areaContainer.classList.add('hidden');
        if (floorSection) floorSection.classList.add('hidden');
        return;
    }
    if (areaContainer) areaContainer.classList.remove('hidden');
    if (floorSection) floorSection.classList.remove('hidden');

    const areaSelect = document.getElementById('area-select');
    if (areaSelect) {
        areaSelect.innerHTML = posState.areas.map(a => `<option value="${a.id}" ${a.id === posState.selectedAreaId ? 'selected' : ''}>${a.name}</option>`).join('');
    }

    const grid = document.getElementById('tables-grid');
    if (!grid) return;

    grid.innerHTML = posState.tables.map(t => {
        let statusColor = "bg-emerald-50 border-emerald-300 text-emerald-800"; let statusName = "متاحة";
        if (t.status === 'occupied') { statusColor = "bg-rose-50 border-rose-300 text-rose-800"; statusName = "مشغولة"; }
        else if (t.status === 'reserved') { statusColor = "bg-amber-50 border-amber-300 text-amber-800"; statusName = "محجوزة"; }
        else if (t.status === 'cleaning') { statusColor = "bg-sky-50 border-sky-300 text-sky-800"; statusName = "قيد التنظيف"; }
        
        const isSelected = posState.selectedTable && posState.selectedTable.id === t.id ? "ring-4 ring-blue-600" : "";
        return `<div onclick="selectPosTable('${t.id}')" class="p-3 rounded-2xl border-2 ${statusColor} ${isSelected} cursor-pointer transition flex flex-col justify-between h-24">
            <div class="flex justify-between items-center"><span class="font-extrabold text-sm">${t.table_number}</span><span class="text-[10px] font-bold px-1.5 py-0.5 rounded bg-white/60">${statusName}</span></div>
            <div class="text-[10px] font-bold text-slate-500">سعة: ${t.capacity} ضيوف</div>
        </div>`;
    }).join('');
}

async function selectPosTable(tableId) {
    posState.selectedTable = posState.tables.find(t => t.id === tableId);
    renderAreaAndTables();

    const { data: openOrders } = await _supabase
        .from('orders')
        .select('*, order_items(*, products(name), order_item_modifiers(*))')
        .eq('table_id', tableId)
        .not('status', 'in', '("closed","cancelled")');

    if (openOrders && openOrders.length > 0) {
        const ord = openOrders[0];
        posState.cart = {
            id: ord.id, order_number: ord.order_number, status: ord.status, kitchen_status: ord.kitchen_status,
            items: ord.order_items.filter(i => i.status !== 'voided').map(i => ({
                db_item_id: i.id, product_id: i.product_id, name: i.products ? i.products.name : 'صنف',
                price: parseFloat(i.unit_price), qty: i.quantity, modifiers: i.order_item_modifiers || [], discount: parseFloat(i.discount_amount) || 0
            })),
            guest_count: ord.guest_count, waiter_id: ord.waiter_id, customer_id: ord.customer_id,
            discount_amount: parseFloat(ord.discount_amount) || 0, discount_type: 'fixed',
            enable_vat: taxSettings.enable_vat, enable_service: taxSettings.enable_service
        };
    } else {
        resetActiveCart();
    }
    renderOrderCartTicket();
}

function renderCategoriesPills() {
    const container = document.getElementById('category-pills');
    if (!container) return;
    container.innerHTML = `<button onclick="filterPosProducts(null)" class="px-3 py-1 bg-blue-600 text-white rounded-xl text-xs font-bold shadow">الكل</button>` +
        posState.categories.map(c => `<button onclick="filterPosProducts('${c.id}')" class="px-3 py-1 bg-slate-100 text-slate-700 rounded-xl text-xs font-bold hover:bg-slate-200">${c.name}</button>`).join('');
}

function filterPosProducts(catId) { posState.activeCategory = catId; renderProductsGrid(); }

function renderProductsGrid() {
    const grid = document.getElementById('products-grid');
    if (!grid) return;
    let filtered = posState.products;
    if (posState.activeCategory) filtered = filtered.filter(p => p.category_id === posState.activeCategory);
    grid.innerHTML = filtered.map(p => `
        <div onclick="checkAndAddProduct('${p.id}')" class="p-4 border rounded-2xl bg-slate-50 hover:border-blue-500 hover:shadow-md cursor-pointer transition flex flex-col justify-between h-28">
            <h4 class="font-extrabold text-slate-800 text-xs">${p.name}</h4><span class="text-blue-600 font-extrabold text-sm">${formatCurrency(p.price)}</span>
        </div>
    `).join('');
}

async function checkAndAddProduct(productId) {
    const product = posState.products.find(p => p.id === productId);
    if (!product) return;
    const { data: modGroupLinks } = await _supabase.from('product_modifier_groups').select('group_id, modifier_groups(*, modifiers(*))').eq('product_id', productId);
    
    if (modGroupLinks && modGroupLinks.length > 0) {
        const groups = modGroupLinks.map(l => l.modifier_groups).filter(g => g !== null);
        if (groups.length > 0) { openModifiersModal(product, groups); return; }
    }
    addItemToCart(product, []);
}

function openModifiersModal(product, groups) {
    posState.pendingModifierProduct = product; posState.selectedModifiers = [];
    let modal = document.getElementById('modifiers-modal');
    if (!modal) {
        modal = document.createElement('div'); modal.id = 'modifiers-modal';
        modal.className = 'fixed inset-0 bg-slate-900/60 backdrop-blur-sm z-50 flex items-center justify-center p-4';
        document.body.appendChild(modal);
    }
    const groupsHtml = groups.map(g => `
        <div class="mb-4 text-right">
            <h4 class="font-black text-xs text-slate-800 mb-2 border-b pb-1">${g.name}</h4>
            <div class="grid grid-cols-2 gap-2">
                ${g.modifiers.map(m => `<button onclick="toggleModifierSelection('${m.id}', '${m.name}', ${m.price}, '${m.ingredient_id||''}', ${m.ingredient_quantity||0}, this)" class="mod-option-btn p-2 border rounded-xl text-xs font-bold bg-slate-50 text-slate-700 flex justify-between items-center hover:border-blue-500"><span>${m.name}</span><span class="text-blue-600">${m.price > 0 ? '+' + formatCurrency(m.price) : 'مجاني'}</span></button>`).join('')}
            </div>
        </div>
    `).join('');
    modal.innerHTML = `<div class="bg-white p-6 rounded-3xl shadow-2xl max-w-md w-full border border-slate-100"><h3 class="font-black text-base text-slate-800 mb-1 text-center">إضافات: ${product.name}</h3><div class="max-h-[300px] overflow-y-auto mb-4">${groupsHtml}</div><div class="flex gap-2"><button onclick="confirmModifiersSelection()" class="flex-1 bg-blue-600 text-white py-3 rounded-xl font-bold text-xs hover:bg-blue-700 shadow">إضافة</button><button onclick="closeModifiersModal()" class="flex-1 bg-slate-100 text-slate-600 py-3 rounded-xl font-bold text-xs hover:bg-slate-200">إلغاء</button></div></div>`;
    modal.classList.remove('hidden');
}

function toggleModifierSelection(id, name, price, ingId, ingQty, btn) {
    const idx = posState.selectedModifiers.findIndex(m => m.id === id);
    if (idx >= 0) { posState.selectedModifiers.splice(idx, 1); btn.classList.remove('border-blue-600', 'bg-blue-50', 'text-blue-700'); } 
    else { posState.selectedModifiers.push({ id, name, price, ingredient_id: ingId, ingredient_quantity: ingQty }); btn.classList.add('border-blue-600', 'bg-blue-50', 'text-blue-700'); }
}
function confirmModifiersSelection() { if (posState.pendingModifierProduct) addItemToCart(posState.pendingModifierProduct, [...posState.selectedModifiers]); closeModifiersModal(); }
function closeModifiersModal() { const modal = document.getElementById('modifiers-modal'); if (modal) modal.classList.add('hidden'); posState.pendingModifierProduct = null; posState.selectedModifiers = []; }

function addItemToCart(product, selectedModifiers = []) {
    let modPrice = selectedModifiers.reduce((s, m) => s + parseFloat(m.price || 0), 0);
    const itemPrice = parseFloat(product.price) + modPrice;
    const existing = posState.cart.items.find(i => i.product_id === product.id && JSON.stringify(i.modifiers) === JSON.stringify(selectedModifiers) && !i.db_item_id);
    if (existing) { existing.qty++; } else { posState.cart.items.push({ db_item_id: null, product_id: product.id, name: product.name, price: itemPrice, qty: 1, modifiers: selectedModifiers, discount: 0, notes: '' }); }
    renderOrderCartTicket();
}

function calculateCartTotals() {
    let subtotal = 0; let itemDiscounts = 0;
    posState.cart.items.forEach(i => { subtotal += (i.price * i.qty); itemDiscounts += (i.discount || 0); });
    let discountTotal = itemDiscounts + posState.cart.discount_amount;
    let taxableAmount = Math.max(0, subtotal - discountTotal);
    let vatAmount = posState.cart.enable_vat ? (taxableAmount * taxSettings.vat_percentage) / 100 : 0;
    let serviceAmount = (posState.selectedOrderType === 'dine_in' && posState.cart.enable_service) ? (taxableAmount * taxSettings.service_charge_percentage) / 100 : 0;
    return { subtotal, discountTotal, vatAmount, serviceAmount, finalTotal: taxableAmount + vatAmount + serviceAmount };
}

function renderOrderCartTicket() {
    const totals = calculateCartTotals();
    const orderNumElem = document.getElementById('ticket-order-number');
    const statusBadgeElem = document.getElementById('ticket-status-badge');
    const tableInfoElem = document.getElementById('ticket-table-info');

    if (orderNumElem) orderNumElem.innerText = posState.cart.order_number;
    if (statusBadgeElem) statusBadgeElem.innerText = `حالة: ${posState.cart.status}`;
    if (tableInfoElem) tableInfoElem.innerText = `الطاولة: ${posState.selectedTable ? posState.selectedTable.table_number : '---'}`;

    const itemsContainer = document.getElementById('cart-items-list');
    if (!itemsContainer) return;

    if (posState.cart.items.length === 0) {
        itemsContainer.innerHTML = `<p class="text-slate-400 text-center py-8 text-xs font-bold">الفاتورة فارغة</p>`;
    } else {
        itemsContainer.innerHTML = posState.cart.items.map((item, idx) => {
            const modsText = item.modifiers.map(m => `+ ${m.name || m.modifier_name}`).join(', ');
            return `<div class="bg-slate-50 p-2.5 rounded-xl border border-slate-200 text-xs font-bold space-y-1">
                <div class="flex justify-between items-center"><span class="text-slate-800">${item.name}</span><span class="text-blue-600 font-extrabold">${formatCurrency(item.price * item.qty)}</span></div>
                ${modsText ? `<p class="text-[10px] text-amber-600 font-bold">${modsText}</p>` : ''}
                <div class="flex justify-between items-center text-[10px] text-slate-400 pt-1"><span>${item.price} × ${item.qty}</span><button onclick="voidCartItem(${idx})" class="text-red-500 hover:bg-red-50 px-1.5 py-0.5 rounded border border-red-100 font-bold">مسح / Void</button></div>
            </div>`;
        }).join('');
    }
    document.getElementById('summary-subtotal').innerText = formatCurrency(totals.subtotal);
    document.getElementById('summary-tax').innerText = formatCurrency(totals.vatAmount);
    document.getElementById('summary-service').innerText = formatCurrency(totals.serviceAmount);
    document.getElementById('summary-total').innerText = formatCurrency(totals.finalTotal);
}

async function voidCartItem(idx) {
    const item = posState.cart.items[idx];
    if (!item) return;
    if (!item.db_item_id) { posState.cart.items.splice(idx, 1); renderOrderCartTicket(); return; }

    const reasonPrompt = prompt('أدخل سبب مسح الصنف المكتوب بالمطبخ:\n' + posState.cancelReasons.map((r, i) => `${i+1}. ${r.reason}`).join('\n'));
    if (!reasonPrompt) return;
    let reasonId = posState.cancelReasons.length > 0 ? posState.cancelReasons[0].id : null;

    try {
        const { error } = await _supabase.rpc('void_order_item', {
            p_order_item_id: item.db_item_id, p_reason_id: reasonId, p_user_id: currentUser.id, p_warehouse_id: 'd0000000-0000-0000-0000-000000000001'
        });
        if (error) return showToast('خطأ: ' + error.message, 'error');
        
        posState.cart.items.splice(idx, 1);
        const totals = calculateCartTotals();
        await _supabase.rpc('update_order_financials', { p_order_id: posState.cart.id, p_sub_total: totals.subtotal, p_tax_amount: totals.vatAmount, p_service_amount: totals.serviceAmount, p_discount_amount: totals.discountTotal, p_total_amount: totals.finalTotal });
        renderOrderCartTicket(); showToast('تم مسح الصنف وإرجاع المخزون');
    } catch (err) { console.error(err); }
}

function toggleVatTax() { posState.cart.enable_vat = !posState.cart.enable_vat; renderOrderCartTicket(); }
function toggleServiceCharge() { posState.cart.enable_service = !posState.cart.enable_service; renderOrderCartTicket(); }
function resetActiveCart() {
    posState.cart = { id: null, order_number: 'طلب جديد', status: 'draft', kitchen_status: 'pending', items: [], guest_count: 1, waiter_id: null, customer_id: null, discount_amount: 0, discount_type: 'fixed', enable_vat: taxSettings.enable_vat, enable_service: taxSettings.enable_service };
    posState.paymentsList = []; posState.currentTip = 0; posState.tipStaffId = null; posState.splits = [];
}
function renderWaitersAndCustomersDropdowns() {
    const wSel = document.getElementById('select-waiter'); if (wSel) wSel.innerHTML = posState.waiters.map(w => `<option value="${w.id}">${w.name}</option>`).join('');
    const cSel = document.getElementById('select-customer'); if (cSel) cSel.innerHTML = posState.customers.map(c => `<option value="${c.id}">${c.name}</option>`).join('');
}
function setOrderType(type) {
    posState.selectedOrderType = type;
    document.querySelectorAll('.type-btn').forEach(b => b.className = "type-btn px-4 py-2 rounded-xl text-xs font-bold bg-slate-100 text-slate-600 hover:bg-slate-200");
    const activeBtn = document.getElementById('type-' + type);
    if (activeBtn) activeBtn.className = "type-btn px-4 py-2 rounded-xl text-xs font-bold bg-blue-600 text-white shadow";
    renderAreaAndTables();
}
function updateGuestCount() { const input = document.getElementById('input-guests'); if (input) posState.cart.guest_count = parseInt(input.value) || 1; }

async function sendOrderToKitchen() {
    if (posState.cart.items.length === 0) return showToast('الفاتورة فارغة!', 'error');
    const branchId = currentUser.branch_id;
    const waiterId = document.getElementById('select-waiter') ? document.getElementById('select-waiter').value : null;
    const totals = calculateCartTotals();

    try {
        if (!posState.cart.id) {
            const { data: newOrd, error } = await _supabase.from('orders').insert([{
                company_id: currentUser.company_id, brand_id: currentUser.brand_id, branch_id: branchId,
                area_id: posState.selectedAreaId, table_id: posState.selectedTable ? posState.selectedTable.id : null,
                waiter_id: waiterId, order_type: posState.selectedOrderType, guest_count: posState.cart.guest_count,
                sub_total: totals.subtotal, tax_amount: totals.vatAmount, service_charge_amount: totals.serviceAmount,
                discount_amount: totals.discountTotal, total_amount: totals.finalTotal, status: 'sent', kitchen_status: 'pending'
            }]).select().single();
            if (error) return showToast(error.message, 'error');
            posState.cart.id = newOrd.id; posState.cart.order_number = newOrd.order_number; posState.cart.status = 'sent';

            for (const item of posState.cart.items) {
                const { data: insItem } = await _supabase.from('order_items').insert([{ order_id: newOrd.id, product_id: item.product_id, quantity: item.qty, unit_price: item.price, total_price: item.price * item.qty }]).select().single();
                if (insItem) item.db_item_id = insItem.id;
            }
            if (posState.selectedTable) { await _supabase.from('tables').update({ status: 'occupied' }).eq('id', posState.selectedTable.id); await fetchBranchTables(); renderAreaAndTables(); }
        } else {
            await _supabase.rpc('update_order_financials', { p_order_id: posState.cart.id, p_sub_total: totals.subtotal, p_tax_amount: totals.vatAmount, p_service_amount: totals.serviceAmount, p_discount_amount: totals.discountTotal, p_total_amount: totals.finalTotal });
            for (const item of posState.cart.items) {
                if (!item.db_item_id) {
                    const { data: insItem } = await _supabase.from('order_items').insert([{ order_id: posState.cart.id, product_id: item.product_id, quantity: item.qty, unit_price: item.price, total_price: item.price * item.qty }]).select().single();
                    if (insItem) item.db_item_id = insItem.id;
                }
            }
        }
        showToast('🚀 تم الإرسال للمطبخ!'); renderOrderCartTicket();
    } catch (err) { console.error(err); }
}

// -----------------------------------------
// نظام الدفع المتعدد و Tips و On Account
// -----------------------------------------
function openMultiplePaymentsModal() {
    if (posState.cart.items.length === 0) return alert('الفاتورة فارغة!');
    const totals = calculateCartTotals();
    posState.paymentsList = [{ method: 'cash', amount: totals.finalTotal }];
    posState.currentTip = 0;
    
    // إعداد قائمة الويترز للـ Tip
    const tipWaiterSelect = document.getElementById('tip-waiter-select');
    if (tipWaiterSelect) {
        tipWaiterSelect.innerHTML = posState.waiters.map(w => `<option value="${w.id}">${w.name}</option>`).join('');
        if (posState.cart.waiter_id) tipWaiterSelect.value = posState.cart.waiter_id;
    }
    
    renderPaymentLines();
    document.getElementById('payments-modal').classList.remove('hidden');
}

function closeMultiplePaymentsModal() { document.getElementById('payments-modal').classList.add('hidden'); }

function renderPaymentLines() {
    const container = document.getElementById('payment-lines-list');
    const totals = calculateCartTotals();
    const paidSum = posState.paymentsList.reduce((s, p) => s + (parseFloat(p.amount) || 0), 0);
    const tip = parseFloat(document.getElementById('input-tip-amount')?.value) || 0;
    
    const requiredDue = totals.finalTotal; // Tip منفصل ماليا ولا يضاف للإيراد
    const totalCollected = paidSum + tip;
    const remaining = requiredDue - paidSum;

    document.getElementById('modal-pay-total-due').innerText = formatCurrency(requiredDue);
    document.getElementById('modal-pay-remaining').innerText = formatCurrency(remaining);
    document.getElementById('modal-pay-collected').innerText = formatCurrency(totalCollected);

    container.innerHTML = posState.paymentsList.map((p, idx) => `
        <div class="flex gap-2 items-center bg-slate-50 p-2 rounded-xl border border-slate-200 mb-2">
            <select onchange="updatePaymentMethod(${idx}, this.value)" class="bg-white border text-xs font-bold p-2 rounded-lg flex-1">
                <option value="cash" ${p.method==='cash'?'selected':''}>نقدي (Cash)</option>
                <option value="card" ${p.method==='card'?'selected':''}>بطاقة (Card)</option>
                <option value="on_account" ${p.method==='on_account'?'selected':''}>على الحساب (On Account)</option>
            </select>
            <input type="number" step="0.01" value="${p.amount}" onchange="updatePaymentAmount(${idx}, this.value)" class="w-28 bg-white border p-2 rounded-lg text-xs font-bold text-center">
            <button onclick="removePaymentLine(${idx})" class="text-red-500 font-bold px-2">✕</button>
        </div>
    `).join('');
}

function updatePaymentMethod(idx, val) { posState.paymentsList[idx].method = val; renderPaymentLines(); }
function updatePaymentAmount(idx, val) { posState.paymentsList[idx].amount = parseFloat(val) || 0; renderPaymentLines(); }
function addPaymentLine() { posState.paymentsList.push({ method: 'card', amount: 0 }); renderPaymentLines(); }
function removePaymentLine(idx) { posState.paymentsList.splice(idx, 1); renderPaymentLines(); }

async function confirmMultiplePaymentsAndClose() {
    const totals = calculateCartTotals();
    const paidSum = posState.paymentsList.reduce((s, p) => s + (parseFloat(p.amount) || 0), 0);
    const tip = parseFloat(document.getElementById('input-tip-amount').value) || 0;
    const tipWaiterId = document.getElementById('tip-waiter-select').value;

    if (Math.abs(paidSum - totals.finalTotal) > 0.01) {
        return showToast('مجموع المدفوعات لا يطابق إجمالي الفاتورة المطلوب!', 'error');
    }

    const onAcc = posState.paymentsList.find(p => p.method === 'on_account');
    if (onAcc) {
        const custId = document.getElementById('select-customer').value;
        const cust = posState.customers.find(c => c.id === custId);
        if (!cust || cust.customer_type !== 'on_account') return showToast('العميل غير مصرح له بالسداد الآجل!', 'error');
        const newBal = (parseFloat(cust.current_balance) || 0) + onAcc.amount;
        if (newBal > (parseFloat(cust.credit_limit) || 0)) return showToast('تجاوز الحد الائتماني للعميل!', 'error');
        await _supabase.from('customers').update({ current_balance: newBal }).eq('id', cust.id);
    }

    if (!posState.cart.id) await sendOrderToKitchen();

    // حفظ المدفوعات مع عزل ה-Tip بالكامل عن Sales Revenue
    for (const p of posState.paymentsList) {
        await _supabase.from('payments').insert([{
            order_id: posState.cart.id, payment_method: p.method, amount: p.amount,
            tip_amount: (p === posState.paymentsList[0]) ? tip : 0, // وضع ה-tip على أول دفعة
            tip_staff_id: (p === posState.paymentsList[0] && tip > 0) ? tipWaiterId : null
        }]);
    }

    await _supabase.from('orders').update({ status: 'closed', kitchen_status: 'ready' }).eq('id', posState.cart.id);
    if (posState.selectedTable) { await _supabase.from('tables').update({ status: 'available' }).eq('id', posState.selectedTable.id); await fetchBranchTables(); renderAreaAndTables(); }

    closeMultiplePaymentsModal(); showToast(`💳 تم دفع وإغلاق الطلب بنجاح!`); resetActiveCart(); renderOrderCartTicket();
}

// -----------------------------------------
// نظام تقسيم الفاتورة (Split Bill)
// -----------------------------------------
function openSplitBillModal() {
    if (!posState.cart.id) return alert('الطلب لم يرسل بعد!');
    if (posState.cart.items.length === 0) return;
    
    document.getElementById('split-modal').classList.remove('hidden');
    // إعداد واجهة التقسيم (Split by Amount, Items, Guests) ستضاف لاحقا
    showToast('يتم الآن فتح وحدة التقسيم المتقدمة...');
}
function closeSplitModal() { document.getElementById('split-modal').classList.add('hidden'); }
