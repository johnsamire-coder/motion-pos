// js/pos.js - موديول الكاشير ونقاط البيع المتقدم

let posState = {
    selectedOrderType: 'dine_in',
    selectedAreaId: null,
    selectedTable: null,
    areas: [],
    tables: [],
    categories: [],
    products: [],
    waiters: [],
    customers: [],
    cancelReasons: [],
    discounts: [],
    activeCategory: null,
    
    // الفاتورة والطلب الحالي
    cart: {
        id: null,
        order_number: 'طلب جديد',
        status: 'draft',
        kitchen_status: 'pending',
        items: [], // { product_id, name, price, qty, modifiers: [], discount: 0, notes: '' }
        guest_count: 1,
        waiter_id: null,
        customer_id: null,
        discount_amount: 0,
        discount_type: 'fixed', // 'fixed' or 'percentage'
        enable_vat: true,
        enable_service: true
    },
    
    // المدفوعات المتعددة
    payments: [] // { method: 'cash'|'card'|'instapay'|'wallet'|'on_account', amount: 0 }
};

// تهيئة موديول الكاشير عند تسجيل الدخول
async function initPOSModule() {
    if (!currentUser || !currentUser.branch_id) return;
    
    // ضبط الخيارات الأولية للضريبة والخدمة
    posState.cart.enable_vat = taxSettings.enable_vat;
    posState.cart.enable_service = taxSettings.enable_service;
    
    await loadPOSMasterData();
    renderPOSTerminal();
}

// جلب جميع البيانات المرجعية من الداتا بيز للفرع والبراند الحالي
async function loadPOSMasterData() {
    const branchId = currentUser.branch_id;
    const brandId = currentUser.brand_id;

    try {
        // 1. الموظفين (الويترز) والعملاء
        const { data: waitersData } = await _supabase.from('staff').select('*').eq('branch_id', branchId);
        posState.waiters = waitersData || [];

        const { data: customersData } = await _supabase.from('customers').select('*');
        posState.customers = customersData || [];

        // 2. المنيو والأقسام
        const { data: categoriesData } = await _supabase.from('categories').select('*');
        posState.categories = categoriesData || [];

        const { data: productsData } = await _supabase.from('products').select('*');
        posState.products = productsData || [];

        // 3. أسباب الإلغاء والخصومات المتاحة
        const { data: reasonsData } = await _supabase.from('cancel_reasons').select('*');
        posState.cancelReasons = reasonsData || [];

        const { data: discountsData } = await _supabase.from('discounts').select('*');
        posState.discounts = discountsData || [];

        // 4. المناطق والطاولات
        if (currentBranch && currentBranch.has_tables) {
            const { data: areasData } = await _supabase.from('areas').select('*').eq('branch_id', branchId);
            posState.areas = areasData || [];
            if (posState.areas.length > 0) {
                posState.selectedAreaId = posState.areas[0].id;
                await fetchBranchTables();
            }
        }
    } catch (err) {
        console.error('Error loading master data:', err);
        showToast('خطأ في تحميل بيانات الكاشير', 'error');
    }
}

async function fetchBranchTables() {
    if (!posState.selectedAreaId) return;
    const { data: tablesData } = await _supabase.from('tables').select('*').eq('area_id', posState.selectedAreaId);
    posState.tables = tablesData || [];
}

// رسم واجهة الكاشير التفاعلية
function renderPOSTerminal() {
    renderAreaAndTables();
    renderCategoriesPills();
    renderProductsGrid();
    renderWaitersAndCustomersDropdowns();
    renderOrderCartTicket();
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
        areaSelect.innerHTML = posState.areas.map(a => 
            `<option value="${a.id}" ${a.id === posState.selectedAreaId ? 'selected' : ''}>${a.name}</option>`
        ).join('');
    }

    const grid = document.getElementById('tables-grid');
    if (!grid) return;

    grid.innerHTML = posState.tables.map(t => {
        let statusColor = "bg-emerald-50 border-emerald-300 text-emerald-800";
        let statusName = "متاحة";

        if (t.status === 'occupied') { statusColor = "bg-rose-50 border-rose-300 text-rose-800"; statusName = "مشغولة"; }
        else if (t.status === 'reserved') { statusColor = "bg-amber-50 border-amber-300 text-amber-800"; statusName = "محجوزة"; }
        else if (t.status === 'cleaning') { statusColor = "bg-sky-50 border-sky-300 text-sky-800"; statusName = "قيد التنظيف"; }
        else if (t.status === 'out_of_service') { statusColor = "bg-slate-100 border-slate-300 text-slate-500"; statusName = "خارج الخدمة"; }

        const isSelected = posState.selectedTable && posState.selectedTable.id === t.id ? "ring-4 ring-blue-600" : "";

        return `
            <div onclick="selectPosTable('${t.id}')" class="p-3 rounded-2xl border-2 ${statusColor} ${isSelected} cursor-pointer transition flex flex-col justify-between h-24">
                <div class="flex justify-between items-center">
                    <span class="font-extrabold text-sm">${t.table_number}</span>
                    <span class="text-[10px] font-bold px-1.5 py-0.5 rounded bg-white/60">${statusName}</span>
                </div>
                <div class="text-[10px] font-bold text-slate-500">سعة: ${t.capacity} ضيوف</div>
            </div>
        `;
    }).join('');
}

async function selectPosTable(tableId) {
    posState.selectedTable = posState.tables.find(t => t.id === tableId);
    renderAreaAndTables();

    // فحص ما إذا كان يوجد أوردر مفتوح حاليا على الطاولة
    const { data: openOrders } = await _supabase
        .from('orders')
        .select('*, order_items(*, products(name), order_item_modifiers(*))')
        .eq('table_id', tableId)
        .not('status', 'in', '("closed","cancelled")');

    if (openOrders && openOrders.length > 0) {
        const ord = openOrders[0];
        posState.cart = {
            id: ord.id,
            order_number: ord.order_number,
            status: ord.status,
            kitchen_status: ord.kitchen_status,
            items: ord.order_items.map(i => ({
                product_id: i.product_id,
                name: i.products ? i.products.name : 'صنف',
                price: parseFloat(i.unit_price),
                qty: i.quantity,
                modifiers: i.order_item_modifiers || [],
                discount: parseFloat(i.discount_amount) || 0
            })),
            guest_count: ord.guest_count,
            waiter_id: ord.waiter_id,
            customer_id: ord.customer_id,
            discount_amount: parseFloat(ord.discount_amount) || 0,
            discount_type: 'fixed',
            enable_vat: taxSettings.enable_vat,
            enable_service: taxSettings.enable_service
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
        posState.categories.map(c => `
            <button onclick="filterPosProducts('${c.id}')" class="px-3 py-1 bg-slate-100 text-slate-700 rounded-xl text-xs font-bold hover:bg-slate-200">${c.name}</button>
        `).join('');
}

function filterPosProducts(catId) {
    posState.activeCategory = catId;
    renderProductsGrid();
}

function renderProductsGrid() {
    const grid = document.getElementById('products-grid');
    if (!grid) return;

    let filtered = posState.products;
    if (posState.activeCategory) {
        filtered = filtered.filter(p => p.category_id === posState.activeCategory);
    }

    grid.innerHTML = filtered.map(p => `
        <div onclick="checkAndAddProduct('${p.id}')" class="p-4 border rounded-2xl bg-slate-50 hover:border-blue-500 hover:shadow-md cursor-pointer transition flex flex-col justify-between h-28">
            <h4 class="font-extrabold text-slate-800 text-xs">${p.name}</h4>
            <span class="text-blue-600 font-extrabold text-sm">${formatCurrency(p.price)}</span>
        </div>
    `).join('');
}

// فحص وجود Modifiers للمنتج قبل الإضافة
async function checkAndAddProduct(productId) {
    const product = posState.products.find(p => p.id === productId);
    if (!product) return;

    // جلب مجموعات الإضافات المربوطة بهذا المنتج
    const { data: modGroupLinks } = await _supabase
        .from('product_modifier_groups')
        .select('group_id, modifier_groups(*, modifiers(*))')
        .eq('product_id', productId);

    if (modGroupLinks && modGroupLinks.length > 0) {
        // توجد إضافات -> فتح نافذة خيارات المنتج (Modifiers Modal)
        openModifiersModal(product, modGroupLinks.map(l => l.modifier_groups));
    } else {
        // لا توجد إضافات -> إضافته أوتوماتيكيا للفاتورة
        addItemToCart(product, []);
    }
}

function addItemToCart(product, selectedModifiers = []) {
    let modPrice = selectedModifiers.reduce((s, m) => s + parseFloat(m.price || 0), 0);
    const itemPrice = parseFloat(product.price) + modPrice;

    const existing = posState.cart.items.find(i => 
        i.product_id === product.id && JSON.stringify(i.modifiers) === JSON.stringify(selectedModifiers)
    );

    if (existing) {
        existing.qty++;
    } else {
        posState.cart.items.push({
            product_id: product.id,
            name: product.name,
            price: itemPrice,
            qty: 1,
            modifiers: selectedModifiers,
            discount: 0,
            notes: ''
        });
    }
    renderOrderCartTicket();
}

// حساب المجموع والضرائب والخدمة والخصم بالفاتورة
function calculateCartTotals() {
    let subtotal = 0;
    let itemDiscounts = 0;

    posState.cart.items.forEach(i => {
        let lineTotal = i.price * i.qty;
        subtotal += lineTotal;
        itemDiscounts += (i.discount || 0);
    });

    let discountTotal = itemDiscounts + posState.cart.discount_amount;
    let taxableAmount = Math.max(0, subtotal - discountTotal);

    let vatAmount = posState.cart.enable_vat ? (taxableAmount * taxSettings.vat_percentage) / 100 : 0;
    let serviceAmount = (posState.selectedOrderType === 'dine_in' && posState.cart.enable_service) 
        ? (taxableAmount * taxSettings.service_charge_percentage) / 100 : 0;

    let finalTotal = taxableAmount + vatAmount + serviceAmount;

    return { subtotal, discountTotal, vatAmount, serviceAmount, finalTotal };
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
            const modsText = item.modifiers.map(m => `+ ${m.name}`).join(', ');
            return `
                <div class="bg-slate-50 p-2.5 rounded-xl border border-slate-200 text-xs font-bold space-y-1">
                    <div class="flex justify-between items-center">
                        <span class="text-slate-800">${item.name}</span>
                        <span class="text-blue-600 font-extrabold">${formatCurrency(item.price * item.qty)}</span>
                    </div>
                    ${modsText ? `<p class="text-[10px] text-amber-600 font-bold">${modsText}</p>` : ''}
                    <div class="flex justify-between items-center text-[10px] text-slate-400 pt-1">
                        <span>${item.price} × ${item.qty}</span>
                        <div class="flex gap-1">
                            <button onclick="voidCartItem(${idx})" class="text-red-500 hover:bg-red-50 px-1.5 py-0.5 rounded border border-red-100">مسح/Void</button>
                        </div>
                    </div>
                </div>
            `;
        }).join('');
    }

    // عرض المبالغ المالية
    document.getElementById('summary-subtotal').innerText = formatCurrency(totals.subtotal);
    document.getElementById('summary-tax').innerText = formatCurrency(totals.vatAmount);
    document.getElementById('summary-service').innerText = formatCurrency(totals.serviceAmount);
    document.getElementById('summary-total').innerText = formatCurrency(totals.finalTotal);
}

// مفاتيح التحكم في تفعيل/إلغاء الضريبة والخدمة اختياريا بالفاتورة
function toggleVatTax() {
    posState.cart.enable_vat = !posState.cart.enable_vat;
    renderOrderCartTicket();
    showToast(posState.cart.enable_vat ? 'تم إضافة الضريبة' : 'تم استبعاد الضريبة');
}

function toggleServiceCharge() {
    posState.cart.enable_service = !posState.cart.enable_service;
    renderOrderCartTicket();
    showToast(posState.cart.enable_service ? 'تم إضافة الخدمة' : 'تم استبعاد الخدمة');
}

function voidCartItem(idx) {
    if (posState.cancelReasons.length === 0) {
        posState.cart.items.splice(idx, 1);
        renderOrderCartTicket();
        return;
    }
    // اختيار سبب الإلغاء
    const reasonText = prompt('أدخل سبب مسح الصنف:\n' + posState.cancelReasons.map((r, i) => `${i+1}. ${r.reason}`).join('\n'));
    if (reasonText) {
        posState.cart.items.splice(idx, 1);
        renderOrderCartTicket();
        showToast('تم مسح الصنف وتسجيل السبب');
    }
}

function resetActiveCart() {
    posState.cart = {
        id: null,
        order_number: 'طلب جديد',
        status: 'draft',
        kitchen_status: 'pending',
        items: [],
        guest_count: 1,
        waiter_id: null,
        customer_id: null,
        discount_amount: 0,
        discount_type: 'fixed',
        enable_vat: taxSettings.enable_vat,
        enable_service: taxSettings.enable_service
    };
}

function renderWaitersAndCustomersDropdowns() {
    const wSel = document.getElementById('select-waiter');
    if (wSel) {
        wSel.innerHTML = posState.waiters.map(w => `<option value="${w.id}">${w.name}</option>`).join('');
    }
    const cSel = document.getElementById('select-customer');
    if (cSel) {
        cSel.innerHTML = posState.customers.map(c => `<option value="${c.id}">${c.name}</option>`).join('');
    }
}
