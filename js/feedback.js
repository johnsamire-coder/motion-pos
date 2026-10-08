// js/feedback.js - الشكاوي والاقتراحات: العميل بيكتبها من صفحة feedback.html (من غير دخول)، والمدير بيتابعها هنا

const FB_KINDS = { complaint: ['😟 شكوى', 'bg-red-50 text-red-700 border-red-200'], suggestion: ['💡 اقتراح', 'bg-blue-50 text-blue-700 border-blue-200'],
    praise: ['❤️ شكر', 'bg-emerald-50 text-emerald-700 border-emerald-200'] };
const FB_STATUS = { new: 'جديدة', in_progress: 'بنتابعها', closed: 'اتقفلت' };
let fbState = { filter: 'open', data: null, timer: null };

function startFeedbackBadge() {
    if (fbState.timer || typeof canOpenTab !== 'function' || !canOpenTab('feedback')) return;
    const tick = async () => {
        if (!currentUser || !staffSessionToken) return;
        try {
            const res = await serverRpc('feedback_secure', { p_action: 'list', p_data: { filter: 'new' } });
            const n = res && res.ok ? Number(res.counts.new) || 0 : 0;
            const b = document.getElementById('feedback-badge');
            if (b) { b.textContent = String(n); b.classList.toggle('hidden', n === 0); }
        } catch (e) { /* next time */ }
    };
    tick();
    fbState.timer = setInterval(tick, 120000);
}

function setFeedbackFilter(f) { fbState.filter = f; loadFeedbackScreen(); }

async function loadFeedbackScreen() {
    const root = document.getElementById('feedback-root');
    if (!root) return;
    const res = await uiCall('feedback_secure', { p_action: 'list', p_data: { filter: fbState.filter } });
    if (!res) return;
    fbState.data = res;
    const c = res.counts || {};
    const link = appLinks.feedback || '';
    const cards = (res.items || []).map(f => {
        const k = FB_KINDS[f.kind] || [f.kind, ''];
        return `<div class="bg-white rounded-2xl border ${f.status === 'new' ? 'border-amber-300' : 'border-slate-200'} p-4 shadow-sm">
            <div class="flex flex-wrap justify-between gap-2 items-center mb-2">
                <div class="flex flex-wrap items-center gap-2"><span class="text-xs font-black border rounded-lg px-2 py-0.5 ${k[1]}">${k[0]}</span>
                    ${f.rating ? `<span class="text-amber-500 text-sm">${'★'.repeat(f.rating)}<span class="text-slate-300">${'★'.repeat(5 - f.rating)}</span></span>` : ''}
                    <span class="text-[11px] font-bold text-slate-500">${uiEsc(uiDate(f.created_at))}</span></div>
                <span class="text-[11px] font-black ${f.status === 'closed' ? 'text-emerald-700' : 'text-amber-700'}">${uiEsc(FB_STATUS[f.status] || f.status)}</span></div>
            <p class="text-sm font-bold text-slate-800 whitespace-pre-line">${uiEsc(f.message)}</p>
            <p class="text-[11px] font-bold text-slate-500 mt-2">${f.customer_name ? '👤 ' + uiEsc(f.customer_name) : 'من غير اسم'}
                ${f.customer_phone ? ` | <a class="text-blue-600" href="tel:${uiEsc(f.customer_phone)}">${uiEsc(f.customer_phone)}</a>
                    <a class="text-emerald-600" target="_blank" rel="noopener" href="${uiEsc(waLink(f.customer_phone, waFill('أهلاً يا {الاسم}، شكراً على رأيك 🙏', f.customer_name)))}">💬</a>` : ''}
                ${f.order_number ? ` | طلب ${uiEsc(f.order_number)}` : ''}</p>
            ${f.manager_note ? `<p class="text-[11px] font-bold text-slate-700 bg-slate-50 rounded-lg p-2 mt-2">📝 ${uiEsc(f.manager_note)} ${f.handled_by ? `<span class="text-slate-400">(${uiEsc(f.handled_by)})</span>` : ''}</p>` : ''}
            <div class="flex flex-wrap gap-2 mt-3">
                ${f.status !== 'in_progress' && f.status !== 'closed' ? uiBtn('بنتابعها', `fbSet('${f.id}','in_progress')`, 'amber') : ''}
                ${f.status !== 'closed' ? uiBtn('اتحلّت / اقفلها', `fbSet('${f.id}','closed')`, 'green') : uiBtn('افتحها تاني', `fbSet('${f.id}','in_progress')`, 'gray')}
            </div></div>`;
    }).join('');
    root.innerHTML = uiCard('💬 الشكاوي والاقتراحات', `
        <div class="grid grid-cols-2 md:grid-cols-4 gap-3 mb-4 text-xs font-bold">
            <div class="bg-amber-50 border border-amber-200 rounded-xl p-3">جديدة<p class="text-xl font-black">${c.new || 0}</p></div>
            <div class="bg-blue-50 border border-blue-200 rounded-xl p-3">بنتابعها<p class="text-xl font-black">${c.in_progress || 0}</p></div>
            <div class="bg-red-50 border border-red-200 rounded-xl p-3">شكاوي آخر ٣٠ يوم<p class="text-xl font-black">${c.complaints_30 || 0}</p></div>
            <div class="bg-emerald-50 border border-emerald-200 rounded-xl p-3">متوسط التقييم (٣٠ يوم)<p class="text-xl font-black">${c.avg_rating_30 ? c.avg_rating_30 + ' ⭐' : '—'}</p></div>
        </div>
        ${uiTabs('fb', [['open', 'المفتوحة'], ['new', 'الجديدة بس'], ['closed', 'اللي اتقفلت'], ['all', 'الكل']], fbState.filter, 'setFeedbackFilter')}
        <div class="grid grid-cols-1 lg:grid-cols-2 gap-3">${cards || '<p class="text-center text-slate-400 font-bold text-xs py-8 lg:col-span-2">مفيش حاجة هنا 👌</p>'}</div>`,
        link ? `${uiBtn('📋 انسخ لينك صفحة الشكاوي', `fbCopyLink()`, 'gray')} ${uiBtn('🖨️ اطبع QR للصفحة', 'fbPrintQr()', 'gray')}` : '');
    const b = document.getElementById('feedback-badge');
    if (b) { b.textContent = String(c.new || 0); b.classList.toggle('hidden', !Number(c.new)); }
}

async function fbSet(id, status) {
    const v = await uiForm(status === 'closed' ? 'قفل الشكوى' : 'متابعة', [{ key: 'note', label: 'ملاحظة (اتعمل إيه؟) - اختياري', type: 'textarea', full: true }], { ok: 'حفظ' });
    if (!v) return;
    if (await uiCall('feedback_secure', { p_action: 'set', p_data: { id, status, note: v.note || '' } }, 'تم')) loadFeedbackScreen();
}

function fbCopyLink() {
    const link = appLinks.feedback;
    if (!link) return;
    try { navigator.clipboard.writeText(link); showToast('اللينك اتنسخ'); } catch (e) { prompt('انسخ اللينك:', link); }
}

async function fbPrintQr() {
    const link = appLinks.feedback;
    if (!link) return;
    try { await loadScriptOnce('vendor/qrcode.min.js'); } catch (err) { return showToast(err.message, 'error'); }
    const qr = qrcode(0, 'M'); qr.addData(link); qr.make();
    const g = (appSettings && appSettings.general) || {};
    printHtml(`<div style="text-align:center;padding:20mm">${g.logo ? `<img src="${uiEsc(g.logo)}" style="max-height:25mm">` : `<h1>${uiEsc(g.company_name || '')}</h1>`}
        <h2>رأيك يهمنا 🙏</h2><img src="${qr.createDataURL(8, 2)}" style="width:70mm;height:70mm"><p>امسح الكود واكتبلنا شكوتك أو اقتراحك</p></div>`, '@page { size: A5; margin: 10mm; }');
}
