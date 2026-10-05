// js/purchasing.js - موديول المشتريات وفواتير الموردين - Motion POS

async function loadPurchaseOptions() {
    try {
        const [suppliersRes, warehousesRes, ingredientsRes] = await Promise.all([
            _supabase.from('suppliers').select('id, name').order('name'),
            _supabase.from('warehouses').select('id, name').order('name'),
            _supabase.from('ingredients').select('id, name, unit').order('name')
        ]);
        if (suppliersRes.error) throw suppliersRes.error;
        if (warehousesRes.error) throw warehousesRes.error;
        if (ingredientsRes.error) throw ingredientsRes.error;

        populateSelectOptions('purchase-supplier', suppliersRes.data, 'اختر المورد', 'لا يوجد موردون مسجلون');
        populateSelectOptions('purchase-warehouse', warehousesRes.data, 'اختر المخزن', 'لا توجد مخازن مسجلة');
        populateSelectOptions('purchase-ingredient', ingredientsRes.data, 'اختر الخامة', 'لا توجد خامات مسجلة', item => item.unit ? `${item.name} (${item.unit})` : item.name);
        return true;
    } catch (err) {
        console.error('Purchase options error:', err);
        showToast('تعذر تحميل قوائم المشتريات: ' + (err.message || 'خطأ غير معروف'), 'error');
        return false;
    }
}

async function submitPurchaseInvoice() {
    const supplierId = document.getElementById('purchase-supplier')?.value;
    const warehouseId = document.getElementById('purchase-warehouse')?.value;
    const ingredientId = document.getElementById('purchase-ingredient')?.value;
    const qty = parseFloat(document.getElementById('purchase-qty')?.value);
    const price = parseFloat(document.getElementById('purchase-unit-price')?.value);

    if (!supplierId || !warehouseId || !ingredientId) {
        showToast('اختر المورد والمخزن والخامة أولًا', 'error');
        return;
    }
    if (!Number.isFinite(qty) || qty <= 0 || !Number.isFinite(price) || price <= 0) {
        showToast('أدخل الكمية وسعر الوحدة بشكل صحيح', 'error');
        return;
    }

    const totalPrice = qty * price;

    try {
        // 1. إنشاء رأس الفاتورة
        const { data: po, error: poErr } = await _supabase
            .from('purchase_orders')
            .insert([{
                supplier_id: supplierId,
                warehouse_id: warehouseId,
                total_amount: totalPrice,
                status: 'received'
            }])
            .select()
            .single();

        if (poErr) {
            showToast('خطأ في إيقاع الفاتورة: ' + poErr.message, 'error');
            return;
        }

        // 2. إدخال عنصر الفاتورة
        const { error: itemError } = await _supabase.from('purchase_order_items').insert([{
            purchase_order_id: po.id,
            ingredient_id: ingredientId,
            quantity: qty,
            unit_price: price,
            total_price: totalPrice
        }]);
        if (itemError) throw itemError;

        // 3. زيادة الكمية وتحديث التكلفة من خلال الدالة
        const { error: processError } = await _supabase.rpc('process_purchase_item', {
            p_warehouse_id: warehouseId,
            p_ingredient_id: ingredientId,
            p_quantity: qty,
            p_unit_price: price
        });
        if (processError) throw processError;

        showToast('تم استلام الشحنة وتحديث المخزون وسعر التكلفة بنجاح');
        document.getElementById('purchase-qty').value = '';
        document.getElementById('purchase-unit-price').value = '';

        loadPurchaseHistory();
        if (typeof loadInventoryStock === 'function') loadInventoryStock();

    } catch (err) {
        console.error('Purchase error:', err);
        showToast('لم تكتمل عملية حفظ الفاتورة والمخزون: ' + (err.message || 'خطأ غير معروف'), 'error');
    }
}

async function loadPurchaseHistory() {
    try {
        const { data, error } = await _supabase
            .from('purchase_order_items')
            .select('*, purchase_orders(created_at, suppliers(name)), ingredients(name, unit)')
            .order('id', { ascending: false });

        const tbody = document.getElementById('purchase-history-body');
        if (!tbody) return;

        if (error) {
            console.error('Purchase history query error:', error);
            tbody.innerHTML = `<tr><td colspan="6" class="text-center p-4 text-red-500 font-bold">تعذر تحميل سجل المشتريات: ${error.message}</td></tr>`;
            showToast('تعذر تحميل سجل المشتريات: ' + error.message, 'error');
            return;
        }
        if (!data || data.length === 0) {
            tbody.innerHTML = `<tr><td colspan="6" class="text-center p-4 text-slate-400 font-bold">لا توجد فواتير مشتريات مسجلة</td></tr>`;
            return;
        }

        tbody.innerHTML = data.map(item => {
            const date = item.purchase_orders?.created_at ? new Date(item.purchase_orders.created_at).toLocaleDateString('ar-EG') : '-';
            const supplierName = item.purchase_orders?.suppliers?.name || 'مورد عام';
            return `
                <tr class="border-b border-slate-100 text-xs font-bold hover:bg-slate-50">
                    <td class="p-3 text-slate-500">${date}</td>
                    <td class="p-3 text-slate-800 font-extrabold">${supplierName}</td>
                    <td class="p-3 text-slate-700">${item.ingredients ? item.ingredients.name : ''}</td>
                    <td class="p-3 text-center text-blue-600">${item.quantity} ${item.ingredients ? item.ingredients.unit : ''}</td>
                    <td class="p-3">${formatCurrency(item.unit_price)}</td>
                    <td class="p-3 font-extrabold text-emerald-600">${formatCurrency(item.total_price)}</td>
                </tr>
            `;
        }).join('');

    } catch (err) {
        console.error('Purchase history error:', err);
    }
}
