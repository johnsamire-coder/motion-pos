// js/pos.js - موديول الكاشير (طلبات، طاولات، تعدد المدفوعات، الإكراميات، والإضافات)

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
    recordedPayments: 0,
    currentTip: 0,
    tipStaffId: null,
    
    // حالة تقسيم الفاتورة (Split Bill State)
    splitState: {
        activeTab: 'items', // 'items' | 'amount' | 'guests'
        splits: [], // [{ id, split_number, items: [{db_item_id, product_id, name, price, qty}], amount_due, status: 'pending'|'paid', payments: [] }]
        activeSplitIndex: 0
    }
};
let paymentSubmissionInProgress = false;
let orderSubmissionInProgress = false;

async function initPOSModule() {
    if (!currentUser) return;
    if (!currentUser.branch_id) {
        showToast('حساب الموظف غير مرتبط بفرع، لذلك لا يمكن فتح الكاشير.', 'error');
        return;
    }
    posState.cart.enable_vat = taxSettings.enable_vat;
    posState.cart.enable_service = taxSettings.enable_service;
    await loadPOSMasterData();
    renderPOSTerminal();
}

async function loadPOSMasterData() {
    const branchId = currentUser.branch_id;
    try {
        const [waitersRes, custRes, catRes, prodRes, reasonRes, discRes] = await Promise.all([
            _supabase.rpc('list_branch_staff', { p_token: staffSessionToken }),
            _supabase.from('customers').select('*'),
            _supabase.from('categories').select('*'),
            _supabase.from('products').select('*'),
            _supabase.from('cancel_reasons').select('*'),
            _supabase.from('discounts').select('*')
        ]);

        const errors = [
            ['الموظفين', waitersRes], ['العملاء', custRes], ['الأقسام', catRes],
            ['الأصناف', prodRes], ['أسباب الإلغاء', reasonRes], ['الخصومات', discRes]
        ].filter(([, result]) => result?.error).map(([label, result]) => `${label}: ${result.error.message}`);
        if (errors.length) {
            console.error('POS master data load errors:', errors);
            showToast('تعذر تحميل بعض قوائم الكاشير: ' + errors.join(' | '), 'error');
        }

        posState.waiters = waitersRes.data || [];
        posState.customers = custRes.data || [];
        posState.categories = catRes.data || [];
        posState.products = prodRes.data || [];
        posState.cancelReasons = reasonRes.data || [];
        posState.discounts = discRes.data || [];

        if (currentBranch && currentBranch.has_tables) {
            const { data: areasData, error: areasError } = await _supabase.from('areas').select('*').eq('branch_id', branchId);
            if (areasError) throw areasError;
            posState.areas = areasData || [];
            if (posState.areas.length > 0) {
                if (!posState.areas.some(area => String(area.id) === String(posState.selectedAreaId))) {
                    posState.selectedAreaId = posState.areas[0].id;
                }
                await fetchBranchTables();
            } else {
                posState.selectedAreaId = null;
                posState.tables = [];
            }
        } else {
            posState.areas = [];
            posState.tables = [];
        }
    } catch (err) {
        console.error('POS master data exception:', err);
        showToast('تعذر تحميل بيانات الكاشير: ' + (err.message || 'خطأ غير معروف'), 'error');
    }
}

async function fetchBranchTables() {
    if (!posState.selectedAreaId) return;
    const { data, error } = await _supabase.from('tables').select('*').eq('area_id', posState.selectedAreaId);
    if (error) {
        console.error('Table load error:', error);
        showToast('تعذر تحميل الطاولات: ' + error.message, 'error');
        posState.tables = [];
        return;
    }
    posState.tables = data || [];
}

async function renderTablesForArea() {
    const areaSelect = document.getElementById('area-select');
    if (!areaSelect) return;
    if (posState.cart.id) {
        areaSelect.value = String(posState.selectedAreaId || '');
        showToast('لا يمكن تغيير المنطقة أثناء وجود طلب محفوظ مفتوح', 'error');
        return;
    }

    posState.selectedAreaId = areaSelect.value || null;
    posState.selectedTable = null;
    posState.tables = [];
    if (posState.selectedAreaId) await fetchBranchTables();
    renderAreaAndTables();
    renderOrderCartTicket();
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
        populateSelectOptions('area-select', posState.areas, 'اختر المنطقة', 'لا توجد مناطق لهذا الفرع', area => area.name);
        if (posState.selectedAreaId) areaSelect.value = String(posState.selectedAreaId);
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
    if (posState.cart.id && posState.selectedTable?.id !== tableId) {
        return showToast('أغلق الطلب الحالي قبل الانتقال إلى طاولة أخرى', 'error');
    }
    if (!posState.cart.id && posState.cart.items.length > 0) {
        return showToast('أرسل الطلب الحالي أو أفرغه قبل اختيار طاولة أخرى', 'error');
    }

    const previousTable = posState.selectedTable;
    const nextTable = posState.tables.find(t => t.id === tableId);
    if (!nextTable) return showToast('الطاولة المحددة غير موجودة في المنطقة الحالية', 'error');
    posState.selectedTable = nextTable;
    renderAreaAndTables();

    const { data: openOrders, error } = await _supabase
        .from('orders')
        .select('*, order_items(*, products(name), order_item_modifiers(*))')
        .eq('table_id', tableId)
        .not('status', 'in', '("closed","cancelled")');

    if (error) {
        posState.selectedTable = previousTable;
        renderAreaAndTables();
        showToast('تعذر تحميل الطلب المرتبط بالطاولة: ' + error.message, 'error');
        return;
    }

    if (openOrders && openOrders.length > 0) {
        const ord = openOrders[0];
        posState.selectedOrderType = ord.order_type || 'dine_in';
        posState.cart = {
            id: ord.id, order_number: ord.order_number, status: ord.status, kitchen_status: ord.kitchen_status,
            items: ord.order_items.filter(i => i.status !== 'voided').map(i => ({
                db_item_id: i.id, product_id: i.product_id, name: i.products ? i.products.name : 'صنف',
                price: parseFloat(i.unit_price), qty: i.quantity, modifiers: i.order_item_modifiers || [], discount: parseFloat(i.discount_amount) || 0
            })),
            guest_count: ord.guest_count || 1, waiter_id: ord.waiter_id, customer_id: ord.customer_id,
            discount_amount: parseFloat(ord.discount_amount) || 0, discount_type: 'fixed',
            enable_vat: taxSettings.enable_vat, enable_service: taxSettings.enable_service
        };
    } else {
        posState.selectedOrderType = 'dine_in';
        resetActiveCart();
    }
    document.querySelectorAll('.type-btn').forEach(button => {
        button.className = "type-btn px-4 py-2 rounded-xl text-xs font-bold bg-slate-100 text-slate-600 hover:bg-slate-200";
    });
    const activeTypeButton = document.getElementById('type-' + posState.selectedOrderType);
    if (activeTypeButton) activeTypeButton.className = "type-btn px-4 py-2 rounded-xl text-xs font-bold bg-blue-600 text-white shadow";
    renderAreaAndTables();
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
    let filtered = posState.products.filter(product => product.is_available !== false);
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
    const typeInfoElem = document.getElementById('ticket-type-info');
    if (typeInfoElem) typeInfoElem.innerText = `النوع: ${posState.selectedOrderType}`;
    const waiterSelect = document.getElementById('select-waiter');
    if (waiterSelect) waiterSelect.value = posState.cart.waiter_id || '';
    const customerSelect = document.getElementById('select-customer');
    if (customerSelect) customerSelect.value = posState.cart.customer_id || '';
    const guestInput = document.getElementById('input-guests');
    if (guestInput) guestInput.value = posState.cart.guest_count || 1;

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

// شباك صغير لرقم المدير: الأرقام بتظهر نجوم عشان الكاشير ميشوفش رقم المدير
function askManagerPin(message) {
    return new Promise(resolve => {
        const overlay = document.createElement('div');
        overlay.className = 'fixed inset-0 bg-slate-900/60 z-50 flex items-center justify-center p-4';
        overlay.innerHTML = '<div class="bg-white rounded-2xl p-5 w-full max-w-xs shadow-xl text-right" dir="rtl">'
            + '<p class="text-sm font-bold mb-3 text-slate-700"></p>'
            + '<input type="password" inputmode="numeric" maxlength="4" autocomplete="off" class="w-full text-center text-2xl font-extrabold tracking-widest bg-slate-50 border p-3 rounded-2xl mb-4 focus:outline-none">'
            + '<div class="flex gap-2"><button data-ok class="flex-1 bg-blue-600 text-white py-2 rounded-xl font-bold text-xs">تأكيد</button>'
            + '<button data-cancel class="flex-1 bg-slate-200 text-slate-700 py-2 rounded-xl font-bold text-xs">إلغاء</button></div></div>';
        overlay.querySelector('p').textContent = message;
        const input = overlay.querySelector('input');
        const done = value => { overlay.remove(); resolve(value); };
        overlay.querySelector('[data-ok]').onclick = () => done(input.value || null);
        overlay.querySelector('[data-cancel]').onclick = () => done(null);
        input.addEventListener('keydown', e => {
            if (e.key === 'Enter') done(input.value || null);
            if (e.key === 'Escape') done(null);
        });
        document.body.appendChild(overlay);
        input.focus();
    });
}

async function voidCartItem(idx) {
    const item = posState.cart.items[idx];
    if (!item) return;
    if (!item.db_item_id) { posState.cart.items.splice(idx, 1); renderOrderCartTicket(); return; }

    if (!posState.cancelReasons.length) return showToast('لا توجد أسباب إلغاء مسجلة. أضف أسباب الإلغاء أولاً.', 'error');
    const reasonPrompt = prompt('اكتب رقم سبب مسح الصنف المكتوب بالمطبخ:\n' + posState.cancelReasons.map((r, i) => `${i+1}. ${r.reason}`).join('\n'));
    if (!reasonPrompt) return;
    const reason = posState.cancelReasons[parseInt(reasonPrompt, 10) - 1];
    if (!reason) return showToast('رقم السبب غير صحيح', 'error');

    // مسح صنف اتبعت للمطبخ لازم موافقة المدير، والسيرفر هو اللي بيتأكد من رقمه
    const managerPin = await askManagerPin('مسح صنف اتبعت للمطبخ يحتاج موافقة المدير. أدخل رقم المدير:');
    if (!managerPin) return;

    try {
        const { data: res, error } = await _supabase.rpc('void_order_item_secure', {
            p_token: staffSessionToken, p_order_item_id: item.db_item_id, p_reason_id: reason.id, p_manager_pin: String(managerPin).trim()
        });
        if (error) return showToast('خطأ: ' + error.message, 'error');
        if (!res || !res.ok) {
            const messages = {
                manager_pin: 'رقم المدير غير صحيح، أو الموافقة متوقفة مؤقتاً بسبب محاولات خاطئة كثيرة',
                bad_reason: 'سبب الإلغاء غير صحيح',
                item_not_found: 'الصنف غير موجود أو الطلب مقفول'
            };
            return showToast(messages[res && res.reason] || 'تعذر مسح الصنف', 'error');
        }

        posState.cart.items.splice(idx, 1);
        const totals = calculateCartTotals();
        await _supabase.rpc('update_order_financials', { p_order_id: posState.cart.id, p_sub_total: totals.subtotal, p_tax_amount: totals.vatAmount, p_service_amount: totals.serviceAmount, p_discount_amount: totals.discountTotal, p_total_amount: totals.finalTotal });
        renderOrderCartTicket(); showToast('تم مسح الصنف بموافقة المدير');
    } catch (err) { console.error(err); showToast('حدث خطأ أثناء الاتصال بالسيرفر', 'error'); }
}

function toggleVatTax() { posState.cart.enable_vat = !posState.cart.enable_vat; renderOrderCartTicket(); }
function toggleServiceCharge() { posState.cart.enable_service = !posState.cart.enable_service; renderOrderCartTicket(); }
function resetActiveCart() {
    posState.cart = { id: null, order_number: 'طلب جديد', status: 'draft', kitchen_status: 'pending', items: [], guest_count: 1, waiter_id: null, customer_id: null, discount_amount: 0, discount_type: 'fixed', enable_vat: taxSettings.enable_vat, enable_service: taxSettings.enable_service };
    posState.paymentsList = []; posState.recordedPayments = 0; posState.currentTip = 0; posState.tipStaffId = null; posState.splitState = { activeTab: 'items', splits: [], activeSplitIndex: 0 };
}
function renderWaitersAndCustomersDropdowns() {
    populateSelectOptions('select-waiter', posState.waiters, 'اختر الويتر', 'لا يوجد موظفون لهذا الفرع');
    populateSelectOptions('select-customer', posState.customers, 'اختر العميل', 'لا يوجد عملاء مسجلون');
}
function setOrderType(type) {
    posState.selectedOrderType = type;
    document.querySelectorAll('.type-btn').forEach(b => b.className = "type-btn px-4 py-2 rounded-xl text-xs font-bold bg-slate-100 text-slate-600 hover:bg-slate-200");
    const activeBtn = document.getElementById('type-' + type);
    if (activeBtn) activeBtn.className = "type-btn px-4 py-2 rounded-xl text-xs font-bold bg-blue-600 text-white shadow";
    const typeInfo = document.getElementById('ticket-type-info');
    if (typeInfo) typeInfo.innerText = `النوع: ${type}`;
    renderAreaAndTables();
}
function updateGuestCount() { const input = document.getElementById('input-guests'); if (input) posState.cart.guest_count = parseInt(input.value) || 1; }

async function sendOrderToKitchen() {
    if (orderSubmissionInProgress) return false;
    if (posState.cart.items.length === 0) {
        showToast('الفاتورة فارغة!', 'error');
        return false;
    }
    orderSubmissionInProgress = true;
    const branchId = currentUser.branch_id;
    const waiterId = document.getElementById('select-waiter') ? document.getElementById('select-waiter').value : null;
    const customerId = document.getElementById('select-customer') ? document.getElementById('select-customer').value : null;
    const totals = calculateCartTotals();

    try {
        if (!posState.cart.id) {
            const { data: newOrd, error } = await _supabase.from('orders').insert([{
                company_id: currentUser.company_id, brand_id: currentUser.brand_id, branch_id: branchId,
                area_id: posState.selectedAreaId, table_id: posState.selectedTable ? posState.selectedTable.id : null,
                waiter_id: waiterId || null, customer_id: customerId || null, order_type: posState.selectedOrderType, guest_count: posState.cart.guest_count,
                sub_total: totals.subtotal, tax_amount: totals.vatAmount, service_charge_amount: totals.serviceAmount,
                discount_amount: totals.discountTotal, total_amount: totals.finalTotal, status: 'sent', kitchen_status: 'pending'
            }]).select().single();
            if (error) throw error;
            posState.cart.id = newOrd.id; posState.cart.order_number = newOrd.order_number; posState.cart.status = 'sent';

            for (const item of posState.cart.items) {
                const { data: insItem, error: itemError } = await _supabase.from('order_items').insert([{ order_id: newOrd.id, product_id: item.product_id, quantity: item.qty, unit_price: item.price, total_price: item.price * item.qty }]).select().single();
                if (itemError) throw itemError;
                if (insItem) item.db_item_id = insItem.id;
            }
            if (posState.selectedTable) {
                const { error: tableError } = await _supabase.from('tables').update({ status: 'occupied' }).eq('id', posState.selectedTable.id);
                if (tableError) throw tableError;
                await fetchBranchTables();
                renderAreaAndTables();
            }
        } else {
            const { error: totalsError } = await _supabase.rpc('update_order_financials', { p_order_id: posState.cart.id, p_sub_total: totals.subtotal, p_tax_amount: totals.vatAmount, p_service_amount: totals.serviceAmount, p_discount_amount: totals.discountTotal, p_total_amount: totals.finalTotal });
            if (totalsError) throw totalsError;
            const { error: orderError } = await _supabase.from('orders').update({
                waiter_id: waiterId || null, customer_id: customerId || null,
                order_type: posState.selectedOrderType, guest_count: posState.cart.guest_count
            }).eq('id', posState.cart.id);
            if (orderError) throw orderError;
            for (const item of posState.cart.items) {
                if (!item.db_item_id) {
                    const { data: insItem, error: itemError } = await _supabase.from('order_items').insert([{ order_id: posState.cart.id, product_id: item.product_id, quantity: item.qty, unit_price: item.price, total_price: item.price * item.qty }]).select().single();
                    if (itemError) throw itemError;
                    if (insItem) item.db_item_id = insItem.id;
                }
            }
        }
        showToast('🚀 تم الإرسال للمطبخ!'); renderOrderCartTicket();
        return true;
    } catch (err) {
        console.error('Send order error:', err);
        showToast('تعذر حفظ الطلب أو إرساله للمطبخ: ' + (err.message || 'خطأ غير معروف'), 'error');
        return false;
    } finally {
        orderSubmissionInProgress = false;
    }
}

// -----------------------------------------
// نظام الدفع المتعدد و Tips و On Account
// -----------------------------------------
async function openMultiplePaymentsModal() {
    if (posState.cart.items.length === 0) return showToast('الفاتورة فارغة!', 'error');
    const totals = calculateCartTotals();
    posState.recordedPayments = 0;
    if (posState.cart.id) {
        const { data, error } = await _supabase.from('payments').select('amount').eq('order_id', posState.cart.id);
        if (error) {
            showToast('تعذر قراءة المدفوعات السابقة؛ لم يتم فتح شاشة الدفع: ' + error.message, 'error');
            return;
        }
        posState.recordedPayments = (data || []).reduce((sum, payment) => sum + (Number(payment.amount) || 0), 0);
        if (posState.recordedPayments > totals.finalTotal + 0.01) {
            showToast('المدفوعات المسجلة تتجاوز إجمالي الفاتورة؛ راجع الحسابات قبل الإغلاق', 'error');
            return;
        }
    }
    const remainingDue = Math.max(0, totals.finalTotal - posState.recordedPayments);
    posState.paymentsList = [{ method: 'cash', amount: remainingDue }];
    posState.currentTip = 0;
    const tipInput = document.getElementById('input-tip-amount');
    if (tipInput) tipInput.value = '0';
    
    const tipWaiterSelect = document.getElementById('tip-waiter-select');
    if (tipWaiterSelect) {
        populateSelectOptions('tip-waiter-select', posState.waiters, 'اختر موظف الإكرامية', 'لا يوجد موظفون لهذا الفرع');
        if (posState.cart.waiter_id) tipWaiterSelect.value = String(posState.cart.waiter_id);
    }
    
    renderPaymentLines();
    document.getElementById('payments-modal').classList.remove('hidden');
}

function closeMultiplePaymentsModal() { document.getElementById('payments-modal').classList.add('hidden'); }

function renderPaymentLines() {
    const container = document.getElementById('payment-lines-list');
    if (!container) return;
    const totals = calculateCartTotals();
    const paidSum = posState.paymentsList.reduce((s, p) => s + (parseFloat(p.amount) || 0), 0);
    const tip = parseFloat(document.getElementById('input-tip-amount')?.value) || 0;
    
    const requiredDue = totals.finalTotal; 
    const totalCollected = posState.recordedPayments + paidSum + tip;
    const remaining = requiredDue - posState.recordedPayments - paidSum;

    const dueEl = document.getElementById('modal-pay-total-due');
    const remainingEl = document.getElementById('modal-pay-remaining');
    const collectedEl = document.getElementById('modal-pay-collected');
    if (dueEl) dueEl.innerText = formatCurrency(requiredDue);
    if (remainingEl) remainingEl.innerText = formatCurrency(remaining);
    if (collectedEl) collectedEl.innerText = formatCurrency(totalCollected);

    container.innerHTML = posState.paymentsList.map((p, idx) => `
        <div class="flex gap-2 items-center bg-slate-50 p-2 rounded-xl border border-slate-200 mb-2">
            <select onchange="updatePaymentMethod(${idx}, this.value)" class="bg-white border text-xs font-bold p-2 rounded-lg flex-1">
                <option value="cash" ${p.method==='cash'?'selected':''}>نقدي (Cash)</option>
                <option value="card" ${p.method==='card'?'selected':''}>بطاقة (Card)</option>
                <option value="on_account" ${p.method==='on_account'?'selected':''}>على الحساب (On Account)</option>
            </select>
            <input type="number" min="0" step="0.01" value="${p.amount}" onchange="updatePaymentAmount(${idx}, this.value)" class="w-28 bg-white border p-2 rounded-lg text-xs font-bold text-center">
            <button onclick="removePaymentLine(${idx})" class="text-red-500 font-bold px-2">✕</button>
        </div>
    `).join('');
}

function updatePaymentMethod(idx, val) { posState.paymentsList[idx].method = val; renderPaymentLines(); }
function updatePaymentAmount(idx, val) {
    const amount = Number(val);
    posState.paymentsList[idx].amount = Number.isFinite(amount) && amount >= 0 ? amount : 0;
    renderPaymentLines();
}
function addPaymentLine() { posState.paymentsList.push({ method: 'card', amount: 0 }); renderPaymentLines(); }
function removePaymentLine(idx) { posState.paymentsList.splice(idx, 1); renderPaymentLines(); }

async function confirmMultiplePaymentsAndClose() {
    if (paymentSubmissionInProgress) return;
    const totals = calculateCartTotals();
    const paidSum = posState.paymentsList.reduce((s, p) => s + (parseFloat(p.amount) || 0), 0);
    const tipValue = Number(document.getElementById('input-tip-amount')?.value ?? 0);
    const tip = Number.isFinite(tipValue) && tipValue >= 0 ? tipValue : NaN;
    const tipWaiterId = document.getElementById('tip-waiter-select')?.value || null;

    if (posState.paymentsList.some(p => !Number.isFinite(Number(p.amount)) || Number(p.amount) < 0) || !Number.isFinite(tip)) {
        return showToast('أدخل مبالغ مدفوعات وإكرامية صحيحة (صفر أو أكثر)', 'error');
    }
    if (tip > 0 && !tipWaiterId) {
        return showToast('اختر موظفًا لتخصيص الإكرامية له', 'error');
    }
    if (Math.abs(paidSum + posState.recordedPayments - totals.finalTotal) > 0.01) {
        return showToast('مجموع الدفعات الجديدة والسابقة لا يطابق إجمالي الفاتورة!', 'error');
    }

    const onAccountAmount = posState.paymentsList
        .filter(p => p.method === 'on_account')
        .reduce((sum, p) => sum + Number(p.amount), 0);
    let onAccountCustomer = null;
    let onAccountBalance = 0;
    if (onAccountAmount > 0) {
        const custId = posState.cart.customer_id || document.getElementById('select-customer')?.value;
        onAccountCustomer = posState.customers.find(c => String(c.id) === String(custId));
        if (!onAccountCustomer || onAccountCustomer.customer_type !== 'on_account') {
            return showToast('العميل غير مصرح له بالسداد الآجل!', 'error');
        }
        onAccountBalance = Number(onAccountCustomer.current_balance) || 0;
        const newBalance = onAccountBalance + onAccountAmount;
        if (newBalance > (Number(onAccountCustomer.credit_limit) || 0)) {
            return showToast('تجاوز الحد الائتماني للعميل!', 'error');
        }
    }

    paymentSubmissionInProgress = true;
    const confirmButton = document.getElementById('confirm-payments-button');
    if (confirmButton) confirmButton.disabled = true;
    let onAccountBalanceUpdated = false;
    let onAccountRecordedAmount = 0;
    const firstPositivePayment = posState.paymentsList.find(p => Number(p.amount) > 0);
    try {
        if (!(await sendOrderToKitchen())) return;
        if (!posState.cart.id) {
            showToast('تعذر إنشاء رقم للطلب؛ لم يتم تسجيل أي دفعة.', 'error');
            return;
        }

        for (const p of posState.paymentsList) {
            const amount = Number(p.amount);
            if (amount <= 0) continue;

            if (p.method === 'on_account' && !onAccountBalanceUpdated) {
                const { error: customerError } = await _supabase.from('customers')
                    .update({ current_balance: onAccountBalance + onAccountAmount })
                    .eq('id', onAccountCustomer.id);
                if (customerError) throw new Error('تعذر تحديث رصيد العميل الآجل: ' + customerError.message);
                onAccountBalanceUpdated = true;
                onAccountCustomer.current_balance = onAccountBalance + onAccountAmount;
            }

            const { error: paymentError } = await _supabase.from('payments').insert([{
                order_id: posState.cart.id, payment_method: p.method, amount,
                tip_amount: (p === firstPositivePayment) ? tip : 0,
                tip_staff_id: (p === firstPositivePayment && tip > 0) ? tipWaiterId : null
            }]);
            if (paymentError) throw new Error('تعذر تسجيل إحدى الدفعات: ' + paymentError.message);
            posState.recordedPayments += amount;
            if (p.method === 'on_account') onAccountRecordedAmount += amount;
        }

        const { error: orderError } = await _supabase.from('orders')
            .update({ status: 'closed', kitchen_status: 'ready' }).eq('id', posState.cart.id);
        if (orderError) throw new Error('تم تسجيل الدفعات لكن تعذر إغلاق الطلب: ' + orderError.message);

        let tableError = null;
        if (posState.selectedTable) {
            const result = await _supabase.from('tables')
                .update({ status: 'available' }).eq('id', posState.selectedTable.id);
            tableError = result.error;
            await fetchBranchTables();
            renderAreaAndTables();
        }

        closeMultiplePaymentsModal();
        resetActiveCart();
        renderOrderCartTicket();
        if (tableError) showToast('أُغلق الطلب، لكن تعذر تحديث حالة الطاولة: ' + tableError.message, 'error');
        else showToast('💳 تم تسجيل الدفعات وإغلاق الطلب بنجاح!');
    } catch (err) {
        console.error('Payment completion error:', err);
        let rollbackMessage = '';
        const unrecordedCredit = onAccountAmount - onAccountRecordedAmount;
        if (onAccountBalanceUpdated && onAccountCustomer && unrecordedCredit > 0) {
            try {
                const { data: freshCustomer, error: readError } = await _supabase.from('customers')
                    .select('current_balance').eq('id', onAccountCustomer.id).single();
                if (readError) throw readError;
                const currentBalance = Number(freshCustomer.current_balance) || 0;
                const restoredBalance = currentBalance - unrecordedCredit;
                const { error: rollbackError } = await _supabase.from('customers')
                    .update({ current_balance: restoredBalance })
                    .eq('id', onAccountCustomer.id);
                if (rollbackError) throw rollbackError;
                onAccountCustomer.current_balance = restoredBalance;
            } catch (rollbackError) {
                console.error('Customer credit rollback error:', rollbackError);
                rollbackMessage = ' وتعذر التراجع عن تحديث رصيد العميل؛ راجع رصيد العميل يدويًا.';
            }
        }
        showToast((posState.recordedPayments > 0
            ? 'قد تكون بعض الدفعات قد سُجلت؛ أعد فتح الدفع لمزامنة الرصيد قبل المحاولة مرة أخرى. '
            : 'لم تكتمل عملية الدفع. ') + (err.message || 'خطأ غير معروف') + rollbackMessage, 'error');
    } finally {
        paymentSubmissionInProgress = false;
        if (confirmButton) confirmButton.disabled = false;
    }
}

// -----------------------------------------
// معاينة تقسيم الفاتورة (الدفع المنفصل غير مدعوم)
// -----------------------------------------
function openSplitBillModal() {
    if (!posState.cart.id) return alert('الطلب لم يرسل للمطبخ بعد للحفظ بالداتا بيز!');
    if (posState.cart.items.length === 0) return;
    
    // إعداد التفتيت الأولي (Initial 2 Splits)
    const totals = calculateCartTotals();
    posState.splitState.splits = [
        { split_number: 1, items: JSON.parse(JSON.stringify(posState.cart.items)), amount_due: totals.finalTotal, status: 'pending', payments: [] },
        { split_number: 2, items: [], amount_due: 0, status: 'pending', payments: [] }
    ];
    
    renderSplitModal();
    document.getElementById('split-modal').classList.remove('hidden');
}

function closeSplitModal() { document.getElementById('split-modal').classList.add('hidden'); }

function setSplitType(type) {
    posState.splitState.activeTab = type;
    if (type === 'guests') {
        const guestCount = posState.cart.guest_count || 2;
        const totals = calculateCartTotals();
        const perGuestAmount = totals.finalTotal / guestCount;
        
        posState.splitState.splits = [];
        for (let i = 1; i <= guestCount; i++) {
            posState.splitState.splits.push({ split_number: i, items: [], amount_due: perGuestAmount, status: 'pending', payments: [] });
        }
    } else if (type === 'amount') {
        const totals = calculateCartTotals();
        posState.splitState.splits = [
            { split_number: 1, items: [], amount_due: totals.finalTotal / 2, status: 'pending', payments: [] },
            { split_number: 2, items: [], amount_due: totals.finalTotal / 2, status: 'pending', payments: [] }
        ];
    }
    renderSplitModal();
}

function addNewSplitGroup() {
    const nextNum = posState.splitState.splits.length + 1;
    posState.splitState.splits.push({ split_number: nextNum, items: [], amount_due: 0, status: 'pending', payments: [] });
    renderSplitModal();
}

function renderSplitModal() {
    const totals = calculateCartTotals();
    document.getElementById('split-orig-total').innerText = formatCurrency(totals.finalTotal);
    
    const container = document.getElementById('split-workspace-content');
    if (!container) return;

    if (posState.splitState.activeTab === 'items') {
        renderSplitByItems(container);
    } else if (posState.splitState.activeTab === 'amount') {
        renderSplitByAmount(container);
    } else if (posState.splitState.activeTab === 'guests') {
        renderSplitByGuests(container);
    }
}

function applyDiscountPrompt() {
    if (posState.cart.items.length === 0) return showToast('أضف صنفًا قبل تطبيق الخصم', 'error');
    const itemSubtotal = posState.cart.items.reduce((sum, item) => sum + item.price * item.qty, 0);
    const itemDiscounts = posState.cart.items.reduce((sum, item) => sum + (Number(item.discount) || 0), 0);
    const maxDiscount = Math.max(0, itemSubtotal - itemDiscounts);
    const amountStr = prompt('أدخل قيمة الخصم (بالجنيه):', String(posState.cart.discount_amount || 0));
    if (amountStr === null) return;

    const amount = Number(amountStr);
    if (!Number.isFinite(amount) || amount < 0 || amount > maxDiscount) {
        return showToast(`أدخل خصمًا بين 0 و${formatCurrency(maxDiscount)}`, 'error');
    }
    posState.cart.discount_amount = amount;
    renderOrderCartTicket();
    showToast('تم تطبيق الخصم');
}

function openTransferTableModal() {
    if (!posState.cart.id) return showToast('أرسل الطلب للمطبخ قبل نقله إلى طاولة أخرى', 'error');
    if (!posState.selectedTable) return showToast('اختر الطاولة الحالية أولًا', 'error');

    const availableTables = posState.tables.filter(table => table.id !== posState.selectedTable.id && table.status === 'available');
    if (availableTables.length === 0) return showToast('لا توجد طاولات متاحة للنقل', 'error');

    const targetNumber = prompt('أدخل رقم الطاولة المتاحة:\n' + availableTables.map(table => table.table_number).join(', '));
    if (targetNumber === null || !targetNumber.trim()) return;

    const targetTable = availableTables.find(table => String(table.table_number).trim() === targetNumber.trim());
    if (!targetTable) return showToast('الطاولة غير موجودة أو غير متاحة', 'error');
    executeTransferTable(targetTable.id);
}

async function executeTransferTable(newTableId) {
    try {
        const { error } = await _supabase.rpc('transfer_table_order', {
            p_order_id: posState.cart.id,
            p_new_table_id: newTableId,
            p_user_id: currentUser?.id || null
        });
        if (error) throw error;

        await fetchBranchTables();
        posState.selectedTable = posState.tables.find(table => table.id === newTableId) || null;
        renderAreaAndTables();
        renderOrderCartTicket();
        showToast('تم نقل الطلب للطاولة الجديدة');
    } catch (err) {
        console.error('Transfer error:', err);
        showToast('تعذر نقل الطلب: ' + (err.message || 'خطأ غير معروف'), 'error');
    }
}

function renderSplitByItems(container) {
    container.innerHTML = `
        <div class="grid grid-cols-2 gap-4 text-right">
            <div class="bg-slate-50 p-3 rounded-2xl border">
                <h4 class="font-black text-xs text-slate-800 mb-2 border-b pb-1">الطلب الأصلي (الأصناف)</h4>
                <div class="space-y-1 max-h-[220px] overflow-y-auto">
                    ${posState.splitState.splits[0].items.map((item, idx) => `
                        <div class="flex justify-between items-center bg-white p-2 rounded-xl border text-xs font-bold">
                            <span>${item.name} (x${item.qty})</span>
                            <button onclick="moveItemToSplit(${idx}, 1)" class="bg-blue-50 text-blue-600 px-2 py-0.5 rounded-lg border hover:bg-blue-100">نقل لـ Split 2 ⬅️</button>
                        </div>
                    `).join('')}
                </div>
            </div>
            <div class="bg-blue-50/50 p-3 rounded-2xl border border-blue-200">
                <h4 class="font-black text-xs text-blue-800 mb-2 border-b border-blue-200 pb-1">Split 2 (الشيك الفرعي)</h4>
                <div class="space-y-1 max-h-[220px] overflow-y-auto">
                    ${posState.splitState.splits[1].items.map((item, idx) => `
                        <div class="flex justify-between items-center bg-white p-2 rounded-xl border text-xs font-bold">
                            <span>${item.name} (x${item.qty})</span>
                            <button onclick="moveItemBackToOriginal(${idx})" class="bg-red-50 text-red-600 px-2 py-0.5 rounded-lg border hover:bg-red-100">إرجاع ➡️</button>
                        </div>
                    `).join('')}
                </div>
            </div>
        </div>
    `;
}

function moveItemToSplit(itemIdx, targetSplitIdx) {
    const origItem = posState.splitState.splits[0].items[itemIdx];
    if (!origItem) return;

    if (origItem.qty > 1) {
        origItem.qty--;
        const splitItem = posState.splitState.splits[targetSplitIdx].items.find(i => i.product_id === origItem.product_id);
        if (splitItem) splitItem.qty++;
        else posState.splitState.splits[targetSplitIdx].items.push({ ...origItem, qty: 1 });
    } else {
        const [moved] = posState.splitState.splits[0].items.splice(itemIdx, 1);
        posState.splitState.splits[targetSplitIdx].items.push(moved);
    }
    recalculateSplitAmounts();
    renderSplitModal();
}

function moveItemBackToOriginal(itemIdx) {
    const splitItem = posState.splitState.splits[1].items[itemIdx];
    if (!splitItem) return;

    if (splitItem.qty > 1) {
        splitItem.qty--;
        const origItem = posState.splitState.splits[0].items.find(i => i.product_id === splitItem.product_id);
        if (origItem) origItem.qty++;
        else posState.splitState.splits[0].items.push({ ...splitItem, qty: 1 });
    } else {
        const [moved] = posState.splitState.splits[1].items.splice(itemIdx, 1);
        posState.splitState.splits[0].items.push(moved);
    }
    recalculateSplitAmounts();
    renderSplitModal();
}

function recalculateSplitAmounts() {
    posState.splitState.splits.forEach(s => {
        let sub = s.items.reduce((sum, i) => sum + (i.price * i.qty), 0);
        let tax = posState.cart.enable_vat ? (sub * taxSettings.vat_percentage) / 100 : 0;
        let srv = (posState.selectedOrderType === 'dine_in' && posState.cart.enable_service) ? (sub * taxSettings.service_charge_percentage) / 100 : 0;
        s.amount_due = sub + tax + srv;
    });
}

function renderSplitByAmount(container) {
    container.innerHTML = `
        <div class="space-y-2">
            ${posState.splitState.splits.map((s, idx) => `
                <div class="flex justify-between items-center bg-slate-50 p-2 rounded-xl border text-xs font-bold">
                    <span>Split #${s.split_number}</span>
                    <input type="number" step="0.01" value="${s.amount_due.toFixed(2)}" onchange="updateSplitAmount(${idx}, this.value)" class="w-32 bg-white border p-1 rounded text-center font-bold">
                </div>
            `).join('')}
            <button onclick="addNewSplitGroup()" class="w-full bg-slate-100 p-2 rounded-xl text-xs font-bold border border-dashed">+ إضافة تقسيم جديد</button>
        </div>
    `;
}

function updateSplitAmount(idx, val) {
    posState.splitState.splits[idx].amount_due = parseFloat(val) || 0;
    renderSplitModal();
}

function renderSplitByGuests(container) {
    container.innerHTML = `
        <div class="space-y-2">
            <p class="text-xs font-bold text-slate-500 mb-2">تقسيم متساوي على ${posState.cart.guest_count} ضيوف:</p>
            ${posState.splitState.splits.map(s => `
                <div class="flex justify-between items-center bg-slate-50 p-2 rounded-xl border text-xs font-bold">
                    <span>ضيف #${s.split_number}</span>
                    <span class="text-blue-600 font-black">${formatCurrency(s.amount_due)}</span>
                </div>
            `).join('')}
        </div>
    `;
}
