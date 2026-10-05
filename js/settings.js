// js/settings.js - لوحة الإعدادات والتحكم الشاملة - Motion POS

let settingsState = {
    branches: [],
    warehouses: [],
    areas: [],
    tables: [],
    categories: [],
    products: []
};

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

        const { data: pData } = await _supabase.from('products').select('*, categories(name)');
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
    const name = prompt('أدخل اسم القسم الجديد (مثال: عصائر طازجة):');
    if (!name) return;

    try {
        const brandId = currentUser ? currentUser.brand_id : 'b0000000-0000-0000-0000-000000000000';
        const { error } = await _supabase.from('categories').insert([{ brand_id: brandId, name: name }]);

        if (error) {
            showToast('خطأ في إضافة القسم: ' + error.message, 'error');
        } else {
            showToast('تمت إضافة القسم الجديد بنجاح');
            await loadSettingsData();
            renderMenuSettings();
            if (typeof loadPOSMasterData === 'function') loadPOSMasterData();
        }
    } catch (err) {
        console.error('Add category error:', err);
    }
}

async function addNewProductPrompt() {
    if (settingsState.categories.length === 0) {
        alert('يرجى إضافة قسم أولا قبل إضافة المنتجات!');
        return;
    }

    const name = prompt('أدخل اسم الصنف الجديد (مثال: عصير مانجو طازج):');
    if (!name) return;
    const priceStr = prompt('أدخل سعر البيع (بالجنيه):', '50');
    if (!priceStr) return;

    let catOptions = "اختر رقم القسم Tابع له المنتج:\n";
    settingsState.categories.forEach((c, idx) => { catOptions += `${idx + 1}. ${c.name}\n`; });

    const choiceStr = prompt(catOptions, '1');
    if (!choiceStr) return;

    const choiceIdx = parseInt(choiceStr) - 1;
    if (choiceIdx < 0 || choiceIdx >= settingsState.categories.length) return alert('اختيار غير صحيح!');

    const categoryId = settingsState.categories[choiceIdx].id;
    const price = parseFloat(priceStr) || 0;

    try {
        const brandId = currentUser ? currentUser.brand_id : 'b0000000-0000-0000-0000-000000000000';
        const { error } = await _supabase.from('products').insert([{
            brand_id: brandId,
            category_id: categoryId,
            name: name,
            price: price,
            is_available: true
        }]);

        if (error) {
            showToast('خطأ في إضافة المنتج: ' + error.message, 'error');
        } else {
            showToast('تمت إضافة المنتج الجديد بنجاح المنيو');
            await loadSettingsData();
            renderMenuSettings();
            if (typeof loadPOSMasterData === 'function') loadPOSMasterData();
        }
    } catch (err) {
        console.error('Add product error:', err);
    }
}

async function editProductPrice(productId, currentPrice) {
    const newPriceStr = prompt('أدخل السعر الجديد للصنف (بالجنيه):', currentPrice);
    if (!newPriceStr) return;

    const price = parseFloat(newPriceStr);
    if (isNaN(price) || price < 0) return alert('أدخل سعر صحفي!');

    try {
        const { error } = await _supabase.from('products').update({ price: price }).eq('id', productId);
        if (error) {
            showToast('خطأ في التعديل: ' + error.message, 'error');
        } else {
            showToast('تم تحديث سعر المنتج بنجاح');
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
        const { error } = await _supabase.from('products').update({ is_available: !currentStatus }).eq('id', productId);
        if (error) {
            showToast('خطأ في تحديث حالة المنتج', 'error');
        } else {
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

    container.innerHTML = `
        <div class="bg-white p-5 rounded-2xl border border-slate-200 shadow-sm mb-4">
            <div class="flex justify-between items-center mb-4 border-b pb-3">
                <h4 class="font-black text-sm text-slate-800">🏢 الفروع الحالية (${settingsState.branches.length})</h4>
                <button onclick="addNewBranchPrompt()" class="bg-blue-600 text-white px-3.5 py-2 rounded-xl text-xs font-bold shadow hover:bg-blue-700">إضافة فرع جديد ➕</button>
            </div>
            <div class="grid grid-cols-2 gap-3">
                ${settingsState.branches.map(b => `
                    <div class="bg-slate-50 border p-3 rounded-2xl flex justify-between items-center text-xs font-bold">
                        <div>
                            <p class="text-slate-800 font-black">${b.name}</p>
                            <p class="text-[10px] text-slate-400">${b.address || 'بدون عنوان'}</p>
                        </div>
                        <span class="px-2 py-0.5 rounded-full text-[10px] ${b.has_tables ? 'bg-emerald-100 text-emerald-700' : 'bg-slate-200 text-slate-600'}">
                            ${b.has_tables ? 'يدعم طاولات' : 'تيك أواي بس'}
                        </span>
                    </div>
                `).join('')}
            </div>
        </div>
    `;
}

async function addNewBranchPrompt() {
    const name = prompt('أدخل اسم الفرع الجديد (مثال: فرع مدينة نصر):');
    if (!name) return;
    const address = prompt('أدخل عنوان الفرع:');
    const hasTablesConfirm = confirm('هل يدعم هذا الفرع طاولات وقعدة صالة\n(موافق = نعم إلغاء = تيك أواي فقط)');

    try {
        const brandId = currentUser ? currentUser.brand_id : 'b0000000-0000-0000-0000-000000000000';
        const { error } = await _supabase.from('branches').insert([{ brand_id: brandId, name: name, address: address || '', has_tables: hasTablesConfirm }]);
        if (error) showToast('خطأ: ' + error.message, 'error');
        else { showToast('تم إضافة الفرع بنجاح'); await loadSettingsData(); renderBranchesSettings(); renderTaxSettings(); }
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
            <div class="grid grid-cols-2 gap-3">
                ${settingsState.warehouses.map(w => `
                    <div class="bg-slate-50 border p-3 rounded-2xl flex justify-between items-center text-xs font-bold">
                        <div>
                            <p class="text-slate-800 font-black">${w.name}</p>
                            <p class="text-[10px] text-blue-600">${w.branches ? 'تابعة لـ: ' + w.branches.name : 'مخزن رئيسي مشترك'}</p>
                        </div>
                        ${w.is_main ? '<span class="bg-amber-100 text-amber-800 text-[10px] px-2 py-0.5 rounded-full font-bold">رئيسي</span>' : ''}
                    </div>
                `).join('')}
            </div>
        </div>
    `;
}

async function addNewWarehousePrompt() {
    const name = prompt('أدخل اسم المخزن الجديد:');
    if (!name) return;
    let branchOptions = "0. مخزن رئيسي مشترك\n";
    settingsState.branches.forEach((b, idx) => { branchOptions += `${idx + 1}. ${b.name}\n`; });
    const choiceStr = prompt('اختر رقم الفرع التابع له المخزن:\n' + branchOptions, '0');
    if (choiceStr === null) return;
    const choiceIdx = parseInt(choiceStr) || 0;
    let selectedBranchId = choiceIdx > 0 && choiceIdx <= settingsState.branches.length ? settingsState.branches[choiceIdx - 1].id : null;

    try {
        const { error } = await _supabase.from('warehouses').insert([{ branch_id: selectedBranchId, name: name, is_main: !selectedBranchId }]);
        if (error) showToast('خطأ: ' + error.message, 'error');
        else { showToast('تم إضافة المخزن بنجاح'); await loadSettingsData(); renderWarehousesSettings(); }
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
    const { error } = await _supabase.from('branch_tax_settings').upsert({ branch_id: branchId, vat_percentage: vat, service_charge_percentage: srv });
    if (error) showToast('خطأ في الحفظ', 'error');
    else { showToast('تم التحديث بنجاح'); if (currentUser && currentUser.branch_id === branchId) { taxSettings.vat_percentage = vat; taxSettings.service_charge_percentage = srv; } }
}

function renderTablesSettings() {
    const container = document.getElementById('settings-tables-container');
    if (!container) return;
    container.innerHTML = settingsState.areas.map(area => `
        <div class="bg-white p-5 rounded-2xl border border-slate-200 mb-4 shadow-sm">
            <div class="flex justify-between items-center mb-4 border-b pb-3">
                <h4 class="font-black text-sm text-slate-800">منطقة: ${area.name}</h4>
                <button onclick="addNewTable('${area.id}')" class="bg-blue-600 text-white px-4 py-2 rounded-xl text-xs font-bold shadow hover:bg-blue-700">إضافة طاولة ➕</button>
            </div>
            <div class="grid grid-cols-4 gap-3">
                ${(area.tables || []).map(t => `
                    <div class="bg-slate-50 border border-slate-200 rounded-2xl p-3 flex flex-col justify-between text-center">
                        <span class="font-black text-sm text-slate-800">${t.table_number}</span>
                        <div class="my-2 bg-white border rounded-xl p-1 flex justify-between items-center">
                            <span class="text-[10px] font-bold text-slate-500">سعة: ${t.capacity} ضيوف</span>
                            <button onclick="editTableCapacity('${t.id}', ${t.capacity})" class="text-[10px] text-blue-600 font-bold px-1 rounded hover:bg-blue-50">تعديل ✏️</button>
                        </div>
                        <button onclick="deleteTable('${t.id}')" class="bg-red-50 text-red-600 text-[10px] font-bold py-1 rounded-lg hover:bg-red-100 border border-red-100">حذف 🗑️</button>
                    </div>
                `).join('')}
            </div>
        </div>
    `).join('');
}

async function editTableCapacity(tableId, currentCapacity) {
    const newCap = prompt('أدخل عدد الضيوف الجديد:', currentCapacity);
    if (!newCap) return;
    const { error } = await _supabase.from('tables').update({ capacity: parseInt(newCap) || 4 }).eq('id', tableId);
    if (error) showToast('خطأ: ' + error.message, 'error');
    else { showToast('تم التعديل بنجاح'); await loadSettingsData(); renderTablesSettings(); }
}

async function addNewTable(areaId) {
    const tNum = prompt('أدخل رقم الطاولة:'); if (!tNum) return;
    const cap = prompt('أدخل سعة الطاولة:', '4'); if (!cap) return;
    const { error } = await _supabase.from('tables').insert([{ area_id: areaId, table_number: tNum, capacity: parseInt(cap) || 4 }]);
    if (error) showToast('خطأ: ' + error.message, 'error');
    else { showToast('تمت الإضافة بنجاح'); await loadSettingsData(); renderTablesSettings(); }
}

async function deleteTable(tableId) {
    if (!confirm('حذف الطاولة')) return;
    const { error } = await _supabase.from('tables').delete().eq('id', tableId);
    if (error) showToast('لا يمكن حذف طاولة عليها طلبات سابقة', 'error');
    else { showToast('تم الحذف'); await loadSettingsData(); renderTablesSettings(); }
}
