// js/settings2.js - باقي الإعدادات: الشركة واللوجو، الطباعة، الكاشير، المطبخ والأماكن، الويتر والـ QR،
// الوردية والمخازن والموظفين، الشغل من غير نت، الوصفات والخامات، القوايم، طرق الدفع والضرايب.
// الأقسام دي بتتضاف جنب أقسام الإعدادات القديمة (الضرائب والطاولات، الفروع والمخازن، المنيو).

const SET2_SECTIONS = [['general', 'الشركة والشعار'], ['receipt', 'الطباعة والفاتورة'], ['poscfg', 'إعدادات الكاشير'], ['kdscfg', 'المطبخ والأماكن'],
    ['qr', 'الويتر وقائمة الـ QR'], ['loyalty', 'خصم العملاء الدائمين والسوشيال'], ['work', 'الوردية والمخازن والموظفون'], ['offline', 'العمل بدون إنترنت'], ['recipes', 'الوصفات والخامات'], ['modifiers', 'الإضافات'],
    ['lists', 'الخصومات والأسباب والمناطق'], ['payacc', 'طرق الدفع والضرايب'], ['reset', '🧹 تصفير البرنامج']];

let set2 = { settings: null, data: null, recipeProduct: '', recipeLines: [], products: [] };

const _origInitSettingsModule = initSettingsModule;
initSettingsModule = async function () {
    await _origInitSettingsModule();
    await initSettings2();
};

function set2Inject() {
    const aside = document.querySelector('#view-settings-workspace aside');
    const content = document.querySelector('#view-settings-workspace .lg\\:col-span-3');
    if (!aside || !content || document.getElementById('btn-set-general')) return;
    SET2_SECTIONS.forEach(([k, label]) => {
        if (k === 'reset' && String(currentUser?.roles?.name || '') !== 'owner') return;
        const b = document.createElement('button');
        b.id = 'btn-set-' + k;
        b.className = 'set-nav-btn w-full text-right px-4 py-3 rounded-xl text-xs font-black bg-slate-50 text-slate-600 border border-slate-100 mb-2';
        b.textContent = label;
        b.onclick = () => switchSettingsSection(k);
        aside.appendChild(b);
        const d = document.createElement('div');
        d.id = 'set-section-' + k;
        d.className = 'set-section hidden space-y-4';
        content.appendChild(d);
    });
}

async function initSettings2() {
    set2Inject();
    const [a, b, p] = await Promise.all([uiCall('app_settings_get_secure', {}), uiCall('settings2_secure', { p_action: 'get', p_data: null }),
        _supabase.from('products').select('id, name, price').order('name')]);
    if (!a || !b) return;
    set2.settings = a.settings;
    set2.data = b;
    set2.products = p.data || [];
    appSettings = a.settings;
    set2RenderAll();
}

function set2RenderAll() {
    set2Form('general', 'الشركة', [['company_name', 'اسم الشركة', 'text'], ['address', 'العنوان', 'text'], ['phone', 'التليفون', 'text'],
        ['tax_number', 'الرقم الضريبي', 'text'], ['commercial_register', 'السجل التجاري', 'text'], ['currency', 'العملة', 'text'],
        ['day_start_hour', 'يوم العمل يبدأ الساعة كم صباحًا؟ (للتقارير: إذا كان المحل يغلق 7 صباحًا اكتب 8، و0 = من 12 ليلًا)', 'number']],
        `<div class="mt-3 border-t pt-3"><p class="text-xs font-black mb-2">الشعار (يظهر في الشاشة والفاتورة والتقارير والقائمة)</p>
         <div class="flex flex-wrap items-center gap-3"><div id="set2-logo-preview">${set2.settings.general.logo ? `<img src="${uiEsc(set2.settings.general.logo)}" class="h-16 max-w-[160px] object-contain border rounded-xl p-1">` : '<span class="text-xs text-slate-400">لا يوجد شعار</span>'}</div>
         <input type="file" accept="image/png,image/jpeg,image/webp" onchange="set2PickLogo(this)" class="text-xs">
         ${set2.settings.general.logo ? uiBtn('احذف الشعار', "set2Save('general', { logo: '' })", 'gray') : ''}</div></div>`, 'الإعدادات العامة (للمالك فقط)');
    set2Form('receipt', 'الطباعة والفاتورة', [['header', 'سطر فوق الفاتورة', 'text'], ['footer', 'سطر تحت الفاتورة (رسالة شكر)', 'text'],
        ['show_logo', 'الشعار يظهر في الفاتورة', 'bool'], ['show_tax_number', 'الرقم الضريبي يظهر في الفاتورة', 'bool'],
        ['paper_mm', 'مقاس الورق', 'select', [[58, '58 مم'], [80, '80 مم']]], ['copies', 'عدد النسخ', 'number'],
        ['auto_print_after_pay', 'طباعة الفاتورة أوتوماتيك بعد الدفع', 'bool'],
        ['show_feedback_qr', 'رمز QR لصفحة الشكاوى والاقتراحات في آخر الفاتورة', 'bool']],
        '<p class="text-[11px] text-slate-500 font-bold mt-2">تُطبع ورقة المطبخ والبار من شاشة التحضير ذاتها بزر 🖨️ على كل طلب.</p>');
    set2Form('whatsapp', 'رسائل واتساب', [['customer_message', 'الرسالة التي تُرسَل من شاشة العملاء (زر 💬)', 'text'],
        ['thanks_enabled', 'بعد الدفع: يظهر للكاشير زر «ابعت رسالة شكر» إذا كان الطلب لعميل له رقم هاتف', 'bool'],
        ['thanks_message', 'رسالة الشكر بعد الدفع', 'text']],
        '<p class="text-[11px] text-slate-500 font-bold mt-2">اكتب <b>{الاسم}</b> مكان اسم العميل، و<b>{المحل}</b> مكان اسم الشركة. يفتح واتساب والرسالة جاهزة، وأنت تضغط إرسال. يجب أن يكون واتساب المحل مفتوحًا على الجهاز ومتصلًا بالإنترنت.</p>',
        '', 'receipt', true);
    set2Form('payinfo', '💳 أرقام الدفع (إنستاباي والمحفظة)', [['instapay', 'عنوان أو رقم إنستاباي (مثلاً name@instapay أو رقم الهاتف)', 'text'],
        ['instapay_link', 'رابط الدفع بإنستاباي (اختياري، يظهر كرمز QR على الفاتورة)', 'text'],
        ['wallet', 'رقم المحفظة', 'text'], ['wallet_name', 'نوع المحفظة (فودافون كاش، اتصالات كاش...)', 'text'],
        ['show_on_receipt', 'تظهر على الفاتورة والحساب', 'bool'], ['show_on_menu', 'تظهر في قائمة الـ QR', 'bool']],
        '<p class="text-[11px] text-slate-500 font-bold mt-2">يمكن للعميل التحويل على هذه الأرقام، ويُغلق الكاشير الطلب بطريقة الدفع «إنستاباي» أو «محفظة» بعد التأكد من وصول المبلغ.</p>',
        '', 'receipt', true);
    set2Form('pos', 'إعدادات الكاشير', [['order_types', 'أنواع الطلبات المفعّلة', 'multi', [['dine_in', 'صالة'], ['takeaway', 'تيك أواي'], ['delivery', 'توصيل'], ['pickup', 'استلام']]],
        ['payment_methods', 'طرق الدفع المفعّلة', 'multi', [['cash', 'كاش'], ['card', 'كارت'], ['instapay', 'إنستاباي'], ['wallet', 'محفظة'], ['on_account', 'آجل']]],
        ['require_waiter', 'يجب اختيار الويتر قبل الإرسال للمطبخ', 'bool'],
        ['quick_notes', 'الملاحظات الجاهزة التي تظهر للكاشير (كل ملاحظة في سطر، مثلاً: بدون بصل)', 'lines']], '', '', 'poscfg');
    set2Form('hospitality', '🎁 الضيافة', [['enabled', 'تفعيل الضيافة (زر 🎁 في شاشة الدفع)', 'bool'],
        ['manager_daily_limit', 'حد موافقة المدير اليومي بالجنيه بسعر القائمة (0 = المالك فقط)', 'number'], ['auto_print', 'طباعة ورقة الضيافة تلقائيًا', 'bool']],
        '<p class="text-[11px] text-slate-500 font-bold mt-2">يُغلق طلب الضيافة بدون مبالغ، وتُخصم الخامات من المخزن، ويُحمَل القيد بالتكلفة: المالك والموظفين على مصروف ضيافة 6600، والأهل على جارٍ صاحب المحل 3300، والدعاية على 6300. التقرير في التقارير ← الضيافة.</p>', '', 'poscfg', true);
    set2Form('kds', 'شاشة التحضير', [['stations', 'الأماكن المفعّلة', 'multi', [['kitchen', 'مطبخ'], ['bar', 'بار'], ['shisha', 'شيشة']]],
        ['warn_kitchen_minutes', 'المطبخ: يُعتبر الطلب متأخرًا بعد كم دقيقة', 'number'], ['warn_bar_minutes', 'البار: يُعتبر متأخرًا بعد كم دقيقة', 'number'],
        ['warn_shisha_minutes', 'الشيشة: يُعتبر متأخرًا بعد كم دقيقة', 'number'], ['sound', 'صوت تنبيه للطلب الجديد', 'bool'], ['refresh_seconds', 'مدة التحديث بالثواني', 'number'],
        ['rush_kitchen_orders', '🔥 زحمة المطبخ: عدد الطلبات المفتوحة الذي يبدأ لديه الزحام (0 = بدون)', 'number'], ['rush_kitchen_minutes', '🔥 دقائق إضافية في وقت تحضير المطبخ عند الزحام', 'number'],
        ['rush_bar_orders', '🔥 زحمة البار: عدد الطلبات المفتوحة الذي يبدأ لديه الزحام (0 = بدون)', 'number'], ['rush_bar_minutes', '🔥 دقائق إضافية في وقت تحضير البار عند الزحام', 'number'],
        ['rush_shisha_orders', '🔥 زحام الشيشة: عدد الطلبات المفتوحة الذي يبدأ لديه الزحام (0 = بدون)', 'number'], ['rush_shisha_minutes', '🔥 زيادة زمن التحضير بالدقائق عند زحام الشيشة', 'number']],
        `<p class="text-[11px] text-slate-500 font-bold mt-2">🔥 الزحام: عند وصول عدد الطلبات المفتوحة في المحطة إلى هذا الرقم، يُضاف هذا القدر من الدقائق إلى أي طلب جديد قبل اعتباره متأخرًا، وتكتب الشاشة "زحمة". مثال: البار 8 طلبات و5 دقائق.</p>
         <div class="mt-4 border-t pt-3"><p class="text-xs font-black mb-2">كل قسم في القائمة يُرسل إلى محطة تحضير</p>
         ${uiTable(set2.data.categories, [{ label: 'القسم', key: 'name' }, { label: 'المكان', render: c => `<select onchange="set2Station('${c.id}', this.value)" class="${uiInputClass()}">
            ${[['kitchen', 'مطبخ'], ['bar', 'بار'], ['shisha', 'شيشة']].filter(([v]) => (set2.settings.kds.stations || []).includes(v) || c.station === v).map(([v, l]) => `<option value="${v}" ${c.station === v ? 'selected' : ''}>${l}${(set2.settings.kds.stations || []).includes(v) ? '' : ' (مغلق! لن تظهر الأصناف)'}</option>`).join('')}</select>` }], 'لا توجد أقسام')}</div>`, '', 'kdscfg');
    set2Form('waiter_qr', 'الويتر وقائمة الـ QR', [['qr_enabled', 'تفعيل قائمة الـ QR', 'bool'], ['qr_ordering', 'يستطيع العميل الطلب بنفسه من القائمة (والويتر يؤكد)', 'bool'],
        ['qr_call_waiter', 'زر نداء الويتر', 'bool'], ['qr_request_bill', 'زر طلب الحساب', 'bool'], ['qr_show_prices', 'الأسعار تظهر في القائمة', 'bool'],
        ['qr_welcome', 'جملة الترحيب أول القائمة', 'text'],
        ['qr_privacy_note', 'الجملة التي تطمئن العميل عند طلب اسمه ورقمه وتاريخ ميلاده', 'text']],
        `<div class="mt-4 border-t pt-3">${uiBtn('طباعة أكواد الطاولات (QR)', 'set2PrintQr()', 'blue')}
         <p class="text-[11px] text-slate-500 font-bold mt-2">لكل طاولة كود مختلف. اطبع اللوحات وضع كل كود على طاولته.</p></div>`, '', 'qr');
    set2Form('loyalty', '⭐ خصم الولاء (للعميل الدائم)', [['enabled', 'تفعيل', 'bool'], ['min_spent', 'إذا اشترى بمبلغ (جنيه) أو أكثر', 'number'],
        ['period_days', 'عدد الأيام السابقة (365 = سنة)', 'number'], ['percent', 'نسبة الخصم %', 'number'], ['label', 'اسم الخصم على الفاتورة', 'text']],
        '<p class="text-[11px] text-slate-500 font-bold mt-2">يُطبَّق تلقائيًا عند اختيار الكاشير للعميل بالهاتف (أو طلب العميل من QR)، ويظهر في الفاتورة كسطر مستقل. يُحسب من الطلبات المدفوعة فقط.</p>', '', 'loyalty');
    set2Form('social', '📣 السوشيال والشكاوى', [['facebook_url', 'رابط صفحة الفيسبوك', 'text'], ['instagram_url', 'رابط الإنستجرام', 'text'],
        ['feedback_enabled', 'تفعيل صفحة الشكاوى والاقتراحات', 'bool'], ['links_in_thanks', 'تُرسل هذه الروابط مع رسالة الشكر على واتساب بعد الدفع', 'bool'],
        ['feedback_intro', 'العبارة الافتتاحية في صفحة الشكاوى', 'text']],
        `<p class="text-[11px] text-slate-500 font-bold mt-2">صفحة الشكاوى: <span class="text-blue-700 select-all">${uiEsc((typeof appLinks !== 'undefined' && appLinks.feedback) || 'تظهر بعد الحفظ')}</span> | تصل الشكاوى للمدير في تبويب "الشكاوى والاقتراحات".</p>`, '', 'loyalty', true);
    const work = document.getElementById('set-section-work');
    if (work) {
        work.innerHTML = '';
        set2Form('shift', 'الوردية', [['default_float', 'العهدة (الفكة) الافتراضية عند فتح الوردية', 'number']], '', '', 'work', true);
        set2Form('purchasing', 'المشتريات', [['manager_limit', 'يعتمد مدير الفرع أمر الشراء بنفسه حتى حد يومي محدد (0 = المالك فقط)', 'number']],
            '<p class="text-[11px] text-slate-500 font-bold mt-2">أمر الشراء الذي ينشئه مدير الفرع ويكون هو ومجموع أوامره في نفس اليوم ضمن هذا الحد، يُعتمد مباشرة بدون المالك، ويستطيع المدير ترحيل استلامه للمخزن. هذا الحد يغيّره المالك فقط.</p>', '', 'work', true);
        set2Form('inventory', 'المخازن', [['default_min_stock', 'الحد الأدنى الافتراضي للخامة الجديدة', 'number']], '', '', 'work', true);
        set2Form('staff', 'الموظفين (التأخير)', [['work_start_time', 'موعد بداية العمل (مثلاً 09:00)', 'text'], ['late_grace_minutes', 'مدة سماح التأخير بالدقائق', 'number']], '', '', 'work', true);
    }
    set2RenderSync();
    set2RenderRecipes();
    if (typeof set2RenderModifiers === 'function') set2RenderModifiers();
    set2RenderLists();
    set2RenderPayAcc();
    set2RenderReset();
}

// ---------------------------------------------------------------- تصفير البرنامج (المالك بس)
function set2RenderReset() {
    const box = document.getElementById('set-section-reset');
    if (!box) return;
    box.innerHTML = uiCard('🧹 تصفير البرنامج (بداية جديدة)', `
        <div class="bg-red-50 border border-red-200 text-red-800 rounded-xl p-3 text-xs font-bold leading-6 mb-3">
            ⚠️ هذا الإجراء يحذف البيانات نهائيًا ولا يمكن التراجع عنه:<br>
            كل الفواتير والطلبات والمدفوعات، والمشتريات والاستلامات وفواتير الموردين، والورديات وحركات الدرج والخزينة،
            والقيود والمصروفات والمرتبات والسلف، وحركات المخزن وأرصدته (يصبح الرصيد صفرًا)، والعملاء، والموردين، والشكاوى،
            وكل اليوزرات ماعدا المالك.</div>
        <div class="bg-emerald-50 border border-emerald-200 text-emerald-800 rounded-xl p-3 text-xs font-bold leading-6 mb-3">
            ✅ يبقى دون تغيير: الأصناف والأقسام، والخامات بأسعارها وعبواتها، والوصفات، والإضافات، وكل الإعدادات، والشركة والشعار،
            والفروع والمخازن والطاولات، وشجرة الحسابات، والصلاحيات.</div>
        <p class="text-[11px] font-bold text-slate-500 mb-3">إذا كان بالمحل لابتوب يعمل بدون إنترنت، سيصله الحذف تلقائيًا مع المزامنة. خذ نسخة احتياطية أولًا عند الحاجة.</p>`,
        uiBtn('🧹 احذف كل شيء وابدأ من جديد', 'set2DoReset()', 'red'));
}

async function set2DoReset() {
    const v = await uiForm('تأكيد تصفير البرنامج', [
        { type: 'note', html: '<p class="text-sm font-bold text-red-700">الحذف نهائي ولا يمكن التراجع. لإكمال العملية اكتب هذه الجملة بالضبط: <b>احذف كل شيء</b></p>' },
        { key: 'confirm', label: 'اكتب: احذف كل شيء', required: true },
        { key: 'pin', label: 'رقمك السري (المالك)', type: 'pin', required: true }], { ok: 'حذف نهائي', danger: true,
        validate: x => x.confirm !== 'احذف كل شيء' ? { key: 'confirm', msg: 'اكتب العبارة كما هي بالضبط' } : null });
    if (!v) return;
    const res = await uiCall('system_reset_secure', { p_pin: v.pin, p_confirm: v.confirm });
    if (!res) return;
    const d = res.deleted || {};
    const total = Object.values(d).reduce((s, n) => s + (Number(n) || 0), 0);
    await uiForm('تم التصفير ✅', [{ type: 'note', html: `<p class="text-sm font-bold">تم حذف ${total} سطر، منها ${Number(d.orders) || 0} طلب و${Number(d.staff) || 0} مستخدم.<br>أصبح البرنامج جاهزًا لأول يوم عمل.</p>` }], { ok: 'موافق' });
    if (typeof motionDataChanged === 'function') motionDataChanged();
    location.reload();
}

// ---------------------------------------------------------------- الشغل من غير نت (المزامنة) - للمالك بس
const SYNC_TABLE_NAMES = { customers: 'العملاء', products: 'الأصناف', categories: 'أقسام القائمة', staff: 'الموظفين', orders: 'الطلبات',
    order_items: 'أصناف الطلبات', payments: 'الدفعات', ingredients: 'الخامات', recipes: 'الوصفات', suppliers: 'الموردين',
    purchase_orders: 'المشتريات', expenses: 'المصروفات', tables: 'الطاولات', areas: 'المناطق', branches: 'الفروع', discounts: 'الخصومات',
    app_settings: 'الإعدادات', modifier_groups: 'مجموعات الإضافات', modifiers: 'الإضافات', customer_ledger: 'حساب العميل',
    stock_movements: 'حركات المخزن', warehouses: 'المخازن', units: 'الوحدات', roles: 'الأدوار' };
let set2Sync = null;

async function set2RenderSync() {
    const box = document.getElementById('set-section-offline');
    if (!box) return;
    box.innerHTML = '<p class="text-center text-slate-400 font-bold text-xs py-6">جارٍ التحميل...</p>';
    let res = null;
    try { res = await serverRpc('sync_admin_secure', { p_action: 'status', p_data: null }); } catch (err) { res = { ok: false, reason: '', message: err.message }; }
    if (!res || res.ok === false) {
        box.innerHTML = uiCard('العمل بدون إنترنت', `<p class="text-xs font-bold text-slate-500">${uiEsc(res && res.message ? res.message : serverReasonMessage(res, 'تعذر التحميل'))}</p>`);
        return;
    }
    set2Sync = res;
    const isStore = res.node === 'store';
    const last = res.last_sync ? new Date(res.last_sync) : null;
    const mins = last ? Math.floor((Date.now() - last.getTime()) / 60000) : null;
    const fresh = mins !== null && mins < 3;
    const status = `<div class="grid md:grid-cols-3 gap-3 text-xs font-bold">
        <div class="bg-slate-50 rounded-xl p-3">هذه النسخة: <span class="font-black">${isStore ? '🖥️ كمبيوتر المحل' : '☁️ الإنترنت'}</span></div>
        <div class="rounded-xl p-3 ${fresh ? 'bg-emerald-50 text-emerald-700' : 'bg-red-50 text-red-700'}">${isStore ? 'آخر مزامنة ناجحة' : 'آخر مرة كمبيوتر المحل كلّم الإنترنت'}:
            <span class="font-black">${last ? uiDate(res.last_sync) + (mins !== null ? ` (من ${mins} دقيقة)` : '') : 'لم يحدث بعد'}</span></div>
        <div class="rounded-xl p-3 ${res.open_count ? 'bg-amber-50 text-amber-700' : 'bg-slate-50'}">تعارضات ومشاكل لم تُغلق: <span class="font-black">${res.open_count}</span></div></div>
        <p class="text-[11px] text-slate-500 font-bold mt-2">إذا كانت آخر مزامنة منذ أكثر من ٣ دقائق، فالإنترنت في المحل متوقف أو برنامج المزامنة مغلق. العمل في المحل مستمر بشكل طبيعي، والبيانات تُنقل تلقائيًا عند عودة الإنترنت.</p>`;
    const branches = uiTable(res.branches, [{ label: 'الفرع', key: 'name' },
        { label: 'لديه كمبيوتر في المحل', render: b => `<input type="checkbox" class="w-5 h-5" ${b.has_store_server ? 'checked' : ''} onchange="set2SyncBranch('${b.id}', this.checked, this)">` }], 'لا توجد فروع');
    const rows = res.items.map(x => ({ ...x }));
    const items = uiTable(rows, [
        { label: 'الوقت', render: x => uiEsc(uiDate(x.created_at)) },
        { label: 'النوع', render: x => x.kind === 'conflict' ? '<span class="text-amber-700">تعدّل في المكانين</span>' : '<span class="text-red-700">لم يُكتب</span>' },
        { label: 'فين', render: x => uiEsc(SYNC_TABLE_NAMES[x.tbl] || x.tbl) },
        { label: 'الإجراء', render: x => uiEsc(set2SyncLabel(x)) },
        { label: 'ما تم تطبيقه', render: x => x.kind === 'conflict' ? (x.winner === 'store' ? 'نسخة المحل' : 'نسخة الإنترنت') : '-' },
        { label: '', render: x => `<div class="flex flex-wrap gap-1">${uiBtn('تفاصيل', `set2SyncDetails('${x.id}')`, 'gray')}
            ${x.kind === 'conflict' ? uiBtn('استخدم الثانية', `set2SyncAct('${x.id}', 'use_other')`, 'amber') : uiBtn('أعد المحاولة', `set2SyncAct('${x.id}', 'retry')`, 'amber')}
            ${uiBtn('موافق', `set2SyncAct('${x.id}', 'keep')`, 'green')}</div>` }], 'لا توجد تعارضات 👌');
    box.innerHTML = uiCard('حالة العمل بدون إنترنت', status, uiBtn('تحديث', 'set2RenderSync()', 'gray'))
        + uiCard('الفروع التي لديها كمبيوتر في المحل', `${branches}<p class="text-[11px] text-amber-700 font-bold mt-2">⚠️ فعّل خيار الفرع فقط عندما يكون كمبيوتر المحل يعمل فعليًا. عندئذٍ لن يفتح موقع الإنترنت ورديات أو طلبات لهذا الفرع، وستتم كل العمليات من المحل.</p>`)
        + uiCard('التعارضات والمشاكل', `<p class="text-[11px] text-slate-500 font-bold mb-2">"تعدّل في المكانين": تم تطبيق آخر تعديل، والنسخة الأخرى محفوظة هنا. «موافق» = اترك ما تم تطبيقه. «استخدم الثانية» = طبّق النسخة الثانية بدلته.<br>"لم يُكتب": تعذّر نقل الصف (مثلاً نفس رقم الهاتف لعميلين). صلّح السبب ثم «أعد المحاولة»، أو «موافق» إن لم يكن مهمًا.</p>${items}`);
}

function set2SyncLabel(x) {
    const d = x.store_data || x.cloud_data || {};
    return d.name || d.name_ar || (d.order_number ? '#' + d.order_number : '') || d.phone || d.reason || d.section || (x.message || '').slice(0, 60) || '-';
}

async function set2SyncDetails(id) {
    const x = ((set2Sync && set2Sync.items) || []).find(i => i.id === id);
    if (!x) return;
    const a = x.store_data || {}, b = x.cloud_data || {};
    const keys = [...new Set([...Object.keys(a), ...Object.keys(b)])].filter(k => JSON.stringify(a[k]) !== JSON.stringify(b[k]));
    const fmt = v => v === undefined ? '-' : (v === null ? 'فارغ' : (typeof v === 'object' ? JSON.stringify(v) : String(v)));
    const table = x.kind === 'conflict'
        ? uiTable(keys.map(k => ({ k, s: fmt(a[k]), c: fmt(b[k]) })), [{ label: 'الخانة', key: 'k' }, { label: 'في المحل', key: 's' }, { label: 'على الإنترنت', key: 'c' }], x.store_data === null || x.cloud_data === null ? 'أحد الطرفين محذوف' : 'لا توجد فروق')
        : `<p class="text-red-700">${uiEsc(x.message || '')}</p>` + uiTable(Object.keys(a).length ? Object.keys(a).map(k => ({ k, v: fmt(a[k]) })) : Object.keys(b).map(k => ({ k, v: fmt(b[k]) })), [{ label: 'الخانة', key: 'k' }, { label: 'القيمة', key: 'v' }]);
    await uiForm(`${SYNC_TABLE_NAMES[x.tbl] || x.tbl}: ${set2SyncLabel(x)}`, [{ type: 'note', html: table }], { ok: 'إغلاق' });
}

async function set2SyncAct(id, action) {
    const msg = { keep: 'هل تريد الإبقاء على ما تم تطبيقه وإغلاق هذا التعارض؟', use_other: 'تطبيق النسخة الثانية بدل الأولى؟ (سيتم نقلها إلى الموقع الآخر أيضًا)', retry: 'هل تريد إعادة كتابة هذا الصف؟' }[action];
    if (!(await uiConfirm(msg))) return;
    const res = await uiCall('sync_admin_secure', { p_action: action, p_data: { id } }, 'تم');
    if (res === null) { const x = ((set2Sync && set2Sync.items) || []).find(i => i.id === id); if (x) console.warn('sync action failed', action, x); }
    set2RenderSync();
}

async function set2SyncBranch(branchId, on, el) {
    const ok = await uiConfirm(on ? 'سيعمل هذا الفرع من كمبيوتر المحل، ولن يفتح موقع الإنترنت له ورديات أو طلبات. هل تأكدت أن كمبيوتر المحل يعمل؟'
                                  : 'سيعود هذا الفرع للعمل من موقع الإنترنت بشكل طبيعي. هل أنت متأكد؟', 'موافق', on);
    if (!ok) { el.checked = !on; return; }
    if (!(await uiCall('sync_admin_secure', { p_action: 'set_store_server', p_data: { branch_id: branchId, on } }, 'تم'))) el.checked = !on;
    set2RenderSync();
}

// generic form for one settings section. fields: [key, label, type, options]
function set2Form(section, title, fields, extraHtml = '', note = '', boxId = null, append = false) {
    const box = document.getElementById('set-section-' + (boxId || section));
    if (!box) return;
    const vals = set2.settings[section] || {};
    const inputs = fields.map(([k, label, type, opts]) => {
        const v = vals[k];
        let input;
        if (type === 'bool') input = `<input type="checkbox" data-s2="${section}" data-k="${k}" data-t="bool" ${v ? 'checked' : ''} class="w-4 h-4">`;
        else if (type === 'number') input = `<input type="number" data-s2="${section}" data-k="${k}" data-t="number" value="${uiEsc(v)}" class="${uiInputClass()} w-32">`;
        else if (type === 'select') input = `<select data-s2="${section}" data-k="${k}" data-t="${typeof opts[0][0] === 'number' ? 'number' : 'text'}" class="${uiInputClass()}">${opts.map(([ov, ol]) => `<option value="${uiEsc(ov)}" ${String(v) === String(ov) ? 'selected' : ''}>${uiEsc(ol)}</option>`).join('')}</select>`;
        else if (type === 'lines') input = `<textarea rows="6" data-s2="${section}" data-k="${k}" data-t="lines" class="${uiInputClass()} w-full">${uiEsc((v || []).join('\n'))}</textarea>`;
        else if (type === 'multi') input = `<div class="flex flex-wrap gap-3">${opts.map(([ov, ol]) => `<label class="flex items-center gap-1"><input type="checkbox" data-s2="${section}" data-k="${k}" data-t="multi" value="${uiEsc(ov)}" ${(v || []).includes(ov) ? 'checked' : ''}>${uiEsc(ol)}</label>`).join('')}</div>`;
        else input = `<input type="text" data-s2="${section}" data-k="${k}" data-t="text" value="${uiEsc(v)}" class="${uiInputClass()} w-full">`;
        return `<div class="flex flex-wrap items-center justify-between gap-2 py-2 border-b text-xs font-bold"><span>${uiEsc(label)}</span><div class="min-w-[200px] text-left">${input}</div></div>`;
    }).join('');
    const html = uiCard(title, `${note ? `<p class="text-[11px] text-slate-500 font-bold mb-2">${uiEsc(note)}</p>` : ''}${inputs}${extraHtml}`, uiBtn('حفظ', `set2SaveForm('${section}')`, 'green'));
    if (append) box.insertAdjacentHTML('beforeend', html); else box.innerHTML = html;
}

async function set2SaveForm(section) {
    const data = {};
    document.querySelectorAll(`[data-s2="${section}"]`).forEach(el => {
        const k = el.dataset.k;
        if (el.dataset.t === 'bool') data[k] = el.checked;
        else if (el.dataset.t === 'number') data[k] = Number(el.value) || 0;
        else if (el.dataset.t === 'lines') data[k] = el.value.split('\n').map(x => x.trim()).filter(Boolean).slice(0, 50);
        else if (el.dataset.t === 'multi') { data[k] = data[k] || []; if (el.checked) data[k].push(el.value); }
        else data[k] = el.value;
    });
    // لو مكان اتقفل، الأقسام اللي رايحة عليه بتتحوّل للبار (أو لأول مكان مفتوح)، عشان أصنافها متختفيش
    if (section === 'kds' && Array.isArray(data.stations) && data.stations.length) {
        const target = data.stations.includes('bar') ? 'bar' : data.stations[0];
        for (const c of (set2.data.categories || [])) {
            if (!data.stations.includes(c.station || 'kitchen')) { await set2Station(c.id, target); c.station = target; }
        }
    }
    await set2Save(section, data);
}

async function set2Save(section, data) {
    const res = await uiCall('app_settings_save_secure', { p_section: section, p_data: data }, 'تم الحفظ');
    if (!res) return;
    set2.settings = res.settings;
    appSettings = res.settings;
    if (section === 'general' && typeof loadAppSettings === 'function') loadAppSettings();
    set2RenderAll();
}

function set2PickLogo(input) {
    const file = input.files && input.files[0];
    if (!file) return;
    const reader = new FileReader();
    reader.onload = () => {
        const img = new Image();
        img.onload = () => {
            const max = 400;
            const scale = Math.min(1, max / Math.max(img.width, img.height));
            const canvas = document.createElement('canvas');
            canvas.width = Math.round(img.width * scale); canvas.height = Math.round(img.height * scale);
            canvas.getContext('2d').drawImage(img, 0, 0, canvas.width, canvas.height);
            const url = canvas.toDataURL('image/png');
            if (url.length > 400000) return showToast('الصورة كبيرة جدًا، اختر صورة أصغر', 'error');
            set2Save('general', { logo: url });
        };
        img.onerror = () => showToast('هذا الملف ليس صورة', 'error');
        img.src = reader.result;
    };
    reader.readAsDataURL(file);
}

async function set2Station(categoryId, station) {
    await uiCall('settings2_secure', { p_action: 'set_category_station', p_data: { category_id: categoryId, station } }, 'تم');
}

async function set2PrintQr() {
    const res = await uiCall('tables_qr_secure', {});
    if (!res) return;
    try { await loadScriptOnce('vendor/qrcode.min.js'); }
    catch (err) { return showToast(err.message, 'error'); }
    const g = (appSettings && appSettings.general) || {};
    // كود الـ QR لازم يفتح الموقع على النت دايماً (موبايل الزبون مش على شبكة المحل)
    const base = (MOTION_LOCAL ? CLOUD_SITE : location.origin + location.pathname.replace(/[^/]*$/, '')) + 'menu.html?t=';
    const cards = (res.tables || []).map(t => {
        const qr = qrcode(0, 'M'); qr.addData(base + t.qr_token); qr.make();
        return `<div class="card">${g.logo ? `<img class="logo" src="${uiEsc(g.logo)}">` : `<div class="co">${uiEsc(g.company_name || '')}</div>`}
            <img class="qr" src="${qr.createDataURL(6, 2)}"><div class="t">طاولة ${uiEsc(t.table_number)}</div><div class="s">${uiEsc(t.area || '')} | امسح الرمز للقائمة واستدعاء الويتر</div></div>`;
    }).join('');
    if (!cards) return showToast('لا توجد طاولات في الفرع', 'error');
    printHtml(`<div class="grid">${cards}</div>`, `@page { size: A4; margin: 10mm; } .grid { display: flex; flex-wrap: wrap; gap: 8mm; justify-content: center; }
        .card { width: 60mm; border: 1px dashed #999; border-radius: 4mm; padding: 4mm; text-align: center; page-break-inside: avoid; }
        .logo { max-height: 14mm; max-width: 40mm; } .co { font-weight: bold; font-size: 14px; } .qr { width: 45mm; height: 45mm; }
        .t { font-size: 18px; font-weight: bold; } .s { font-size: 10px; color: #555; }`);
}

// ---------------------------------------------------------------- recipes and ingredients
async function set2RenderRecipes() {
    const box = document.getElementById('set-section-recipes');
    if (!box) return;
    const ings = set2.data.ingredients || [];
    box.innerHTML = uiCard('الوصفات', `<p class="text-xs font-bold text-slate-600">أصبحت الوصفات داخل كل صنف في <button onclick="switchSettingsSection('menu')" class="text-blue-700 underline font-black">القائمة والوصفات 🍽️</button>: افتح الصنف، وأضف الخامات والكميات، ويمكنك إنشاء خامة جديدة من نفس المكان.</p>`)
        + uiCard('الخامات', uiTable(ings, [{ label: 'الخامة', key: 'name' }, { label: 'الوحدة', key: 'unit' },
            { label: 'عبوة الشراء', render: i => unitPack(i) ? `${uiEsc(i.pack_unit)} = ${unitNum(i.pack_size)} ${uiEsc(i.unit)}` : '<span class="text-slate-400">-</span>' },
            { label: 'التكلفة (من المشتريات)', render: i => formatCurrency(i.cost_per_unit) }, { label: 'الحد الأدنى', key: 'min_stock_alert' },
            { label: '', render: i => uiBtn('تعديل', `set2EditIngredient('${i.id}')`, 'gray') }], 'لا توجد خامات'), uiBtn('إضافة خامة', 'set2EditIngredient(null)', 'blue'));
}

async function set2RecipeLoad(productId) {
    set2.recipeProduct = productId;
    set2.recipeLines = [];
    if (productId) {
        const res = await uiCall('settings2_secure', { p_action: 'get_recipe', p_data: { product_id: productId } });
        set2.recipeLines = ((res && res.lines) || []).map(l => ({ ingredient_id: l.ingredient_id, qty: l.qty }));
    }
    set2RenderRecipes();
}

function set2RecipeAdd() {
    const ing = document.getElementById('set2-rec-ing').value;
    const qty = Number(document.getElementById('set2-rec-qty').value);
    if (!ing || !(qty > 0)) return showToast('اختر الخامة واكتب الكمية', 'error');
    const ex = set2.recipeLines.find(l => l.ingredient_id === ing);
    if (ex) ex.qty = (Number(ex.qty) || 0) + qty; else set2.recipeLines.push({ ingredient_id: ing, qty });
    set2RenderRecipes();
}

async function set2RecipeSave() {
    const lines = set2.recipeLines.filter(l => Number(l.qty) > 0).map(l => ({ ingredient_id: l.ingredient_id, qty: Number(l.qty) }));
    await uiCall('settings2_secure', { p_action: 'save_recipe', p_data: { product_id: set2.recipeProduct, lines } }, 'تم حفظ الوصفة');
}

// أسماء خامات جاهزة تظهر وانت بتكتب (وتقدر تكتب غيرها)
const SET2_INGREDIENT_CATALOG = ['بن', 'بن اسبريسو', 'بن تركي', 'نسكافيه', 'شاي', 'شاي أخضر', 'كاكاو', 'سكر', 'سكر دايت', 'لبن', 'لبن شوفان', 'كريمة خفق',
    'شوكولاتة', 'صوص كراميل', 'صوص شوكولاتة', 'فانيليا', 'تلج', 'مياه معدنية', 'صودا', 'كولا', 'عصير برتقال', 'مانجو', 'فراولة', 'ليمون', 'نعناع', 'موز',
    'عيش برجر', 'عيش فينو', 'عيش توست', 'لحمة برجر', 'فراخ', 'سجق', 'جبنة', 'جبنة شيدر', 'جبنة موتزاريلا', 'بيض', 'طماطم', 'خس', 'بصل', 'خيار', 'مخلل',
    'بطاطس', 'زيت', 'زبدة', 'كاتشب', 'مايونيز', 'مستردة', 'ملح', 'فلفل', 'دقيق', 'مكرونة', 'رز', 'معسل', 'فحم', 'ولاعة', 'خرطوم شيشة',
    'كوبايات ورق', 'غطيان كوبايات', 'شفاطات', 'مناديل', 'علب تيك أواي', 'أكياس'];
const SET2_PACK_UNITS = ['جالون', 'كرتونة', 'شوال', 'علبة', 'كيس', 'باكيت', 'زجاجة', 'جركن', 'صندوق', 'شدّة'];
const SET2_DEFAULT_UNITS = ['كيلو', 'جرام', 'لتر', 'مللي', 'قطعة', 'علبة', 'كرتونة', 'رغيف', 'كيس', 'زجاجة', 'باكيت'];

async function set2EditIngredient(id) {
    const i = id ? (set2.data.ingredients || []).find(x => x.id === id) : {};
    const saved = appSet('inventory', 'units', []) || [];
    const used = (set2.data.ingredients || []).map(x => x.unit).filter(Boolean);
    const units = [...new Set([...SET2_DEFAULT_UNITS, ...saved, ...used])];
    const fields = [
        { key: 'name', label: 'اسم الخامة', value: i.name || '', required: true, list: SET2_INGREDIENT_CATALOG, help: 'اكتب حرفين وستظهر لك أسماء جاهزة، أو اكتب اسمًا جديدًا' },
        { key: 'unit', label: 'الوحدة', type: 'select', options: units.map(u => [u, u]), value: i.unit || '', placeholder: 'اختر الوحدة', addNew: 'وحدة جديدة', required: true },
        { key: 'min', label: 'الحد الأدنى للتنبيه', type: 'number', min: 0, value: i.min_stock_alert ?? appSet('inventory', 'default_min_stock', 5), required: true },
        { type: 'note', html: '📦 <b>العبوة (اختياري):</b> إذا كنت تشتري الخامة بعبوة (جالون، كرتونة، شوال...) فاكتب اسمها وعدد الوحدات داخلها. بعد ذلك في الشراء والاستلام والجرد تكتب بالعبوة ويحسب النظام الوحدات تلقائيًا. مثال: الوحدة لتر، العبوة جالون، وداخلها 3 (أو المكتوب على الجالون).' },
        { key: 'pack_unit', label: 'اسم العبوة', value: i.pack_unit || '', list: SET2_PACK_UNITS, placeholder: 'مثلاً جالون' },
        { key: 'pack_size', label: 'عدد الوحدات في العبوة', type: 'number', min: 0, value: i.pack_size || '', placeholder: 'مثلاً 3' }];
    if (!id) fields.push({ key: 'cost', label: 'تكلفة الوحدة المبدئية', type: 'money', min: 0, value: 0, help: 'تُحسب تلقائيًا لاحقًا من المشتريات' });
    const v = await uiForm(id ? 'تعديل خامة' : 'خامة جديدة', fields, { validate: x => {
        if (x.pack_unit && !(Number(x.pack_size) > 0)) return { key: 'pack_size', msg: 'اكتب عدد الوحدات في العبوة' };
        if (!x.pack_unit && Number(x.pack_size) > 0) return { key: 'pack_unit', msg: 'اكتب اسم العبوة' };
        if (x.pack_unit && x.pack_unit === x.unit) return { key: 'pack_unit', msg: 'يجب أن تختلف العبوة عن الوحدة الأساسية' };
        const dup = (set2.data.ingredients || []).find(y => y.id !== id && String(y.name).trim() === x.name);
        return dup ? { key: 'name', msg: 'هذه الخامة موجودة من قبل' } : null;
    } });
    if (!v) return;
    if (v.unit_new && !saved.includes(v.unit)) {
        try { await serverRpc('app_settings_save_secure', { p_section: 'inventory', p_data: { units: [...saved, v.unit].slice(-40) } }); } catch (err) { console.warn('unit not saved', err); }
        if (typeof loadAppSettings === 'function') loadAppSettings();
    }
    if (await uiCall('settings2_secure', { p_action: 'save_ingredient', p_data: { id: id || null, name: v.name, unit: v.unit, min_stock_alert: String(v.min || 0), cost_per_unit: String(v.cost || 0),
        pack_unit: v.pack_unit || '', pack_size: v.pack_unit ? String(v.pack_size) : '' } }, 'تم الحفظ')) initSettings2();
}

// ---------------------------------------------------------------- discounts, cancel reasons, areas
function set2RenderLists() {
    const box = document.getElementById('set-section-lists');
    if (!box) return;
    const typeNames = { void_item: 'إلغاء صنف', cancel_order: 'إلغاء طلب', return: 'مرتجع' };
    box.innerHTML = uiCard('الخصومات', uiTable(set2.data.discounts, [{ label: 'الاسم', key: 'name' },
        { label: 'القيمة', render: d => d.discount_type === 'percentage' ? `${uiEsc(d.value)}%` : formatCurrency(d.value) },
        { label: 'يتطلب موافقة المدير', render: d => d.requires_approval !== false ? 'نعم' : 'لا' },
        { label: '', render: d => uiBtn('تعديل', `set2EditDiscount('${d.id}')`, 'gray') }], 'لا يوجد'), uiBtn('إضافة خصم', 'set2EditDiscount(null)', 'blue'))
        + uiCard('أسباب الإلغاء والمرتجع', uiTable(set2.data.cancel_reasons, [{ label: 'السبب', key: 'reason' }, { label: 'النوع', render: r => uiEsc(typeNames[r.reason_type] || r.reason_type) },
            { label: '', render: r => uiBtn('تعديل', `set2EditReason('${r.id}')`, 'gray') }], 'لا يوجد'), uiBtn('إضافة سبب', 'set2EditReason(null)', 'blue'))
        + uiCard('مناطق الصالة', uiTable(set2.data.areas, [{ label: 'المنطقة', key: 'name' }], 'لا يوجد'), uiBtn('إضافة منطقة', 'set2AddArea()', 'blue'));
}

async function set2EditDiscount(id) {
    const d = id ? set2.data.discounts.find(x => x.id === id) : {};
    const v = await uiForm(id ? 'تعديل خصم' : 'خصم جديد', [
        { key: 'name', label: 'اسم الخصم', value: d.name || '', required: true },
        { key: 'type', label: 'النوع', type: 'select', options: [['percentage', 'نسبة %'], ['fixed', 'مبلغ ثابت']], value: d.discount_type || 'percentage', required: true },
        { key: 'value', label: 'القيمة (النسبة أو المبلغ)', type: 'money', min: 0.01, value: d.value || '', required: true },
        { key: 'approval', label: 'يتطلب موافقة المدير', type: 'check', value: d.requires_approval !== false }],
        { validate: x => x.type === 'percentage' && x.value > 100 ? { key: 'value', msg: 'النسبة متزيدش عن 100' } : null });
    if (!v) return;
    if (await uiCall('settings2_secure', { p_action: 'save_discount', p_data: { id: id || null, name: v.name, discount_type: v.type, value: String(v.value), requires_approval: String(v.approval) } }, 'تم الحفظ')) initSettings2();
}

async function set2EditReason(id) {
    const r = id ? set2.data.cancel_reasons.find(x => x.id === id) : {};
    const v = await uiForm(id ? 'تعديل سبب' : 'سبب جديد', [
        { key: 'reason', label: 'السبب', value: r.reason || '', required: true },
        { key: 'type', label: 'النوع', type: 'select', options: [['void_item', 'إلغاء صنف'], ['cancel_order', 'إلغاء طلب'], ['return', 'مرتجع']], value: r.reason_type || 'void_item', required: true }]);
    if (!v) return;
    if (await uiCall('settings2_secure', { p_action: 'save_cancel_reason', p_data: { id: id || null, reason: v.reason, reason_type: v.type } }, 'تم الحفظ')) initSettings2();
}

async function set2AddArea() {
    const v = await uiForm('منطقة جديدة', [{ key: 'name', label: 'اسم المنطقة (مثلاً: الدور الأول، التراس)', required: true }]);
    if (!v) return;
    if (await uiCall('settings2_secure', { p_action: 'add_area', p_data: { name: v.name } }, 'تم الحفظ')) initSettings2();
}

// ---------------------------------------------------------------- payment accounts and tax flags
function set2RenderPayAcc() {
    const box = document.getElementById('set-section-payacc');
    if (!box) return;
    const names = { cash: 'كاش', card: 'كارت', instapay: 'إنستاباي', wallet: 'محفظة', on_account: 'آجل' };
    const accOpts = set2.data.asset_accounts || [];
    box.innerHTML = uiCard('ربط طرق الدفع بالحسابات (للمالك فقط)', uiTable(set2.data.payment_accounts, [{ label: 'طريقة الدفع', render: p => uiEsc(names[p.method] || p.method) },
        { label: 'الحساب', render: p => `<select onchange="set2PayAccount('${p.method}', this.value)" class="${uiInputClass()}">${accOpts.map(a => `<option value="${uiEsc(a.id)}" ${a.id === p.account_id ? 'selected' : ''}>${uiEsc(a.name)}</option>`).join('')}${p.account_id ? '' : '<option value="" selected>غير مرتبط</option>'}</select>` }]))
        + uiCard('الضرايب والخدمة لكل فرع', uiTable(set2.data.tax, [{ label: 'الفرع', key: 'branch' },
            { label: 'الضريبة %', key: 'vat_percentage' }, { label: 'الخدمة %', key: 'service_charge_percentage' },
            { label: 'الأسعار شاملة الضريبة', render: t => `<input type="checkbox" id="tx-inc-${uiEsc(t.branch_id)}" ${t.is_vat_inclusive ? 'checked' : ''}>` },
            { label: 'الضريبة على الخدمة', render: t => `<input type="checkbox" id="tx-srv-${uiEsc(t.branch_id)}" ${t.is_service_taxable ? 'checked' : ''}>` },
            { label: '', render: t => uiBtn('حفظ', `set2TaxFlags('${t.branch_id}')`, 'green') }]),
            '<span class="text-[11px] text-slate-500 font-bold">النسب ذاتها تُعدَّل من "الضرائب والطاولات"</span>');
}

async function set2PayAccount(method, accountId) {
    if (!accountId) return;
    await uiCall('settings2_secure', { p_action: 'set_payment_account', p_data: { method, account_id: accountId } }, 'تم الربط');
}

async function set2TaxFlags(branchId) {
    const inc = document.getElementById('tx-inc-' + branchId).checked;
    const srv = document.getElementById('tx-srv-' + branchId).checked;
    if (await uiCall('settings2_secure', { p_action: 'save_tax_flags', p_data: { branch_id: branchId, is_vat_inclusive: String(inc), is_service_taxable: String(srv) } }, 'تم الحفظ')
        && currentUser && currentUser.branch_id === branchId) {
        taxSettings.is_vat_inclusive = inc;
        taxSettings.is_service_taxable = srv;
    }
}
