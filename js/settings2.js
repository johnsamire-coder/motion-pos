// js/settings2.js - باقي الإعدادات: الشركة واللوجو، الطباعة، الكاشير، المطبخ والأماكن، الويتر والـ QR،
// الوردية والمخازن والموظفين، الشغل من غير نت، الوصفات والخامات، القوايم، طرق الدفع والضرايب.
// الأقسام دي بتتضاف جنب أقسام الإعدادات القديمة (الضرائب والطاولات، الفروع والمخازن، المنيو).

const SET2_SECTIONS = [['general', 'الشركة واللوجو'], ['receipt', 'الطباعة والفاتورة'], ['poscfg', 'إعدادات الكاشير'], ['kdscfg', 'المطبخ والأماكن'],
    ['qr', 'الويتر والـ QR'], ['work', 'الوردية والمخازن والموظفين'], ['offline', 'الشغل من غير نت'], ['recipes', 'الوصفات والخامات'], ['modifiers', 'الإضافات'],
    ['lists', 'الخصومات والأسباب والمناطق'], ['payacc', 'طرق الدفع والضرايب']];

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
        ['tax_number', 'الرقم الضريبي', 'text'], ['commercial_register', 'السجل التجاري', 'text'], ['currency', 'العملة', 'text']],
        `<div class="mt-3 border-t pt-3"><p class="text-xs font-black mb-2">اللوجو (بيظهر في الشاشة والفاتورة والتقارير والمنيو)</p>
         <div class="flex flex-wrap items-center gap-3"><div id="set2-logo-preview">${set2.settings.general.logo ? `<img src="${uiEsc(set2.settings.general.logo)}" class="h-16 max-w-[160px] object-contain border rounded-xl p-1">` : '<span class="text-xs text-slate-400">مفيش لوجو</span>'}</div>
         <input type="file" accept="image/png,image/jpeg,image/webp" onchange="set2PickLogo(this)" class="text-xs">
         ${set2.settings.general.logo ? uiBtn('شيل اللوجو', "set2Save('general', { logo: '' })", 'gray') : ''}</div></div>`, 'الإعدادات العامة للمالك بس');
    set2Form('receipt', 'الطباعة والفاتورة', [['header', 'سطر فوق الفاتورة', 'text'], ['footer', 'سطر تحت الفاتورة (رسالة شكر)', 'text'],
        ['show_logo', 'اللوجو يظهر في الفاتورة', 'bool'], ['show_tax_number', 'الرقم الضريبي يظهر في الفاتورة', 'bool'],
        ['paper_mm', 'مقاس الورق', 'select', [[58, '58 مم'], [80, '80 مم']]], ['copies', 'عدد النسخ', 'number'],
        ['auto_print_after_pay', 'طباعة الفاتورة أوتوماتيك بعد الدفع', 'bool'], ['auto_kitchen_ticket', 'طباعة ورقة المطبخ أوتوماتيك بعد الإرسال', 'bool']]);
    set2Form('whatsapp', 'رسايل الواتساب', [['customer_message', 'الرسالة اللي بتتبعت من شاشة العملاء (زرار 💬)', 'text'],
        ['thanks_enabled', 'بعد الدفع: الكاشير يشوف زرار "ابعت رسالة شكر" لو الطلب عليه عميل بموبايل', 'bool'],
        ['thanks_message', 'رسالة الشكر بعد الدفع', 'text']],
        '<p class="text-[11px] text-slate-500 font-bold mt-2">اكتب <b>{الاسم}</b> مكان اسم العميل، و<b>{المحل}</b> مكان اسم الشركة. الواتساب بيفتح والرسالة جاهزة، وانت تدوس إرسال. لازم واتساب المحل يكون مفتوح على الجهاز، ولازم يكون فيه نت.</p>',
        '', 'receipt', true);
    set2Form('pos', 'إعدادات الكاشير', [['order_types', 'أنواع الطلبات المفعّلة', 'multi', [['dine_in', 'صالة'], ['takeaway', 'تيك أواي'], ['delivery', 'توصيل'], ['pickup', 'استلام']]],
        ['payment_methods', 'طرق الدفع المفعّلة', 'multi', [['cash', 'كاش'], ['card', 'كارت'], ['instapay', 'إنستاباي'], ['wallet', 'محفظة'], ['on_account', 'آجل']]],
        ['require_waiter', 'لازم يتختار ويتر قبل الإرسال للمطبخ', 'bool'],
        ['quick_notes', 'الملاحظات الجاهزة اللي بتظهر للكاشير (كل ملاحظة في سطر، مثلاً: بدون بصل)', 'lines']], '', '', 'poscfg');
    set2Form('kds', 'شاشة التحضير', [['stations', 'الأماكن المفعّلة', 'multi', [['kitchen', 'مطبخ'], ['bar', 'بار'], ['shisha', 'شيشة']]],
        ['warn_kitchen_minutes', 'المطبخ: الطلب يبقى متأخر بعد كام دقيقة', 'number'], ['warn_bar_minutes', 'البار: متأخر بعد كام دقيقة', 'number'],
        ['warn_shisha_minutes', 'الشيشة: متأخر بعد كام دقيقة', 'number'], ['sound', 'صوت تنبيه للطلب الجديد', 'bool'], ['refresh_seconds', 'التحديث كل كام ثانية', 'number']],
        `<div class="mt-4 border-t pt-3"><p class="text-xs font-black mb-2">كل قسم في المنيو بيروح لأنهي مكان</p>
         ${uiTable(set2.data.categories, [{ label: 'القسم', key: 'name' }, { label: 'المكان', render: c => `<select onchange="set2Station('${c.id}', this.value)" class="${uiInputClass()}">
            ${[['kitchen', 'مطبخ'], ['bar', 'بار'], ['shisha', 'شيشة']].map(([v, l]) => `<option value="${v}" ${c.station === v ? 'selected' : ''}>${l}</option>`).join('')}</select>` }], 'مفيش أقسام')}</div>`, '', 'kdscfg');
    set2Form('waiter_qr', 'الويتر والـ QR', [['qr_enabled', 'منيو الـ QR شغال', 'bool'], ['qr_call_waiter', 'زرار نداء الويتر', 'bool'],
        ['qr_request_bill', 'زرار طلب الحساب', 'bool'], ['qr_show_prices', 'الأسعار تظهر في المنيو', 'bool']],
        `<div class="mt-4 border-t pt-3">${uiBtn('طباعة أكواد الطاولات (QR)', 'set2PrintQr()', 'blue')}
         <p class="text-[11px] text-slate-500 font-bold mt-2">كل طاولة ليها كود سري مختلف. اطبعهم وحط كل واحد على طاولته.</p></div>`, '', 'qr');
    const work = document.getElementById('set-section-work');
    if (work) {
        work.innerHTML = '';
        set2Form('shift', 'الوردية', [['default_float', 'العهدة (الفكة) الافتراضية عند فتح الوردية', 'number']], '', '', 'work', true);
        set2Form('inventory', 'المخازن', [['default_min_stock', 'الحد الأدنى الافتراضي للخامة الجديدة', 'number']], '', '', 'work', true);
        set2Form('staff', 'الموظفين (التأخير)', [['work_start_time', 'ميعاد بداية الشغل (مثلاً 09:00)', 'text'], ['late_grace_minutes', 'سماح التأخير بالدقايق', 'number']], '', '', 'work', true);
    }
    set2RenderSync();
    set2RenderRecipes();
    if (typeof set2RenderModifiers === 'function') set2RenderModifiers();
    set2RenderLists();
    set2RenderPayAcc();
}

// ---------------------------------------------------------------- الشغل من غير نت (المزامنة) - للمالك بس
const SYNC_TABLE_NAMES = { customers: 'العملاء', products: 'الأصناف', categories: 'أقسام المنيو', staff: 'الموظفين', orders: 'الطلبات',
    order_items: 'أصناف الطلبات', payments: 'الدفعات', ingredients: 'الخامات', recipes: 'الوصفات', suppliers: 'الموردين',
    purchase_orders: 'المشتريات', expenses: 'المصروفات', tables: 'الطاولات', areas: 'المناطق', branches: 'الفروع', discounts: 'الخصومات',
    app_settings: 'الإعدادات', modifier_groups: 'مجموعات الإضافات', modifiers: 'الإضافات', customer_ledger: 'حساب العميل',
    stock_movements: 'حركات المخزن', warehouses: 'المخازن', units: 'الوحدات', roles: 'الأدوار' };
let set2Sync = null;

async function set2RenderSync() {
    const box = document.getElementById('set-section-offline');
    if (!box) return;
    box.innerHTML = '<p class="text-center text-slate-400 font-bold text-xs py-6">جاري التحميل...</p>';
    let res = null;
    try { res = await serverRpc('sync_admin_secure', { p_action: 'status', p_data: null }); } catch (err) { res = { ok: false, reason: '', message: err.message }; }
    if (!res || res.ok === false) {
        box.innerHTML = uiCard('الشغل من غير نت', `<p class="text-xs font-bold text-slate-500">${uiEsc(res && res.message ? res.message : serverReasonMessage(res, 'تعذر التحميل'))}</p>`);
        return;
    }
    set2Sync = res;
    const isStore = res.node === 'store';
    const last = res.last_sync ? new Date(res.last_sync) : null;
    const mins = last ? Math.floor((Date.now() - last.getTime()) / 60000) : null;
    const fresh = mins !== null && mins < 3;
    const status = `<div class="grid md:grid-cols-3 gap-3 text-xs font-bold">
        <div class="bg-slate-50 rounded-xl p-3">النسخة دي: <span class="font-black">${isStore ? '🖥️ كمبيوتر المحل' : '☁️ النت'}</span></div>
        <div class="rounded-xl p-3 ${fresh ? 'bg-emerald-50 text-emerald-700' : 'bg-red-50 text-red-700'}">${isStore ? 'آخر مزامنة ناجحة' : 'آخر مرة كمبيوتر المحل كلّم النت'}:
            <span class="font-black">${last ? uiDate(res.last_sync) + (mins !== null ? ` (من ${mins} دقيقة)` : '') : 'لسه محصلش'}</span></div>
        <div class="rounded-xl p-3 ${res.open_count ? 'bg-amber-50 text-amber-700' : 'bg-slate-50'}">تعارضات ومشاكل مفتوحة: <span class="font-black">${res.open_count}</span></div></div>
        <p class="text-[11px] text-slate-500 font-bold mt-2">لو آخر مزامنة أكتر من ٣ دقايق، يبقى النت في المحل واقف أو برنامج المزامنة مقفول. الشغل في المحل مكمّل عادي، والبيانات هتتنقل لوحدها أول ما النت يرجع.</p>`;
    const branches = uiTable(res.branches, [{ label: 'الفرع', key: 'name' },
        { label: 'عنده كمبيوتر في المحل', render: b => `<input type="checkbox" class="w-5 h-5" ${b.has_store_server ? 'checked' : ''} onchange="set2SyncBranch('${b.id}', this.checked, this)">` }], 'مفيش فروع');
    const rows = res.items.map(x => ({ ...x }));
    const items = uiTable(rows, [
        { label: 'الوقت', render: x => uiEsc(uiDate(x.created_at)) },
        { label: 'النوع', render: x => x.kind === 'conflict' ? '<span class="text-amber-700">اتعدّل في المكانين</span>' : '<span class="text-red-700">متكتبش</span>' },
        { label: 'فين', render: x => uiEsc(SYNC_TABLE_NAMES[x.tbl] || x.tbl) },
        { label: 'إيه', render: x => uiEsc(set2SyncLabel(x)) },
        { label: 'اللي اتطبق', render: x => x.kind === 'conflict' ? (x.winner === 'store' ? 'نسخة المحل' : 'نسخة النت') : '-' },
        { label: '', render: x => `<div class="flex flex-wrap gap-1">${uiBtn('تفاصيل', `set2SyncDetails('${x.id}')`, 'gray')}
            ${x.kind === 'conflict' ? uiBtn('رجّع التانية', `set2SyncAct('${x.id}', 'use_other')`, 'amber') : uiBtn('جرّب تاني', `set2SyncAct('${x.id}', 'retry')`, 'amber')}
            ${uiBtn('تمام', `set2SyncAct('${x.id}', 'keep')`, 'green')}</div>` }], 'مفيش تعارضات 👌');
    box.innerHTML = uiCard('حالة الشغل من غير نت', status, uiBtn('تحديث', 'set2RenderSync()', 'gray'))
        + uiCard('الفروع اللي ليها كمبيوتر في المحل', `${branches}<p class="text-[11px] text-amber-700 font-bold mt-2">⚠️ علّم على الفرع بس لما كمبيوتر المحل يكون شغال فعلاً. ساعتها الموقع على النت مش هيفتح وردية ولا طلبات للفرع ده، وكله يتعمل من المحل.</p>`)
        + uiCard('التعارضات والمشاكل', `<p class="text-[11px] text-slate-500 font-bold mb-2">"اتعدّل في المكانين": آخر تعديل اتطبق، والتاني محفوظ هنا. "تمام" = سيب اللي اتطبق. "رجّع التانية" = طبّق النسخة التانية بدله.<br>"متكتبش": صف مقدرش يتنقل (مثلاً نفس الموبايل لعميلين). صلّح السبب وبعدها "جرّب تاني"، أو "تمام" لو مش مهم.</p>${items}`);
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
    const fmt = v => v === undefined ? '-' : (v === null ? 'فاضي' : (typeof v === 'object' ? JSON.stringify(v) : String(v)));
    const table = x.kind === 'conflict'
        ? uiTable(keys.map(k => ({ k, s: fmt(a[k]), c: fmt(b[k]) })), [{ label: 'الخانة', key: 'k' }, { label: 'في المحل', key: 's' }, { label: 'على النت', key: 'c' }], x.store_data === null || x.cloud_data === null ? 'واحدة منهم اتمسحت' : 'مفيش فرق')
        : `<p class="text-red-700">${uiEsc(x.message || '')}</p>` + uiTable(Object.keys(a).length ? Object.keys(a).map(k => ({ k, v: fmt(a[k]) })) : Object.keys(b).map(k => ({ k, v: fmt(b[k]) })), [{ label: 'الخانة', key: 'k' }, { label: 'القيمة', key: 'v' }]);
    await uiForm(`${SYNC_TABLE_NAMES[x.tbl] || x.tbl}: ${set2SyncLabel(x)}`, [{ type: 'note', html: table }], { ok: 'قفل' });
}

async function set2SyncAct(id, action) {
    const msg = { keep: 'تسيب اللي اتطبق وتقفل التعارض ده؟', use_other: 'تطبّق النسخة التانية بدل اللي اتطبقت؟ (هتتنقل للمكان التاني كمان)', retry: 'تجرّب تكتب الصف ده تاني؟' }[action];
    if (!(await uiConfirm(msg))) return;
    const res = await uiCall('sync_admin_secure', { p_action: action, p_data: { id } }, 'تم');
    if (res === null) { const x = ((set2Sync && set2Sync.items) || []).find(i => i.id === id); if (x) console.warn('sync action failed', action, x); }
    set2RenderSync();
}

async function set2SyncBranch(branchId, on, el) {
    const ok = await uiConfirm(on ? 'الفرع ده هيشتغل من كمبيوتر المحل، والموقع على النت مش هيفتح له وردية ولا طلبات. متأكد إن كمبيوتر المحل شغال؟'
                                  : 'الفرع ده هيرجع يشتغل من الموقع على النت عادي. متأكد؟', 'موافق', on);
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
            if (url.length > 400000) return showToast('الصورة كبيرة جداً، اختار صورة أصغر', 'error');
            set2Save('general', { logo: url });
        };
        img.onerror = () => showToast('الملف ده مش صورة', 'error');
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
            <img class="qr" src="${qr.createDataURL(6, 2)}"><div class="t">طاولة ${uiEsc(t.table_number)}</div><div class="s">${uiEsc(t.area || '')} | امسح الكود للمنيو ونداء الويتر</div></div>`;
    }).join('');
    if (!cards) return showToast('مفيش طاولات في الفرع', 'error');
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
    let recipeHtml = '';
    if (set2.recipeProduct) {
        const names = Object.fromEntries(ings.map(i => [i.id, i]));
        const cost = set2.recipeLines.reduce((s, l) => s + (Number(l.qty) || 0) * (Number(names[l.ingredient_id]?.cost_per_unit) || 0), 0);
        const product = set2.products.find(p => p.id === set2.recipeProduct) || {};
        recipeHtml = `${uiTable(set2.recipeLines.map((l, i) => ({ ...l, i })), [
            { label: 'الخامة', render: l => uiEsc(names[l.ingredient_id] ? `${names[l.ingredient_id].name} (${names[l.ingredient_id].unit})` : '') },
            { label: 'الكمية', render: l => `<input type="number" min="0" step="any" value="${uiEsc(l.qty)}" onchange="set2.recipeLines[${l.i}].qty = this.value; set2RenderRecipes()" class="${uiInputClass()} w-28">` },
            { label: 'التكلفة', render: l => formatCurrency((Number(l.qty) || 0) * (Number(names[l.ingredient_id]?.cost_per_unit) || 0)) },
            { label: '', render: l => uiBtn('شيل', `set2.recipeLines.splice(${l.i},1); set2RenderRecipes()`, 'gray') }], 'الوصفة فاضية')}
            <div class="flex flex-wrap gap-2 mt-2"><select id="set2-rec-ing" class="${uiInputClass()}">${uiOptions(ings, 'id', i => `${i.name} (${i.unit})`, 'اختار الخامة')}</select>
            <input id="set2-rec-qty" type="number" min="0" step="any" placeholder="الكمية" class="${uiInputClass()} w-28">${uiBtn('إضافة', 'set2RecipeAdd()', 'gray')}</div>
            <p class="text-xs font-black mt-3">تكلفة الصنف: ${formatCurrency(cost)} من سعر ${formatCurrency(product.price)} (${product.price ? (100 * cost / product.price).toFixed(1) : 0}%)</p>
            <div class="mt-2">${uiBtn('حفظ الوصفة', 'set2RecipeSave()', 'green')}</div>`;
    }
    box.innerHTML = uiCard('الوصفات (الريسبي)', `<div class="flex gap-2 mb-3"><select onchange="set2RecipeLoad(this.value)" class="${uiInputClass()}">
        ${uiOptions(set2.products, 'id', p => p.name, 'اختار الصنف')}</select></div>${recipeHtml}`)
        + uiCard('الخامات', uiTable(ings, [{ label: 'الخامة', key: 'name' }, { label: 'الوحدة', key: 'unit' },
            { label: 'التكلفة (من المشتريات)', render: i => formatCurrency(i.cost_per_unit) }, { label: 'الحد الأدنى', key: 'min_stock_alert' },
            { label: '', render: i => uiBtn('تعديل', `set2EditIngredient('${i.id}')`, 'gray') }], 'مفيش خامات'), uiBtn('إضافة خامة', 'set2EditIngredient(null)', 'blue'));
    const sel = box.querySelector('select');
    if (sel) sel.value = set2.recipeProduct;
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
    if (!ing || !(qty > 0)) return showToast('اختار الخامة واكتب الكمية', 'error');
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
const SET2_DEFAULT_UNITS = ['كيلو', 'جرام', 'لتر', 'مللي', 'قطعة', 'علبة', 'كرتونة', 'رغيف', 'كيس', 'زجاجة', 'باكيت'];

async function set2EditIngredient(id) {
    const i = id ? (set2.data.ingredients || []).find(x => x.id === id) : {};
    const saved = appSet('inventory', 'units', []) || [];
    const used = (set2.data.ingredients || []).map(x => x.unit).filter(Boolean);
    const units = [...new Set([...SET2_DEFAULT_UNITS, ...saved, ...used])];
    const fields = [
        { key: 'name', label: 'اسم الخامة', value: i.name || '', required: true, list: SET2_INGREDIENT_CATALOG, help: 'اكتب حرفين وهتظهرلك أسماء جاهزة، أو اكتب اسم جديد' },
        { key: 'unit', label: 'الوحدة', type: 'select', options: units.map(u => [u, u]), value: i.unit || '', placeholder: 'اختار الوحدة', addNew: 'وحدة جديدة', required: true },
        { key: 'min', label: 'الحد الأدنى للتنبيه', type: 'number', min: 0, value: i.min_stock_alert ?? appSet('inventory', 'default_min_stock', 5), required: true }];
    if (!id) fields.push({ key: 'cost', label: 'تكلفة الوحدة المبدئية', type: 'money', min: 0, value: 0, help: 'بعد كده بتتحسب لوحدها من المشتريات' });
    const v = await uiForm(id ? 'تعديل خامة' : 'خامة جديدة', fields, { validate: x => {
        const dup = (set2.data.ingredients || []).find(y => y.id !== id && String(y.name).trim() === x.name);
        return dup ? { key: 'name', msg: 'الخامة دي موجودة قبل كده' } : null;
    } });
    if (!v) return;
    if (v.unit_new && !saved.includes(v.unit)) {
        try { await serverRpc('app_settings_save_secure', { p_section: 'inventory', p_data: { units: [...saved, v.unit].slice(-40) } }); } catch (err) { console.warn('unit not saved', err); }
        if (typeof loadAppSettings === 'function') loadAppSettings();
    }
    if (await uiCall('settings2_secure', { p_action: 'save_ingredient', p_data: { id: id || null, name: v.name, unit: v.unit, min_stock_alert: String(v.min || 0), cost_per_unit: String(v.cost || 0) } }, 'تم الحفظ')) initSettings2();
}

// ---------------------------------------------------------------- discounts, cancel reasons, areas
function set2RenderLists() {
    const box = document.getElementById('set-section-lists');
    if (!box) return;
    const typeNames = { void_item: 'إلغاء صنف', cancel_order: 'إلغاء طلب', return: 'مرتجع' };
    box.innerHTML = uiCard('الخصومات', uiTable(set2.data.discounts, [{ label: 'الاسم', key: 'name' },
        { label: 'القيمة', render: d => d.discount_type === 'percentage' ? `${uiEsc(d.value)}%` : formatCurrency(d.value) },
        { label: 'محتاج موافقة المدير', render: d => d.requires_approval !== false ? 'نعم' : 'لا' },
        { label: '', render: d => uiBtn('تعديل', `set2EditDiscount('${d.id}')`, 'gray') }], 'مفيش'), uiBtn('إضافة خصم', 'set2EditDiscount(null)', 'blue'))
        + uiCard('أسباب الإلغاء والمرتجع', uiTable(set2.data.cancel_reasons, [{ label: 'السبب', key: 'reason' }, { label: 'النوع', render: r => uiEsc(typeNames[r.reason_type] || r.reason_type) },
            { label: '', render: r => uiBtn('تعديل', `set2EditReason('${r.id}')`, 'gray') }], 'مفيش'), uiBtn('إضافة سبب', 'set2EditReason(null)', 'blue'))
        + uiCard('مناطق الصالة', uiTable(set2.data.areas, [{ label: 'المنطقة', key: 'name' }], 'مفيش'), uiBtn('إضافة منطقة', 'set2AddArea()', 'blue'));
}

async function set2EditDiscount(id) {
    const d = id ? set2.data.discounts.find(x => x.id === id) : {};
    const v = await uiForm(id ? 'تعديل خصم' : 'خصم جديد', [
        { key: 'name', label: 'اسم الخصم', value: d.name || '', required: true },
        { key: 'type', label: 'النوع', type: 'select', options: [['percentage', 'نسبة %'], ['fixed', 'مبلغ ثابت']], value: d.discount_type || 'percentage', required: true },
        { key: 'value', label: 'القيمة (النسبة أو المبلغ)', type: 'money', min: 0.01, value: d.value || '', required: true },
        { key: 'approval', label: 'محتاج موافقة المدير', type: 'check', value: d.requires_approval !== false }],
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
    box.innerHTML = uiCard('ربط طرق الدفع بالحسابات (للمالك بس)', uiTable(set2.data.payment_accounts, [{ label: 'طريقة الدفع', render: p => uiEsc(names[p.method] || p.method) },
        { label: 'الحساب', render: p => `<select onchange="set2PayAccount('${p.method}', this.value)" class="${uiInputClass()}">${accOpts.map(a => `<option value="${uiEsc(a.id)}" ${a.id === p.account_id ? 'selected' : ''}>${uiEsc(a.name)}</option>`).join('')}${p.account_id ? '' : '<option value="" selected>مش مربوط</option>'}</select>` }]))
        + uiCard('الضرايب والخدمة لكل فرع', uiTable(set2.data.tax, [{ label: 'الفرع', key: 'branch' },
            { label: 'الضريبة %', key: 'vat_percentage' }, { label: 'الخدمة %', key: 'service_charge_percentage' },
            { label: 'الأسعار شاملة الضريبة', render: t => `<input type="checkbox" id="tx-inc-${uiEsc(t.branch_id)}" ${t.is_vat_inclusive ? 'checked' : ''}>` },
            { label: 'الضريبة على الخدمة', render: t => `<input type="checkbox" id="tx-srv-${uiEsc(t.branch_id)}" ${t.is_service_taxable ? 'checked' : ''}>` },
            { label: '', render: t => uiBtn('حفظ', `set2TaxFlags('${t.branch_id}')`, 'green') }]),
            '<span class="text-[11px] text-slate-500 font-bold">النسب نفسها بتتعدل من "الضرائب والطاولات"</span>');
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
