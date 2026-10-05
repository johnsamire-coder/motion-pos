// js/inventory.js - موديول المخازن الهالك والجرد الفعلي - Motion POS

let inventoryOptionsLoaded = false;

async function loadInventoryOptions() {
    if (inventoryOptionsLoaded) return true;
    try {
        const [warehousesRes, ingredientsRes] = await Promise.all([
            _supabase.from('warehouses').select('id, name').order('name'),
            _supabase.from('ingredients').select('id, name, unit').order('name')
        ]);
        const errors = [];
        if (warehousesRes.error) errors.push('المخازن: ' + warehousesRes.error.message);
        if (ingredientsRes.error) errors.push('الخامات: ' + ingredientsRes.error.message);
        const warehouses = warehousesRes.data || [];
        const ingredients = ingredientsRes.data || [];
        populateSelectOptions('inventory-warehouse-select', warehouses, 'اختر المخزن', errors.length ? 'تعذر تحميل المخازن' : 'لا توجد مخازن مسجلة');
        populateSelectOptions('waste-ingredient-select', ingredients, 'اختر الخامة', errors.length ? 'تعذر تحميل الخامات' : 'لا توجد خامات مسجلة', item => item.unit ? item.name + ' (' + item.unit + ')' : item.name);
        populateSelectOptions('stocktake-ingredient-select', ingredients, 'اختر الخامة', errors.length ? 'تعذر تحميل الخامات' : 'لا توجد خامات مسجلة', item => item.unit ? item.name + ' (' + item.unit + ')' : item.name);
        if (errors.length) {
            console.error('Inventory dropdown load errors:', errors);
            showToast('تعذر تحميل قوائم المخزون: ' + errors.join(' | '), 'error');
            return false;
        }
        inventoryOptionsLoaded = true;
        return true;
    } catch (err) {
        console.error('Inventory options exception:', err);
        showToast('تعذر تحميل قوائم المخزون من قاعدة البيانات: ' + (err.message || 'خطأ غير معروف'), 'error');
        return false;
    }
}

async function loadInventoryStock() {
    const warehouseSelect = document.getElementById('inventory-warehouse-select');
    if (!warehouseSelect) return;
    if (!(await loadInventoryOptions())) return;

    const wId = warehouseSelect.value;
    if (!wId) {
        const tbody = document.getElementById('inventory-table-body');
        if (tbody) {
            const row = document.createElement('tr');
            const cell = document.createElement('td');
            cell.colSpan = 4;
            cell.className = 'text-center p-4 text-slate-400 font-bold';
            cell.textContent = warehouseSelect.options.length > 1 ? 'اختر مخزنًا لعرض الرصيد' : 'لا توجد مخازن مسجلة';
            row.appendChild(cell);
            tbody.replaceChildren(row);
        }
        return;
    }

    try {
        const { data, error } = await _supabase
            .from('warehouse_stock')
            .select('quantity, ingredients(id, name, unit, min_stock_alert)')
            .eq('warehouse_id', wId);

        if (error) {
            console.error('Error fetching stock:', error);
            showToast('تعذر تحميل رصيد المخزن: ' + error.message, 'error');
            return;
        }

        const tbody = document.getElementById('inventory-table-body');
        if (!tbody) return;

        if (!data || data.length === 0) {
            tbody.innerHTML = `<tr><td colspan="4" class="text-center p-4 text-slate-400 font-bold">لا يوجد خامات في هذا المخزن</td></tr>`;
            return;
        }

        tbody.innerHTML = data.map(item => {
            const ing = item.ingredients;
            const isLow = item.quantity <= (ing ? ing.min_stock_alert : 0);
            return `
                <tr class="border-b border-slate-100 text-xs font-bold hover:bg-slate-50">
                    <td class="p-3 text-slate-800">${ing ? ing.name : 'خامة'}</td>
                    <td class="p-3 text-center text-blue-600 font-extrabold">${item.quantity}</td>
                    <td class="p-3 text-slate-500">${ing ? ing.unit : ''}</td>
                    <td class="p-3">
                        <span class="px-2 py-0.5 rounded-lg text-[10px] font-extrabold ${isLow ? 'bg-red-100 text-red-600' : 'bg-emerald-100 text-emerald-600'}">
                            ${isLow ? '⚠️ رصيد منخفض' : '✅ آمن'}
                        </span>
                    </td>
                </tr>
            `;
        }).join('');

    } catch (err) {
        console.error('Inventory exception:', err);
        showToast('تعذر تحميل رصيد المخزن: ' + (err.message || 'خطأ غير معروف'), 'error');
    }
}

async function submitWasteLog() {
    const wId = document.getElementById('inventory-warehouse-select').value;
    const ingId = document.getElementById('waste-ingredient-select').value;
    const qty = parseFloat(document.getElementById('waste-qty').value);
    const reason = document.getElementById('waste-reason').value;

    if (!wId || !ingId) {
        showToast('اختر المخزن والخامة أولًا', 'error');
        return;
    }

    if (!qty || qty <= 0) {
        showToast('أدخل كمية هالك صحيحة', 'error');
        return;
    }

    try {
        const { error } = await _supabase.rpc('log_waste', {
            p_warehouse_id: wId,
            p_ingredient_id: ingId,
            p_quantity: qty,
            p_reason: reason
        });

        if (error) {
            showToast('خطأ: ' + error.message, 'error');
        } else {
            showToast('تم تسجيل الهالك وخصم الكمية من المخزن');
            document.getElementById('waste-qty').value = '';
            loadInventoryStock();
        }
    } catch (err) {
        console.error('Waste log error:', err);
    }
}

async function submitStockTake() {
    const wId = document.getElementById('inventory-warehouse-select').value;
    const ingId = document.getElementById('stocktake-ingredient-select').value;
    const actualQty = parseFloat(document.getElementById('stocktake-qty').value);

    if (!wId || !ingId) {
        showToast('اختر المخزن والخامة أولًا', 'error');
        return;
    }

    if (isNaN(actualQty) || actualQty < 0) {
        showToast('أدخل الكمية الفعلية الموزونة', 'error');
        return;
    }

    try {
        const { error } = await _supabase.rpc('record_stock_take', {
            p_warehouse_id: wId,
            p_ingredient_id: ingId,
            p_actual_qty: actualQty
        });

        if (error) {
            showToast('خطأ: ' + error.message, 'error');
        } else {
            showToast('تم حفظ الجرد وتحديث رصيد المخزن للكمية الفعلية');
            document.getElementById('stocktake-qty').value = '';
            loadInventoryStock();
        }
    } catch (err) {
        console.error('Stock take error:', err);
    }
}
