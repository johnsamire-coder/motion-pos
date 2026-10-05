// js/settings.js - لوحة الإعدادات والتحكم الشاملة - Motion POS

let settingsState = {
    branches: [],
    warehouses: [],
    areas: [],
    tables: []
};

async function initSettingsModule() {
    await loadSettingsData();
    renderTaxSettings();
    renderBranchesSettings();
    renderWarehousesSettings();
    renderTablesSettings();
}

// دالة التبديل بين أقسام الإعدادات (Sidebar Logic)
function switchSettingsSection(section) {
    // إخفاء كل الأقسام
    document.querySelectorAll('.set-section').forEach(el => el.classList.add('hidden'));
    // إظهار القسم المطلوب
    const targetEl = document.getElementById('set-section-' + section);
    if (targetEl) targetEl.classList.remove('hidden');

    // إعادة ضبط شكل الأزرار الجانبية
    document.querySelectorAll('.set-nav-btn').forEach(btn => {
        btn.className = "set-nav-btn w-full text-right px-4 py-3 rounded-xl text-xs font-black bg-slate-50 text-slate-600 border border-slate-100 hover:bg-slate-100 transition mb-2";
    });
    
    // تفعيل الزر الحالي
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
    } catch (err) {
        console.error('Error loading settings data:', err);
    }
}

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
        const { error } = await _supabase.from('branches').insert([{
            brand_id: brandId,
            name: name,
            address: address || '',
            has_tables: hasTablesConfirm
        }]);

        if (error) {
            showToast('خطأ في إضافة الفرع: ' + error.message, 'error');
        } else {
            showToast('تم إضافة الفرع الجديد بنجاح');
            await loadSettingsData();
            renderBranchesSettings();
            renderTaxSettings();
        }
    } catch (err) {
        console.error('Add branch error:', err);
    }
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
    const name = prompt('أدخل اسم المخزن الجديد (مثال: مخزن بار التجمع):');
    if (!name) return;

    let branchOptions = "0. مخزن رئيسي مشترك (غير تابع لفرع معين)\n";
    settingsState.branches.forEach((b, idx) => {
        branchOptions += `${idx + 1}. ${b.name}\n`;
    });

    const choiceStr = prompt('اختر رقم الفرع التابع له المخزن:\n' + branchOptions, '0');
    if (choiceStr === null) return;

    const choiceIdx = parseInt(choiceStr) || 0;
    let selectedBranchId = null;
    let isMain = true;

    if (choiceIdx > 0 && choiceIdx <= settingsState.branches.length) {
        selectedBranchId = settingsState.branches[choiceIdx - 1].id;
        isMain = false;
    }

    try {
        const { error } = await _supabase.from('warehouses').insert([{
            branch_id: selectedBranchId,
            name: name,
            is_main: isMain
        }]);

        if (error) {
            showToast('خطأ في إضافة المخزن: ' + error.message, 'error');
        } else {
            showToast('تم إضافة المخزن الجديد بنجاح');
            await loadSettingsData();
            renderWarehousesSettings();
        }
    } catch (err) {
        console.error('Add warehouse error:', err);
    }
}

function renderTaxSettings() {
    const container = document.getElementById('settings-tax-container');
    if (!container) return;
    
    container.innerHTML = settingsState.branches.map(b => {
        const tax = (b.branch_tax_settings && b.branch_tax_settings.length > 0) 
            ? b.branch_tax_settings[0] 
            : { vat_percentage: 0, service_charge_percentage: 0 };
            
        return `
            <div class="bg-white p-5 rounded-2xl border border-slate-200 mb-4 shadow-sm">
                <h4 class="font-black text-sm mb-3 text-blue-600 border-b pb-2">فرع: ${b.name}</h4>
                <div class="grid grid-cols-2 gap-4">
                    <div>
                        <label class="block text-[11px] font-bold text-slate-500 mb-1">ضريبة القيمة المضافة (VAT %)</label>
                        <input type="number" id="tax-vat-${b.id}" value="${tax.vat_percentage}" class="w-full border p-2.5 rounded-xl text-sm font-black bg-slate-50 focus:border-blue-500 focus:outline-none">
                    </div>
                    <div>
                        <label class="block text-[11px] font-bold text-slate-500 mb-1">رسوم الخدمة (Service %)</label>
                        <input type="number" id="tax-srv-${b.id}" value="${tax.service_charge_percentage}" class="w-full border p-2.5 rounded-xl text-sm font-black bg-slate-50 focus:border-blue-500 focus:outline-none">
                    </div>
                </div>
                <button onclick="saveTaxSettings('${b.id}')" class="mt-4 bg-emerald-600 text-white px-5 py-2.5 rounded-xl text-xs font-bold w-full shadow-md hover:bg-emerald-700">حفظ الإعدادات المالية للفرع ✅</button>
            </div>
        `;
    }).join('');
}

async function saveTaxSettings(branchId) {
    const vat = parseFloat(document.getElementById(`tax-vat-${branchId}`).value) || 0;
    const srv = parseFloat(document.getElementById(`tax-srv-${branchId}`).value) || 0;

    const { error } = await _supabase.from('branch_tax_settings').upsert({
        branch_id: branchId,
        vat_percentage: vat,
        service_charge_percentage: srv
    });

    if (error) {
        showToast('خطأ في حفظ الضرائب', 'error');
    } else {
        showToast('تم تحديث الضرائب والخدمة للفرع بنجاح');
        if (currentUser && currentUser.branch_id === branchId) {
            taxSettings.vat_percentage = vat;
            taxSettings.service_charge_percentage = srv;
        }
    }
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

                        <button onclick="deleteTable('${t.id}')" class="bg-red-50 text-red-600 text-[10px] font-bold py-1 rounded-lg hover:bg-red-100 border border-red-100 transition">حذف 🗑️</button>
                    </div>
                `).join('')}
            </div>
        </div>
    `).join('');
}

async function editTableCapacity(tableId, currentCapacity) {
    const newCap = prompt('أدخل عدد الضيوف/الكراسي الجديد للطاولة:', currentCapacity);
    if (!newCap) return;
    const val = parseInt(newCap);
    if (isNaN(val) || val <= 0) return alert('أدخل سعة صحيحة');

    try {
        const { error } = await _supabase.from('tables').update({ capacity: val }).eq('id', tableId);
        if (error) {
            showToast('خطأ في التعديل: ' + error.message, 'error');
        } else {
            showToast('تم تعديل سعة الطاولة بنجاح');
            await loadSettingsData();
            renderTablesSettings();
        }
    } catch (err) {
        console.error('Edit capacity error:', err);
    }
}

async function addNewTable(areaId) {
    const tNum = prompt('أدخل اسم أو رقم الطاولة (مثال: طاولة 5 أو T5):');
    if (!tNum) return;
    const cap = prompt('أدخل سعة الطاولة (عدد الكراسي):', '4');
    if (!cap) return;

    const { error } = await _supabase.from('tables').insert([{ area_id: areaId, table_number: tNum, capacity: parseInt(cap) || 4 }]);

    if (error) {
        showToast('خطأ في الإضافة: ' + error.message, 'error');
    } else {
        showToast('تمت إضافة الطاولة بنجاح');
        await loadSettingsData();
        renderTablesSettings();
    }
}

async function deleteTable(tableId) {
    if (!confirm('هل أنت متأكد من حذف هذه الطاولة بشكل نهائي')) return;
    const { error } = await _supabase.from('tables').delete().eq('id', tableId);
    if (error) {
        showToast('لا يمكن حذف طاولة عليها أوردرات سابقة للحفاظ على السجلات المالية!', 'error');
    } else {
        showToast('تم حذف الطاولة بنجاح');
        await loadSettingsData();
        renderTablesSettings();
    }
}
