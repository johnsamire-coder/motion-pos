// js/pos.js - موديول الكاشير (طلبات، طاولات، تعدد المدفوعات، الإكراميات، والإضافات)
// كل الفلوس والكميات بتتحسب وبتتسجل على السيرفر. المتصفح بيعرض بس، وبيبعت "عايز إيه" مش "بكام".

let posState = {
    selectedOrderType: 'dine_in',
    selectedAreaId: null,
    selectedTable: null,
    areas: [], tables: [], categories: [], products: [], waiters: [], customers: [], cancelReasons: [], discounts: [],
    activeCategory: undefined, pendingModifierProduct: null, selectedModifiers: [],

    cart: emptyCart(),
    paymentsList: [],
    currentTip: 0,
    tipStaffId: null,

    // حالة تقسيم الفاتورة (Split Bill State)
    splitState: {
        activeTab: 'items', // 'items' | 'amount' | 'guests'
        splits: [],
        activeSplitIndex: 0
    }
};
let paymentSubmissionInProgress = false;
let orderSubmissionInProgress = false;

function emptyCart() {
    return {
        id: null, order_number: 'طلب جديد', status: 'draft', kitchen_status: 'pending',
        items: [], guest_count: 1, waiter_id: null, customer_id: null,
        enable_vat: true, enable_service: true,
        discount_id: null, discount_percent: 0, order_discount_amount: 0, loyalty_percent: 0,
        server_total: 0, paid_amount: 0
    };
}

async function initPOSModule() {
    if (!currentUser) return;
    if (!currentUser.branch_id) {
        showToast('حساب الموظف غير مرتبط بفرع، لذلك لا يمكن فتح الكاشير.', 'error');
        return;
    }
    await loadBranchTaxSettings();
    resetActiveCart();
    await loadPOSMasterData();
    renderPOSTerminal();
    posStartAutoRefresh();
}

// إعدادات الضريبة والخدمة للفرع (للعرض بس، والحساب الحقيقي على السيرفر)
async function loadBranchTaxSettings() {
    try {
        const { data, error } = await _supabase.from('branch_tax_settings').select('*').eq('branch_id', currentUser.branch_id).maybeSingle();
        if (error) throw error;
        if (data) {
            taxSettings.vat_percentage = Number(data.vat_percentage) || 0;
            taxSettings.service_charge_percentage = Number(data.service_charge_percentage) || 0;
            taxSettings.is_vat_inclusive = data.is_vat_inclusive === true;
            taxSettings.is_service_taxable = data.is_service_taxable !== false;
        }
    } catch (err) {
        console.error('Tax settings load error:', err);
    }
}

async function loadPOSMasterData() {
    const branchId = currentUser.branch_id;
    try {
        const [waitersRes, custRes, catRes, prodRes, reasonRes, discRes] = await Promise.all([
            _supabase.rpc('list_branch_staff', { p_token: staffSessionToken }),
            serverRpc('list_customers_secure').then(data => ({ data: (data && data.customers) || [] }), error => ({ error })),
            _supabase.from('categories').select('*').order('sort_order').order('name'),
            _supabase.from('products').select('id, category_id, name, price, is_available, brand_id, name_en, sort_order, show_in_menu').order('sort_order').order('name'),
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
    posState.tables = (data || []).slice().sort((a, b) => String(a.table_number).localeCompare(String(b.table_number), 'ar', { numeric: true }));
}

// الكاشير بيتحدّث لوحده: الطاولات كل ٢٠ ثانية (عشان اللي بيحصل على الأجهزة التانية)، والمنيو والأسعار كل ٣ دقايق
let posAutoTimer = null, posAutoTick = 0;
function posStartAutoRefresh() {
    if (posAutoTimer) return;
    posAutoTimer = setInterval(async () => {
        const view = document.getElementById('view-pos-workspace');
        if (!currentUser || !staffSessionToken || !view || view.classList.contains('hidden') || document.hidden) return;
        posAutoTick++;
        try {
            if (posAutoTick % 9 === 0) { await posRefreshData(); return; }
            if (currentBranch && currentBranch.has_tables && posState.selectedAreaId) { await fetchBranchTables(); renderAreaAndTables(); }
        } catch (e) { /* next time */ }
    }, 20000);
}

async function posRefreshData() {
    if (!currentUser || !currentUser.branch_id) return;
    await loadPOSMasterData();
    renderAreaAndTables(); renderCategoriesPills(); renderProductsGrid(); renderWaitersAndCustomersDropdowns(); renderOrderCartTicket();
}

async function renderTablesForArea() {
    const areaSelect = document.getElementById('area-select');
    if (!areaSelect) return;
    if (hasUnsentItems()) {
        areaSelect.value = String(posState.selectedAreaId || '');
        showToast('في أصناف لسه ما اتبعتتش: ابعتها أو امسحها الأول', 'error');
        return;
    }

    posState.selectedAreaId = areaSelect.value || null;
    posState.selectedTable = null;
    posState.tables = [];
    resetActiveCart();
    if (posState.selectedAreaId) await fetchBranchTables();
    renderAreaAndTables();
    renderOrderCartTicket();
}

function renderPOSTerminal() {
    renderAreaAndTables(); renderCategoriesPills(); renderProductsGrid(); renderWaitersAndCustomersDropdowns(); renderOrderCartTicket();
    refreshTypeButtons();
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
        return `<button onclick="selectPosTable('${t.id}')" class="text-right px-2 py-1.5 rounded-xl border-2 ${statusColor} ${isSelected} transition flex flex-col justify-between gap-0.5 min-h-[3.4rem] min-w-0">
            <span class="font-black text-sm leading-tight truncate w-full">${uiEsc(t.table_number)}</span>
            <span class="flex justify-between items-center w-full gap-1"><span class="text-[10px] font-bold">${statusName}</span><span class="text-[10px] font-bold text-slate-500">👥${uiEsc(t.capacity)}</span></span>
        </button>`;
    }).join('');
}

function hasUnsentItems() {
    return posState.cart.items.some(i => !i.db_item_id);
}

function refreshTypeButtons() {
    document.querySelectorAll('.type-btn').forEach(button => {
        button.className = "type-btn px-4 py-2 rounded-xl text-xs font-bold bg-slate-100 text-slate-600 hover:bg-slate-200";
    });
    const activeTypeButton = document.getElementById('type-' + posState.selectedOrderType);
    if (activeTypeButton) activeTypeButton.className = "type-btn px-4 py-2 rounded-xl text-xs font-bold bg-blue-600 text-white shadow";
    // أنواع الطلبات المقفولة من الإعدادات بتستخبى
    const enabled = (typeof appSet === 'function') ? appSet('pos', 'order_types', null) : null;
    if (Array.isArray(enabled)) {
        ['dine_in', 'takeaway', 'delivery', 'pickup'].forEach(t => {
            const b = document.getElementById('type-' + t);
            if (b) b.classList.toggle('hidden', !enabled.includes(t) && t !== posState.selectedOrderType);
        });
    }
}

// طباعة الحساب قبل الدفع (الويتر والكاشير)
async function printCurrentBill() {
    if (posState.cart.items.length === 0) return showToast('الفاتورة فارغة!', 'error');
    if (!posState.cart.id || hasUnsentItems()) {
        if (!(await sendOrderToKitchen())) return;
    }
    if (typeof printOrderReceipt === 'function') printOrderReceipt(posState.cart.id);
}

// تحميل طلب محفوظ من السيرفر للفاتورة اللي على الشاشة
async function loadOrderIntoCart(orderId, keepUnsent = false) {
    const res = await serverRpc('get_order_secure', { p_order_id: orderId });
    if (!res || !res.ok) throw new Error(serverReasonMessage(res, 'تعذر تحميل الطلب'));
    const ord = res.order;
    const unsent = keepUnsent ? posState.cart.items.filter(i => !i.db_item_id) : [];
    posState.selectedOrderType = ord.order_type || 'dine_in';
    posState.cart = {
        id: ord.id, order_number: ord.order_number, status: ord.status, kitchen_status: ord.kitchen_status,
        items: (ord.items || []).map(i => ({
            db_item_id: i.id, product_id: i.product_id, name: i.name || 'صنف',
            price: Number(i.unit_price) || 0, qty: Number(i.quantity) || 0,
            modifiers: i.modifiers || [], discount: Number(i.discount_amount) || 0, notes: i.item_notes || ''
        })).concat(unsent),
        guest_count: ord.guest_count || 1, waiter_id: ord.waiter_id || null, customer_id: ord.customer_id || null,
        enable_vat: ord.vat_enabled !== false, enable_service: ord.service_enabled !== false,
        discount_id: ord.discount_id || null,
        discount_percent: Number(ord.discount_percent) || 0,
        order_discount_amount: Number(ord.order_discount_amount) || 0,
        loyalty_percent: Number(ord.loyalty_percent) || 0,
        server_total: Number(ord.total_amount) || 0,
        paid_amount: Number(ord.paid_amount) || 0
    };
    if (ord.table_id) {
        posState.selectedTable = posState.tables.find(t => t.id === ord.table_id)
            || { id: ord.table_id, table_number: ord.table_number || '---', status: 'occupied', capacity: '-' };
    } else {
        posState.selectedTable = null;
    }
    return ord;
}

async function selectPosTable(tableId) {
    // الانتقال بين الطاولات مسموح، طول ما مفيش أصناف جديدة لسه ما اتبعتتش للمطبخ.
    if (hasUnsentItems() && posState.selectedTable?.id !== tableId) {
        return showToast('في أصناف جديدة لسه ما اتبعتتش للمطبخ: ابعتها أو امسحها الأول قبل الانتقال لطاولة تانية', 'error');
    }

    const previousTable = posState.selectedTable;
    const nextTable = posState.tables.find(t => t.id === tableId);
    if (!nextTable) return showToast('الطاولة المحددة غير موجودة في المنطقة الحالية', 'error');
    posState.selectedTable = nextTable;
    renderAreaAndTables();

    try {
        const res = await serverRpc('list_open_orders_secure', { p_table_id: tableId });
        const orders = (res && res.orders) || [];
        if (orders.length === 0) {
            resetActiveCart();
            posState.selectedOrderType = 'dine_in';
            posState.selectedTable = nextTable;
        } else {
            let chosen = orders[0];
            if (orders.length > 1) {
                const pick = await uiForm('الطاولة دي عليها أكتر من طلب', [{ key: 'id', label: 'الطلب', type: 'select', required: true,
                    options: orders.map(o => [o.id, `${o.order_number} - ${formatCurrency(o.total_amount)}`]), value: orders[0].id }], { ok: 'فتح' });
                if (!pick) {
                    posState.selectedTable = previousTable;
                    renderAreaAndTables();
                    return;
                }
                chosen = orders.find(o => o.id === pick.id) || orders[0];
            }
            await loadOrderIntoCart(chosen.id, false);
            posState.selectedTable = nextTable;
        }
    } catch (err) {
        console.error('Load table order error:', err);
        posState.selectedTable = previousTable;
        renderAreaAndTables();
        return showToast('تعذر تحميل الطلب المرتبط بالطاولة: ' + (err.message || 'خطأ غير معروف'), 'error');
    }
    refreshTypeButtons();
    renderAreaAndTables();
    renderOrderCartTicket();
}

// الأقسام: الزرار المختار بيبان أزرق. المنيو الكبير: أول قسم بيتفتح لوحده، والبحث بيدوّر في كل الأصناف.
function renderCategoriesPills() {
    const container = document.getElementById('category-pills');
    if (!container) return;
    const cats = posState.categories.filter(c => posState.products.some(p => p.category_id === c.id && p.is_available !== false));
    if (posState.activeCategory === undefined || (posState.activeCategory && !cats.some(c => c.id === posState.activeCategory))) {
        posState.activeCategory = posState.products.length > 40 && cats.length ? cats[0].id : null;
    }
    const pill = (id, label) => `<button onclick="filterPosProducts(${id ? `'${id}'` : 'null'})" class="shrink-0 whitespace-nowrap px-3 py-1.5 rounded-xl text-xs font-black ${posState.activeCategory === id ? 'bg-blue-600 text-white shadow' : 'bg-slate-100 text-slate-700 hover:bg-slate-200'}">${uiEsc(label)}</button>`;
    container.innerHTML = pill(null, 'الكل') + cats.map(c => pill(c.id, c.name)).join('');
}

function filterPosProducts(catId) {
    posState.activeCategory = catId;
    posState.productSearch = '';
    const s = document.getElementById('pos-product-search');
    if (s) s.value = '';
    renderCategoriesPills();
    renderProductsGrid();
}

function posSearchProducts(v) { posState.productSearch = String(v || '').trim(); renderProductsGrid(); }

function renderProductsGrid() {
    const grid = document.getElementById('products-grid');
    if (!grid) return;
    let filtered = posState.products.filter(product => product.is_available !== false);
    const q = posState.productSearch || '';
    if (q) filtered = filtered.filter(p => String(p.name).includes(q));
    else if (posState.activeCategory) filtered = filtered.filter(p => p.category_id === posState.activeCategory);
    else {
        // "الكل": بترتيب الأقسام زي المنيو
        const order = Object.fromEntries(posState.categories.map((c, i) => [c.id, i]));
        filtered = filtered.slice().sort((a, b) => (order[a.category_id] ?? 999) - (order[b.category_id] ?? 999));
    }
    grid.innerHTML = filtered.length ? filtered.map(p => `
        <button onclick="checkAndAddProduct('${p.id}')" class="text-right px-2.5 py-2 border rounded-xl bg-slate-50 hover:border-blue-500 hover:bg-blue-50 active:scale-95 transition flex flex-col justify-between gap-1 min-h-[58px] min-w-0">
            <span class="font-extrabold text-slate-800 text-[11px] leading-snug line-clamp-2 break-words">${uiEsc(p.name)}</span><span class="text-blue-600 font-black text-[11px]">${formatCurrency(p.price)}</span>
        </button>`).join('') : `<p class="col-span-full text-center text-slate-400 font-bold text-xs py-8">${q ? 'مفيش صنف بالاسم ده' : 'مفيش أصناف'}</p>`;
}

async function checkAndAddProduct(productId) {
    const product = posState.products.find(p => p.id === productId);
    if (!product) return;
    const { data: modGroupLinks } = await _supabase.from('product_modifier_groups').select('group_id, modifier_groups(*, modifiers(*))').eq('product_id', productId);
    const groups = (modGroupLinks || []).map(l => l.modifier_groups).filter(g => g && (g.modifiers || []).length > 0);
    if (groups.length > 0) { openModifiersModal(product, groups); return; }
    addItemToCart(product, []);
}

// شباك الإضافات: كل مجموعة بقواعدها (لازم / اختياري / أكتر عدد)، وتحتها الملاحظات الجاهزة وخانة ملاحظة
function posModRule(g) {
    const min = Math.max(Number(g.min_selection) || 0, g.is_required ? 1 : 0);
    const max = Number(g.max_selection) || 1;
    return { min, max, text: min > 0 ? (min === max ? `لازم تختار ${min}` : `لازم تختار من ${min} لـ ${max}`) : (max === 1 ? 'اختياري (واحدة)' : `اختياري (لحد ${max})`) };
}

function openModifiersModal(product, groups) {
    posState.pendingModifierProduct = product;
    posState.selectedModifiers = [];
    posState.modGroups = groups.map(g => ({ ...g, modifiers: [...(g.modifiers || [])].sort((x, y) => String(x.created_at || '').localeCompare(String(y.created_at || ''))) }));
    let modal = document.getElementById('modifiers-modal');
    if (!modal) {
        modal = document.createElement('div'); modal.id = 'modifiers-modal';
        modal.className = 'fixed inset-0 bg-slate-900/60 backdrop-blur-sm z-50 flex items-center justify-center p-4';
        document.body.appendChild(modal);
    }
    const groupsHtml = posState.modGroups.map((g, gi) => `
        <div class="mb-4 text-right">
            <h4 class="font-black text-xs text-slate-800 mb-2 border-b pb-1 flex justify-between"><span>${uiEsc(g.name)}</span><span class="text-[10px] ${posModRule(g).min > 0 ? 'text-red-600' : 'text-slate-400'}">${uiEsc(posModRule(g).text)}</span></h4>
            <div class="grid grid-cols-2 gap-2">
                ${g.modifiers.map((m, mi) => `<button id="pos-mod-${gi}-${mi}" onclick="toggleModifierSelection(${gi}, ${mi})" class="mod-option-btn p-2 border rounded-xl text-xs font-bold bg-slate-50 text-slate-700 flex justify-between items-center hover:border-blue-500"><span>${uiEsc(m.name)}</span><span class="text-blue-600">${Number(m.price) > 0 ? '+' + formatCurrency(m.price) : 'مجاني'}</span></button>`).join('')}
            </div>
        </div>`).join('');
    modal.innerHTML = `<div class="bg-white p-6 rounded-3xl shadow-2xl max-w-md w-full border border-slate-100" dir="rtl">
        <h3 class="font-black text-base text-slate-800 mb-1 text-center">${uiEsc(product.name)}</h3>
        <div class="max-h-[340px] overflow-y-auto mb-3">${groupsHtml}${posNotesHtml('pos-mod-note', '')}</div>
        <div class="flex gap-2"><button onclick="confirmModifiersSelection()" class="flex-1 bg-blue-600 text-white py-3 rounded-xl font-bold text-xs hover:bg-blue-700 shadow">إضافة</button><button onclick="closeModifiersModal()" class="flex-1 bg-slate-100 text-slate-600 py-3 rounded-xl font-bold text-xs hover:bg-slate-200">إلغاء</button></div></div>`;
    modal.classList.remove('hidden');
}

function toggleModifierSelection(gi, mi) {
    const g = posState.modGroups[gi];
    const m = g && g.modifiers[mi];
    if (!m) return;
    const rule = posModRule(g);
    const idx = posState.selectedModifiers.findIndex(x => x.id === m.id);
    if (idx >= 0) {
        posState.selectedModifiers.splice(idx, 1);
    } else {
        const inGroup = posState.selectedModifiers.filter(x => x.group_id === g.id);
        if (inGroup.length >= rule.max) {
            if (rule.max === 1) posState.selectedModifiers = posState.selectedModifiers.filter(x => x.group_id !== g.id);
            else return showToast(`أكتر عدد في "${g.name}" هو ${rule.max}`, 'error');
        }
        posState.selectedModifiers.push({ id: m.id, name: m.name, price: Number(m.price) || 0, group_id: g.id });
    }
    posState.modGroups.forEach((gg, a) => gg.modifiers.forEach((mm, b) => {
        const btn = document.getElementById(`pos-mod-${a}-${b}`);
        const on = posState.selectedModifiers.some(x => x.id === mm.id);
        if (btn) btn.classList.toggle('border-blue-600', on), btn.classList.toggle('bg-blue-50', on), btn.classList.toggle('text-blue-700', on);
    }));
}

function confirmModifiersSelection() {
    for (const g of (posState.modGroups || [])) {
        const rule = posModRule(g);
        const n = posState.selectedModifiers.filter(x => x.group_id === g.id).length;
        if (n < rule.min) return showToast(`"${g.name}": ${rule.text}`, 'error');
    }
    const note = (document.getElementById('pos-mod-note')?.value || '').trim();
    // نفس ترتيب المجموعات عشان الصنف المتكرر يتجمّع صح
    const order = [];
    (posState.modGroups || []).forEach(g => g.modifiers.forEach(m => order.push(m.id)));
    const mods = [...posState.selectedModifiers].sort((x, y) => order.indexOf(x.id) - order.indexOf(y.id))
        .map(m => ({ id: m.id, name: m.name, price: m.price }));
    if (posState.pendingModifierProduct) addItemToCart(posState.pendingModifierProduct, mods, note);
    closeModifiersModal();
}
function closeModifiersModal() { const modal = document.getElementById('modifiers-modal'); if (modal) modal.classList.add('hidden'); posState.pendingModifierProduct = null; posState.selectedModifiers = []; posState.modGroups = []; }

// الملاحظات الجاهزة (من الإعدادات) + خانة ملاحظة حرة
function posNotesHtml(inputId, value) {
    const quick = (typeof appSet === 'function' ? appSet('pos', 'quick_notes', []) : []) || [];
    return `<div class="text-right border-t pt-3">
        <p class="text-[11px] font-black text-slate-600 mb-1.5">📝 ملاحظة للمطبخ / البار</p>
        <div class="flex flex-wrap gap-1.5 mb-2">${quick.map((q, i) => `<button type="button" onclick="posToggleQuickNote('${inputId}', ${i})" class="px-2 py-1 rounded-lg border text-[11px] font-bold bg-amber-50 border-amber-200 text-amber-800 hover:bg-amber-100">${uiEsc(q)}</button>`).join('')}</div>
        <input id="${inputId}" value="${uiEsc(value || '')}" maxlength="200" placeholder="اكتب أي ملاحظة (مثلاً: الصوص لوحده)" class="w-full bg-slate-50 border p-2 rounded-xl text-xs font-bold">
    </div>`;
}

function posToggleQuickNote(inputId, i) {
    const quick = appSet('pos', 'quick_notes', []) || [];
    const q = quick[i];
    const input = document.getElementById(inputId);
    if (!q || !input) return;
    const parts = input.value.split('،').map(x => x.trim()).filter(Boolean);
    const at = parts.indexOf(q);
    if (at >= 0) parts.splice(at, 1); else parts.push(q);
    input.value = parts.join('، ');
}

function editCartItemNote(idx) {
    const item = posState.cart.items[idx];
    if (!item || item.db_item_id) return;
    let modal = document.getElementById('pos-note-modal');
    if (!modal) {
        modal = document.createElement('div'); modal.id = 'pos-note-modal';
        modal.className = 'fixed inset-0 bg-slate-900/60 z-50 flex items-center justify-center p-4';
        document.body.appendChild(modal);
    }
    modal.innerHTML = `<div class="bg-white p-5 rounded-3xl shadow-2xl max-w-md w-full" dir="rtl">
        <h3 class="font-black text-sm text-slate-800 mb-2">${uiEsc(item.name)} ×${uiEsc(item.qty)}</h3>
        ${posNotesHtml('pos-item-note', item.notes)}
        <div class="flex gap-2 mt-3"><button onclick="saveCartItemNote(${idx})" class="flex-1 bg-blue-600 text-white py-2.5 rounded-xl font-bold text-xs">حفظ</button>
        <button onclick="document.getElementById('pos-note-modal').remove()" class="flex-1 bg-slate-100 text-slate-600 py-2.5 rounded-xl font-bold text-xs">إلغاء</button></div></div>`;
    setTimeout(() => document.getElementById('pos-item-note')?.focus(), 50);
}

function saveCartItemNote(idx) {
    const item = posState.cart.items[idx];
    const v = (document.getElementById('pos-item-note')?.value || '').trim();
    if (item && !item.db_item_id) item.notes = v.slice(0, 200);
    document.getElementById('pos-note-modal')?.remove();
    renderOrderCartTicket();
}

function addItemToCart(product, selectedModifiers = [], notes = '') {
    let modPrice = selectedModifiers.reduce((s, m) => s + parseFloat(m.price || 0), 0);
    const itemPrice = parseFloat(product.price) + modPrice;
    const existing = posState.cart.items.find(i => i.product_id === product.id && !i.db_item_id
        && JSON.stringify((i.modifiers || []).map(m => m.id)) === JSON.stringify(selectedModifiers.map(m => m.id)) && (i.notes || '') === (notes || ''));
    if (existing) { existing.qty++; } else { posState.cart.items.push({ db_item_id: null, product_id: product.id, name: product.name, price: itemPrice, qty: 1, modifiers: selectedModifiers, discount: 0, notes: notes || '' }); }
    renderOrderCartTicket();
}

// ---------------------------------------------------------------- رسالة شكر على الواتساب بعد الدفع (ضغطة واحدة)
async function posAskThanks(c) {
    let msg = waFill(appSet('whatsapp', 'thanks_message', ''), c.name);
    if (msg && appSet('social', 'links_in_thanks', true)) {
        const extra = [];
        if (appSet('social', 'facebook_url', '')) extra.push('📘 فيسبوك: ' + appSet('social', 'facebook_url', ''));
        if (appSet('social', 'instagram_url', '')) extra.push('📸 إنستجرام: ' + appSet('social', 'instagram_url', ''));
        if (appSet('social', 'feedback_enabled', true) && typeof appLinks !== 'undefined' && appLinks.feedback) extra.push('💬 رأيك أو شكوتك أو اقتراحك يهمنا: ' + appLinks.feedback);
        if (extra.length) msg += '\n\n' + extra.join('\n');
    }
    if (!msg) return;
    if (!(await uiConfirm(`تبعت رسالة شكر على الواتساب لـ ${c.name}؟\n\n${msg}`, 'ابعت 💬'))) return;
    waOpen(c.phone, msg);
}

// ---------------------------------------------------------------- العميل بالموبايل
function posSetCustomer(c) {
    if (!c) return;
    if (!posState.customers.some(x => x.id === c.id)) {
        posState.customers.push({ id: c.id, name: c.name, phone: c.phone, customer_type: c.customer_type, balance: 0 });
        posState.customers.sort((a, b) => String(a.name).localeCompare(String(b.name), 'ar'));
        renderWaitersAndCustomersDropdowns();
    }
    posState.cart.customer_id = c.id;
    const sel = document.getElementById('select-customer');
    if (sel) sel.value = c.id;
    posState.lastCustomerInfo = c;
    renderPosCustomerInfo();
    posSaveCustomerOnOrder();
}

// لو الطلب متسجّل، العميل بيتحفظ عليه على طول (عشان خصم الانتماء يتحسب ويبان)
async function posSaveCustomerOnOrder() {
    if (!posState.cart.id) return;
    try {
        const res = await serverRpc('update_order_info_secure', {
            p_order_id: posState.cart.id, p_waiter_id: document.getElementById('select-waiter')?.value || null,
            p_customer_id: posState.cart.customer_id || null, p_guest_count: parseInt(posState.cart.guest_count, 10) || 1 });
        if (res && res.ok) { await loadOrderIntoCart(posState.cart.id, true); renderOrderCartTicket(); }
    } catch (err) { console.warn('customer save', err); }
}

function posClearCustomer() {
    posState.cart.customer_id = null;
    const sel = document.getElementById('select-customer');
    if (sel) sel.value = '';
    const input = document.getElementById('pos-cust-phone');
    if (input) input.value = '';
    renderPosCustomerInfo();
    posSaveCustomerOnOrder();
}

function renderPosCustomerInfo() {
    const box = document.getElementById('pos-cust-info');
    if (!box) return;
    const id = posState.cart.customer_id;
    if (!id) { box.innerHTML = ''; return; }
    const c = posState.customers.find(x => x.id === id) || {};
    const extra = posState.lastCustomerInfo && posState.lastCustomerInfo.id === id ? posState.lastCustomerInfo : null;
    box.innerHTML = `👤 <span class="text-slate-800">${uiEsc(c.name || '')}</span> ${c.phone ? '| ' + uiEsc(c.phone) : ''}`
        + (extra && extra.orders_count !== undefined ? ` | ${uiEsc(extra.orders_count)} طلب قبل كده` : '')
        + (extra && extra.notes ? `<div class="text-amber-700">📝 ${uiEsc(extra.notes)}</div>` : '')
        + (extra && Number(extra.loyalty_percent) > 0 ? `<div class="text-emerald-700 font-black">⭐ عميل انتماء: خصم ${uiEsc(extra.loyalty_percent)}% بيتطبّق لوحده</div>` : '');
}

async function posFindCustomer() {
    const input = document.getElementById('pos-cust-phone');
    const phone = (input?.value || '').trim();
    if (!phone) return showToast('اكتب موبايل العميل', 'error');
    let res;
    try { res = await serverRpc('customer_lookup_secure', { p_phone: phone }); }
    catch (err) { return showToast(err.message || 'تعذر البحث', 'error'); }
    if (!res || res.ok === false) return showToast(serverReasonMessage(res, 'تعذر البحث'), 'error');
    if (res.found) { posSetCustomer(res.customer); showToast(`العميل: ${res.customer.name}`); return; }
    const f = await uiForm('عميل جديد', [{ type: 'note', label: `الرقم ${res.phone} مش متسجّل.` }, { key: 'name', label: 'اسم العميل', required: true }], { ok: 'تسجيل' });
    if (!f) return;
    let add;
    try { add = await serverRpc('customer_quick_add_secure', { p_name: f.name, p_phone: phone }); }
    catch (err) { return showToast(err.message || 'تعذر الحفظ', 'error'); }
    if (add && add.ok === false && add.reason === 'phone_taken' && add.customer) { posSetCustomer(add.customer); return; }
    if (!add || add.ok === false) return showToast(serverReasonMessage(add, 'تعذر الحفظ'), 'error');
    posSetCustomer({ ...add.customer, orders_count: 0 });
    showToast('تم تسجيل العميل');
}

// نفس طريقة حساب السيرفر بالظبط، للعرض بس. الرقم اللي بيتدفع بيتجاب من السيرفر.
function calculateCartTotals() {
    const cart = posState.cart;
    let subtotal = 0;
    let itemDiscounts = 0;
    cart.items.forEach(i => { subtotal += (i.price * i.qty); itemDiscounts += (Number(i.discount) || 0); });
    subtotal = round2(subtotal);
    const orderDiscount = cart.discount_percent > 0
        ? round2(Math.max(0, subtotal - itemDiscounts) * Math.min(cart.discount_percent, 100) / 100)
        : Math.max(0, Number(cart.order_discount_amount) || 0);
    const loyalty = round2(Math.max(0, subtotal - itemDiscounts - orderDiscount) * Math.min(Number(cart.loyalty_percent) || 0, 100) / 100);
    const discountTotal = Math.min(subtotal, itemDiscounts + orderDiscount + loyalty);
    const net = subtotal - discountTotal;
    const r = (Number(taxSettings.vat_percentage) || 0) / 100;
    const base = taxSettings.is_vat_inclusive ? round2(net / (1 + r)) : net;
    const serviceAmount = (posState.selectedOrderType === 'dine_in' && cart.enable_service)
        ? round2(base * (Number(taxSettings.service_charge_percentage) || 0) / 100) : 0;
    const vatAmount = cart.enable_vat
        ? round2((taxSettings.is_vat_inclusive ? net - base : base * r) + (taxSettings.is_service_taxable !== false ? serviceAmount * r : 0))
        : 0;
    return { subtotal, discountTotal, loyalty, vatAmount, serviceAmount, finalTotal: round2(base + serviceAmount + vatAmount) };
}

function renderOrderCartTicket() {
    const totals = calculateCartTotals();
    const orderNumElem = document.getElementById('ticket-order-number');
    const statusBadgeElem = document.getElementById('ticket-status-badge');
    const tableInfoElem = document.getElementById('ticket-table-info');

    if (orderNumElem) orderNumElem.innerText = posState.cart.order_number;
    if (statusBadgeElem) {
        const discountText = posState.cart.discount_percent > 0 ? ` | خصم ${posState.cart.discount_percent}%`
            : (posState.cart.order_discount_amount > 0 ? ` | خصم ${formatCurrency(posState.cart.order_discount_amount)}` : '');
        const loyaltyText = posState.cart.loyalty_percent > 0 ? ` | ⭐ ${appSet('loyalty', 'label', 'خصم انتماء')} ${posState.cart.loyalty_percent}% (${formatCurrency(totals.loyalty)})` : '';
        statusBadgeElem.innerText = `حالة: ${posState.cart.status}${discountText}${loyaltyText}`;
    }
    if (tableInfoElem) tableInfoElem.innerText = `الطاولة: ${posState.selectedTable ? posState.selectedTable.table_number : '---'}`;
    const typeInfoElem = document.getElementById('ticket-type-info');
    if (typeInfoElem) typeInfoElem.innerText = `النوع: ${posState.selectedOrderType}`;
    const waiterSelect = document.getElementById('select-waiter');
    if (waiterSelect) waiterSelect.value = posState.cart.waiter_id || '';
    const customerSelect = document.getElementById('select-customer');
    if (customerSelect) customerSelect.value = posState.cart.customer_id || '';
    renderPosCustomerInfo();
    const guestInput = document.getElementById('input-guests');
    if (guestInput) guestInput.value = posState.cart.guest_count || 1;

    const itemsContainer = document.getElementById('cart-items-list');
    if (!itemsContainer) return;

    if (posState.cart.items.length === 0) {
        itemsContainer.innerHTML = `<p class="text-slate-400 text-center py-8 text-xs font-bold">الفاتورة فارغة</p>`;
    } else {
        itemsContainer.innerHTML = posState.cart.items.map((item, idx) => {
            const modsText = (item.modifiers || []).map(m => `+ ${m.name || m.modifier_name}`).join(', ');
            const sentBadge = item.db_item_id ? '' : '<span class="text-[9px] text-amber-600 font-bold">(لسه ما اتبعتش)</span>';
            return `<div class="bg-slate-50 p-2.5 rounded-xl border border-slate-200 text-xs font-bold space-y-1">
                <div class="flex justify-between items-center"><span class="text-slate-800">${item.name} ${sentBadge}</span><span class="text-blue-600 font-extrabold">${formatCurrency(item.price * item.qty)}</span></div>
                ${modsText ? `<p class="text-[10px] text-amber-600 font-bold">${uiEsc(modsText)}</p>` : ''}
                ${item.notes ? `<p class="text-[10px] text-red-600 font-bold">📝 ${uiEsc(item.notes)}</p>` : ''}
                <div class="flex justify-between items-center text-[10px] text-slate-400 pt-1"><span>${item.price} × ${item.qty}</span><span class="flex gap-1">${item.db_item_id ? '' : `<button onclick="editCartItemNote(${idx})" class="text-amber-700 hover:bg-amber-50 px-1.5 py-0.5 rounded border border-amber-200 font-bold">📝 ملاحظة</button>`}<button onclick="voidCartItem(${idx})" class="text-red-500 hover:bg-red-50 px-1.5 py-0.5 rounded border border-red-100 font-bold">مسح / Void</button></span></div>
            </div>`;
        }).join('');
    }
    document.getElementById('summary-subtotal').innerText = formatCurrency(totals.subtotal);
    const discRow = document.getElementById('summary-discount-row');
    if (discRow) {
        discRow.classList.toggle('hidden', !(totals.discountTotal > 0));
        document.getElementById('summary-discount').innerText = '-' + formatCurrency(totals.discountTotal);
        document.getElementById('summary-discount-label').innerText = totals.loyalty > 0
            ? `الخصم (فيه ⭐ ${appSet('loyalty', 'label', 'خصم انتماء')} ${posState.cart.loyalty_percent}%):` : 'الخصم:';
    }
    document.getElementById('summary-tax').innerText = formatCurrency(totals.vatAmount) + (posState.cart.enable_vat ? '' : ' (متشالة)');
    document.getElementById('summary-service').innerText = formatCurrency(totals.serviceAmount) + (posState.cart.enable_service ? '' : ' (متشالة)');
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

// اختيار سبب إلغاء من القايمة
// سبب الإلغاء + رقم المدير في شاشة واحدة
async function pickCancelReason(title, type, pinLabel) {
    if (!posState.cancelReasons.length) {
        showToast('لا توجد أسباب إلغاء مسجلة. أضف أسباب الإلغاء أولاً من الإعدادات.', 'error');
        return null;
    }
    let list = posState.cancelReasons.filter(r => !type || !r.reason_type || r.reason_type === type);
    if (!list.length) list = posState.cancelReasons;
    const fields = [{ key: 'reason', label: 'السبب', type: 'select', options: list.map(r => [r.id, r.reason]), placeholder: 'اختار السبب', required: true }];
    if (pinLabel) fields.push({ key: 'pin', label: pinLabel, type: 'pin', required: true });
    const v = await uiForm(title, fields, { ok: 'تأكيد', danger: true });
    if (!v) return null;
    const reason = list.find(r => String(r.id) === String(v.reason));
    return reason ? { ...reason, pin: v.pin } : null;
}

async function voidCartItem(idx) {
    const item = posState.cart.items[idx];
    if (!item) return;
    // صنف لسه ما اتبعتش للمطبخ: بيتشال من الشاشة عادي
    if (!item.db_item_id) { posState.cart.items.splice(idx, 1); renderOrderCartTicket(); return; }

    // مسح صنف اتبعت للمطبخ لازم موافقة المدير، والسيرفر هو اللي بيتأكد من رقمه
    const reason = await pickCancelReason(`مسح "${item.name}" (اتبعت للمطبخ)`, 'void_item', 'رقم المدير');
    if (!reason) return;
    const managerPin = reason.pin;

    try {
        const res = await serverRpc('void_order_item_secure', {
            p_order_item_id: item.db_item_id, p_reason_id: reason.id, p_manager_pin: String(managerPin).trim()
        });
        if (!res || !res.ok) return showToast(serverReasonMessage(res, 'تعذر مسح الصنف'), 'error');

        await loadOrderIntoCart(posState.cart.id, true);
        renderOrderCartTicket();
        showToast('تم مسح الصنف بموافقة المدير');
    } catch (err) { console.error(err); showToast('حدث خطأ أثناء الاتصال بالسيرفر: ' + (err.message || ''), 'error'); }
}

// شيل أو رجوع الضريبة والخدمة: الشيل بموافقة المدير على السيرفر
async function changeOrderCharges(vatOn, serviceOn, label) {
    if (!posState.cart.id) return showToast(`ابعت الطلب للمطبخ الأول، وبعدين غيّر ${label}`, 'error');
    const turningOff = (posState.cart.enable_vat && !vatOn) || (posState.cart.enable_service && !serviceOn);
    let pin = null;
    if (turningOff) {
        pin = await askManagerPin(`شيل ${label} من الطلب محتاج موافقة المدير. أدخل رقم المدير:`);
        if (!pin) return;
    }
    try {
        const res = await serverRpc('set_order_charges_secure', {
            p_order_id: posState.cart.id, p_vat_enabled: vatOn, p_service_enabled: serviceOn,
            p_manager_pin: pin ? String(pin).trim() : null
        });
        if (!res || !res.ok) return showToast(serverReasonMessage(res, 'تعذر التعديل'), 'error');
        await loadOrderIntoCart(posState.cart.id, true);
        renderOrderCartTicket();
        showToast(turningOff ? `تم شيل ${label} بموافقة المدير` : `تم رجوع ${label}`);
    } catch (err) { console.error(err); showToast('حدث خطأ أثناء الاتصال بالسيرفر: ' + (err.message || ''), 'error'); }
}
function toggleVatTax() { changeOrderCharges(!posState.cart.enable_vat, posState.cart.enable_service, 'الضريبة'); }
function toggleServiceCharge() { changeOrderCharges(posState.cart.enable_vat, !posState.cart.enable_service, 'الخدمة'); }

function resetActiveCart() {
    posState.cart = emptyCart();
    posState.paymentsList = []; posState.currentTip = 0; posState.tipStaffId = null;
    posState.splitState = { activeTab: 'items', splits: [], activeSplitIndex: 0 };
}
function renderWaitersAndCustomersDropdowns() {
    populateSelectOptions('select-waiter', posState.waiters, 'اختر الويتر', 'لا يوجد موظفون لهذا الفرع');
    populateSelectOptions('select-customer', posState.customers, 'اختر العميل', 'لا يوجد عملاء مسجلون');
}
function setOrderType(type) {
    if (posState.cart.id) {
        return showToast('نوع الطلب مينفعش يتغيّر بعد ما الطلب يتبعت للمطبخ', 'error');
    }
    posState.selectedOrderType = type;
    refreshTypeButtons();
    const typeInfo = document.getElementById('ticket-type-info');
    if (typeInfo) typeInfo.innerText = `النوع: ${(typeof PRINT_TYPE_NAMES !== 'undefined' && PRINT_TYPE_NAMES[type]) || type}`;
    renderAreaAndTables();
    renderOrderCartTicket();
}
function updateGuestCount() { const input = document.getElementById('input-guests'); if (input) posState.cart.guest_count = parseInt(input.value) || 1; }

// إرسال الأصناف الجديدة للمطبخ: السعر بيتجاب من السيرفر، والمتصفح بيبعت الصنف والكمية والإضافات بس
async function sendOrderToKitchen() {
    if (orderSubmissionInProgress) return false;
    const unsent = posState.cart.items.filter(i => !i.db_item_id);
    if (!posState.cart.id && unsent.length === 0) {
        showToast('الفاتورة فارغة!', 'error');
        return false;
    }
    if (typeof appSet === 'function' && appSet('pos', 'require_waiter', false) && !(document.getElementById('select-waiter')?.value)) {
        showToast('لازم تختار الويتر الأول (من الإعدادات)', 'error');
        return false;
    }
    // طلب الصالة لازم يكون على طاولة (لو الفرع فيه طاولات)، وإلا الكاشير مش هيلاقيه على الطاولة
    if (!posState.cart.id && posState.selectedOrderType === 'dine_in' && currentBranch && currentBranch.has_tables && !posState.selectedTable) {
        showToast('اختار الطاولة الأول من خريطة الصالة، وبعدها ابعت الطلب', 'error');
        return false;
    }
    orderSubmissionInProgress = true;
    const waiterId = document.getElementById('select-waiter')?.value || null;
    const customerId = document.getElementById('select-customer')?.value || null;
    const guestCount = parseInt(posState.cart.guest_count, 10) || 1;

    try {
        if (unsent.length > 0) {
            const isNew = !posState.cart.id;
            const isDineIn = posState.selectedOrderType === 'dine_in';
            const res = await serverRpc('submit_order_items_secure', {
                p_order_id: posState.cart.id || null,
                p_order_type: posState.selectedOrderType,
                p_area_id: isNew && isDineIn && posState.selectedTable ? (posState.selectedAreaId || null) : null,
                p_table_id: isNew && isDineIn && posState.selectedTable ? posState.selectedTable.id : null,
                p_waiter_id: waiterId,
                p_customer_id: customerId,
                p_guest_count: guestCount,
                p_items: unsent.map(i => ({
                    product_id: i.product_id,
                    quantity: i.qty,
                    modifier_ids: (i.modifiers || []).map(m => m.id).filter(Boolean),
                    item_notes: i.notes || null
                }))
            });
            if (!res || !res.ok) {
                showToast(serverReasonMessage(res, 'تعذر إرسال الطلب للمطبخ'), 'error');
                return false;
            }
            const keepTable = posState.selectedTable;
            await loadOrderIntoCart(res.order_id, false);
            if (!posState.selectedTable && keepTable && isNew && isDineIn) posState.selectedTable = keepTable;
        } else {
            const res = await serverRpc('update_order_info_secure', {
                p_order_id: posState.cart.id, p_waiter_id: waiterId, p_customer_id: customerId, p_guest_count: guestCount
            });
            if (!res || !res.ok) {
                showToast(serverReasonMessage(res, 'تعذر حفظ بيانات الطلب'), 'error');
                return false;
            }
            await loadOrderIntoCart(posState.cart.id, false);
        }
        if (currentBranch && currentBranch.has_tables) {
            await fetchBranchTables();
            renderAreaAndTables();
        }
        showToast(unsent.length ? '🚀 تم الإرسال للمطبخ!' : 'تم حفظ بيانات الطلب');
        renderOrderCartTicket();
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
// نظام الدفع المتعدد و Tips و On Account (كله في عملية واحدة على السيرفر)
// -----------------------------------------
async function openMultiplePaymentsModal() {
    if (posState.cart.items.length === 0) return showToast('الفاتورة فارغة!', 'error');
    if (!posState.cart.id || hasUnsentItems()) {
        if (!(await sendOrderToKitchen())) return;
    } else {
        try {
            // العميل والويتر بيتحفظوا الأول، عشان الإجمالي اللي هيتدفع يبقى فيه خصم الانتماء لو العميل يستحقه
            await serverRpc('update_order_info_secure', {
                p_order_id: posState.cart.id, p_waiter_id: document.getElementById('select-waiter')?.value || null,
                p_customer_id: document.getElementById('select-customer')?.value || null, p_guest_count: parseInt(posState.cart.guest_count, 10) || 1 });
            await loadOrderIntoCart(posState.cart.id, false);
        } catch (err) {
            return showToast('تعذر قراءة الطلب من السيرفر: ' + (err.message || ''), 'error');
        }
    }
    renderOrderCartTicket();
    const due = round2(posState.cart.server_total);
    posState.paymentsList = [{ method: 'cash', amount: due }];
    posState.currentTip = 0;
    const tipInput = document.getElementById('input-tip-amount');
    if (tipInput) tipInput.value = '0';

    renderPaymentLines();
    document.getElementById('payments-modal').classList.remove('hidden');
}

function closeMultiplePaymentsModal() { document.getElementById('payments-modal').classList.add('hidden'); }

function renderPaymentLines() {
    const container = document.getElementById('payment-lines-list');
    if (!container) return;
    const paidSum = round2(posState.paymentsList.reduce((s, p) => s + (parseFloat(p.amount) || 0), 0));
    const tip = parseFloat(document.getElementById('input-tip-amount')?.value) || 0;

    const requiredDue = round2(posState.cart.server_total);
    const totalCollected = round2(paidSum + tip);
    const remaining = round2(requiredDue - paidSum);

    const dueEl = document.getElementById('modal-pay-total-due');
    const remainingEl = document.getElementById('modal-pay-remaining');
    const collectedEl = document.getElementById('modal-pay-collected');
    if (dueEl) dueEl.innerText = formatCurrency(requiredDue);
    if (remainingEl) remainingEl.innerText = formatCurrency(remaining);
    if (collectedEl) collectedEl.innerText = formatCurrency(totalCollected);

    const enabledMethods = (typeof appSet === 'function') ? appSet('pos', 'payment_methods', null) : null;
    const methods = [['cash', 'نقدي (Cash)'], ['card', 'بطاقة (Card)'], ['instapay', 'إنستاباي'], ['wallet', 'محفظة'], ['on_account', 'على الحساب (آجل)']]
        .filter(([value]) => !Array.isArray(enabledMethods) || enabledMethods.includes(value) || posState.paymentsList.some(p => p.method === value));
    container.innerHTML = posState.paymentsList.map((p, idx) => `
        <div class="flex gap-2 items-center bg-slate-50 p-2 rounded-xl border border-slate-200 mb-2">
            <select onchange="updatePaymentMethod(${idx}, this.value)" class="bg-white border text-xs font-bold p-2 rounded-lg flex-1">
                ${methods.map(([value, label]) => `<option value="${value}" ${p.method === value ? 'selected' : ''}>${label}</option>`).join('')}
            </select>
            <input type="number" min="0" step="0.01" value="${p.amount}" onchange="updatePaymentAmount(${idx}, this.value)" class="w-28 bg-white border p-2 rounded-lg text-xs font-bold text-center">
            <button onclick="removePaymentLine(${idx})" class="text-red-500 font-bold px-2">✕</button>
        </div>
    `).join('');
}

function updatePaymentMethod(idx, val) { posState.paymentsList[idx].method = val; renderPaymentLines(); }
function updatePaymentAmount(idx, val) {
    const amount = Number(val);
    posState.paymentsList[idx].amount = Number.isFinite(amount) && amount >= 0 ? round2(amount) : 0;
    renderPaymentLines();
}
function addPaymentLine() {
    const paidSum = posState.paymentsList.reduce((s, p) => s + (parseFloat(p.amount) || 0), 0);
    posState.paymentsList.push({ method: 'card', amount: Math.max(0, round2(posState.cart.server_total - paidSum)) });
    renderPaymentLines();
}
function removePaymentLine(idx) { posState.paymentsList.splice(idx, 1); renderPaymentLines(); }

async function confirmMultiplePaymentsAndClose() {
    if (paymentSubmissionInProgress) return;
    if (!posState.cart.id) return showToast('الطلب لسه ما اتحفظش', 'error');
    const due = round2(posState.cart.server_total);
    const tipValue = Number(document.getElementById('input-tip-amount')?.value ?? 0);
    const tip = Number.isFinite(tipValue) && tipValue >= 0 ? round2(tipValue) : NaN;

    if (posState.paymentsList.some(p => !Number.isFinite(Number(p.amount)) || Number(p.amount) < 0) || !Number.isFinite(tip)) {
        return showToast('أدخل مبالغ مدفوعات وإكرامية صحيحة (صفر أو أكثر)', 'error');
    }
    const payments = posState.paymentsList
        .filter(p => Number(p.amount) > 0)
        .map(p => ({ method: p.method, amount: round2(p.amount) }));
    const paidSum = round2(payments.reduce((s, p) => s + p.amount, 0));
    if (Math.abs(paidSum - due) > 0.004) {
        return showToast(`مجموع الدفعات (${formatCurrency(paidSum)}) لازم يساوي إجمالي الفاتورة (${formatCurrency(due)})`, 'error');
    }
    if (payments.some(p => p.method === 'on_account') && !(document.getElementById('select-customer')?.value)) {
        return showToast('الدفع الآجل محتاج تختار العميل الأول', 'error');
    }

    paymentSubmissionInProgress = true;
    const confirmButton = document.getElementById('confirm-payments-button');
    if (confirmButton) confirmButton.disabled = true;
    try {
        // حفظ الويتر والعميل وعدد الضيوف على الطلب قبل القفل (الآجل بيتسجل على العميل المحفوظ)
        const info = await serverRpc('update_order_info_secure', {
            p_order_id: posState.cart.id,
            p_waiter_id: document.getElementById('select-waiter')?.value || null,
            p_customer_id: document.getElementById('select-customer')?.value || null,
            p_guest_count: parseInt(posState.cart.guest_count, 10) || 1
        });
        if (!info || !info.ok) return showToast(serverReasonMessage(info, 'تعذر حفظ بيانات الطلب'), 'error');

        const res = await serverRpc('close_order_secure', {
            p_order_id: posState.cart.id,
            p_payments: payments,
            p_tip_amount: tip,
            p_tip_staff_id: null
        });
        if (!res || !res.ok) {
            let message = serverReasonMessage(res, 'تعذر إغلاق الطلب');
            if (res && res.reason === 'payment_mismatch') message += ` (المطلوب ${formatCurrency(res.due)})`;
            if (res && res.reason === 'credit_limit_exceeded') message += ` (الرصيد ${formatCurrency(res.balance)} والحد ${formatCurrency(res.limit)})`;
            return showToast(message, 'error');
        }

        const closedOrderId = posState.cart.id;
        const paidCustomerId = document.getElementById('select-customer')?.value || null;
        const paidCustomer = paidCustomerId ? (posState.customers.find(x => x.id === paidCustomerId) || null) : null;
        closeMultiplePaymentsModal();
        resetActiveCart();
        posState.selectedTable = null;
        if (typeof printOrderReceipt === 'function' && appSet('receipt', 'auto_print_after_pay', false)) printOrderReceipt(closedOrderId);
        if (currentBranch && currentBranch.has_tables) await fetchBranchTables();
        renderAreaAndTables();
        renderOrderCartTicket();
        showToast(`💳 تم الدفع وإغلاق الطلب ${res.order_number || ''} بنجاح!`);
        if (paidCustomer && paidCustomer.phone && appSet('whatsapp', 'thanks_enabled', true)) posAskThanks(paidCustomer);
    } catch (err) {
        console.error('Payment completion error:', err);
        showToast('لم تكتمل عملية الدفع، ومفيش أي حاجة اتسجلت: ' + (err.message || 'خطأ غير معروف'), 'error');
    } finally {
        paymentSubmissionInProgress = false;
        if (confirmButton) confirmButton.disabled = false;
    }
}

// -----------------------------------------
// تقسيم الفاتورة: بالأصناف بيعمل طلب جديد على السيرفر، والمبلغ والضيوف معاينة بس (الدفع بأكتر من طريقة متاح في شاشة الدفع)
// -----------------------------------------
function openSplitBillModal() {
    if (!posState.cart.id) return showToast('ابعت الطلب للمطبخ الأول قبل التقسيم', 'error');
    if (hasUnsentItems()) return showToast('في أصناف لسه ما اتبعتتش: ابعتها الأول', 'error');
    if (posState.cart.items.length === 0) return;

    const totals = calculateCartTotals();
    posState.splitState.activeTab = 'items';
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
    const totals = calculateCartTotals();
    if (type === 'items') {
        posState.splitState.splits = [
            { split_number: 1, items: JSON.parse(JSON.stringify(posState.cart.items)), amount_due: totals.finalTotal, status: 'pending', payments: [] },
            { split_number: 2, items: [], amount_due: 0, status: 'pending', payments: [] }
        ];
    } else if (type === 'guests') {
        const guestCount = posState.cart.guest_count || 2;
        const perGuestAmount = totals.finalTotal / guestCount;
        posState.splitState.splits = [];
        for (let i = 1; i <= guestCount; i++) {
            posState.splitState.splits.push({ split_number: i, items: [], amount_due: perGuestAmount, status: 'pending', payments: [] });
        }
    } else if (type === 'amount') {
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

// الخصم: من جدول الخصومات، أو مبلغ يدوي بموافقة المدير. الحساب على السيرفر.
async function applyDiscountPrompt() {
    if (!posState.cart.id) return showToast('ابعت الطلب للمطبخ الأول، وبعدين طبّق الخصم', 'error');
    const list = posState.discounts || [];
    const opts = [['none', 'من غير خصم (إلغاء الخصم)']]
        .concat(list.map(d => [d.id, `${d.name} (${d.discount_type === 'percentage' ? d.value + '%' : formatCurrency(d.value)})${d.requires_approval !== false ? ' - بموافقة المدير' : ''}`]))
        .concat([['manual', 'خصم يدوي بمبلغ - بموافقة المدير']]);
    const needs = x => x.d === 'manual' || (list.find(d => d.id === x.d) || {}).requires_approval !== false && x.d !== 'none';
    const v = await uiForm('الخصم', [
        { key: 'd', label: 'الخصم', type: 'select', options: opts, required: true, placeholder: 'اختار' },
        { key: 'amount', label: 'مبلغ الخصم اليدوي (لو اخترت يدوي)', type: 'money', min: 0 },
        { key: 'pin', label: 'رقم المدير (لو الخصم محتاج موافقة)', type: 'pin' }], { ok: 'تطبيق', validate: x => {
            if (x.d === 'manual' && !(x.amount > 0)) return { key: 'amount', msg: 'اكتب مبلغ الخصم' };
            if (needs(x) && !x.pin) return { key: 'pin', msg: 'الخصم ده محتاج رقم المدير' };
            return null;
        } });
    if (!v) return;
    const n = v.d === 'none' ? 0 : 1;
    const discountId = v.d !== 'none' && v.d !== 'manual' ? v.d : null;
    const manualAmount = v.d === 'manual' ? round2(v.amount) : null;
    const pin = needs(v) ? v.pin : null;
    try {
        const res = await serverRpc('apply_order_discount_secure', {
            p_order_id: posState.cart.id, p_discount_id: discountId, p_manual_amount: manualAmount,
            p_manager_pin: pin ? String(pin).trim() : null
        });
        if (!res || !res.ok) return showToast(serverReasonMessage(res, 'تعذر تطبيق الخصم'), 'error');
        await loadOrderIntoCart(posState.cart.id, true);
        renderOrderCartTicket();
        showToast(n === 0 ? 'تم إلغاء الخصم' : 'تم تطبيق الخصم');
    } catch (err) { console.error(err); showToast('حدث خطأ أثناء الاتصال بالسيرفر: ' + (err.message || ''), 'error'); }
}

function openTransferTableModal() {
    if (!posState.cart.id) return showToast('أرسل الطلب للمطبخ قبل نقله إلى طاولة أخرى', 'error');
    if (!posState.selectedTable) return showToast('اختر الطاولة الحالية أولًا', 'error');

    const availableTables = posState.tables.filter(table => table.id !== posState.selectedTable.id && table.status === 'available');
    if (availableTables.length === 0) return showToast('لا توجد طاولات متاحة للنقل في المنطقة دي', 'error');

    uiForm('نقل الطلب لطاولة تانية', [{ key: 't', label: 'الطاولة الفاضية', type: 'select', required: true, placeholder: 'اختار الطاولة',
        options: availableTables.map(t => [t.id, 'طاولة ' + t.table_number]) }], { ok: 'نقل' }).then(v => { if (v) executeTransferTable(v.t); });
}

async function executeTransferTable(newTableId) {
    try {
        const res = await serverRpc('transfer_table_order_secure', {
            p_order_id: posState.cart.id,
            p_new_table_id: newTableId
        });
        if (!res || !res.ok) return showToast(serverReasonMessage(res, 'تعذر نقل الطلب'), 'error');

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
                            <button onclick="moveItemToSplit(${idx}, 1)" class="bg-blue-50 text-blue-600 px-2 py-0.5 rounded-lg border hover:bg-blue-100">نقل للطلب الجديد ⬅️</button>
                        </div>
                    `).join('')}
                </div>
            </div>
            <div class="bg-blue-50/50 p-3 rounded-2xl border border-blue-200">
                <h4 class="font-black text-xs text-blue-800 mb-2 border-b border-blue-200 pb-1">الطلب الجديد (فاتورة منفصلة)</h4>
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
        <button onclick="executeSplitByItems()" class="w-full mt-3 bg-blue-600 text-white py-2.5 rounded-xl font-black text-xs shadow hover:bg-blue-700">تنفيذ التقسيم (فاتورة منفصلة) ✂️</button>
    `;
}

function moveItemToSplit(itemIdx, targetSplitIdx) {
    const origItem = posState.splitState.splits[0].items[itemIdx];
    if (!origItem) return;

    if (origItem.qty > 1) {
        origItem.qty--;
        const splitItem = posState.splitState.splits[targetSplitIdx].items.find(i => i.db_item_id === origItem.db_item_id);
        if (splitItem) splitItem.qty++;
        else posState.splitState.splits[targetSplitIdx].items.push({ ...origItem, qty: 1 });
    } else {
        const [moved] = posState.splitState.splits[0].items.splice(itemIdx, 1);
        const splitItem = posState.splitState.splits[targetSplitIdx].items.find(i => i.db_item_id === moved.db_item_id);
        if (splitItem) splitItem.qty += moved.qty;
        else posState.splitState.splits[targetSplitIdx].items.push(moved);
    }
    recalculateSplitAmounts();
    renderSplitModal();
}

function moveItemBackToOriginal(itemIdx) {
    const splitItem = posState.splitState.splits[1].items[itemIdx];
    if (!splitItem) return;

    if (splitItem.qty > 1) {
        splitItem.qty--;
        const origItem = posState.splitState.splits[0].items.find(i => i.db_item_id === splitItem.db_item_id);
        if (origItem) origItem.qty++;
        else posState.splitState.splits[0].items.push({ ...splitItem, qty: 1 });
    } else {
        const [moved] = posState.splitState.splits[1].items.splice(itemIdx, 1);
        const origItem = posState.splitState.splits[0].items.find(i => i.db_item_id === moved.db_item_id);
        if (origItem) origItem.qty += moved.qty;
        else posState.splitState.splits[0].items.push(moved);
    }
    recalculateSplitAmounts();
    renderSplitModal();
}

async function executeSplitByItems() {
    const moved = posState.splitState.splits[1]?.items || [];
    if (moved.length === 0) return showToast('انقل صنف واحد على الأقل للطلب الجديد', 'error');
    try {
        const res = await serverRpc('split_order_items_secure', {
            p_order_id: posState.cart.id,
            p_items: moved.map(i => ({ order_item_id: i.db_item_id, quantity: i.qty }))
        });
        if (!res || !res.ok) return showToast(serverReasonMessage(res, 'تعذر تقسيم الطلب'), 'error');
        closeSplitModal();
        await loadOrderIntoCart(posState.cart.id, false);
        renderOrderCartTicket();
        showToast(`اتعمل طلب جديد رقم ${res.new_order_number} بالأصناف المنقولة. افتحه من "طلبات مفتوحة" أو من الطاولة.`);
    } catch (err) { console.error(err); showToast('حدث خطأ أثناء الاتصال بالسيرفر: ' + (err.message || ''), 'error'); }
}

function recalculateSplitAmounts() {
    const r = (Number(taxSettings.vat_percentage) || 0) / 100;
    posState.splitState.splits.forEach(s => {
        const sub = s.items.reduce((sum, i) => sum + (i.price * i.qty), 0);
        const srv = (posState.selectedOrderType === 'dine_in' && posState.cart.enable_service) ? sub * (Number(taxSettings.service_charge_percentage) || 0) / 100 : 0;
        const tax = posState.cart.enable_vat ? (sub + (taxSettings.is_service_taxable !== false ? srv : 0)) * r : 0;
        s.amount_due = round2(sub + srv + tax);
    });
}

function renderSplitByAmount(container) {
    container.innerHTML = `
        <div class="space-y-2">
            <p class="text-xs font-bold text-slate-500 mb-2">معاينة بس: الدفع بأكتر من طريقة أو على أكتر من شخص بيتعمل من شاشة "دفع وإغلاق".</p>
            ${posState.splitState.splits.map((s, idx) => `
                <div class="flex justify-between items-center bg-slate-50 p-2 rounded-xl border text-xs font-bold">
                    <span>جزء #${s.split_number}</span>
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
            <p class="text-xs font-bold text-slate-500 mb-2">معاينة: تقسيم متساوي على ${posState.cart.guest_count} ضيوف. الدفع نفسه من شاشة "دفع وإغلاق".</p>
            ${posState.splitState.splits.map(s => `
                <div class="flex justify-between items-center bg-slate-50 p-2 rounded-xl border text-xs font-bold">
                    <span>ضيف #${s.split_number}</span>
                    <span class="text-blue-600 font-black">${formatCurrency(s.amount_due)}</span>
                </div>
            `).join('')}
        </div>
    `;
}

// -----------------------------------------
// طلب جديد، الطلبات المفتوحة، الدمج، إلغاء الطلب، المرتجع
// -----------------------------------------
async function startNewOrder() {
    if (hasUnsentItems() && !(await uiConfirm('في أصناف لسه ما اتبعتتش للمطبخ. تمسحها وتبدأ طلب جديد؟', 'امسح وابدأ جديد', true))) return;
    resetActiveCart();
    posState.selectedTable = null;
    refreshTypeButtons();
    renderAreaAndTables();
    renderOrderCartTicket();
}

async function chooseOpenOrder(title, excludeId) {
    const res = await serverRpc('list_open_orders_secure', { p_table_id: null });
    const orders = ((res && res.orders) || []).filter(o => o.id !== excludeId);
    if (orders.length === 0) {
        showToast('مفيش طلبات مفتوحة', 'error');
        return null;
    }
    const typeNames = { dine_in: 'صالة', takeaway: 'تيك أواي', delivery: 'توصيل', pickup: 'استلام' };
    const v = await uiForm(title, [{ key: 'id', label: 'الطلب', type: 'select', required: true, placeholder: 'اختار الطلب',
        options: orders.map(o => [o.id, `${o.order_number} - ${typeNames[o.order_type] || o.order_type}${o.table_number ? ' - طاولة ' + o.table_number : ''} - ${formatCurrency(o.total_amount)}`]) }], { ok: 'اختيار' });
    if (!v) return null;
    return orders.find(o => o.id === v.id) || null;
}

async function openOpenOrdersList() {
    if (hasUnsentItems()) return showToast('في أصناف لسه ما اتبعتتش: ابعتها أو امسحها الأول', 'error');
    try {
        const chosen = await chooseOpenOrder('افتح طلب مفتوح', null);
        if (!chosen) return;
        await loadOrderIntoCart(chosen.id, false);
        refreshTypeButtons();
        renderAreaAndTables();
        renderOrderCartTicket();
    } catch (err) { console.error(err); showToast('تعذر فتح الطلب: ' + (err.message || ''), 'error'); }
}

async function mergeOrderPrompt() {
    if (!posState.cart.id) return showToast('افتح الطلب اللي هيتجمع فيه الأول', 'error');
    if (hasUnsentItems()) return showToast('في أصناف لسه ما اتبعتتش: ابعتها الأول', 'error');
    try {
        const chosen = await chooseOpenOrder(`الطلب اللي هيتنقل بأصنافه جوه ${posState.cart.order_number}`, posState.cart.id);
        if (!chosen) return;
        if (!(await uiConfirm(`كل أصناف ${chosen.order_number} هتتنقل لـ ${posState.cart.order_number}، والطلب ${chosen.order_number} هيتقفل. موافق؟`, 'دمج'))) return;
        const res = await serverRpc('merge_orders_secure', { p_source_order_id: chosen.id, p_target_order_id: posState.cart.id });
        if (!res || !res.ok) return showToast(serverReasonMessage(res, 'تعذر دمج الطلبات'), 'error');
        await loadOrderIntoCart(posState.cart.id, false);
        if (currentBranch && currentBranch.has_tables) await fetchBranchTables();
        renderAreaAndTables();
        renderOrderCartTicket();
        showToast('تم دمج الطلبين');
    } catch (err) { console.error(err); showToast('تعذر دمج الطلبات: ' + (err.message || ''), 'error'); }
}

async function cancelOrderPrompt() {
    if (!posState.cart.id) {
        if (posState.cart.items.length === 0) return showToast('مفيش طلب مفتوح', 'error');
        if (!(await uiConfirm('الطلب لسه ما اتبعتش. تمسحه من الشاشة؟', 'مسح', true))) return;
        resetActiveCart();
        posState.selectedTable = null;
        refreshTypeButtons();
        renderAreaAndTables();
        renderOrderCartTicket();
        return;
    }
    const reason = await pickCancelReason(`إلغاء الطلب ${posState.cart.order_number} بالكامل`, 'cancel_order', 'رقم المدير');
    if (!reason) return;
    const managerPin = reason.pin;
    try {
        const res = await serverRpc('cancel_order_secure', {
            p_order_id: posState.cart.id, p_reason_id: reason.id, p_manager_pin: String(managerPin).trim()
        });
        if (!res || !res.ok) return showToast(serverReasonMessage(res, 'تعذر إلغاء الطلب'), 'error');
        resetActiveCart();
        posState.selectedTable = null;
        if (currentBranch && currentBranch.has_tables) await fetchBranchTables();
        renderAreaAndTables();
        renderOrderCartTicket();
        showToast('تم إلغاء الطلب بموافقة المدير');
    } catch (err) { console.error(err); showToast('تعذر إلغاء الطلب: ' + (err.message || ''), 'error'); }
}

async function refundOrderPrompt() {
    let list = posState.cancelReasons.filter(r => !r.reason_type || r.reason_type === 'return');
    if (!list.length) list = posState.cancelReasons;
    if (!list.length) return showToast('لا توجد أسباب مرتجع مسجلة. أضفها من الإعدادات.', 'error');
    const v = await uiForm('مرتجع كامل لطلب مدفوع', [
        { type: 'note', label: 'الفلوس هترجع للزبون، والقيد هيتعكس.' },
        { key: 'num', label: 'رقم الطلب (زي 1005)', required: true },
        { key: 'reason', label: 'السبب', type: 'select', options: list.map(r => [r.id, r.reason]), placeholder: 'اختار السبب', required: true },
        { key: 'pin', label: 'رقم المدير', type: 'pin', required: true }], { ok: 'مرتجع', danger: true });
    if (!v) return;
    const normalized = v.num.startsWith('#') ? v.num : '#' + v.num;
    const reason = { id: v.reason };
    const managerPin = v.pin;
    try {
        const res = await serverRpc('refund_order_secure', {
            p_order_number: normalized, p_reason_id: reason.id, p_manager_pin: String(managerPin).trim()
        });
        if (!res || !res.ok) return showToast(serverReasonMessage(res, 'تعذر عمل المرتجع'), 'error');
        showToast(`تم مرتجع الطلب ${res.order_number} بمبلغ ${formatCurrency(res.total)}. رجّع الفلوس للزبون.`);
    } catch (err) { console.error(err); showToast('تعذر عمل المرتجع: ' + (err.message || ''), 'error'); }
}
