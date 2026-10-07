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
        if (String(error.message || '').includes('not_allowed')) {
            throw new Error('العملية دي مش مسموحة لدورك.');
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
    table_has_orders: 'مينفعش تمسح طاولة عليها طلبات سابقة',
    no_open_shift: 'لازم تفتح ورديتك الأول من شاشة "الوردية"',
    shift_already_open: 'عندك وردية مفتوحة بالفعل',
    shift_not_found: 'الوردية غير موجودة',
    not_enough_cash: 'المبلغ أكبر من الموجود في الدرج',
    invalid_destination: 'الجهة غير صحيحة',
    reason_required: 'لازم تكتب السبب أو الوصف',
    open_shifts_exist: 'في ورديات لسه مفتوحة. لازم تتقفل الأول',
    day_already_closed: 'اليوم ده اتقفل قبل كده',
    warehouse_not_allowed: 'المخزن ده مش تبع فرعك',
    ingredient_not_found: 'الخامة غير موجودة',
    invalid_warehouses: 'اختيار المخازن غلط',
    transfer_not_found: 'التحويل غير موجود',
    wrong_transfer_status: 'الخطوة دي مش مناسبة لحالة التحويل',
    invalid_role: 'الدور غير صحيح',
    staff_not_found: 'الموظف غير موجود أو مش تبعك',
    cannot_disable_self: 'مينفعش توقف نفسك',
    invalid_pin: 'الرقم السري لازم يكون 4 أرقام',
    pin_taken: 'الرقم السري ده مستخدم لموظف تاني. اختار رقم تاني',
    wrong_pin: 'الرقم السري غلط',
    locked: 'متوقف مؤقتاً بسبب محاولات غلط كتير. استنى 10 دقايق',
    payroll_not_draft: 'المرتبات دي اتعتمدت، مينفعش تتعدل',
    payroll_not_approved: 'لازم تعتمد المرتبات الأول',
    not_found: 'غير موجود',
    owner_pin_required: 'المبلغ فوق حد المدير، ومحتاج رقم المالك',
    invalid_account: 'الحساب غير صحيح',
    recurring_already_paid: 'المصروف المتكرر ده اتصرف الشهر ده',
    no_custody: 'الموظف ده معهوش عهدة',
    custody_amount_mismatch: 'المجموع أكبر من العهدة اللي معاه',
    supplier_not_found: 'المورد غير موجود',
    po_not_found: 'أمر الشراء غير موجود',
    wrong_po_status: 'الخطوة دي مش مناسبة لحالة أمر الشراء',
    invoice_duplicate: 'رقم الفاتورة ده متسجل قبل كده للمورد ده',
    nothing_to_invoice: 'مفيش بضاعة مستلمة لسه من غير فاتورة',
    invalid_period: 'الفترة غلط (لازم البداية قبل النهاية، وبحد أقصى سنتين)',
    not_balanced: 'القيد مش متوازن: المدين لازم يساوي الدائن',
    cannot_reverse: 'القيد ده مينفعش يتعكس من هنا (القيود اللي السيستم بيعملها بتتعكس من شاشتها)',
    value_too_long: 'القيمة طويلة جداً',
    invalid_logo: 'اللوجو لازم يكون صورة (PNG أو JPG أو WEBP أو SVG)',
    qr_disabled: 'الخدمة دي متوقفة من الإعدادات',
    too_many: 'طلبات كتير. حاول بعد شوية',
    invalid_status: 'حالة غير صحيحة'
};

// إعدادات الشركة والشاشات (بتتحمّل بعد الدخول)
let appSettings = null;
async function loadAppSettings() {
    try {
        const res = await serverRpc('app_settings_get_secure');
        if (res && res.ok) {
            appSettings = res.settings;
            const g = appSettings.general || {};
            const logo = document.getElementById('main-brand-logo');
            if (logo) logo.innerHTML = g.logo ? `<img src="${uiEsc(g.logo)}" class="h-8 max-w-[120px] object-contain">` : uiEsc(g.company_name || 'Motion POS');
            if (g.company_name) document.title = g.company_name;
        }
    } catch (err) {
        console.error('Settings load error:', err);
    }
    return appSettings;
}

function serverReasonMessage(res, fallback) {
    const reason = res && res.reason;
    return SERVER_REASON_MESSAGES[reason] || fallback || ('تعذر تنفيذ العملية' + (reason ? ` (${reason})` : ''));
}

function round2(value) {
    return Math.round((Number(value) || 0) * 100) / 100;
}

// -----------------------------------------
// أدوات الشاشات (جداول، تواريخ، نداء السيرفر مع رسالة واضحة)
// -----------------------------------------
function uiEsc(value) {
    return String(value ?? '').replace(/[&<>"']/g, ch => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[ch]));
}

function uiDate(ts) {
    if (!ts) return '-';
    const d = new Date(ts);
    return d.toLocaleDateString('ar-EG') + ' ' + d.toLocaleTimeString('ar-EG', { hour: '2-digit', minute: '2-digit' });
}

function uiToday(offsetDays = 0) {
    const d = new Date(Date.now() + offsetDays * 86400000);
    return d.toISOString().slice(0, 10);
}

// columns: [{ label, key }] or [{ label, render: row => html }]
function uiTable(rows, columns, emptyText = 'لا توجد بيانات') {
    if (!rows || rows.length === 0) return `<p class="text-center text-slate-400 font-bold text-xs py-6">${uiEsc(emptyText)}</p>`;
    const head = columns.map(c => `<th class="p-2 text-[11px] text-slate-500 font-black border-b">${uiEsc(c.label)}</th>`).join('');
    const body = rows.map(r => '<tr class="border-b border-slate-100 text-xs font-bold hover:bg-slate-50">'
        + columns.map(c => `<td class="p-2">${c.render ? c.render(r) : uiEsc(r[c.key])}</td>`).join('') + '</tr>').join('');
    return `<div class="overflow-x-auto"><table class="w-full text-right"><thead><tr>${head}</tr></thead><tbody>${body}</tbody></table></div>`;
}

function uiTabs(groupId, tabs, active, onClickName) {
    return '<div class="flex flex-wrap gap-1.5 mb-4">' + tabs.map(([key, label]) =>
        `<button onclick="${onClickName}('${key}')" class="px-3 py-1.5 rounded-xl text-xs font-black ${key === active ? 'bg-blue-600 text-white shadow' : 'bg-slate-100 text-slate-600 hover:bg-slate-200'}">${uiEsc(label)}</button>`).join('') + '</div>';
}

function uiCard(title, inner, actionsHtml = '') {
    return `<section class="bg-white p-5 rounded-2xl shadow-sm border border-slate-200 mb-4">
        <div class="flex flex-wrap justify-between items-center gap-2 mb-3 border-b pb-2"><h3 class="font-black text-sm text-slate-800">${uiEsc(title)}</h3><div class="flex flex-wrap gap-2">${actionsHtml}</div></div>
        ${inner}</section>`;
}

function uiBtn(label, onclick, color = 'blue') {
    const colors = { blue: 'bg-blue-600 text-white hover:bg-blue-700', red: 'bg-red-600 text-white hover:bg-red-700',
        green: 'bg-emerald-600 text-white hover:bg-emerald-700', gray: 'bg-slate-100 text-slate-700 hover:bg-slate-200',
        amber: 'bg-amber-500 text-white hover:bg-amber-600' };
    return `<button onclick="${onclick}" class="px-3 py-1.5 rounded-xl text-xs font-black ${colors[color] || colors.blue}">${uiEsc(label)}</button>`;
}

function uiInputClass() { return 'bg-slate-50 border p-2 rounded-xl text-xs font-bold'; }

function uiOptions(items, valueKey, labelFn, placeholder) {
    return (placeholder ? `<option value="">${uiEsc(placeholder)}</option>` : '')
        + (items || []).map(i => `<option value="${uiEsc(i[valueKey])}">${uiEsc(labelFn(i))}</option>`).join('');
}

// Asks the manager PIN through the same small window the cashier uses
function uiAskPin(message) {
    if (typeof askManagerPin === 'function') return askManagerPin(message);
    return Promise.resolve(prompt(message));
}

// Call a server function; on refusal show the reason. Returns the result or null.
// If the server asks for the owner PIN, ask for it and try once more.
async function uiCall(name, params, okMessage, ownerPinParam) {
    try {
        let res = await serverRpc(name, params);
        if (res && res.ok === false && res.reason === 'owner_pin_required' && ownerPinParam) {
            const pin = await uiAskPin(`المبلغ فوق حد المدير (${formatCurrency(res.limit)}). أدخل رقم المالك:`);
            if (!pin) return null;
            res = await serverRpc(name, { ...params, [ownerPinParam]: String(pin).trim() });
        }
        if (!res || res.ok === false) {
            showToast(serverReasonMessage(res, 'تعذر تنفيذ العملية'), 'error');
            return null;
        }
        if (okMessage) showToast(okMessage);
        return res;
    } catch (err) {
        console.error(name, err);
        showToast((err && err.message) || 'حدث خطأ أثناء الاتصال بالسيرفر', 'error');
        return null;
    }
}

const UI_BOX_NAMES = { main_cash: 'الخزينة الرئيسية', bank: 'البنك', owner: 'صاحب المحل', drawer: 'درج الكاشير' };
function uiPickBox(title, allowed) {
    const list = allowed.map((k, i) => `${i + 1}. ${UI_BOX_NAMES[k]}`).join('\n');
    const pick = prompt(title + '\n' + list, '1');
    if (pick === null) return null;
    const key = allowed[parseInt(pick, 10) - 1];
    if (!key) { showToast('اختيار غير صحيح', 'error'); return null; }
    return key;
}

function uiAskAmount(title, defaultValue = '') {
    const v = prompt(title, defaultValue);
    if (v === null) return null;
    const n = Number(v);
    if (!Number.isFinite(n) || n < 0) { showToast('المبلغ غير صحيح', 'error'); return null; }
    return round2(n);
}
