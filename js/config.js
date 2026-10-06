// js/config.js - الإعدادات المركزية
const SUPABASE_URL = 'https://qyrezfpzcuioxasxjhiq.supabase.co';
const SUPABASE_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InF5cmV6ZnB6Y3Vpb3hhc3hqaGlxIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTExNzY2ODAsImV4cCI6MjEwNjc1MjY4MH0._BrruPh4V6IUKa78u5CDJl-I4cRmU0RvZf5MsmAUXTQ';
const _supabase = supabase.createClient(SUPABASE_URL, SUPABASE_KEY);

let currentUser = null;
let currentBranch = null;
let taxSettings = { 
    vat_percentage: 14.00, 
    service_charge_percentage: 12.00,
    enable_vat: true,  // الضريبة اختيارية
    enable_service: true, // الخدمة اختيارية
    is_vat_inclusive: false, // الأسعار شاملة الضريبة؟ (من إعدادات الفرع)
    is_service_taxable: true // الضريبة بتتحسب على الخدمة؟ (من إعدادات الفرع)
};

function formatCurrency(amount) {
    return (parseFloat(amount) || 0).toFixed(2) + ' ج.م';
}

function showToast(message, type = 'success') {
    alert((type === 'error' ? '❌ ' : '✅ ') + message);
}

function populateSelectOptions(selectId, items, placeholderText, emptyText, labelBuilder) {
    const select = document.getElementById(selectId);
    if (!select) return 0;

    const rows = Array.isArray(items) ? items.filter(item => item && item.id !== undefined && item.id !== null) : [];
    const previousValue = select.value;
    select.replaceChildren();

    const placeholder = document.createElement('option');
    placeholder.value = '';
    placeholder.textContent = rows.length ? placeholderText : emptyText;
    select.appendChild(placeholder);

    rows.forEach(item => {
        const option = document.createElement('option');
        option.value = String(item.id);
        option.textContent = String(typeof labelBuilder === 'function' ? labelBuilder(item) : (item.name || ''));
        select.appendChild(option);
    });

    if (previousValue && rows.some(item => String(item.id) === previousValue)) {
        select.value = previousValue;
    }
    return rows.length;
}

// -----------------------------------------
// النداء على دوال السيرفر: كل عملية حساسة بتتبعت معاها تذكرة الوردية
// -----------------------------------------
async function serverRpc(name, params = {}) {
    const { data, error } = await _supabase.rpc(name, { p_token: (typeof staffSessionToken !== 'undefined' ? staffSessionToken : null), ...params });
    if (error) {
        if (String(error.message || '').includes('session_invalid')) {
            throw new Error('انتهت صلاحية الوردية. اخرج وادخل تاني برقمك.');
        }
        throw error;
    }
    return data;
}

const SERVER_REASON_MESSAGES = {
    order_not_found: 'الطلب غير موجود في الفرع ده',
    order_not_open: 'الطلب ده مقفول أو ملغي',
    empty_order: 'الطلب مفيهوش أصناف',
    payment_mismatch: 'مجموع الدفعات لازم يساوي إجمالي الفاتورة بالظبط',
    invalid_payments: 'بيانات الدفع غير صحيحة',
    invalid_payment_method: 'طريقة الدفع غير صحيحة',
    invalid_payment_amount: 'مبلغ الدفع غير صحيح (أرقام موجبة وبحد أقصى قرشين بعد العلامة)',
    invalid_tip: 'مبلغ الإكرامية غير صحيح',
    invalid_tip_staff: 'اختار موظف الإكرامية من موظفين الفرع',
    tip_needs_cash_or_card: 'الإكرامية لازم تتدفع كاش أو كارت، مش آجل',
    credit_needs_customer: 'الدفع الآجل محتاج تختار العميل الأول',
    customer_not_allowed_credit: 'العميل ده مش مسموح له بالآجل',
    credit_limit_exceeded: 'العميل هيعدّي الحد المسموح له في الآجل',
    order_has_old_payments: 'الطلب عليه دفعات قديمة. راجع المدير',
    order_has_payments: 'الطلب عليه دفعات',
    manager_pin: 'رقم المدير غير صحيح، أو الموافقة متوقفة مؤقتاً بسبب محاولات خاطئة كثيرة',
    bad_reason: 'سبب الإلغاء غير صحيح',
    item_not_found: 'الصنف غير موجود أو الطلب مقفول',
    discount_not_found: 'الخصم غير موجود',
    invalid_discount: 'الخصم ده متسجّل غلط في الإعدادات',
    invalid_amount: 'المبلغ غير صحيح',
    table_not_available: 'الطاولة دي مش فاضية',
    table_not_in_branch: 'الطاولة مش تبع الفرع ده',
    table_area_mismatch: 'الطاولة مش في المنطقة المختارة',
    area_not_in_branch: 'المنطقة مش تبع الفرع ده',
    same_table: 'الطلب على نفس الطاولة أصلاً',
    source_not_open: 'الطلب اللي هيتدمج مقفول',
    target_not_open: 'الطلب الحالي مقفول',
    invalid_orders: 'اختيار الطلبات غلط',
    nothing_left: 'لازم يفضل صنف واحد على الأقل في الطلب الأصلي',
    quantity_too_big: 'الكمية أكبر من الموجود',
    duplicate_item: 'الصنف متكرر في التقسيم',
    invalid_items: 'بيانات الأصناف غير صحيحة',
    waiter_not_in_branch: 'الويتر مش من موظفين الفرع',
    customer_not_in_company: 'العميل غير موجود',
    invalid_guest_count: 'عدد الضيوف غير صحيح',
    invalid_order_type: 'نوع الطلب غير صحيح',
    invalid_item_count: 'عدد الأصناف غير صحيح',
    invalid_quantity: 'الكمية غير صحيحة',
    invalid_product_id: 'صنف غير صحيح',
    product_not_found: 'الصنف غير موجود',
    product_not_available: 'الصنف ده موقوف',
    product_not_in_branch_brand: 'الصنف مش من منيو الفرع ده',
    required_modifier_missing: 'في إضافة لازم تختارها للصنف',
    too_many_modifiers: 'اخترت إضافات أكتر من المسموح',
    modifier_not_for_product: 'إضافة مش تبع الصنف',
    invalid_modifier_ids: 'إضافات غير صحيحة',
    duplicate_modifier_id: 'إضافة متكررة',
    item_notes_too_long: 'الملاحظة طويلة جداً',
    item_total_out_of_range: 'المبلغ كبير جداً',
    branch_brand_not_configured: 'الفرع مش مربوط ببراند',
    branch_not_found: 'الفرع غير موجود',
    session_scope_missing: 'حساب الموظف مش مربوط بفرع',
    invalid_input: 'بيانات غير صحيحة',
    invalid_status: 'حالة غير صحيحة',
    not_allowed: 'العملية دي للمدير أو المالك بس',
    unknown_action: 'عملية غير معروفة',
    invalid_name: 'الاسم غير صحيح',
    invalid_price: 'السعر غير صحيح',
    invalid_category: 'القسم غير صحيح',
    invalid_value: 'قيمة غير صحيحة',
    invalid_branch: 'الفرع غير صحيح',
    invalid_percentage: 'النسبة لازم تكون من 0 لـ 100',
    invalid_capacity: 'السعة لازم تكون رقم من 1 لـ 999',
    table_not_found: 'الطاولة غير موجودة',
    invalid_table_number: 'رقم الطاولة غير صحيح',
    area_not_found: 'المنطقة غير موجودة',
    table_has_orders: 'مينفعش تمسح طاولة عليها طلبات سابقة'
};

function serverReasonMessage(res, fallback) {
    const reason = res && res.reason;
    return SERVER_REASON_MESSAGES[reason] || fallback || ('تعذر تنفيذ العملية' + (reason ? ` (${reason})` : ''));
}

function round2(value) {
    return Math.round((Number(value) || 0) * 100) / 100;
}
