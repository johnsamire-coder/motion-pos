// js/menuadmin.js - المنيو والوصفات في شاشة واحدة
// الأقسام والأصناف والأسعار والصور والوصف والإضافات والوصفة (المقادير) كلهم من هنا،
// والخامة الجديدة بتتعمل من جوه الصنف نفسه. كل حفظ بيرجع البيانات كلها، فمفيش ريفرش.

let ma = { data: null, cat: 'all', search: '', ed: null, imgCache: {} };

const MA_STATIONS = [['kitchen', 'المطبخ 👨‍🍳'], ['bar', 'البار 🍹'], ['shisha', 'الشيشة 💨']];
const MA_SMALL_UNITS = { 'كيلو': ['جرام', 1000], 'لتر': ['مللي', 1000] };

// وصفات مقترحة لأشهر الأصناف (نقطة بداية بس، وانت تعدّل المقادير على حسب المحل)
// [كلمة في اسم الصنف, [[الخامة, الوحدة, الكمية بالوحدة دي]]]
const MA_SUGGEST = [
    [/اسبريسو|إسبريسو|espresso/i, [['بن اسبريسو', 'كيلو', 0.018]]],
    [/دبل|double/i, [['بن اسبريسو', 'كيلو', 0.036]]],
    [/كابتشينو|cappuccino/i, [['بن اسبريسو', 'كيلو', 0.018], ['لبن', 'لتر', 0.15]]],
    [/لاتيه|لاتي|latte/i, [['بن اسبريسو', 'كيلو', 0.018], ['لبن', 'لتر', 0.2]]],
    [/موكا|mocha/i, [['بن اسبريسو', 'كيلو', 0.018], ['لبن', 'لتر', 0.15], ['صوص شوكولاتة', 'كيلو', 0.03]]],
    [/كراميل|caramel/i, [['بن اسبريسو', 'كيلو', 0.018], ['لبن', 'لتر', 0.2], ['صوص كراميل', 'كيلو', 0.03]]],
    [/أمريكان|امريكان|americano/i, [['بن اسبريسو', 'كيلو', 0.018]]],
    [/تركي|turkish/i, [['بن تركي', 'كيلو', 0.008], ['سكر', 'كيلو', 0.005]]],
    [/نسكافيه|nescafe/i, [['نسكافيه', 'كيلو', 0.004], ['لبن', 'لتر', 0.1], ['سكر', 'كيلو', 0.01]]],
    [/شاي.*(لبن|حليب)/, [['شاي', 'كيلو', 0.003], ['لبن', 'لتر', 0.15], ['سكر', 'كيلو', 0.01]]],
    [/شاي/, [['شاي', 'كيلو', 0.003], ['سكر', 'كيلو', 0.01]]],
    [/هوت ?شوك|شوكولاتة سخنة|hot choc/i, [['كاكاو', 'كيلو', 0.025], ['لبن', 'لتر', 0.2], ['سكر', 'كيلو', 0.01]]],
    [/برتقال/, [['برتقال', 'كيلو', 0.5]]],
    [/مانجو|mango/i, [['مانجو', 'كيلو', 0.25], ['سكر', 'كيلو', 0.02]]],
    [/فراولة|strawberry/i, [['فراولة', 'كيلو', 0.25], ['سكر', 'كيلو', 0.02]]],
    [/ليمون/, [['ليمون', 'كيلو', 0.1], ['نعناع', 'كيلو', 0.01], ['سكر', 'كيلو', 0.03]]],
    [/موز|banana/i, [['موز', 'كيلو', 0.2], ['لبن', 'لتر', 0.2], ['سكر', 'كيلو', 0.02]]],
    [/مياه|مية|water/i, [['مياه معدنية', 'زجاجة', 1]]],
    [/شيشة|معسل/, [['معسل', 'كيلو', 0.05], ['فحم', 'كيلو', 0.1]]],
    [/برجر|burger/i, [['عيش برجر', 'رغيف', 1], ['لحمة برجر', 'قطعة', 1], ['خس', 'كيلو', 0.02], ['طماطم', 'كيلو', 0.03]]],
    [/بطاطس|fries/i, [['بطاطس', 'كيلو', 0.2], ['زيت', 'لتر', 0.02]]],
    [/فراخ|chicken/i, [['عيش فينو', 'رغيف', 1], ['فراخ', 'كيلو', 0.15]]]
];

function maSuggestFor(name) {
    const n = String(name || '');
    for (const [re, lines] of MA_SUGGEST) if (re.test(n)) return lines;
    return null;
}

async function maCall(action, data, okMsg) {
    const res = await uiCall('menu_admin_secure', { p_action: action, p_data: data || null }, okMsg);
    if (res) {
        ma.data = res;
        if (typeof loadPOSMasterData === 'function' && currentUser && currentUser.branch_id) loadPOSMasterData().then(() => { if (typeof renderPOSTerminal === 'function') renderPOSTerminal(); }).catch(() => {});
    }
    return res;
}

async function renderMenuAdmin() {
    const root = document.getElementById('menuadmin-root');
    if (!root) return;
    if (!ma.data) {
        root.innerHTML = '<p class="text-center text-slate-400 font-bold py-10 text-xs">جاري تحميل المنيو...</p>';
        if (!(await maCall('get'))) { root.innerHTML = ''; return; }
    }
    const d = ma.data;
    const cats = d.categories || [];
    const catName = Object.fromEntries(cats.map(c => [c.id, c.name]));
    const q = ma.search.trim();
    const prods = (d.products || []).filter(p => (ma.cat === 'all' || p.category_id === ma.cat || (ma.cat === 'norecipe' && !p.recipe.length && p.is_available))
        && (!q || String(p.name).includes(q)));
    const noRecipe = (d.products || []).filter(p => !p.recipe.length && p.is_available).length;
    const pill = (key, label, n, active) => `<button onclick="ma.cat='${key}'; renderMenuAdmin()" class="shrink-0 whitespace-nowrap px-3 py-1.5 rounded-xl text-xs font-black ${active ? 'bg-blue-600 text-white shadow' : 'bg-slate-100 text-slate-700 hover:bg-slate-200'}">${uiEsc(label)} <span class="opacity-70">${n}</span></button>`;
    const cards = prods.map(p => {
        const pct = Number(p.price) ? Math.round(1000 * p.cost / p.price) / 10 : 0;
        const pctCls = !p.recipe.length ? 'bg-amber-100 text-amber-800' : pct <= 35 ? 'bg-emerald-100 text-emerald-800' : pct <= 50 ? 'bg-amber-100 text-amber-800' : 'bg-red-100 text-red-700';
        return `<button onclick="maOpen('${p.id}')" class="text-right bg-white border ${p.is_available ? 'border-slate-200' : 'border-red-200 opacity-70'} rounded-2xl p-3 hover:shadow-md hover:border-blue-300 transition flex flex-col gap-1 min-w-0">
            <div class="flex justify-between items-start gap-2"><span class="font-black text-sm text-slate-800 truncate">${p.has_image ? '📷 ' : ''}${uiEsc(p.name)}</span>
                <span class="font-black text-sm text-blue-700 whitespace-nowrap">${formatCurrency(p.price)}</span></div>
            <span class="text-[11px] font-bold text-slate-500 truncate">${uiEsc(catName[p.category_id] || '')}${p.description ? ' | ' + uiEsc(p.description) : ''}</span>
            <div class="flex flex-wrap gap-1 mt-1">
                <span class="text-[10px] font-black rounded-lg px-1.5 py-0.5 ${p.recipe.length && !Number(p.cost) ? 'bg-amber-100 text-amber-800' : pctCls}">${!p.recipe.length ? '⚠️ ناقص وصفة' : (Number(p.cost) ? `التكلفة ${formatCurrency(p.cost)} (${pct}%)` : '⚠️ الوصفة موجودة بس الخامات لسه من غير سعر')}</span>
                ${p.is_available ? '' : '<span class="text-[10px] font-black rounded-lg px-1.5 py-0.5 bg-red-100 text-red-700">موقوف</span>'}
                ${p.show_in_menu ? '' : '<span class="text-[10px] font-black rounded-lg px-1.5 py-0.5 bg-slate-200 text-slate-600">مش ظاهر في منيو الـ QR</span>'}
                ${p.group_ids.length ? `<span class="text-[10px] font-black rounded-lg px-1.5 py-0.5 bg-violet-100 text-violet-700">إضافات ${p.group_ids.length}</span>` : ''}
            </div></button>`;
    }).join('');
    root.innerHTML = uiCard('🍽️ المنيو والوصفات', `
        <div class="flex flex-wrap gap-2 items-center mb-3">
            <input value="${uiEsc(ma.search)}" oninput="ma.search=this.value; clearTimeout(window._maT); window._maT=setTimeout(renderMenuAdmin, 250)" placeholder="🔍 دوّر على صنف" class="${uiInputClass()} flex-1 min-w-[160px]">
            <span class="text-[11px] font-bold text-slate-500">${(d.products || []).length} صنف | ${cats.length} قسم${noRecipe ? ` | <button onclick="ma.cat='norecipe'; renderMenuAdmin()" class="text-amber-700 underline">${noRecipe} ناقص وصفة</button>` : ''}</span>
        </div>
        <div class="flex gap-2 overflow-x-auto pb-2 mb-3">
            ${pill('all', 'الكل', (d.products || []).length, ma.cat === 'all')}
            ${cats.map(c => pill(c.id, c.name, c.products, ma.cat === c.id)).join('')}
            ${noRecipe ? pill('norecipe', '⚠️ ناقص وصفة', noRecipe, ma.cat === 'norecipe') : ''}
        </div>
        ${ma.cat !== 'all' && ma.cat !== 'norecipe' && catName[ma.cat] ? `<div class="flex flex-wrap gap-2 mb-3 text-xs">${uiBtn('✏️ تعديل القسم ده', `maEditCategory('${ma.cat}')`, 'gray')}
            ${(cats.find(c => c.id === ma.cat) || {}).products ? '' : uiBtn('🗑️ مسح القسم', `maDeleteCategory('${ma.cat}')`, 'red')}</div>` : ''}
        <div class="grid grid-cols-1 sm:grid-cols-2 xl:grid-cols-3 gap-3">${cards || '<p class="text-center text-slate-400 font-bold text-xs py-8 sm:col-span-2 xl:col-span-3">مفيش أصناف هنا. دوس "➕ صنف جديد".</p>'}</div>`,
        `${uiBtn('➕ صنف جديد', 'maOpen(null)', 'green')} ${uiBtn('➕ قسم جديد', 'maEditCategory(null)', 'blue')} ${uiBtn('📥 إدخال المنيو مرة واحدة', 'maImport()', 'gray')} ${uiBtn('🧪 إدخال الوصفات مرة واحدة', 'maImportRecipes()', 'gray')}`);
}

async function maEditCategory(id) {
    const c = id ? (ma.data.categories || []).find(x => x.id === id) : {};
    const v = await uiForm(id ? 'تعديل القسم' : 'قسم جديد', [
        { key: 'name', label: 'اسم القسم', value: c.name || '', required: true },
        { key: 'station', label: 'أصنافه بتتحضّر فين', type: 'select', options: MA_STATIONS, value: c.station || 'kitchen', required: true },
        { key: 'sort', label: 'ترتيبه في المنيو (الأصغر الأول)', type: 'number', min: 0, value: c.sort_order ?? '' },
        { key: 'show', label: 'يظهر في منيو الـ QR للعميل', type: 'check', value: c.show_in_menu !== false },
        ...(id ? [{ type: 'note', label: c.products ? `فيه ${c.products} صنف في القسم ده.` : 'القسم فاضي، تقدر تمسحه من زرار "مسح القسم" اللي جنب "تعديل القسم".' }] : [])],
        { ok: 'حفظ' });
    if (!v) return;
    const res = await maCall('save_category', { id: id || null, name: v.name, station: v.station, sort_order: v.sort === null ? '' : String(v.sort), show_in_menu: v.show }, 'تم الحفظ');
    if (res && !id) ma.cat = res.id;
    renderMenuAdmin();
    if (typeof initSettings2 === 'function' && set2 && set2.data) initSettings2();
}

async function maDeleteCategory(id) {
    if (!(await uiConfirm('تمسح القسم ده؟', 'مسح', true))) return;
    if (await maCall('delete_category', { id }, 'اتمسح')) { ma.cat = 'all'; renderMenuAdmin(); }
}

// ---------------------------------------------------------------- محرر الصنف
function maOpen(id) {
    const d = ma.data;
    const p = id ? (d.products || []).find(x => x.id === id) : null;
    ma.ed = p ? { ...p, recipe: p.recipe.map(r => ({ ...r })), group_ids: [...p.group_ids], image: null, imageChanged: false }
        : { id: null, name: '', price: '', category_id: (ma.cat !== 'all' && ma.cat !== 'norecipe') ? ma.cat : ((d.categories || [])[0] || {}).id || '',
            description: '', is_available: true, show_in_menu: true, sort_order: 0, recipe: [], group_ids: [], has_image: false, image: null, imageChanged: false };
    let ov = document.getElementById('ma-editor');
    if (!ov) {
        ov = document.createElement('div');
        ov.id = 'ma-editor';
        ov.className = 'fixed inset-0 bg-slate-900/60 z-[55] flex items-start justify-center p-3 overflow-y-auto';
        document.body.appendChild(ov);
    }
    ov.classList.remove('hidden');
    maRenderEditor();
    if (p && p.has_image) maLoadImage(p.id);
}

function maClose() {
    const ov = document.getElementById('ma-editor');
    if (ov) { ov.classList.add('hidden'); ov.innerHTML = ''; }
    ma.ed = null;
}

async function maLoadImage(id) {
    if (ma.imgCache[id] === undefined) {
        try { const r = await serverRpc('menu_admin_secure', { p_action: 'get_image', p_data: { id } }); ma.imgCache[id] = (r && r.image) || ''; }
        catch (e) { ma.imgCache[id] = ''; }
    }
    const img = document.getElementById('ma-img');
    if (img && ma.ed && ma.ed.id === id && !ma.ed.imageChanged && ma.imgCache[id]) { img.src = ma.imgCache[id]; img.classList.remove('hidden'); }
}

function maIngs() { return Object.fromEntries((ma.data.ingredients || []).map(i => [i.id, i])); }

function maRecipeCost() {
    const ings = maIngs();
    return ma.ed.recipe.reduce((s, r) => s + (Number(r.qty) || 0) * (Number(ings[r.ingredient_id]?.cost_per_unit) || 0), 0);
}

// يحفظ اللي مكتوب في الخانات قبل أي إعادة رسم
function maReadFields() {
    const e = ma.ed;
    if (!e || !document.getElementById('ma-name')) return;
    e.name = document.getElementById('ma-name').value;
    e.price = document.getElementById('ma-price').value;
    e.category_id = document.getElementById('ma-cat').value;
    e.description = document.getElementById('ma-desc').value;
    e.is_available = document.getElementById('ma-avail').checked;
    e.show_in_menu = document.getElementById('ma-show').checked;
    e.sort_order = document.getElementById('ma-sort').value;
    e.group_ids = [...document.querySelectorAll('[data-ma-group]:checked')].map(x => x.value);
}

function maRenderEditor() {
    const ov = document.getElementById('ma-editor');
    const e = ma.ed;
    if (!ov || !e) return;
    const d = ma.data;
    const ings = maIngs();
    const cost = maRecipeCost();
    const price = Number(e.price) || 0;
    const pct = price ? Math.round(1000 * cost / price) / 10 : 0;
    const profit = price - cost;
    const sug = maSuggestFor(e.name);
    const rows = e.recipe.map((r, i) => {
        const ing = ings[r.ingredient_id] || {};
        const small = MA_SMALL_UNITS[ing.unit];
        return `<tr class="border-b text-xs font-bold">
            <td class="p-1.5"><select onchange="maRowIng(${i}, this.value)" class="${uiInputClass()} w-full max-w-[170px]">${(d.ingredients || []).map(x => `<option value="${uiEsc(x.id)}" ${x.id === r.ingredient_id ? 'selected' : ''}>${uiEsc(x.name)}</option>`).join('')}</select></td>
            <td class="p-1.5 whitespace-nowrap"><input type="number" min="0" step="any" value="${uiEsc(r.qty)}" oninput="maRowQty(${i}, this.value)" class="${uiInputClass()} w-20"> <span class="text-slate-500">${uiEsc(ing.unit || '')}</span>
                ${small ? `<br><span id="ma-rh-${i}" class="text-[10px] text-slate-400">= ${Math.round((Number(r.qty) || 0) * small[1] * 100) / 100} ${small[0]}</span>` : ''}</td>
            <td class="p-1.5 whitespace-nowrap"><span id="ma-rc-${i}">${formatCurrency((Number(r.qty) || 0) * (Number(ing.cost_per_unit) || 0))}</span>${Number(ing.cost_per_unit) ? '' : '<br><span class="text-[10px] text-amber-700">الخامة لسه من غير سعر</span>'}</td>
            <td class="p-1.5"><button onclick="maRowDel(${i})" class="text-red-600 bg-red-50 border border-red-100 rounded-lg px-2 py-1">🗑️ حذف</button></td></tr>`;
    }).join('');
    ov.innerHTML = `<div class="bg-white rounded-3xl shadow-2xl w-full max-w-5xl my-4 p-5 text-right" dir="rtl">
        <div class="flex justify-between items-center border-b pb-3 mb-4"><h3 class="font-black text-base">${e.id ? '✏️ تعديل الصنف' : '➕ صنف جديد'}</h3>
            <button onclick="maClose()" class="text-slate-400 hover:text-slate-700 font-black text-lg">✕</button></div>
        <div class="grid grid-cols-1 lg:grid-cols-5 gap-5">
            <div class="lg:col-span-2 space-y-3 text-xs font-black">
                <label class="block">اسم الصنف *<input id="ma-name" value="${uiEsc(e.name)}" oninput="ma.ed.name=this.value" class="${uiInputClass()} w-full mt-1 text-sm"></label>
                <div class="grid grid-cols-2 gap-2">
                    <label class="block">سعر البيع *<input id="ma-price" type="number" min="0" step="any" value="${uiEsc(e.price)}" oninput="ma.ed.price=this.value; maUpdateSummary()" class="${uiInputClass()} w-full mt-1 text-sm"></label>
                    <label class="block">القسم *<select id="ma-cat" onchange="if(this.value==='__new__'){maReadFields(); maNewCatInline();}" class="${uiInputClass()} w-full mt-1 text-sm">
                        ${(d.categories || []).map(c => `<option value="${uiEsc(c.id)}" ${c.id === e.category_id ? 'selected' : ''}>${uiEsc(c.name)}</option>`).join('')}<option value="__new__">➕ قسم جديد</option></select></label>
                </div>
                <label class="block">وصف قصير (بيظهر للعميل في منيو الـ QR)<textarea id="ma-desc" rows="2" maxlength="500" class="${uiInputClass()} w-full mt-1" placeholder="مثلاً: دبل شوت اسبريسو مع لبن مبخّر">${uiEsc(e.description || '')}</textarea></label>
                <div class="flex flex-wrap gap-4">
                    <label class="flex items-center gap-1.5"><input id="ma-avail" type="checkbox" class="w-4 h-4" ${e.is_available ? 'checked' : ''}> متاح للبيع</label>
                    <label class="flex items-center gap-1.5"><input id="ma-show" type="checkbox" class="w-4 h-4" ${e.show_in_menu ? 'checked' : ''}> يظهر في منيو الـ QR</label>
                    <label class="flex items-center gap-1.5">الترتيب <input id="ma-sort" type="number" min="0" value="${uiEsc(e.sort_order ?? 0)}" class="${uiInputClass()} w-16"></label>
                </div>
                <div class="border rounded-2xl p-3"><p class="mb-2">صورة الصنف (اختياري، بتخلّي منيو الـ QR أشيك)</p>
                    <div class="flex items-center gap-3"><img id="ma-img" class="${e.image ? '' : 'hidden'} w-20 h-20 object-cover rounded-xl border" src="${e.image ? uiEsc(e.image) : ''}">
                        <div class="space-y-1"><input type="file" accept="image/*" onchange="maPickImage(this)" class="text-[11px]">
                        ${(e.has_image || e.image) ? `<button onclick="maRemoveImage()" class="text-red-600 text-[11px] underline block">شيل الصورة</button>` : ''}</div></div></div>
                <div class="border rounded-2xl p-3"><p class="mb-2">الإضافات المسموحة للصنف</p>
                    ${(d.groups || []).length ? `<div class="flex flex-wrap gap-3">${d.groups.map(g => `<label class="flex items-center gap-1.5 font-bold"><input type="checkbox" data-ma-group value="${uiEsc(g.id)}" ${e.group_ids.includes(g.id) ? 'checked' : ''}> ${uiEsc(g.name)} <span class="text-slate-400">(${g.modifiers})</span></label>`).join('')}</div>`
                        : '<p class="text-[11px] font-bold text-slate-400">مفيش مجموعات إضافات. بتتعمل من: الإعدادات ← الإضافات.</p>'}</div>
            </div>
            <div class="lg:col-span-3">
                <div class="flex flex-wrap justify-between items-center gap-2 mb-2"><p class="text-sm font-black">🥣 الوصفة (المقادير لصنف واحد)</p>
                    ${sug ? `<button onclick="maApplySuggest()" class="text-xs font-black bg-amber-100 text-amber-800 border border-amber-200 rounded-xl px-3 py-1.5">💡 وصفة مقترحة لـ "${uiEsc(e.name)}"</button>` : ''}</div>
                <div class="overflow-x-auto"><table class="w-full text-right"><thead><tr class="text-[11px] text-slate-500"><th class="p-1.5">الخامة</th><th class="p-1.5">الكمية</th><th class="p-1.5">التكلفة</th><th></th></tr></thead>
                    <tbody>${rows || '<tr><td colspan="4" class="text-center text-xs font-bold text-slate-400 py-4">لسه مفيش مقادير. ضيف أول خامة تحت 👇</td></tr>'}</tbody></table></div>
                <div class="bg-slate-50 border rounded-2xl p-3 mt-3 space-y-2">
                    <p class="text-xs font-black">إضافة خامة للوصفة</p>
                    <div class="flex flex-wrap gap-2 items-center">
                        <input id="ma-add-ing" list="ma-ing-list" placeholder="اكتب اسم الخامة" oninput="maAddHint()" class="${uiInputClass()} flex-1 min-w-[150px]">
                        <datalist id="ma-ing-list">${(d.ingredients || []).map(x => `<option value="${uiEsc(x.name)}">`).join('')}</datalist>
                        <input id="ma-add-qty" type="number" min="0" step="any" placeholder="الكمية" class="${uiInputClass()} w-24">
                        <select id="ma-add-unit" class="${uiInputClass()}"></select>
                        <button onclick="maAddLine()" class="bg-blue-600 text-white rounded-xl px-4 py-2 text-xs font-black">إضافة</button>
                    </div>
                    <div id="ma-add-new" class="hidden flex flex-wrap gap-2 items-center bg-white border border-amber-200 rounded-xl p-2">
                        <span class="text-[11px] font-black text-amber-800">خامة جديدة! وحدتها:</span>
                        <select id="ma-new-unit" onchange="maAddHint()" class="${uiInputClass()}">${['كيلو', 'جرام', 'لتر', 'مللي', 'قطعة', 'علبة', 'رغيف', 'كيس', 'زجاجة', 'باكيت'].map(u => `<option>${u}</option>`).join('')}</select>
                        <span class="text-[11px] font-black">سعر الوحدة (لو تعرفه)</span><input id="ma-new-cost" type="number" min="0" step="any" class="${uiInputClass()} w-24" placeholder="0">
                        <span class="text-[10px] font-bold text-slate-500">بعد كده بيتحسب لوحده من المشتريات</span>
                    </div>
                </div>
                <div class="grid grid-cols-3 gap-2 mt-3 text-center">
                    <div class="bg-slate-50 rounded-xl p-2"><p class="text-[11px] font-bold text-slate-500">تكلفة الصنف</p><p id="ma-sum-cost" class="font-black">${formatCurrency(cost)}</p></div>
                    <div class="bg-slate-50 rounded-xl p-2"><p class="text-[11px] font-bold text-slate-500">نسبة التكلفة</p><p id="ma-sum-pct" class="font-black ${pct <= 35 ? 'text-emerald-700' : pct <= 50 ? 'text-amber-700' : 'text-red-600'}">${pct}%</p></div>
                    <div class="bg-slate-50 rounded-xl p-2"><p class="text-[11px] font-bold text-slate-500">مكسب الصنف</p><p id="ma-sum-profit" class="font-black">${formatCurrency(profit)}</p></div>
                </div>
                <p class="text-[10px] font-bold text-slate-400 mt-2">نسبة التكلفة الكويسة في الكافيهات غالباً من 25% لـ 35%.</p>
            </div>
        </div>
        <div class="flex flex-wrap gap-2 mt-5 border-t pt-4">
            <button onclick="maSave()" class="flex-1 min-w-[160px] bg-emerald-600 hover:bg-emerald-700 text-white py-3 rounded-xl font-black text-sm">💾 حفظ الصنف</button>
            ${e.id ? `<button onclick="maDelete()" class="bg-red-50 text-red-600 border border-red-200 px-4 py-3 rounded-xl font-black text-xs">${e.sold ? 'إيقاف الصنف' : 'مسح الصنف'}</button>` : ''}
            <button onclick="maClose()" class="bg-slate-100 text-slate-700 px-5 py-3 rounded-xl font-black text-xs">إلغاء</button>
        </div></div>`;
    maAddHint();
}

// السعر بيتغيّر: الأرقام اللي تحت بس بتتحدّث (من غير ما الشاشة تترسم تاني وزرار الحفظ يفلت)
function maUpdateSummary() {
    const cost = maRecipeCost(), price = Number(ma.ed.price) || 0;
    const pct = price ? Math.round(1000 * cost / price) / 10 : 0;
    const c = document.getElementById('ma-sum-cost'), p = document.getElementById('ma-sum-pct'), f = document.getElementById('ma-sum-profit');
    if (c) c.textContent = formatCurrency(cost);
    if (p) { p.textContent = pct + '%'; p.className = 'font-black ' + (pct <= 35 ? 'text-emerald-700' : pct <= 50 ? 'text-amber-700' : 'text-red-600'); }
    if (f) f.textContent = formatCurrency(price - cost);
}

// اسم الخامة: لو موجودة الوحدة بتتظبط، ولو جديدة بيظهر سطر الخامة الجديدة
function maAddHint() {
    const name = (document.getElementById('ma-add-ing')?.value || '').trim();
    const ing = (ma.data.ingredients || []).find(x => x.name.trim() === name);
    const box = document.getElementById('ma-add-new');
    if (box) box.classList.toggle('hidden', !name || !!ing);
    const unit = ing ? ing.unit : (document.getElementById('ma-new-unit')?.value || '');
    const sel = document.getElementById('ma-add-unit');
    if (sel) {
        const small = MA_SMALL_UNITS[unit];
        const prev = sel.value;
        sel.innerHTML = `<option value="1">${uiEsc(unit || 'الوحدة')}</option>` + (small ? `<option value="${small[1]}">${small[0]}</option>` : '');
        if (small && prev === String(small[1])) sel.value = prev;
    }
}

async function maAddLine() {
    maReadFields();
    const name = (document.getElementById('ma-add-ing').value || '').trim();
    const qtyIn = Number(document.getElementById('ma-add-qty').value);
    const div = Number(document.getElementById('ma-add-unit').value) || 1;
    if (!name || !(qtyIn > 0)) return showToast('اكتب اسم الخامة والكمية', 'error');
    let ing = (ma.data.ingredients || []).find(x => x.name.trim() === name);
    if (!ing) {
        const unit = document.getElementById('ma-new-unit').value;
        const costV = document.getElementById('ma-new-cost').value;
        const res = await maCall('add_ingredient', { name, unit, cost_per_unit: String(Number(costV) || 0) }, 'اتعملت الخامة');
        if (!res) return;
        ing = (ma.data.ingredients || []).find(x => x.id === res.id);
    }
    const qty = Math.round((qtyIn / div) * 1e6) / 1e6;
    const ex = ma.ed.recipe.find(r => r.ingredient_id === ing.id);
    if (ex) ex.qty = Math.round(((Number(ex.qty) || 0) + qty) * 1e6) / 1e6; else ma.ed.recipe.push({ ingredient_id: ing.id, qty });
    maRenderEditor();
    setTimeout(() => document.getElementById('ma-add-ing')?.focus(), 30);
}

function maRowQty(i, v) {
    const r = ma.ed.recipe[i];
    r.qty = Number(v) || 0;
    const ing = maIngs()[r.ingredient_id] || {}, small = MA_SMALL_UNITS[ing.unit];
    const c = document.getElementById('ma-rc-' + i), h = document.getElementById('ma-rh-' + i);
    if (c) c.textContent = formatCurrency(r.qty * (Number(ing.cost_per_unit) || 0));
    if (h && small) h.textContent = `= ${Math.round(r.qty * small[1] * 100) / 100} ${small[0]}`;
    maUpdateSummary();
}
function maRowIng(i, v) { maReadFields(); ma.ed.recipe[i].ingredient_id = v; maRenderEditor(); }
async function maRowDel(i) {
    maReadFields();
    const ing = maIngs()[ma.ed.recipe[i].ingredient_id] || {};
    if (!(await uiConfirm(`تحذف "${ing.name || ''}" من الوصفة؟`, 'حذف', true))) return;
    ma.ed.recipe.splice(i, 1);
    maRenderEditor();
}

async function maApplySuggest() {
    maReadFields();
    const lines = maSuggestFor(ma.ed.name);
    if (!lines) return;
    const ings = ma.data.ingredients || [];
    const missing = lines.filter(([n]) => !ings.some(x => x.name.trim() === n));
    const msg = `هتتضاف المقادير دي (تقدر تعدّلها بعدها):\n${lines.map(([n, u, q]) => `• ${n}: ${q} ${u}`).join('\n')}`
        + (missing.length ? `\n\nخامات جديدة هتتعمل (من غير سعر لحد ما تشتريها): ${missing.map(x => x[0]).join('، ')}` : '');
    if (!(await uiConfirm(msg, 'ضيفهم'))) return;
    for (const [n, u] of missing) { if (!(await maCall('add_ingredient', { name: n, unit: u, cost_per_unit: '0' }))) return; }
    const all = ma.data.ingredients || [];
    for (const [n, , q] of lines) {
        const ing = all.find(x => x.name.trim() === n);
        if (!ing) continue;
        const ex = ma.ed.recipe.find(r => r.ingredient_id === ing.id);
        if (ex) ex.qty = q; else ma.ed.recipe.push({ ingredient_id: ing.id, qty: q });
    }
    maRenderEditor();
}

async function maNewCatInline() {
    const v = await uiForm('قسم جديد', [{ key: 'name', label: 'اسم القسم', required: true },
        { key: 'station', label: 'بيتحضّر فين', type: 'select', options: MA_STATIONS, value: 'kitchen' }], { ok: 'إضافة' });
    if (v) {
        const res = await maCall('save_category', { name: v.name, station: v.station }, 'اتعمل القسم');
        if (res) ma.ed.category_id = res.id;
    }
    maRenderEditor();
}

function maPickImage(input) {
    const file = input.files && input.files[0];
    if (!file) return;
    maReadFields();
    const reader = new FileReader();
    reader.onload = () => {
        const img = new Image();
        img.onload = () => {
            const max = 640;
            const scale = Math.min(1, max / Math.max(img.width, img.height));
            const canvas = document.createElement('canvas');
            canvas.width = Math.round(img.width * scale); canvas.height = Math.round(img.height * scale);
            canvas.getContext('2d').drawImage(img, 0, 0, canvas.width, canvas.height);
            let url = canvas.toDataURL('image/jpeg', 0.78);
            if (url.length > 340000) url = canvas.toDataURL('image/jpeg', 0.55);
            if (url.length > 340000) return showToast('الصورة كبيرة جداً، اختار صورة أصغر', 'error');
            ma.ed.image = url; ma.ed.imageChanged = true;
            maRenderEditor();
        };
        img.onerror = () => showToast('الملف ده مش صورة', 'error');
        img.src = reader.result;
    };
    reader.readAsDataURL(file);
}

function maRemoveImage() { maReadFields(); ma.ed.image = ''; ma.ed.has_image = false; ma.ed.imageChanged = true; maRenderEditor(); }

async function maSave() {
    maReadFields();
    const e = ma.ed;
    if (!e.name.trim()) return showToast('اكتب اسم الصنف', 'error');
    if (e.price === '' || !(Number(e.price) >= 0)) return showToast('اكتب سعر البيع', 'error');
    if (!e.category_id || e.category_id === '__new__') return showToast('اختار القسم', 'error');
    const res = await maCall('save_product', {
        id: e.id, name: e.name.trim(), price: String(Number(e.price)), category_id: e.category_id, description: e.description || '',
        is_available: e.is_available, show_in_menu: e.show_in_menu, sort_order: String(Number(e.sort_order) || 0),
        recipe: e.recipe.filter(r => Number(r.qty) > 0).map(r => ({ ingredient_id: r.ingredient_id, qty: String(r.qty) })),
        group_ids: e.group_ids }, 'اتحفظ الصنف ✅');
    if (!res) return;
    if (e.imageChanged) {
        await maCall('set_image', { id: res.id, image: e.image || '' });
        ma.imgCache[res.id] = e.image || '';
    }
    maClose();
    renderMenuAdmin();
}

async function maDelete() {
    const e = ma.ed;
    const msg = e.sold ? `الصنف "${e.name}" اتباع قبل كده، فمش هيتمسح عشان الفواتير القديمة. هيتوقف ويستخبى من المنيو. موافق؟` : `تمسح "${e.name}" نهائي؟`;
    if (!(await uiConfirm(msg, e.sold ? 'إيقاف' : 'مسح', true))) return;
    if (await maCall('delete_product', { id: e.id }, e.sold ? 'اتوقف الصنف' : 'اتمسح الصنف')) { maClose(); renderMenuAdmin(); }
}

// ---------------------------------------------------------------- إدخال المنيو كله مرة واحدة (لصق)
async function maImport() {
    const v = await uiForm('📥 إدخال المنيو مرة واحدة', [
        { type: 'note', html: `<p class="text-sm">كل سطر صنف بالشكل ده: <b>القسم - الصنف - السعر</b> (وممكن وصف في الآخر)<br>مثال:<br>مشروبات ساخنة - كابتشينو - 65<br>مشروبات ساخنة - شاي - 25 - شاي فتلة بالنعناع<br>
            الصنف اللي اسمه موجود قبل كده سعره بيتعدّل بس. والأقسام الجديدة بتتعمل لوحدها.</p>` },
        { key: 'text', label: 'الأصناف', type: 'textarea', rows: 12, full: true, required: true },
        { key: 'station', label: 'الأقسام الجديدة بتتحضّر فين (تقدر تغيّرها بعدين لكل قسم)', type: 'select', options: MA_STATIONS, value: 'kitchen' }], { ok: 'معاينة' });
    if (!v) return;
    const rows = [], bad = [];
    String(v.text).split('\n').map(x => x.trim()).filter(Boolean).forEach((line, i) => {
        const parts = line.split(/\s*[-|،,\t]\s*/).map(x => x.trim()).filter(Boolean);
        const toNum = s => Number(String(s).replace(/[٠-٩]/g, ch => '٠١٢٣٤٥٦٧٨٩'.indexOf(ch)).replace(/[^0-9.]/g, ''));
        if (parts.length < 3 || !(toNum(parts[2]) >= 0) || !/[0-9٠-٩]/.test(parts[2])) { bad.push(`سطر ${i + 1}: ${line}`); return; }
        rows.push({ category: parts[0], name: parts[1], price: String(toNum(parts[2])), description: parts.slice(3).join(' - '), station: v.station });
    });
    if (!rows.length) return showToast('مفيش ولا سطر مظبوط', 'error');
    const ok = await uiConfirm(`هيتسجل ${rows.length} صنف.${bad.length ? `\n\nالسطور دي فيها غلط ومش هتتسجل:\n${bad.slice(0, 10).join('\n')}` : ''}\n\nأول ٣:\n${rows.slice(0, 3).map(r => `• ${r.category} / ${r.name} / ${r.price}`).join('\n')}`, 'سجّل');
    if (!ok) return;
    const res = await maCall('import', { rows });
    if (res) { showToast(`اتسجل ${res.created} صنف جديد، واتعدل ${res.updated}`); ma.cat = 'all'; renderMenuAdmin(); }
}

// ---------------------------------------------------------------- الوصفات لأصناف كتير مرة واحدة (لصق)
// كل سطر: الصنف - الخامة - الكمية - الوحدة. الصنف اللي ليه وصفة قبل كده بيفضل زي ما هو إلا لو اخترت "استبدال".
async function maImportRecipes() {
    let suggested = '';
    try { const r = await fetch('recipes_suggested.txt', { cache: 'no-store' }); if (r.ok) suggested = await r.text(); } catch (e) { /* empty box */ }
    const v = await uiForm('🧪 إدخال الوصفات مرة واحدة', [
        { type: 'note', html: `<p class="text-sm">كل سطر خامة واحدة في صنف: <b>الصنف - الخامة - الكمية - الوحدة</b> (الكمية للكوباية أو الطبق الواحد)<br>مثال:<br>كابتشينو - بن اسبريسو - 0.018 - كيلو<br>كابتشينو - لبن - 0.15 - لتر<br>
            ${suggested ? '<b class="text-emerald-700">الصندوق فيه وصفات مقترحة لأصناف المنيو، راجعها وعدّل اللي محتاجه.</b><br>' : ''}الخامة اللي مش موجودة بتتعمل لوحدها بتكلفة صفر (التكلفة بتتحدّث من المشتريات). والسطور اللي بتبدأ بـ # مش بتتحسب.</p>` },
        { key: 'text', label: 'الوصفات', type: 'textarea', rows: 14, full: true, required: true, value: suggested },
        { key: 'overwrite', label: 'الأصناف اللي ليها وصفة قبل كده', type: 'select', options: [['keep', 'سيبها زي ما هي'], ['replace', 'استبدلها بالجديدة']], value: 'keep' }], { ok: 'معاينة' });
    if (!v) return;
    const toNum = s => Number(String(s).replace(/[٠-٩]/g, ch => '٠١٢٣٤٥٦٧٨٩'.indexOf(ch)).replace('٫', '.').replace(/[^0-9.]/g, ''));
    const rows = [], bad = [];
    String(v.text).split('\n').map(x => x.trim()).filter(x => x && !x.startsWith('#')).forEach((line, i) => {
        const parts = line.split(/\s+-\s+|\s*\|\s*|\t/).map(x => x.trim()).filter(Boolean);
        if (parts.length < 4) { bad.push(line); return; }
        const unit = parts[parts.length - 1], qty = toNum(parts[parts.length - 2]), ingredient = parts[parts.length - 3];
        const product = parts.slice(0, parts.length - 3).join(' - ');
        if (!(qty > 0) || !/[0-9٠-٩]/.test(parts[parts.length - 2])) { bad.push(line); return; }
        rows.push({ product, ingredient, qty: String(qty), unit });
    });
    if (!rows.length) return showToast('مفيش ولا سطر مظبوط', 'error');
    const d = ma.data || {};
    const prodByName = new Map((d.products || []).map(p => [String(p.name).trim(), p]));
    const ingByName = new Map((d.ingredients || []).map(i => [String(i.name).trim(), i]));
    const products = [...new Set(rows.map(r => r.product))];
    const missing = products.filter(n => !prodByName.has(n));
    const hasRecipe = products.filter(n => prodByName.has(n) && (prodByName.get(n).recipe || []).length);
    const newIngs = [...new Set(rows.filter(r => !ingByName.has(r.ingredient)).map(r => r.ingredient))];
    const unitClash = [...new Set(rows.filter(r => ingByName.has(r.ingredient) && String(ingByName.get(r.ingredient).unit || '').trim() !== r.unit)
        .map(r => `${r.ingredient}: موجودة بـ"${ingByName.get(r.ingredient).unit}" والوصفة مكتوبة بـ"${r.unit}"`))];
    const replace = v.overwrite === 'replace';
    const msg = [`${products.length - missing.length} صنف هتتسجل وصفته${!replace && hasRecipe.length ? ` (منهم ${hasRecipe.length} ليهم وصفة قبل كده وهيفضلوا زي ما هما)` : ''}.`,
        replace && hasRecipe.length ? `⚠️ ${hasRecipe.length} صنف وصفتهم القديمة هتتمسح وتتحط الجديدة.` : '',
        newIngs.length ? `خامات جديدة هتتعمل (${newIngs.length}): ${newIngs.slice(0, 15).join('، ')}${newIngs.length > 15 ? '...' : ''}` : '',
        unitClash.length ? `⚠️ انتبه للوحدة (الكمية بتتحسب بوحدة الخامة الموجودة):\n${unitClash.slice(0, 8).join('\n')}` : '',
        missing.length ? `أصناف مش موجودة في المنيو ومش هتتسجل (${missing.length}): ${missing.slice(0, 10).join('، ')}` : '',
        bad.length ? `سطور فيها غلط (${bad.length}):\n${bad.slice(0, 6).join('\n')}` : ''].filter(Boolean).join('\n\n');
    if (!(await uiConfirm(msg, 'سجّل الوصفات'))) return;
    const res = await maCall('import_recipes', { rows: rows.filter(r => prodByName.has(r.product)), overwrite: replace });
    if (res) { showToast(`اتسجلت وصفات ${res.imported} صنف، و${res.new_ingredients} خامة جديدة${res.skipped ? `، و${res.skipped} صنف فضل زي ما هو` : ''}`); renderMenuAdmin(); }
}

// شاشة الإعدادات: قسم "المنيو والوصفات" بيترسم أول ما الإعدادات تفتح
if (typeof initSettingsModule === 'function') {
    const _maOrigInit = initSettingsModule;
    initSettingsModule = async function () {
        await _maOrigInit();
        ma.data = null;
        renderMenuAdmin();
    };
}
