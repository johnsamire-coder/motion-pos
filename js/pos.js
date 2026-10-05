// js/pos.js - موديول الكاشير المتقدم (Sprint 3)

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
    
    // بيانات الصنف الجاري اختيار إضافاته في المودال
    pendingModifierProduct: null,
    selectedModifiers: [],
    
    // الفاتورة والطلب الحالي
    cart: {
        id: null,
        order_number: 'طلب جديد',
        status: 'draft',
        kitchen_status: 'pending',
        items: [], // { db_item_id, product_id, name, price, qty, modifiers: [], discount: 0, notes: '' }
        guest_count: 1,
        waiter_id: null,
        customer_id: null,
        discount_amount: 0,
        discount_type: 'fixed',
        enable_vat: true,
        enable_service: true
    }
};

// تهيئة موديول الكاشير
async function initPOSModule() {
    if (!currentUser || !currentUser.branch_id) return;
    
    posState.cart.enable_vat = taxSettings.enable_vat;
    posState.cart.enable_service = taxSettings.enable_service;
    
    await loadPOSMasterData();
    renderPOSTerminal();
}

// جلب البيانات المرجعية
async function loadPOSMasterData() {
    const branchId = currentUser.branch_id;

    try {
        const { data: waitersData } = await _supabase.from('staff').select('*').eq('branch_id', branchId);
        posState.waiters = waitersData || [];

        const { data: customersData } = await _supabase.from('customers').select('*');
        posState.customers = customersData || [];

        const { data: categoriesData } = await _supabase.from('categories').select('*');
        posState.categories = categoriesData || [];

        const { data: productsData } = await _supabase.from('products').select('*');
        posState.products = productsData || [];

        const { data: reasonsData } = await _supabase.from('cancel_reasons').select('*');
        posState.cancelReasons = reasonsData || [];

        const { data: discountsData } = await _supabase.from('discounts').select('*');
        posState.discounts = discountsData || [];

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
    }
}

async function fetchBranchTables() {
    if (!posState.selectedAreaId) return;
    const { data: tablesData } = await _supabase.from('tables').select('*').eq('area_id', posState.selectedAreaId);
    posState.tables = tablesData || [];
}

// رسم واجهة الكاشير
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

    // جلب أوردر مفتوح على الطاولة إذا وجد
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
            items: ord.order_items.filter(i => i.status !== 'voided').map(i => ({
                db_item_id: i.id,
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

// فحص وجود Modifiers
async function checkAndAddProduct(productId) {
    const product = posState.products.find(p => p.id === productId);
    if (!product) return;

    const { data: modGroupLinks } = await _supabase
        .from('product_modifier_groups')
        .select('group_id, modifier_groups(*, modifiers(*))')
        .eq('product_id', productId);

    if (modGroupLinks && modGroupLinks.length > 0) {
        const groups = modGroupLinks.map(l => l.modifier_groups).filter(g => g !== null);
        if (groups.length > 0) {
            openModifiersModal(product, groups);
            return;
        }
    }

    addItemToCart(product, []);
}

// نافذة اختيار الإضافات Modifiers Modal
function openModifiersModal(product, groups) {
    posState.pendingModifierProduct = product;
    posState.selectedModifiers = [];

    let modal = document.getElementById('modifiers-modal');
    if (!modal) {
        modal = document.createElement('div');
        modal.id = 'modifiers-modal';
        modal.className = 'fixed inset-0 bg-slate-900/60 backdrop-blur-sm z-50 flex items-center justify-center p-4';
        document.body.appendChild(modal);
    }

    const groupsHtml = groups.map(g => `
        <div class="mb-4 text-right">
            <h4 class="font-black text-xs text-slate-800 mb-2 border-b pb-1">${g.name}</h4>
            <div class="grid grid-cols-2 gap-2">
                ${g.modifiers.map(m => `
                    <button onclick="toggleModifierSelection('${m.id}', '${m.name}', ${m.price}, '${m.ingredient_id||''}', ${m.ingredient_quantity||0}, this)" 
                            class="mod-option-btn p-2 border rounded-xl text-xs font-bold bg-slate-50 text-slate-700 flex justify-between items-center hover:border-blue-500">
                        <span>${m.name}</span>
                        <span class="text-blue-600">${m.price > 0 ? '+' + formatCurrency(m.price) : 'مجاني'}</span>
                    </button>
                `).join('')}
            </div>
        </div>
    `).join('');

    modal.innerHTML = `
        <div class="bg-white p-6 rounded-3xl shadow-2xl max-w-md w-full border border-slate-100">
            <h3 class="font-black text-base text-slate-800 mb-1 text-center">إضافات: ${product.name}</h3>
            <p class="text-[11px] text-slate-400 font-bold mb-4 text-center">اختر الإضافات المطلوبة للصنف</p>
            <div class="max-h-[300px] overflow-y-auto mb-4">${groupsHtml}</div>
            <div class="flex gap-2">
                <button onclick="confirmModifiersSelection()" class="flex-1 bg-blue-600 text-white py-3 rounded-xl font-bold text-xs hover:bg-blue-700 shadow">إضافة للفاتورة</button>
                <button onclick="closeModifiersModal()" class="flex-1 bg-slate-100 text-slate-600 py-3 rounded-xl font-bold text-xs hover:bg-slate-200">إلغاء</button>
            </div>
        </div>
    `;

    modal.classList.remove('hidden');
}

function toggleModifierSelection(id, name, price, ingredient_id, ingredient_quantity, btn) {
    const idx = posState.selectedModifiers.findIndex(m => m.id === id);
    if (idx >= 0) {
        posState.selectedModifiers.splice(idx, 1);
        btn.classList.remove('border-blue-600', 'bg-blue-50', 'text-blue-700');
    } else {
        posState.selectedModifiers.push({ id, name, price, ingredient_id, ingredient_quantity });
        btn.classList.add('border-blue-600', 'bg-blue-50', 'text-blue-700');
    }
}

function confirmModifiersSelection() {
    if (posState.pendingModifierProduct) {
        addItemToCart(posState.pendingModifierProduct, [...posState.selectedModifiers]);
    }
    closeModifiersModal();
}

function closeModifiersModal() {
    const modal = document.getElementById('modifiers-modal');
    if (modal) modal.classList.add('hidden');
    posState.pendingModifierProduct = null;
    posState.selectedModifiers = [];
}

function addItemToCart(product, selectedModifiers = []) {
    let modPrice = selectedModifiers.reduce((s, m) => s + parseFloat(m.price || 0), 0);
    const itemPrice = parseFloat(product.price) + modPrice;

    const existing = posState.cart.items.find(i => 
        i.product_id === product.id && JSON.stringify(i.modifiers) === JSON.stringify(selectedModifiers) && !i.db_item_id
    );

    if (existing) {
        existing.qty++;
    } else {
        posState.cart.items.push({
            db_item_id: null,
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

// حساب المجاميع
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
            const modsText = item.modifiers.map(m => `+ ${m.name || m.modifier_name}`).join(', ');
            return `
                <div class="bg-slate-50 p-2.5 rounded-xl border border-slate-200 text-xs font-bold space-y-1">
                    <div class="flex justify-between items-center">
                        <span class="text-slate-800">${item.name}</span>
                        <span class="text-blue-600 font-extrabold">${formatCurrency(item.price * item.qty)}</span>
                    </div>
                    ${modsText ? `<p class="text-[10px] text-amber-600 font-bold">${modsText}</p>` : ''}
                    <div class="flex justify-between items-center text-[10px] text-slate-400 pt-1">
                        <span>${item.price} × ${item.qty}</span>
                        <button onclick="voidCartItem(${idx})" class="text-red-500 hover:bg-red-50 px-1.5 py-0.5 rounded border border-red-100 font-bold">مسح / Void</button>
                    </div>
                </div>
            `;
        }).join('');
    }

    document.getElementById('summary-subtotal').innerText = formatCurrency(totals.subtotal);
    document.getElementById('summary-tax').innerText = formatCurrency(totals.vatAmount);
    document.getElementById('summary-service').innerText = formatCurrency(totals.serviceAmount);
    document.getElementById('summary-total').innerText = formatCurrency(totals.finalTotal);
}

// تطبيق الخصم
function applyDiscountPrompt() {
    const amountStr = prompt('أدخل قيمة الخصم (بالجنيه):', '0');
    if (amountStr) {
        const val = parseFloat(amountStr) || 0;
        posState.cart.discount_amount = val;
        renderOrderCartTicket();
        showToast('تم تطبيق الخصم بنجاح');
    }
}

// إلغاء/Void صنف حقيقي المربوط بالداتا بيز
async function voidCartItem(idx) {
    const item = posState.cart.items[idx];
    if (!item) return;

    // إذا كان الصنف لم يرفع للداتا بيز بعد (Draft)
    if (!item.db_item_id) {
        posState.cart.items.splice(idx, 1);
        renderOrderCartTicket();
        return;
    }

    // إذا كان الصنف محفوظ بالداتا بيز -> تنفيذ Void حقيقي بدالة void_order_item
    let reasonId = posState.cancelReasons.length > 0 ? posState.cancelReasons[0].id : null;
    const reasonPrompt = prompt('أدخل سبب مسح الصنف المكتوب بالمطبخ:\n' + posState.cancelReasons.map((r, i) => `${i+1}. ${r.reason}`).join('\n'));

    if (!reasonPrompt) return;

    // الحصول على المخزن المناسب لإرجاع المكونات
    let warehouseId = 'd0000000-0000-0000-0000-000000000001'; // المخزن التجريبي الرئيسي

    try {
        const { error } = await _supabase.rpc('void_order_item', {
            p_order_item_id: item.db_item_id,
            p_reason_id: reasonId,
            p_user_id: currentUser ? currentUser.id : null,
            p_warehouse_id: warehouseId
        });

        if (error) {
            showToast('خطأ في مسح الصنف: ' + error.message, 'error');
            return;
        }

        posState.cart.items.splice(idx, 1);
        
        // إعادة حساب الفاتورة بالداتا بيز
        const totals = calculateCartTotals();
        await _supabase.rpc('update_order_financials', {
            p_order_id: posState.cart.id,
            p_sub_total: totals.subtotal,
            p_tax_amount: totals.vatAmount,
            p_service_amount: totals.serviceAmount,
            p_discount_amount: totals.discountTotal,
            p_total_amount: totals.finalTotal
        });

        renderOrderCartTicket();
        showToast('تم مسح الصنف وإرجاع المكونات للمخزن وتسجيل الحركة بـ Audit Log');

    } catch (err) {
        console.error('Void error:', err);
    }
}

function toggleVatTax() {
    posState.cart.enable_vat = !posState.cart.enable_vat;
    renderOrderCartTicket();
    showToast(posState.cart.enable_vat ? 'تم تفعيل الضريبة' : 'تم استبعاد الضريبة');
}

function toggleServiceCharge() {
    posState.cart.enable_service = !posState.cart.enable_service;
    renderOrderCartTicket();
    showToast(posState.cart.enable_service ? 'تم تفعيل الخدمة' : 'تم استبعاد الخدمة');
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

// حفظ وإرسال للمطبخ (دعم الإنشاء أو التعديل على طلب قائم)
async function sendOrderToKitchen() {
    if (posState.cart.items.length === 0) {
        showToast('الفاتورة فارغة!', 'error');
        return;
    }

    const branchId = currentUser.branch_id;
    const waiterId = document.getElementById('select-waiter') ? document.getElementById('select-waiter').value : null;
    const customerId = document.getElementById('select-customer') ? document.getElementById('select-customer').value : null;
    const totals = calculateCartTotals();

    let warehouseId = 'd0000000-0000-0000-0000-000000000001';

    try {
        if (!posState.cart.id) {
            // إنشاء أوردر جديد
            const { data: newOrd, error } = await _supabase.from('orders').insert([{
                company_id: currentUser.company_id,
                brand_id: currentUser.brand_id,
                branch_id: branchId,
                area_id: posState.selectedAreaId,
                table_id: posState.selectedTable ? posState.selectedTable.id : null,
                waiter_id: waiterId,
                customer_id: customerId,
                order_type: posState.selectedOrderType,
                guest_count: posState.cart.guest_count,
                sub_total: totals.subtotal,
                tax_amount: totals.vatAmount,
                service_charge_amount: totals.serviceAmount,
                discount_amount: totals.discountTotal,
                total_amount: totals.finalTotal,
                status: 'sent',
                kitchen_status: 'pending'
            }]).select().single();

            if (error) {
                showToast('خطأ في حفظ الطلب: ' + error.message, 'error');
                return;
            }

            posState.cart.id = newOrd.id;
            posState.cart.order_number = newOrd.order_number;
            posState.cart.status = 'sent';

            // إدخال الأصناف والإضافات وخصم المكونات
            for (const item of posState.cart.items) {
                const { data: insertedItem } = await _supabase.from('order_items').insert([{
                    order_id: newOrd.id,
                    product_id: item.product_id,
                    quantity: item.qty,
                    unit_price: item.price,
                    total_price: item.price * item.qty
                }]).select().single();

                if (insertedItem) {
                    item.db_item_id = insertedItem.id;
                    // إدخال الـ Modifiers
                    for (const m of item.modifiers) {
                        await _supabase.from('order_item_modifiers').insert([{
                            order_item_id: insertedItem.id,
                            modifier_id: m.id,
                            modifier_name: m.name,
                            unit_price: m.price
                        }]);

                        // خصم مكون الخامة المربوط بالـ Modifier من المخزن
                        if (m.ingredient_id && m.ingredient_quantity > 0) {
                            await _supabase.rpc('log_waste', {
                                p_warehouse_id: warehouseId,
                                p_ingredient_id: m.ingredient_id,
                                p_quantity: m.ingredient_quantity * item.qty,
                                p_reason: 'إضافة Modifier مبيوع'
                            });
                        }
                    }
                }

                // خصم مكونات الصنف الأساسي بالريسبي
                await _supabase.rpc('deduct_recipe_on_sale', {
                    p_warehouse_id: warehouseId,
                    p_product_id: item.product_id,
                    p_quantity_sold: item.qty
                });
            }

            if (posState.selectedTable) {
                await _supabase.from('tables').update({ status: 'occupied' }).eq('id', posState.selectedTable.id);
                await fetchBranchTables();
                renderAreaAndTables();
            }

        } else {
            // أوردر قائم (تعديل إضافة أصناف)
            await _supabase.rpc('update_order_financials', {
                p_order_id: posState.cart.id,
                p_sub_total: totals.subtotal,
                p_tax_amount: totals.vatAmount,
                p_service_amount: totals.serviceAmount,
                p_discount_amount: totals.discountTotal,
                p_total_amount: totals.finalTotal
            });

            // إضافة الأصناف الجديدة التي لم تحفظ بعد
            for (const item of posState.cart.items) {
                if (!item.db_item_id) {
                    const { data: insertedItem } = await _supabase.from('order_items').insert([{
                        order_id: posState.cart.id,
                        product_id: item.product_id,
                        quantity: item.qty,
                        unit_price: item.price,
                        total_price: item.price * item.qty
                    }]).select().single();

                    if (insertedItem) item.db_item_id = insertedItem.id;

                    await _supabase.rpc('deduct_recipe_on_sale', {
                        p_warehouse_id: warehouseId,
                        p_product_id: item.product_id,
                        p_quantity_sold: item.qty
                    });
                }
            }
        }

        showToast(`🚀 تم إرسال الطلب ${posState.cart.order_number} للمطبخ بنجاح!`);
        renderOrderCartTicket();

    } catch (err) {
        console.error('Checkout error:', err);
    }
}

// دفع وإغلاق الفاتورة
async function payAndCloseOrder() {
    if (posState.cart.items.length === 0) return;

    if (!posState.cart.id) {
        await sendOrderToKitchen();
    }

    const totals = calculateCartTotals();

    // تسجيل العملية في جدول payments
    await _supabase.from('payments').insert([{
        order_id: posState.cart.id,
        payment_method: 'cash',
        amount: totals.finalTotal
    }]);

    // إغلاق الطلب
    await _supabase.from('orders').update({ status: 'closed', kitchen_status: 'ready' }).eq('id', posState.cart.id);

    // إتاحة الطاولة
    if (posState.selectedTable) {
        await _supabase.from('tables').update({ status: 'available' }).eq('id', posState.selectedTable.id);
        await fetchBranchTables();
        renderAreaAndTables();
    }

    showToast(`💳 تم دفع وإغلاق الطلب ${posState.cart.order_number} بنجاح!`);
    resetActiveCart();
    renderOrderCartTicket();
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

function updateGuestCount() {
    const input = document.getElementById('input-guests');
    if (input) posState.cart.guest_count = parseInt(input.value) || 1;
}
