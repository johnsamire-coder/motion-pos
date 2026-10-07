// js/modifiers.js - الإعدادات ← الإضافات
// مجموعة إضافات (مثلاً "إضافات البرجر") فيها كذا إضافة بسعرها، وممكن كل إضافة تخصم خامة من المخزن.
// المجموعة بتتربط بالأصناف. السعر بيتحسب على السيرفر وقت الإرسال للمطبخ.

let modState = { groups: [], products: [], ingredients: [], edit: null };

async function set2RenderModifiers() {
    const box = document.getElementById('set-section-modifiers');
    if (!box) return;
    const res = await uiCall('modifiers_admin_secure', { p_action: 'get', p_data: null });
    if (!res) return;
    modState.groups = res.groups || [];
    modState.products = res.products || [];
    modState.ingredients = res.ingredients || [];
    modRender();
}

function modRuleText(g) {
    const min = Number(g.min_selection) || 0;
    const max = Number(g.max_selection) || 1;
    if (min > 0) return min === max ? `لازم يختار ${min}` : `لازم يختار من ${min} لـ ${max}`;
    return max === 1 ? 'اختياري (واحدة بس)' : `اختياري (لحد ${max})`;
}

function modRender() {
    const box = document.getElementById('set-section-modifiers');
    if (!box) return;
    if (modState.edit) { box.innerHTML = modEditorHtml(); return; }
    const pname = Object.fromEntries(modState.products.map(p => [p.id, p.name]));
    const cards = modState.groups.map(g => `
        <div class="border rounded-2xl p-3 mb-3 bg-slate-50">
            <div class="flex flex-wrap justify-between items-center gap-2 mb-2">
                <div><span class="font-black text-sm">${uiEsc(g.name)}</span>
                    <span class="text-[11px] font-bold text-blue-700 bg-blue-50 px-2 py-0.5 rounded-lg mr-2">${uiEsc(modRuleText(g))}</span></div>
                <div class="flex gap-1">${uiBtn('تعديل', `modEdit('${g.id}')`, 'gray')}${uiBtn('مسح', `modDelete('${g.id}')`, 'red')}</div>
            </div>
            <div class="flex flex-wrap gap-1 mb-2">${(g.modifiers || []).map(m => `<span class="bg-white border rounded-lg px-2 py-1 text-[11px] font-bold">${uiEsc(m.name)} <span class="text-blue-600">${Number(m.price) > 0 ? '+' + formatCurrency(m.price) : 'مجاني'}</span>${m.ingredient_id ? ' 📦' : ''}</span>`).join('')}</div>
            <p class="text-[11px] text-slate-500 font-bold">الأصناف: ${(g.product_ids || []).length ? uiEsc((g.product_ids || []).map(id => pname[id] || '').filter(Boolean).join('، ')) : '<span class="text-red-500">مش مربوطة بأي صنف</span>'}</p>
        </div>`).join('');
    box.innerHTML = uiCard('الإضافات', `
        <p class="text-[11px] text-slate-500 font-bold mb-3">اعمل مجموعة (مثلاً "إضافات البرجر" أو "نوع اللبن")، وحط فيها الإضافات بأسعارها، واختار الأصناف اللي تظهر معاها.
        لما الكاشير يدوس على الصنف هيظهرله شباك الإضافات. 📦 = الإضافة بتخصم خامة من المخزن.</p>
        ${cards || '<p class="text-center text-slate-400 font-bold text-xs py-6">مفيش مجموعات إضافات لسه</p>'}`, uiBtn('مجموعة جديدة ➕', 'modEdit(null)', 'blue'));
}

function modEdit(id) {
    const g = id ? modState.groups.find(x => x.id === id) : null;
    modState.edit = g ? JSON.parse(JSON.stringify(g)) : { id: null, name: '', min_selection: 0, max_selection: 1, modifiers: [{ name: '', price: 0 }], product_ids: [] };
    modRender();
}

function modCancel() { modState.edit = null; modRender(); }

function modEditorHtml() {
    const e = modState.edit;
    const ingOpts = ing => '<option value="">بدون خصم من المخزن</option>' + modState.ingredients.map(i => `<option value="${uiEsc(i.id)}" ${i.id === ing ? 'selected' : ''}>${uiEsc(i.name)} (${uiEsc(i.unit)})</option>`).join('');
    const rows = e.modifiers.map((m, i) => `
        <tr class="border-b text-xs font-bold">
            <td class="p-1"><input value="${uiEsc(m.name)}" oninput="modState.edit.modifiers[${i}].name = this.value" placeholder="مثلاً: جبنة زيادة" class="${uiInputClass()} w-full"></td>
            <td class="p-1"><input type="number" min="0" step="any" value="${uiEsc(m.price)}" oninput="modState.edit.modifiers[${i}].price = this.value" class="${uiInputClass()} w-24"></td>
            <td class="p-1"><select onchange="modState.edit.modifiers[${i}].ingredient_id = this.value || null; modRender()" class="${uiInputClass()}">${ingOpts(m.ingredient_id)}</select></td>
            <td class="p-1">${m.ingredient_id ? `<input type="number" min="0" step="any" value="${uiEsc(m.ingredient_quantity || '')}" oninput="modState.edit.modifiers[${i}].ingredient_quantity = this.value" placeholder="الكمية" class="${uiInputClass()} w-24">` : '-'}</td>
            <td class="p-1">${uiBtn('شيل', `modState.edit.modifiers.splice(${i},1); modRender()`, 'gray')}</td>
        </tr>`).join('');
    const cats = {};
    modState.products.forEach(p => { const k = p.category || 'بدون قسم'; (cats[k] = cats[k] || []).push(p); });
    modState.catKeys = Object.keys(cats);
    const prodHtml = Object.entries(cats).map(([cat, list], ci) => {
        const all = list.every(p => e.product_ids.includes(p.id));
        return `<div class="mb-2"><label class="flex items-center gap-1 text-xs font-black text-slate-700 mb-1"><input type="checkbox" ${all ? 'checked' : ''} onchange="modToggleCategory(${ci}, this.checked)"> ${uiEsc(cat)} (القسم كله)</label>
            <div class="flex flex-wrap gap-2 pr-4">${list.map(p => `<label class="flex items-center gap-1 text-[11px] font-bold bg-slate-50 border rounded-lg px-2 py-1"><input type="checkbox" ${e.product_ids.includes(p.id) ? 'checked' : ''} onchange="modToggleProduct('${p.id}', this.checked)"> ${uiEsc(p.name)}</label>`).join('')}</div></div>`;
    }).join('');
    return uiCard(e.id ? 'تعديل مجموعة إضافات' : 'مجموعة إضافات جديدة', `
        <div class="grid grid-cols-1 md:grid-cols-3 gap-2 mb-3 text-xs font-bold">
            <label>اسم المجموعة<br><input value="${uiEsc(e.name)}" oninput="modState.edit.name = this.value" placeholder="مثلاً: إضافات البرجر" class="${uiInputClass()} w-full"></label>
            <label>أقل عدد لازم يتختار (0 = اختياري)<br><input type="number" min="0" max="50" value="${uiEsc(e.min_selection)}" oninput="modState.edit.min_selection = this.value" class="${uiInputClass()} w-full"></label>
            <label>أكتر عدد يتختار<br><input type="number" min="1" max="50" value="${uiEsc(e.max_selection)}" oninput="modState.edit.max_selection = this.value" class="${uiInputClass()} w-full"></label>
        </div>
        <p class="text-[11px] text-slate-500 font-bold mb-2">مثال: "نوع اللبن" = أقل 1 وأكتر 1 (لازم يختار واحد). "إضافات البرجر" = أقل 0 وأكتر 3.</p>
        <div class="overflow-x-auto"><table class="w-full text-right"><thead><tr class="text-[11px] text-slate-500">
            <th class="p-1">الإضافة</th><th class="p-1">السعر</th><th class="p-1">بتخصم من المخزن</th><th class="p-1">الكمية من الخامة</th><th></th></tr></thead>
            <tbody>${rows}</tbody></table></div>
        <div class="mt-2">${uiBtn('إضافة سطر ➕', "modState.edit.modifiers.push({ name: '', price: 0 }); modRender()", 'gray')}</div>
        <div class="mt-4 border-t pt-3"><p class="text-xs font-black mb-2">تظهر مع الأصناف دي:</p>${prodHtml || '<p class="text-xs text-slate-400">مفيش أصناف</p>'}</div>`,
        uiBtn('حفظ', 'modSave()', 'green') + uiBtn('رجوع', 'modCancel()', 'gray'));
}

function modToggleProduct(id, on) {
    const ids = modState.edit.product_ids;
    const i = ids.indexOf(id);
    if (on && i < 0) ids.push(id);
    if (!on && i >= 0) ids.splice(i, 1);
    modRender();
}

function modToggleCategory(ci, on) {
    const cat = (modState.catKeys || [])[ci];
    modState.products.filter(p => (p.category || 'بدون قسم') === cat).forEach(p => {
        const ids = modState.edit.product_ids;
        const i = ids.indexOf(p.id);
        if (on && i < 0) ids.push(p.id);
        if (!on && i >= 0) ids.splice(i, 1);
    });
    modRender();
}

async function modSave() {
    const e = modState.edit;
    const mods = e.modifiers.filter(m => String(m.name || '').trim());
    if (!String(e.name || '').trim()) return showToast('اكتب اسم المجموعة', 'error');
    if (!mods.length) return showToast('لازم إضافة واحدة على الأقل', 'error');
    for (const m of mods) {
        if (!(Number(m.price) >= 0)) return showToast(`سعر "${m.name}" غلط`, 'error');
        if (m.ingredient_id && !(Number(m.ingredient_quantity) > 0)) return showToast(`اكتب كمية الخامة اللي "${m.name}" بتخصمها`, 'error');
    }
    const data = {
        id: e.id || null, name: String(e.name).trim(),
        min_selection: parseInt(e.min_selection, 10) || 0, max_selection: parseInt(e.max_selection, 10) || 1,
        modifiers: mods.map(m => ({ id: m.id || null, name: String(m.name).trim(), price: String(Number(m.price) || 0),
            ingredient_id: m.ingredient_id || null, ingredient_quantity: m.ingredient_id ? String(Number(m.ingredient_quantity)) : '0' })),
        product_ids: e.product_ids
    };
    if (await uiCall('modifiers_admin_secure', { p_action: 'save_group', p_data: data }, 'تم حفظ الإضافات')) {
        modState.edit = null;
        set2RenderModifiers();
    }
}

async function modDelete(id) {
    const g = modState.groups.find(x => x.id === id);
    if (!g || !confirm(`مسح مجموعة "${g.name}"؟\nالفواتير القديمة مش هتتأثر.`)) return;
    if (await uiCall('modifiers_admin_secure', { p_action: 'delete_group', p_data: { id } }, 'تم المسح')) set2RenderModifiers();
}
