// js/settings.js - لوحة الإعدادات والتحكم الشاملة - Motion POS

let settingsState = {
    branches: [],
    warehouses: [],
    areas: [],
    tables: [],
    categories: [],
    products: []
};

// كل تعديل في الإعدادات بيتعمل على السيرفر بتذكرة الوردية، ومسموح للمدير والمالك بس، وبيتسجل مين عمل إيه
async function settingsAction(action, data) {
    try {
        const res = await serverRpc('settings_action_secure', { p_action: action, p_data: data });
        if (!res || !res.ok) {
            showToast(serverReasonMessage(res, 'تعذر الحفظ'), 'error');
            return false;
        }
        if (typeof motionDataChanged === 'function') motionDataChanged();
        return true;
    } catch (err) {
        console.error('Settings action error:', err);
        showToast('تعذر الحفظ: ' + (err.message || 'خطأ غير معروف'), 'error');
        return false;
    }
}

async function initSettingsModule() {
    await loadSettingsData();
    renderTaxSettings();
    renderBranchesSettings();
    renderWarehousesSettings();
    renderTablesSettings();
    renderMenuSettings();
}

function switchSettingsSection(section) {
    document.querySelectorAll('.set-section').forEach(el => el.classList.add('hidden'));
    const targetEl = document.getElementById('set-section-' + section);
    if (targetEl) targetEl.classList.remove('hidden');

    document.querySelectorAll('.set-nav-btn').forEach(btn => {
        btn.className = "set-nav-btn w-full text-right px-4 py-3 rounded-xl text-xs font-black bg-slate-50 text-slate-600 border border-slate-100 hover:bg-slate-100 transition mb-2";
    });
    
    const activeBtn = document.getElementById('btn-set-' + section);
    if (activeBtn) {
        activeBtn.className = "set-nav-btn w-full text-right px-4 py-3 rounded-xl text-xs font-black bg-blue-50 text-blue-700 border border-blue-200 transition mb-2 shadow-sm";
    }
}

async function loadSettingsData() {
    try {
        const { data: bData } = await _supabase.from('branches').select('*, branch_tax_settings(*)');
        settingsState.branches = bData || [];

        const { data: wData } = await _supabase.from('warehouses').select('*, branches(name)');
        settingsState.warehouses = wData || [];

        const { data: aData } = await _supabase.from('areas').select('*, tables(*)');
        settingsState.areas = aData || [];

        const { data: cData } = await _supabase.from('categories').select('*');
        settingsState.categories = cData || [];

        const { data: pData } = await _supabase.from('products').select('id, category_id, name, price, is_available, brand_id, name_en, sort_order, show_in_menu, categories(name)');
        settingsState.products = pData || [];
    } catch (err) {
        console.error('Error loading settings data:', err);
    }
}

// -----------------------------------------
// 1. إدارة المنيو والأصناف (Menu Builder)
// -----------------------------------------
function renderMenuSettings() {
    const categoriesContainer = document.getElementById('settings-categories-list');
    const productsContainer = document.getElementById('settings-products-table-body');

    if (categoriesContainer) {
        categoriesContainer.innerHTML = settingsState.categories.map(c => `
            <span class="bg-slate-100 text-slate-800 border px-3 py-1.5 rounded-xl font-black text-xs inline-flex items-center gap-2">
                ${c.name}
            </span>
        `).join('');
    }

    if (productsContainer) {
        if (settingsState.products.length === 0) {
            productsContainer.innerHTML = `<tr><td colspan="5" class="text-center p-4 text-slate-400 font-bold">لا يوجد أصناف في المنيو حتى الآن</td></tr>`;
            return;
        }

        productsContainer.innerHTML = settingsState.products.map(p => `
            <tr class="border-b border-slate-100 text-xs font-bold hover:bg-slate-50">
                <td class="p-3 text-slate-800 font-black">${p.name}</td>
                <td class="p-3 text-blue-600">${p.categories ? p.categories.name : 'بدون قسم'}</td>
                <td class="p-3 font-extrabold">${formatCurrency(p.price)}</td>
                <td class="p-3">
                    <span class="px-2 py-0.5 rounded-lg text-[10px] font-extrabold ${p.is_available !== false ? 'bg-emerald-100 text-emerald-700' : 'bg-red-100 text-red-600'}">
                        ${p.is_available !== false ? 'متاح للبيع ✅' : 'غير متاح ❌'}
                    </span>
                </td>
                <td class="p-3 flex gap-2 justify-end">
                    <button onclick="editProductPrice('${p.id}', ${p.price})" class="bg-blue-50 text-blue-600 border border-blue-200 px-2.5 py-1 rounded-lg hover:bg-blue-100">تعديل السعر ✏️</button>
                    <button onclick="toggleProductAvailability('${p.id}', ${p.is_available !== false})" class="bg-slate-100 text-slate-700 border px-2.5 py-1 rounded-lg hover:bg-slate-200">
                        ${p.is_available !== false ? 'إيقاف 🚫' : 'تفعيل ⚡'}
                    </button>
                </td>
            </tr>
        `).join('');
    }
}

async function addNewCategoryPrompt() {
    const v = await uiForm('قسم جديد', [{ key: 'name', label: 'اسم القسم (مثال: عصائر طازجة)', required: true }]);
    if (!v) return;
    try {
        if (await settingsAction('add_category', { name: v.name })) {
            showToast('تمت إضافة القسم');
            await loadSettingsData();
            renderMenuSettings();
            if (typeof loadPOSMasterData === 'function') loadPOSMasterData();
        }
    } catch (err) {
        console.error('Add category error:', err);
    }
}

async function addNewProductPrompt() {
    const v = await uiForm('صنف جديد', [
        { key: 'name', label: 'اسم الصنف (مثال: عصير مانجو)', required: true, full: true },
        { key: 'price', label: 'سعر البيع', type: 'money', min: 0, required: true },
        { key: 'cat', label: 'القسم', type: 'select', options: settingsState.categories.map(c => [c.id, c.name]), placeholder: 'اختار القسم', addNew: 'قسم جديد', required: true }]);
    if (!v) return;
    try {
        let categoryId = v.cat;
        if (v.cat_new) {
            if (!(await settingsAction('add_category', { name: v.cat }))) return;
            await loadSettingsData();
            const c = settingsState.categories.find(x => x.name === v.cat);
            if (!c) return showToast('القسم الجديد متعملش', 'error');
            categoryId = c.id;
        }
        if (await settingsAction('add_product', { name: v.name, price: String(v.price), category_id: categoryId })) {
            showToast('تمت إضافة الصنف');
            await loadSettingsData();
            renderMenuSettings();
            if (typeof loadPOSMasterData === 'function') loadPOSMasterData();
        }
    } catch (err) {
        console.error('Add product error:', err);
    }
}

async function editProductPrice(productId, currentPrice) {
    const v = await uiForm('تعديل السعر', [{ key: 'price', label: 'السعر الجديد', type: 'money', min: 0, value: currentPrice, required: true }]);
    if (!v) return;
    try {
        if (await settingsAction('set_product_price', { product_id: productId, price: String(v.price) })) {
            showToast('تم تحديث السعر');
            await loadSettingsData();
            renderMenuSettings();
            if (typeof loadPOSMasterData === 'function') loadPOSMasterData();
        }
    } catch (err) {
        console.error('Edit price error:', err);
    }
}

async function toggleProductAvailability(productId, currentStatus) {
    try {
        if (await settingsAction('toggle_product', { product_id: productId, is_available: String(!currentStatus) })) {
            showToast(!currentStatus ? 'تم تفعيل الصنف بجدول الكاشير' : 'تم إيقاف الصنف');
            await loadSettingsData();
            renderMenuSettings();
            if (typeof loadPOSMasterData === 'function') loadPOSMasterData();
        }
    } catch (err) {
        console.error('Toggle availability error:', err);
    }
}

// -----------------------------------------
// 2. الفروع والمخازن والطاولات والضرائب
// -----------------------------------------
function renderBranchesSettings() {
    const container = document.getElementById('settings-branches-container');
    if (!container) return;
    const isOwner = String(currentUser?.roles?.name || '') === 'owner';
    container.innerHTML = `
        <div class="bg-white p-5 rounded-2xl border border-slate-200 shadow-sm mb-4">
            <div class="flex justify-between items-center mb-4 border-b pb-3">
                <h4 class="font-black text-sm text-slate-800">🏢 الفروع الحالية (${settingsState.branches.length})</h4>
                <button onclick="addNewBranchPrompt()" class="bg-blue-600 text-white px-3.5 py-2 rounded-xl text-xs font-bold shadow hover:bg-blue-700">إضافة فرع جديد ➕</button>
            </div>
            <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
                ${settingsState.branches.map(b => `
                    <div class="bg-slate-50 border p-3 rounded-2xl text-xs font-bold space-y-2">
                        <div class="flex justify-between items-start gap-2">
                            <div><p class="text-slate-800 font-black">${uiEsc(b.name)}</p><p class="text-[10px] text-slate-400">${uiEsc(b.address || 'بدون عنوان')}</p></div>
                            <span class="px-2 py-0.5 rounded-full text-[10px] whitespace-nowrap ${b.has_tables ? 'bg-emerald-100 text-emerald-700' : 'bg-slate-200 text-slate-600'}">${b.has_tables ? 'يدعم طاولات' : 'تيك أواي بس'}</span>
                        </div>
                        ${isOwner ? `<div class="flex gap-2"><button onclick="editBranchPrompt('${b.id}')" class="text-blue-700 bg-white border rounded-lg px-2 py-1">✏️ تعديل</button>
                            <button onclick="deleteBranchPrompt('${b.id}')" class="text-red-600 bg-white border border-red-100 rounded-lg px-2 py-1">🗑️ مسح</button></div>` : ''}
                    </div>`).join('')}
            </div>
        </div>`;
}

async function setupAction(action, data, okMsg) {
    const res = await uiCall('setup_admin_secure', { p_action: action, p_data: data }, okMsg);
    if (!res) return false;
    await loadSettingsData();
    renderBranchesSettings(); renderWarehousesSettings(); renderTablesSettings(); renderTaxSettings();
    return true;
}

async function editBranchPrompt(id) {
    const b = settingsState.branches.find(x => x.id === id) || {};
    const v = await uiForm('تعديل الفرع', [
        { key: 'name', label: 'اسم الفرع', value: b.name || '', required: true },
        { key: 'address', label: 'العنوان', value: b.address || '' },
        { key: 'tables', label: 'الفرع فيه طاولات وصالة (لو لأ: تيك أواي بس)', type: 'check', value: b.has_tables !== false, full: true }]);
    if (!v) return;
    if (await setupAction('edit_branch', { id, name: v.name, address: v.address || '', has_tables: v.tables }, 'تم تعديل الفرع') && currentBranch && currentUser?.branch_id === id) {
        currentBranch.name = v.name; currentBranch.has_tables = v.tables;
        const badge = document.getElementById('branch-badge'); if (badge) badge.textContent = v.name;
    }
}

async function deleteBranchPrompt(id) {
    const b = settingsState.branches.find(x => x.id === id) || {};
    if (!(await uiConfirm(`تمسح فرع "${b.name}"؟\nمناطقه وطاولاته ومخازنه الفاضية هتتمسح معاه.\nالفرع اللي عليه أي شغل (طلبات، موظفين، مشتريات...) مش هيتمسح.`, 'مسح', true))) return;
    const res = await uiCall('setup_admin_secure', { p_action: 'delete_branch', p_data: { id } });
    if (res === null) return;
    showToast('اتمسح الفرع');
    await loadSettingsData(); renderBranchesSettings(); renderWarehousesSettings(); renderTablesSettings(); renderTaxSettings();
}

async function addNewBranchPrompt() {
    const v = await uiForm('فرع جديد', [
        { key: 'name', label: 'اسم الفرع (مثال: فرع مدينة نصر)', required: true },
        { key: 'address', label: 'العنوان' },
        { key: 'tables', label: 'الفرع فيه طاولات وصالة (لو لأ: تيك أواي بس)', type: 'check', value: true, full: true }]);
    if (!v) return;
    try {
        if (await settingsAction('add_branch', { name: v.name, address: v.address || '', has_tables: String(v.tables) })) {
            showToast('تم إضافة الفرع'); await loadSettingsData(); renderBranchesSettings(); renderTaxSettings();
        }
    } catch (err) { console.error(err); }
}

function renderWarehousesSettings() {
    const container = document.getElementById('settings-warehouses-container');
    if (!container) return;
    container.innerHTML = `
        <div class="bg-white p-5 rounded-2xl border border-slate-200 shadow-sm mb-4">
            <div class="flex justify-between items-center mb-4 border-b pb-3">
                <h4 class="font-black text-sm text-slate-800">📦 المخازن الحالية (${settingsState.warehouses.length})</h4>
                <button onclick="addNewWarehousePrompt()" class="bg-blue-600 text-white px-3.5 py-2 rounded-xl text-xs font-bold shadow hover:bg-blue-700">إضافة مخزن جديد ➕</button>
            </div>
            <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
                ${settingsState.warehouses.map(w => `
                    <div class="bg-slate-50 border p-3 rounded-2xl text-xs font-bold space-y-2">
                        <div class="flex justify-between items-start gap-2">
                            <div><p class="text-slate-800 font-black">${uiEsc(w.name)}</p><p class="text-[10px] text-blue-600">${w.branches ? 'تابع لـ: ' + uiEsc(w.branches.name) : 'مخزن رئيسي مشترك'}</p></div>
                            ${w.is_main ? '<span class="bg-amber-100 text-amber-800 text-[10px] px-2 py-0.5 rounded-full font-bold">رئيسي</span>' : ''}
                        </div>
                        <div class="flex gap-2"><button onclick="editWarehousePrompt('${w.id}')" class="text-blue-700 bg-white border rounded-lg px-2 py-1">✏️ تعديل الاسم</button>
                            <button onclick="deleteWarehousePrompt('${w.id}')" class="text-red-600 bg-white border border-red-100 rounded-lg px-2 py-1">🗑️ مسح</button></div>
                    </div>`).join('')}
            </div>
        </div>`;
}

async function editWarehousePrompt(id) {
    const w = settingsState.warehouses.find(x => x.id === id) || {};
    const v = await uiForm('تعديل المخزن', [{ key: 'name', label: 'اسم المخزن', value: w.name || '', required: true }]);
    if (v) await setupAction('edit_warehouse', { id, name: v.name }, 'تم التعديل');
}

async function deleteWarehousePrompt(id) {
    const w = settingsState.warehouses.find(x => x.id === id) || {};
    if (!(await uiConfirm(`تمسح مخزن "${w.name}"؟ (المخزن اللي اتحرّك فيه أي بضاعة مش هيتمسح)`, 'مسح', true))) return;
    await setupAction('delete_warehouse', { id }, 'اتمسح المخزن');
}

async function addNewWarehousePrompt() {
    const v = await uiForm('مخزن جديد', [
        { key: 'name', label: 'اسم المخزن', required: true },
        { key: 'branch', label: 'تابع لـ', type: 'select', options: [['', 'مخزن رئيسي مشترك'], ...settingsState.branches.map(b => [b.id, b.name])], value: '' }]);
    if (!v) return;
    try {
        if (await settingsAction('add_warehouse', { name: v.name, branch_id: v.branch || null })) {
            showToast('تم إضافة المخزن'); await loadSettingsData(); renderWarehousesSettings();
        }
    } catch (err) { console.error(err); }
}

function renderTaxSettings() {
    const container = document.getElementById('settings-tax-container');
    if (!container) return;
    container.innerHTML = settingsState.branches.map(b => {
        const tax = (b.branch_tax_settings && b.branch_tax_settings.length > 0) ? b.branch_tax_settings[0] : { vat_percentage: 0, service_charge_percentage: 0 };
        return `
            <div class="bg-white p-5 rounded-2xl border border-slate-200 mb-4 shadow-sm">
                <h4 class="font-black text-sm mb-3 text-blue-600 border-b pb-2">فرع: ${b.name}</h4>
                <div class="grid grid-cols-2 gap-4">
                    <div>
                        <label class="block text-[11px] font-bold text-slate-500 mb-1">ضريبة القيمة المضافة (VAT %)</label>
                        <input type="number" id="tax-vat-${b.id}" value="${tax.vat_percentage}" class="w-full border p-2.5 rounded-xl text-sm font-black bg-slate-50">
                    </div>
                    <div>
                        <label class="block text-[11px] font-bold text-slate-500 mb-1">رسوم الخدمة (Service %)</label>
                        <input type="number" id="tax-srv-${b.id}" value="${tax.service_charge_percentage}" class="w-full border p-2.5 rounded-xl text-sm font-black bg-slate-50">
                    </div>
                </div>
                <button onclick="saveTaxSettings('${b.id}')" class="mt-4 bg-emerald-600 text-white px-5 py-2.5 rounded-xl text-xs font-bold w-full shadow hover:bg-emerald-700">حفظ الإعدادات المالية للفرع ✅</button>
            </div>
        `;
    }).join('');
}

async function saveTaxSettings(branchId) {
    const vat = parseFloat(document.getElementById(`tax-vat-${branchId}`).value) || 0;
    const srv = parseFloat(document.getElementById(`tax-srv-${branchId}`).value) || 0;
    if (await settingsAction('save_tax', { branch_id: branchId, vat_percentage: String(vat), service_charge_percentage: String(srv) })) {
        showToast('تم التحديث بنجاح');
        if (currentUser && currentUser.branch_id === branchId) { taxSettings.vat_percentage = vat; taxSettings.service_charge_percentage = srv; }
    }
}

function motionTableSort(a, b) { return String(a.table_number).localeCompare(String(b.table_number), 'ar', { numeric: true }); }

function renderTablesSettings() {
    const container = document.getElementById('settings-tables-container');
    if (!container) return;
    const areas = settingsState.areas.filter(a => !currentUser?.branch_id || a.branch_id === currentUser.branch_id || String(currentUser?.roles?.name) === 'owner');
    container.innerHTML = areas.map(area => `
        <div class="bg-white p-4 rounded-2xl border border-slate-200 mb-4 shadow-sm">
            <div class="flex flex-wrap justify-between items-center gap-2 mb-3 border-b pb-3">
                <h4 class="font-black text-sm text-slate-800">منطقة: ${uiEsc(area.name)} <span class="text-[11px] text-slate-400">(${(area.tables || []).length} طاولة)</span></h4>
                <div class="flex flex-wrap gap-2">
                    <button onclick="renameAreaPrompt('${area.id}')" class="text-blue-700 bg-slate-50 border rounded-xl px-3 py-1.5 text-xs font-bold">✏️ اسم المنطقة</button>
                    <button onclick="deleteAreaPrompt('${area.id}')" class="text-red-600 bg-red-50 border border-red-100 rounded-xl px-3 py-1.5 text-xs font-bold">🗑️ مسح المنطقة</button>
                    <button onclick="addNewTable('${area.id}')" class="bg-blue-600 text-white px-3 py-1.5 rounded-xl text-xs font-bold shadow hover:bg-blue-700">إضافة طاولة ➕</button>
                </div>
            </div>
            <div class="grid grid-cols-3 sm:grid-cols-5 lg:grid-cols-6 gap-2">
                ${(area.tables || []).slice().sort(motionTableSort).map(t => `
                    <div class="bg-slate-50 border border-slate-200 rounded-xl p-2 text-center text-[11px] font-bold space-y-1">
                        <p class="font-black text-sm text-slate-800">${uiEsc(t.table_number)}</p>
                        <p class="text-slate-500">${uiEsc(t.capacity)} كراسي</p>
                        <div class="flex gap-1 justify-center"><button onclick="editTablePrompt('${t.id}')" class="text-blue-700 bg-white border rounded px-1.5" title="تعديل">✏️</button>
                            <button onclick="deleteTable('${t.id}')" class="text-red-600 bg-white border border-red-100 rounded px-1.5" title="حذف">🗑️</button></div>
                    </div>`).join('') || '<p class="col-span-full text-center text-slate-400 text-xs py-3">مفيش طاولات</p>'}
            </div>
        </div>`).join('') || '<p class="text-xs text-slate-400 font-bold">مفيش مناطق. اعمل منطقة من: الخصومات والأسباب والمناطق.</p>';
}

async function editTablePrompt(tableId) {
    const t = settingsState.areas.flatMap(a => a.tables || []).find(x => x.id === tableId) || {};
    const v = await uiForm('تعديل الطاولة', [
        { key: 'num', label: 'اسم أو رقم الطاولة (مثلاً 5 أو VIP 1)', value: t.table_number || '', required: true },
        { key: 'cap', label: 'عدد الكراسي', type: 'number', min: 1, max: 50, value: t.capacity || 4, required: true }]);
    if (v) await setupAction('edit_table', { id: tableId, table_number: v.num, capacity: String(parseInt(v.cap, 10) || 4) }, 'تم التعديل');
}

async function renameAreaPrompt(id) {
    const a = settingsState.areas.find(x => x.id === id) || {};
    const v = await uiForm('اسم المنطقة', [{ key: 'name', label: 'الاسم (مثلاً: الدور الأول، التراس)', value: a.name || '', required: true }]);
    if (v) await setupAction('rename_area', { id, name: v.name }, 'تم التعديل');
}

async function deleteAreaPrompt(id) {
    const a = settingsState.areas.find(x => x.id === id) || {};
    if (!(await uiConfirm(`تمسح منطقة "${a.name}" وطاولاتها؟ (لو أي طاولة عليها طلبات قديمة مش هتتمسح)`, 'مسح', true))) return;
    await setupAction('delete_area', { id }, 'اتمسحت المنطقة');
}

async function editTableCapacity(tableId, currentCapacity) {
    const v = await uiForm('عدد الكراسي', [{ key: 'cap', label: 'عدد الضيوف', type: 'number', min: 1, max: 50, value: currentCapacity, required: true }]);
    if (!v) return;
    if (await settingsAction('set_table_capacity', { table_id: tableId, capacity: String(parseInt(v.cap, 10) || 4) })) {
        showToast('تم التعديل'); await loadSettingsData(); renderTablesSettings();
    }
}

async function addNewTable(areaId) {
    const v = await uiForm('طاولة جديدة', [
        { key: 'num', label: 'رقم الطاولة', required: true },
        { key: 'cap', label: 'عدد الكراسي', type: 'number', min: 1, max: 50, value: 4, required: true }]);
    if (!v) return;
    if (await settingsAction('add_table', { area_id: areaId, table_number: v.num, capacity: String(parseInt(v.cap, 10) || 4) })) {
        showToast('تمت الإضافة'); await loadSettingsData(); renderTablesSettings();
    }
}

async function deleteTable(tableId) {
    if (!(await uiConfirm('حذف الطاولة؟', 'حذف', true))) return;
    if (await settingsAction('delete_table', { table_id: tableId })) {
        showToast('تم الحذف'); await loadSettingsData(); renderTablesSettings();
    }
}
