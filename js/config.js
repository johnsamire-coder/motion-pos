// js/config.js - الإعدادات المركزية
// المحل: الصفحة جاية من كمبيوتر المحل (http) فبتكلم قاعدة بيانات المحل. النت: الموقع (https) بيكلم قاعدة بيانات النت.
const MOTION_LOCAL = location.protocol === 'http:';
const CLOUD_URL = 'https://qyrezfpzcuioxasxjhiq.supabase.co';
const CLOUD_SITE = 'https://motion-pos.vercel.app/';
const SUPABASE_URL = MOTION_LOCAL ? location.origin : CLOUD_URL;
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

// رسالة صغيرة فوق: "تم" بتختفي لوحدها بعد ثانيتين ونص، والغلط بيفضل لحد ما تقفله
function showToast(message, type = 'success') {
    let box = document.getElementById('ui-toasts');
    if (!box) {
        box = document.createElement('div');
        box.id = 'ui-toasts';
        box.className = 'fixed top-3 left-1/2 -translate-x-1/2 z-[70] flex flex-col gap-2 items-center w-[92%] max-w-md pointer-events-none';
        document.body.appendChild(box);
    }
    const err = type === 'error';
    const t = document.createElement('div');
    t.dir = 'rtl';
    t.className = `pointer-events-auto w-full rounded-2xl shadow-xl px-4 py-3 text-sm font-black flex justify-between items-start gap-3 text-white ${err ? 'bg-red-600' : 'bg-emerald-600'}`;
    const span = document.createElement('span');
    span.textContent = (err ? '❌ ' : '✅ ') + String(message || '');
    t.appendChild(span);
    const remove = () => t.remove();
    if (err) {
        const b = document.createElement('button');
        b.textContent = '✖';
        b.className = 'opacity-80 hover:opacity-100 shrink-0';
        b.onclick = remove;
        t.appendChild(b);
        setTimeout(remove, 20000);
    } else {
        setTimeout(remove, 2500);
    }
    box.appendChild(t);
    while (box.children.length > 4) box.firstChild.remove();
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
        if (String(error.message || '').includes('store_server_only')) {
            throw new Error('الفرع ده شغال من كمبيوتر المحل. فتح الوردية والطلبات وقفل اليوم بيتعملوا من المحل بس.');
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
    not_allowed: 'العملية دي مش مسموحة لدورك',
    owner_only: 'الإعدادات دي للمالك بس',
    pin_duplicate: 'الرقم السري ده مكرر لأكتر من موظف. كلم المالك يغيّره',
    store_server_only: 'الفرع ده شغال من كمبيوتر المحل. العملية دي بتتعمل من المحل بس',
    store_offline: 'النت في المحل واقف دلوقتي',
    conflict_not_found: 'التعارض ده اتقفل قبل كده',
    retry_failed: 'لسه مش نافع يتكتب. صلّح السبب الأول وجرّب تاني',
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
    phone_taken: 'رقم الموبايل ده متسجّل لعميل تاني',
    invalid_phone: 'رقم الموبايل غلط (لازم ٨ أرقام على الأقل)',
    invalid_date: 'التاريخ غلط',
    group_not_found: 'مجموعة الإضافات غير موجودة',
    modifier_not_found: 'الإضافة غير موجودة',
    invalid_selection_limits: 'أقل وأكتر عدد غلط: الأقل ميزيدش عن الأكتر، والأكتر ميزيدش عن عدد الإضافات',
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
// ---------------------------------------------------------------- واتساب
// رقم مصري 01xxxxxxxxx -> 201xxxxxxxxx
function waPhone(phone) {
    let p = String(phone || '').replace(/[^0-9]/g, '');
    if (p.startsWith('00')) p = p.slice(2);
    if (p.startsWith('0')) p = '20' + p.slice(1);
    return p;
}
// {الاسم} = اسم العميل، {المحل} = اسم الشركة من الإعدادات
function waFill(template, name) {
    const company = (typeof appSettings !== 'undefined' && appSettings && appSettings.general && appSettings.general.company_name) || '';
    return String(template || '').split('{الاسم}').join(name || '').split('{المحل}').join(company).trim();
}
function waLink(phone, text) {
    const p = waPhone(phone);
    if (!p) return '';
    return 'https://wa.me/' + p + (text ? '?text=' + encodeURIComponent(text) : '');
}
function waOpen(phone, text) {
    if (typeof navigator !== 'undefined' && navigator.onLine === false) {
        showToast('مفيش نت دلوقتي، الرسالة مش هتتبعت. ابعتها لما النت يرجع.', 'error');
        return false;
    }
    const url = waLink(phone, text);
    if (!url) { showToast('رقم الموبايل مش صحيح', 'error'); return false; }
    window.open(url, '_blank', 'noopener');
    return true;
}

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

// -----------------------------------------
// شاشة واحدة لكل عملية بدل الشبابيك الصغيرة ورا بعض
// fields: [{ key, label, type, value, options: [[value, label]], required, min, max, step, placeholder, addNew, list, help, full }]
//   type: text | number | money | select | date | textarea | check | pin | note
//   addNew: (select) يضيف "➕ جديد" في آخر القايمة، والقيمة اللي بتتكتب بترجع في الخانة نفسها و key + '_new' = true
//   list: (text) اقتراحات بتنزل وانت بتكتب، وتقدر تكتب غيرها
// Returns a Promise with the values, or null if cancelled. opts: { ok, danger, validate(values) => message | { key, msg } | null }
// -----------------------------------------
let uiFormSeq = 0;
function uiForm(title, fields, opts = {}) {
    return new Promise(resolve => {
        const id = 'uif' + (++uiFormSeq);
        const overlay = document.createElement('div');
        overlay.className = 'fixed inset-0 bg-slate-900/60 z-[60] flex items-start justify-center p-4 overflow-y-auto';
        const fieldHtml = (f, i) => {
            const fid = `${id}-${i}`;
            const v = f.value === undefined || f.value === null ? '' : f.value;
            const cls = 'w-full bg-slate-50 border p-2 rounded-xl text-sm font-bold focus:outline-none focus:border-blue-500';
            let input = '';
            if (f.type === 'note') return `<div class="${f.full === false ? '' : 'md:col-span-2'} text-[11px] font-bold text-slate-500 bg-slate-50 rounded-xl p-2">${f.html || uiEsc(f.label)}</div>`;
            if (f.type === 'select') {
                const opts2 = (f.options || []).map(([ov, ol]) => `<option value="${uiEsc(ov)}" ${String(ov) === String(v) ? 'selected' : ''}>${uiEsc(ol)}</option>`).join('');
                input = `<select id="${fid}" class="${cls}" ${f.addNew ? `onchange="document.getElementById('${fid}-new').classList.toggle('hidden', this.value !== '__new__')"` : ''}>
                    ${f.placeholder ? `<option value="">${uiEsc(f.placeholder)}</option>` : ''}${opts2}${f.addNew ? `<option value="__new__">➕ ${uiEsc(f.addNew)}</option>` : ''}</select>
                    ${f.addNew ? `<input id="${fid}-new" class="${cls} mt-1 hidden" placeholder="${uiEsc(f.addNew)}">` : ''}`;
            } else if (f.type === 'textarea') {
                input = `<textarea id="${fid}" rows="${f.rows || 2}" class="${cls}" placeholder="${uiEsc(f.placeholder || '')}">${uiEsc(v)}</textarea>`;
            } else if (f.type === 'check') {
                return `<label class="flex items-center gap-2 text-sm font-bold ${f.full ? 'md:col-span-2' : ''} py-1"><input id="${fid}" type="checkbox" class="w-5 h-5" ${v ? 'checked' : ''}> ${uiEsc(f.label)}</label>`;
            } else {
                const t = { number: 'number', money: 'number', date: 'date', pin: 'password' }[f.type] || 'text';
                const extra = f.type === 'pin' ? 'inputmode="numeric" maxlength="4" autocomplete="off"' : ((f.type === 'number' || f.type === 'money') ? `inputmode="decimal" step="${f.step || 'any'}" ${f.min !== undefined ? `min="${f.min}"` : ''}` : '');
                input = `<input id="${fid}" type="${t}" ${extra} value="${uiEsc(v)}" placeholder="${uiEsc(f.placeholder || '')}" class="${cls} ${f.type === 'pin' ? 'text-center tracking-widest' : ''}" ${f.list ? `list="${fid}-list"` : ''}>
                    ${f.list ? `<datalist id="${fid}-list">${f.list.map(x => `<option value="${uiEsc(x)}">`).join('')}</datalist>` : ''}`;
            }
            return `<div class="${f.full ? 'md:col-span-2' : ''}"><label for="${fid}" class="block text-xs font-black text-slate-600 mb-1">${uiEsc(f.label)}${f.required ? ' <span class="text-red-500">*</span>' : ''}</label>${input}
                ${f.help ? `<p class="text-[10px] text-slate-400 font-bold mt-0.5">${uiEsc(f.help)}</p>` : ''}<p id="${fid}-err" class="text-[11px] text-red-600 font-bold mt-0.5 hidden"></p></div>`;
        };
        overlay.innerHTML = `<div class="bg-white rounded-3xl shadow-2xl w-full ${fields.length > 4 ? 'max-w-2xl' : 'max-w-md'} p-5 my-8 text-right" dir="rtl">
            <h3 class="font-black text-base text-slate-800 mb-3 border-b pb-2">${uiEsc(title)}</h3>
            <div class="grid grid-cols-1 ${fields.length > 4 ? 'md:grid-cols-2' : ''} gap-3">${fields.map(fieldHtml).join('')}</div>
            <p id="${id}-err" class="text-xs text-red-600 font-black mt-3 hidden"></p>
            <div class="flex gap-2 mt-4"><button data-ok class="flex-1 ${opts.danger ? 'bg-red-600 hover:bg-red-700' : 'bg-blue-600 hover:bg-blue-700'} text-white py-2.5 rounded-xl font-black text-sm">${uiEsc(opts.ok || 'حفظ')}</button>
            <button data-cancel class="flex-1 bg-slate-100 text-slate-700 py-2.5 rounded-xl font-black text-sm hover:bg-slate-200">إلغاء</button></div></div>`;
        document.body.appendChild(overlay);
        const done = val => { overlay.remove(); document.removeEventListener('keydown', onKey); resolve(val); };
        const showErr = (key, msg) => {
            const i = fields.findIndex(f => f.key === key);
            const el = document.getElementById(i >= 0 ? `${id}-${i}-err` : `${id}-err`) || document.getElementById(`${id}-err`);
            el.textContent = msg; el.classList.remove('hidden');
            const inp = document.getElementById(`${id}-${i}`);
            if (inp) inp.focus();
        };
        const submit = () => {
            overlay.querySelectorAll('[id$="-err"]').forEach(e => e.classList.add('hidden'));
            const values = {};
            for (let i = 0; i < fields.length; i++) {
                const f = fields[i];
                if (f.type === 'note' || !f.key) continue;
                const el = document.getElementById(`${id}-${i}`);
                let v;
                if (f.type === 'check') v = el.checked;
                else if (f.type === 'select' && el.value === '__new__') {
                    v = document.getElementById(`${id}-${i}-new`).value.trim();
                    if (!v) return showErr(f.key, 'اكتب الجديد');
                    values[f.key + '_new'] = true;
                } else v = String(el.value).trim();
                if (f.required && (v === '' || v === null)) return showErr(f.key, 'الخانة دي لازم تتملى');
                if ((f.type === 'number' || f.type === 'money') && v !== '') {
                    const n = Number(v);
                    if (!Number.isFinite(n)) return showErr(f.key, 'اكتب رقم صحيح');
                    if (f.min !== undefined && n < f.min) return showErr(f.key, `أقل قيمة ${f.min}`);
                    if (f.max !== undefined && n > f.max) return showErr(f.key, `أكبر قيمة ${f.max}`);
                    v = f.type === 'money' ? round2(n) : n;
                }
                if ((f.type === 'number' || f.type === 'money') && v === '') v = null;
                if (f.type === 'pin' && v !== '' && !/^[0-9]{4}$/.test(v)) return showErr(f.key, 'الرقم السري 4 أرقام');
                values[f.key] = v;
            }
            if (typeof opts.validate === 'function') {
                const r = opts.validate(values);
                if (r) return typeof r === 'string' ? showErr(null, r) : showErr(r.key, r.msg);
            }
            done(values);
        };
        const onKey = e => {
            if (e.key === 'Escape') done(null);
            if (e.key === 'Enter' && e.target && e.target.tagName !== 'TEXTAREA' && overlay.contains(e.target)) { e.preventDefault(); submit(); }
        };
        document.addEventListener('keydown', onKey);
        overlay.querySelector('[data-ok]').onclick = submit;
        overlay.querySelector('[data-cancel]').onclick = () => done(null);
        setTimeout(() => { const first = overlay.querySelector('input:not([type=checkbox]), select, textarea'); if (first) first.focus(); }, 50);
    });
}

// سؤال نعم / لا في شاشة صغيرة بدل confirm
function uiConfirm(message, okLabel = 'موافق', danger = false) {
    return uiForm('تأكيد', [{ type: 'note', html: `<p class="text-sm text-slate-800 font-bold whitespace-pre-line">${uiEsc(message)}</p>` }], { ok: okLabel, danger })
        .then(v => v !== null);
}

const UI_BOX_OPTIONS = keys => keys.map(k => [k, UI_BOX_NAMES[k]]);
