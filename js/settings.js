// js/settings.js - لوحة الإعدادات والتحكم للإدارة (Backoffice)

let settingsState = {
    branches: [],
    areas: [],
    tables: []
};

async function initSettingsModule() {
    await loadSettingsData();
    renderTaxSettings();
    renderTablesSettings();
}

async function loadSettingsData() {
    // جلب الفروع وإعدادات الضرائب الخاصة بها
    const { data: bData } = await _supabase.from('branches').select('*, branch_tax_settings(*)');
    settingsState.branches = bData || [];

    // جلب المناطق والطاولات
    const { data: aData } = await _supabase.from('areas').select('*, tables(*)');
    settingsState.areas = aData || [];
}

// -----------------------------------------
// 1. إعدادات الضرائب والخدمة لكل فرع
// -----------------------------------------
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
                <button onclick="saveTaxSettings('${b.id}')" class="mt-4 bg-emerald-600 text-white px-5 py-2.5 rounded-xl text-xs font-bold w-full shadow-md hover:bg-emerald-700">حفظ وتحديث الضرائب للفرع ✅</button>
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
        // لو المالك بيعدل الفرع اللي هو شغال عليه حاليا نحدث المتغيرات في الرامات
        if (currentUser && currentUser.branch_id === branchId) {
            taxSettings.vat_percentage = vat;
            taxSettings.service_charge_percentage = srv;
        }
    }
}

// -----------------------------------------
// 2. إعدادات وإدارة الطاولات
// -----------------------------------------
function renderTablesSettings() {
    const container = document.getElementById('settings-tables-container');
    if (!container) return;

    container.innerHTML = settingsState.areas.map(area => `
        <div class="bg-white p-5 rounded-2xl border border-slate-200 mb-4 shadow-sm">
            <div class="flex justify-between items-center mb-4 border-b pb-3">
                <h4 class="font-black text-sm text-slate-800">منطقة: ${area.name}</h4>
                <button onclick="addNewTable('${area.id}')" class="bg-blue-600 text-white px-4 py-2 rounded-xl text-xs font-bold shadow hover:bg-blue-700">إضافة طاولة جديدة ➕</button>
            </div>
            <div class="grid grid-cols-4 gap-3">
                ${(area.tables || []).map(t => `
                    <div class="bg-slate-50 border border-slate-200 rounded-2xl p-3 flex flex-col justify-between text-center relative group">
                        <span class="font-black text-sm text-slate-800">${t.table_number}</span>
                        <span class="text-[10px] font-bold text-slate-500 mb-3 bg-white border rounded-full px-2 py-0.5 mx-auto mt-1">سعة: ${t.capacity} ضيوف</span>
                        <button onclick="deleteTable('${t.id}')" class="bg-red-50 text-red-600 text-[11px] font-bold py-1.5 rounded-lg hover:bg-red-100 border border-red-100 transition">حذف الطاولة 🗑️</button>
                    </div>
                `).join('')}
            </div>
        </div>
    `).join('');
}

async function addNewTable(areaId) {
    const tNum = prompt('أدخل اسم أو رقم الطاولة (مثال: طاولة 5 أو T5):');
    if (!tNum) return;
    const cap = prompt('أدخل سعة الطاولة (عدد الكراسي):', '4');
    if (!cap) return;

    const { error } = await _supabase.from('tables').insert([{
        area_id: areaId,
        table_number: tNum,
        capacity: parseInt(cap) || 4
    }]);

    if (error) {
        showToast('خطأ في الإضافة: ' + error.message, 'error');
    } else {
        showToast('تمت إضافة الطاولة بنجاح');
        await loadSettingsData();
        renderTablesSettings();
        // تحديث شاشة الكاشير لو مفتوحة
        if (typeof fetchBranchTables === 'function') {
            await fetchBranchTables();
            if (typeof renderAreaAndTables === 'function') renderAreaAndTables();
        }
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
        if (typeof fetchBranchTables === 'function') {
            await fetchBranchTables();
            if (typeof renderAreaAndTables === 'function') renderAreaAndTables();
        }
    }
}
