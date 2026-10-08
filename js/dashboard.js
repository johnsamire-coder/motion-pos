// js/dashboard.js - لوحة التحكم لصاحب المكان: كل اللي حصل في الفترة + اللي بيحصل دلوقتي + كسبان ولا خسران الشهر ده
// كل الأرقام بتيجي من السيرفر في نداء واحد (dashboard_secure)، والرسومات بمكتبة Chart.js المحفوظة في vendor.

const DASH_COLORS = ['#2a78d6', '#eb6834', '#1baf7a', '#eda100', '#e87ba4', '#008300', '#4a3aa7', '#e34948'];
const DASH_GOOD = '#008300';
const DASH_BAD = '#e34948';
const DASH_WEEKDAYS = ['الأحد', 'الاثنين', 'التلات', 'الأربع', 'الخميس', 'الجمعة', 'السبت'];
const DASH_TYPES = { dine_in: 'صالة', takeaway: 'تيك أواي', delivery: 'توصيل', pickup: 'استلام' };
const DASH_METHODS = { cash: 'كاش', card: 'كارت', instapay: 'إنستاباي', wallet: 'محفظة', on_account: 'آجل' };
const DASH_STATIONS = { kitchen: 'المطبخ', bar: 'البار', shisha: 'الشيشة' };

let dashState = { range: 'today', from: null, to: null, branch: null, data: null, charts: [], tab: 'overview', timer: null, pnl: null, month: null };

function dashMoney(v) { return (Math.round((Number(v) || 0) * 100) / 100).toLocaleString('en-US', { maximumFractionDigits: 2 }); }
function dashInt(v) { return (Number(v) || 0).toLocaleString('en-US'); }
function dashCur() { return (appSettings && appSettings.general && appSettings.general.currency) || 'ج.م'; }

// تاريخ النهارده بتوقيت الجهاز (مش توقيت جرينتش، عشان بعد نص الليل ميبقاش امبارح)
function dashLocal(offsetDays = 0) {
    const x = new Date(); x.setDate(x.getDate() + offsetDays);
    return new Date(x.getTime() - x.getTimezoneOffset() * 60000).toISOString().slice(0, 10);
}

function dashRangeDates(range) {
    const t = dashLocal(0);
    const d = new Date(t + 'T00:00:00');
    const iso = x => new Date(x.getTime() - x.getTimezoneOffset() * 60000).toISOString().slice(0, 10);
    if (range === 'today') return [t, t];
    if (range === 'yesterday') return [dashLocal(-1), dashLocal(-1)];
    if (range === 'week') return [dashLocal(-6), t];
    if (range === 'month') return [iso(new Date(d.getFullYear(), d.getMonth(), 1)), t];
    if (range === 'last_month') return [iso(new Date(d.getFullYear(), d.getMonth() - 1, 1)), iso(new Date(d.getFullYear(), d.getMonth(), 0))];
    return [dashState.from || t, dashState.to || t];
}

async function loadDashboardScreen() {
    const root = document.getElementById('dashboard-root');
    if (!root) return;
    if (!dashState.from) [dashState.from, dashState.to] = dashRangeDates(dashState.range);
    if (!root.innerHTML) root.innerHTML = '<p class="text-center text-slate-400 font-bold py-20">جاري تحميل لوحة التحكم...</p>';
    try { await loadScriptOnce('vendor/chart.umd.js'); } catch (e) { /* the numbers still show without charts */ }
    await dashLoad();
    if (!dashState.timer) {
        dashState.timer = setInterval(() => {
            const v = document.getElementById('view-dashboard-workspace');
            if (v && !v.classList.contains('hidden') && dashState.tab === 'overview' && currentUser) dashLoad(true);
        }, 60000);
    }
}

async function dashLoad(quiet = false) {
    let res;
    try { res = await serverRpc('dashboard_secure', { p_from: dashState.from, p_to: dashState.to, p_branch_id: dashState.branch }); }
    catch (err) { if (!quiet) showToast(err.message || 'تعذر تحميل لوحة التحكم', 'error'); return; }
    if (!res || res.ok === false) { if (!quiet) showToast(serverReasonMessage(res, 'تعذر تحميل لوحة التحكم'), 'error'); return; }
    dashState.data = res;
    dashRender();
}

function dashSetRange(range) {
    dashState.range = range;
    if (range !== 'custom') [dashState.from, dashState.to] = dashRangeDates(range);
    dashLoad();
}

function dashSetCustom() {
    const f = document.getElementById('dash-from').value, t = document.getElementById('dash-to').value;
    if (!f || !t || f > t) return showToast('اختار من وإلى صح', 'error');
    dashState.range = 'custom'; dashState.from = f; dashState.to = t;
    dashLoad();
}

function dashSetBranch(v) { dashState.branch = v || null; dashLoad(); }
function dashSetTab(tab) { dashState.tab = tab; if (tab === 'pnl') dashLoadPnl(); else dashRender(); }

// التغيير عن الفترة اللي قبلها: سهم + نسبة (الأخضر = أحسن للمحل)
function dashDelta(cur, prev, higherIsBetter = true) {
    cur = Number(cur) || 0; prev = Number(prev) || 0;
    if (!prev && !cur) return '<span class="text-slate-400">—</span>';
    if (!prev) return '<span class="text-slate-500">جديد</span>';
    const pct = Math.round(((cur - prev) / Math.abs(prev)) * 1000) / 10;
    const up = pct >= 0;
    const good = up === higherIsBetter;
    return `<span class="${good ? 'text-emerald-700' : 'text-red-600'} font-black">${up ? '▲' : '▼'} ${Math.abs(pct)}%</span>`;
}

function dashTile(label, value, sub = '', accent = 'border-slate-200') {
    return `<div class="bg-white rounded-2xl border ${accent} p-4 shadow-sm min-w-0">
        <p class="text-[11px] font-black text-slate-500 mb-1 truncate">${label}</p>
        <p class="text-xl lg:text-2xl font-black text-slate-900 tabular-nums truncate">${value}</p>
        <p class="text-[11px] font-bold text-slate-500 mt-1 truncate">${sub}</p></div>`;
}

function dashCard(title, inner, extra = '', span = '') {
    return `<section class="bg-white rounded-2xl border border-slate-200 shadow-sm p-4 ${span} min-w-0">
        <div class="flex justify-between items-center mb-3 gap-2"><h3 class="font-black text-sm text-slate-800">${title}</h3><div class="text-[11px] font-bold text-slate-500">${extra}</div></div>${inner}</section>`;
}

function dashHeader() {
    const d = dashState.data || {};
    const ranges = [['today', 'النهارده'], ['yesterday', 'امبارح'], ['week', 'آخر ٧ أيام'], ['month', 'الشهر ده'], ['last_month', 'الشهر اللي فات']];
    const g = (appSettings && appSettings.general) || {};
    const hour = new Date().getHours();
    const hello = hour < 12 ? 'صباح الخير' : 'مساء الخير';
    return `<div class="rounded-3xl p-5 text-white shadow-lg" style="background: linear-gradient(135deg, #0f172a 0%, #1e3a8a 60%, #2a78d6 100%)">
        <div class="flex flex-wrap justify-between items-start gap-3">
            <div><p class="text-sm font-bold text-blue-100">${hello} يا ${uiEsc(String(currentUser?.name || '').split(' ')[0] || '')} 👋</p>
                <h2 class="text-2xl font-black">${uiEsc(g.company_name || 'لوحة التحكم')}</h2>
                <p class="text-xs font-bold text-blue-100 mt-1">${uiEsc(d.branch || '')} | من ${uiEsc(d.from || dashState.from)} لـ ${uiEsc(d.to || dashState.to)} | بيتحدّث كل دقيقة</p></div>
            <div class="flex flex-wrap gap-2 items-center">
                ${d.can_pick_branch && (d.branches || []).length > 1 ? `<select onchange="dashSetBranch(this.value)" class="text-slate-800 rounded-xl px-2 py-1.5 text-xs font-black">
                    <option value="">كل الفروع</option>${d.branches.map(b => `<option value="${uiEsc(b.id)}" ${b.id === dashState.branch ? 'selected' : ''}>${uiEsc(b.name)}</option>`).join('')}</select>` : ''}
                <button onclick="dashLoad()" class="bg-white/15 hover:bg-white/25 rounded-xl px-3 py-1.5 text-xs font-black">تحديث 🔄</button>
            </div>
        </div>
        <div class="flex flex-wrap gap-1.5 mt-4">
            ${ranges.map(([k, l]) => `<button onclick="dashSetRange('${k}')" class="px-3 py-1.5 rounded-xl text-xs font-black ${dashState.range === k ? 'bg-white text-blue-900' : 'bg-white/10 hover:bg-white/20'}">${l}</button>`).join('')}
            <span class="flex items-center gap-1 bg-white/10 rounded-xl px-2 py-1">
                <input id="dash-from" type="date" value="${uiEsc(dashState.from)}" class="text-slate-800 rounded-lg px-1 text-xs font-bold">
                <span class="text-xs">لـ</span><input id="dash-to" type="date" value="${uiEsc(dashState.to)}" class="text-slate-800 rounded-lg px-1 text-xs font-bold">
                <button onclick="dashSetCustom()" class="text-xs font-black px-2">عرض</button></span>
        </div>
        <div class="flex gap-1.5 mt-3">
            ${[['overview', '📊 نظرة عامة'], ['pnl', '💰 كسبان ولا خسران (الشهر)']].map(([k, l]) => `<button onclick="dashSetTab('${k}')" class="px-4 py-2 rounded-xl text-xs font-black ${dashState.tab === k ? 'bg-amber-400 text-slate-900' : 'bg-white/10 hover:bg-white/20'}">${l}</button>`).join('')}
        </div></div>`;
}

function dashDestroyCharts() { dashState.charts.forEach(c => { try { c.destroy(); } catch (e) { /* gone */ } }); dashState.charts = []; }

function dashRender() {
    const root = document.getElementById('dashboard-root');
    if (!root || !dashState.data) return;
    dashDestroyCharts();
    if (dashState.tab === 'pnl') { root.innerHTML = dashHeader() + '<div id="dash-pnl" class="mt-4"></div>'; dashRenderPnl(); return; }
    const d = dashState.data, k = d.kpi || {}, p = d.prev || {}, live = d.live || {}, m = d.month || {};
    const cur = dashCur();
    const gross = (Number(k.revenue) || 0) - (Number(k.cogs) || 0) - (Number(k.waste) || 0);
    const pgross = (Number(p.revenue) || 0) - (Number(p.cogs) || 0) - (Number(p.waste) || 0);
    const margin = Number(k.revenue) ? Math.round(gross / Number(k.revenue) * 1000) / 10 : 0;
    const fc = m.forecast || null;
    const mtdNet = Number((m.mtd || {}).net) || 0;
    const fb = d.feedback || {};

    const liveStrip = `<div class="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-6 gap-3 mt-4">
        ${dashTile('🔴 طلبات مفتوحة دلوقتي', dashInt(live.open_orders), `بقيمة ${dashMoney(live.open_value)} ${cur}`, 'border-blue-200')}
        ${dashTile('🍽️ الطاولات المشغولة', `${dashInt(live.tables_busy)} <span class="text-sm">من ${dashInt(live.tables_total)}</span>`, live.tables_total ? `${Math.round(100 * live.tables_busy / live.tables_total)}% من الصالة` : '')}
        ${dashTile('📱 طلبات QR مستنية', dashInt(live.qr_waiting), live.qr_waiting ? 'الويتر لازم يأكدها' : 'مفيش حاجة مستنية', live.qr_waiting ? 'border-amber-300' : 'border-slate-200')}
        ${dashTile('💵 ورديات مفتوحة', dashInt(live.open_shifts), '')}
        ${dashTile('📦 خامات قربت تخلص', dashInt(live.low_stock), live.low_stock ? 'تحت الحد الأدنى' : 'المخزن تمام', live.low_stock ? 'border-red-300' : 'border-slate-200')}
        ${dashTile('💬 شكاوي واقتراحات', dashInt(fb.count), fb.avg_rating ? `التقييم ${fb.avg_rating} ⭐ | ${dashInt(fb.complaints)} شكوى` : 'في الفترة دي', fb.open ? 'border-amber-300' : 'border-slate-200')}
    </div>`;

    const kpis = `<div class="grid grid-cols-2 lg:grid-cols-4 gap-3 mt-4">
        ${dashTile('المبيعات', `${dashMoney(k.sales)} <span class="text-sm">${cur}</span>`, `${dashDelta(k.sales, p.sales)} عن الفترة اللي قبلها`, 'border-blue-300')}
        ${dashTile('عدد الطلبات', dashInt(k.orders), `${dashDelta(k.orders, p.orders)} | ${dashInt(k.guests)} ضيف`)}
        ${dashTile('متوسط الفاتورة', `${dashMoney(k.avg_ticket)} <span class="text-sm">${cur}</span>`, `${dashDelta(k.avg_ticket, p.avg_ticket)} عن الفترة اللي قبلها`)}
        ${dashTile('مجمل الربح (بعد الخامات والهالك)', `${dashMoney(gross)} <span class="text-sm">${cur}</span>`, `${dashDelta(gross, pgross)} | هامش ${margin}%`, 'border-emerald-300')}
        ${dashTile('تكلفة الخامات', `${dashMoney(k.cogs)}`, Number(k.revenue) ? `${Math.round(1000 * k.cogs / k.revenue) / 10}% من الإيراد` : '')}
        ${dashTile('الهالك', `${dashMoney(k.waste)}`, `${dashDelta(k.waste, p.waste, false)} عن الفترة اللي قبلها`, Number(k.waste) ? 'border-red-200' : 'border-slate-200')}
        ${dashTile('الخصومات', `${dashMoney(k.discounts)}`, `إكراميات ${dashMoney(k.tips)} | ملغي ${dashInt(k.cancelled)}`)}
        ${dashTile('طلبات باسم عميل', dashInt(k.with_customer), `${dashInt(k.new_customers)} عميل جديد | ${dashInt(k.repeat_customers)} رجعوا تاني${Number(k.qr_orders) ? ` | ${dashInt(k.qr_orders)} من الـ QR` : ''}`)}
    </div>`;

    const netGood = mtdNet >= 0;
    const coverage = Number(m.fixed_month) ? Math.min(100, Math.round(100 * Math.max(0, Number((m.mtd || {}).gross_profit) || 0) / Number(m.fixed_month))) : 0;
    const monthCard = `<section class="rounded-2xl border-2 ${netGood ? 'border-emerald-300 bg-emerald-50' : 'border-red-300 bg-red-50'} p-4 shadow-sm mt-4">
        <div class="flex flex-wrap justify-between items-center gap-2 mb-2">
            <h3 class="font-black text-sm text-slate-800">💰 الشهر ده لحد النهارده (${uiEsc(m.month || '')}): ${netGood ? '✅ كسبان' : '⚠️ خسران'} ${dashMoney(Math.abs(mtdNet))} ${cur} <span class="text-[11px] text-slate-500">(مبدئي)</span></h3>
            <button onclick="dashSetTab('pnl')" class="bg-white border rounded-xl px-3 py-1.5 text-xs font-black">التفاصيل يوم بيوم ←</button></div>
        <div class="grid grid-cols-2 lg:grid-cols-4 gap-3 text-xs font-bold">
            <div class="bg-white rounded-xl p-3"><p class="text-slate-500">مجمل الربح من أول الشهر</p><p class="text-lg font-black">${dashMoney((m.mtd || {}).gross_profit)}</p></div>
            <div class="bg-white rounded-xl p-3"><p class="text-slate-500">المصاريف الثابتة للشهر</p><p class="text-lg font-black">${dashMoney(m.fixed_month)}</p>
                <p class="text-slate-500">${dashMoney(m.fixed_daily)} في اليوم${m.estimate_lines ? ` | ${m.estimate_lines} بند لسه تقديري` : ''}</p></div>
            <div class="bg-white rounded-xl p-3"><p class="text-slate-500">لو كمّلنا بنفس المعدل، آخر الشهر</p>
                <p class="text-lg font-black ${fc && fc.net >= 0 ? 'text-emerald-700' : 'text-red-600'}">${fc ? (fc.net >= 0 ? '✅ كسبان ' : '⚠️ خسران ') + dashMoney(Math.abs(fc.net)) : '—'}</p></div>
            <div class="bg-white rounded-xl p-3"><p class="text-slate-500">عشان متخسرش، المبيعات في اليوم لازم تبقى</p>
                <p class="text-lg font-black">${fc && fc.break_even_daily_sales ? dashMoney(fc.break_even_daily_sales) : '—'}</p></div>
        </div>
        ${Number(m.fixed_month) ? `<div class="mt-3"><div class="flex justify-between text-[11px] font-black text-slate-600 mb-1"><span>مجمل الربح غطّى ${coverage}% من المصاريف الثابتة</span><span>${m.days_passed} من ${m.days_in_month} يوم</span></div>
            <div class="h-3 bg-white rounded-full overflow-hidden border"><div class="h-full ${coverage >= Math.round(100 * m.days_passed / m.days_in_month) ? 'bg-emerald-600' : 'bg-amber-500'}" style="width:${coverage}%"></div></div></div>`
            : '<p class="text-[11px] font-bold text-amber-700 mt-2">⚠️ لسه مفيش مصاريف ثابتة متسجلة. سجّل المرتبات والإيجار والكهرباء والغاز من: المصروفات ← المصروفات المتكررة، عشان الحساب يبقى حقيقي.</p>'}
    </section>`;

    const single = d.from === d.to;
    const charts = `<div class="grid grid-cols-1 lg:grid-cols-3 gap-4 mt-4">
        ${dashCard(single ? 'المبيعات بالساعة' : 'المبيعات يوم بيوم', '<div class="h-64"><canvas id="dash-c-main"></canvas></div>', `المجموع ${dashMoney(k.sales)} ${cur}`, 'lg:col-span-2')}
        ${dashCard('المبيعات بالقسم', '<div class="h-48"><canvas id="dash-c-cat"></canvas></div><div id="dash-l-cat" class="mt-2"></div>')}
        ${dashCard(single ? 'أيام الأسبوع' : 'أوقات الذروة (بالساعة)', '<div class="h-56"><canvas id="dash-c-peak"></canvas></div>', '', 'lg:col-span-2')}
        ${dashCard('طرق الدفع', '<div class="h-48"><canvas id="dash-c-pay"></canvas></div><div id="dash-l-pay" class="mt-2"></div>')}
    </div>`;

    const top = (d.top_products || []);
    const maxAmt = Math.max(1, ...top.map(x => Number(x.amount) || 0));
    const topHtml = top.length ? `<div class="space-y-2">${top.map((x, i) => {
        const profit = (Number(x.amount) || 0) - (Number(x.cost) || 0);
        const pm = Number(x.amount) ? Math.round(1000 * profit / x.amount) / 10 : 0;
        return `<div><div class="flex justify-between text-xs font-black gap-2"><span class="truncate">${i + 1}. ${uiEsc(x.name)} <span class="text-slate-500">× ${dashInt(x.qty)}</span>
            ${x.has_recipe ? '' : '<span class="text-[10px] bg-amber-100 text-amber-800 rounded px-1">ناقص وصفة</span>'}</span>
            <span class="tabular-nums whitespace-nowrap">${dashMoney(x.amount)} <span class="text-slate-500 text-[10px]">| ربح ${x.has_recipe ? pm + '%' : '؟'}</span></span></div>
            <div class="h-2 bg-slate-100 rounded-full mt-1"><div class="h-2 rounded-full" style="width:${Math.max(2, 100 * x.amount / maxAmt)}%; background:${DASH_COLORS[0]}"></div></div></div>`;
    }).join('')}</div>` : '<p class="text-xs text-slate-400 font-bold py-6 text-center">مفيش مبيعات في الفترة دي</p>';

    const listRows = (rows, fmt) => rows && rows.length ? `<div class="divide-y">${rows.map(fmt).join('')}</div>` : '<p class="text-xs text-slate-400 font-bold py-4 text-center">مفيش</p>';
    const waiters = listRows(d.waiters, (w, i) => `<div class="flex justify-between py-1.5 text-xs font-bold"><span>${['🥇', '🥈', '🥉'][i] || '•'} ${uiEsc(w.name)}</span><span class="tabular-nums">${dashMoney(w.amount)} <span class="text-slate-500">(${dashInt(w.orders)} طلب)</span></span></div>`);
    const custs = listRows(d.top_customers, c => `<div class="flex justify-between py-1.5 text-xs font-bold"><span>👤 ${uiEsc(c.name)}</span><span class="tabular-nums">${dashMoney(c.amount)} <span class="text-slate-500">(${dashInt(c.orders)})</span></span></div>`);
    const slow = listRows(d.slow_products, s => `<div class="flex justify-between py-1.5 text-xs font-bold"><span>🐢 ${uiEsc(s.name)}</span><span class="text-slate-500">${dashInt(s.qty)} اتباع</span></div>`);
    const prep = listRows(d.prep, s => `<div class="py-1.5 text-xs font-bold"><div class="flex justify-between"><span>${uiEsc(DASH_STATIONS[s.station] || s.station)}</span>
        <span>${s.avg_minutes ?? '-'} دقيقة في المتوسط | <span class="${Number(s.late_pct) > 20 ? 'text-red-600' : 'text-emerald-700'}">${Number(s.late_pct) > 20 ? '⚠️' : '✅'} ${s.late_pct ?? 0}% متأخر</span></span></div></div>`);
    const types = listRows(d.order_types, t => `<div class="flex justify-between py-1.5 text-xs font-bold"><span>${uiEsc(DASH_TYPES[t.type] || t.type)}</span><span class="tabular-nums">${dashMoney(t.amount)} <span class="text-slate-500">(${dashInt(t.orders)} طلب)</span></span></div>`);

    const lower = `<div class="grid grid-cols-1 lg:grid-cols-3 gap-4 mt-4">
        ${dashCard('🏆 أكتر ١٠ أصناف بيعاً', topHtml, '', 'lg:col-span-2')}
        <div class="space-y-4">${dashCard('👨‍🍳 سرعة التحضير', prep)}${dashCard('🧾 بنوع الطلب', types)}</div>
        ${dashCard('🙋 الويترز', waiters)}${dashCard('⭐ أحسن العملاء', custs)}${dashCard('🐢 أقل أصناف بيعاً', slow)}
    </div>
    ${d.no_recipe ? `<p class="mt-3 text-xs font-bold text-amber-800 bg-amber-50 border border-amber-200 rounded-xl p-3">⚠️ فيه ${dashInt(d.no_recipe)} صنف من غير وصفة (مقادير)، فتكلفتهم بتتحسب صفر والربح بيبان أكبر من الحقيقي. كمّلهم من: الإعدادات ← المنيو والوصفات.</p>` : ''}`;

    root.innerHTML = dashHeader() + liveStrip + kpis + monthCard + charts + lower;
    dashDrawCharts(single);
}

function dashChartBase(extra = {}) {
    return Object.assign({ responsive: true, maintainAspectRatio: false, animation: { duration: 400 },
        plugins: { legend: { display: false }, tooltip: { rtl: true, titleFont: { family: 'Cairo' }, bodyFont: { family: 'Cairo' } } } }, extra);
}

function dashBar(id, labels, values, color, valueLabel) {
    const el = document.getElementById(id);
    if (!el || typeof Chart === 'undefined') return;
    dashState.charts.push(new Chart(el, {
        type: 'bar',
        data: { labels, datasets: [{ label: valueLabel, data: values, backgroundColor: color, borderRadius: 4, borderSkipped: 'start', maxBarThickness: 36 }] },
        options: dashChartBase({ scales: {
            x: { grid: { display: false }, ticks: { font: { family: 'Cairo', size: 10 }, color: '#52514e' } },
            y: { beginAtZero: true, grid: { color: '#eceae6' }, border: { display: false }, ticks: { font: { family: 'Cairo', size: 10 }, color: '#52514e' } } } })
    }));
}

function dashDonut(id, legendId, rows) {
    const el = document.getElementById(id);
    const total = rows.reduce((s, r) => s + (Number(r.value) || 0), 0);
    // أكتر من ٧ بيتجمعوا في "باقي"
    let list = rows.slice(0, 7);
    if (rows.length > 7) list.push({ label: 'باقي', value: rows.slice(7).reduce((s, r) => s + (Number(r.value) || 0), 0) });
    const lg = document.getElementById(legendId);
    if (lg) lg.innerHTML = list.length ? list.map((r, i) => `<div class="flex justify-between text-[11px] font-bold py-0.5"><span><span class="inline-block w-2.5 h-2.5 rounded-sm align-middle ml-1" style="background:${DASH_COLORS[i]}"></span>${uiEsc(r.label)}</span>
        <span class="tabular-nums">${dashMoney(r.value)} <span class="text-slate-500">(${total ? Math.round(1000 * r.value / total) / 10 : 0}%)</span></span></div>`).join('') : '<p class="text-xs text-slate-400 font-bold text-center">مفيش</p>';
    if (!el || typeof Chart === 'undefined' || !list.length) return;
    dashState.charts.push(new Chart(el, {
        type: 'doughnut',
        data: { labels: list.map(r => r.label), datasets: [{ data: list.map(r => r.value), backgroundColor: DASH_COLORS.slice(0, list.length), borderColor: '#ffffff', borderWidth: 2 }] },
        options: dashChartBase({ cutout: '62%' })
    }));
}

function dashDrawCharts(single) {
    const d = dashState.data;
    if (single) {
        const hrs = (d.hourly || []).filter(h => h.hour >= 8 || Number(h.sales) > 0);
        dashBar('dash-c-main', hrs.map(h => `${h.hour}:00`), hrs.map(h => Number(h.sales)), DASH_COLORS[0], 'المبيعات');
        dashBar('dash-c-peak', (d.weekday || []).map(w => DASH_WEEKDAYS[w.d]), (d.weekday || []).map(w => Number(w.sales)), DASH_COLORS[2], 'المبيعات');
    } else {
        dashBar('dash-c-main', (d.daily || []).map(x => String(x.day).slice(5)), (d.daily || []).map(x => Number(x.sales)), DASH_COLORS[0], 'المبيعات');
        const hrs = (d.hourly || []).filter(h => h.hour >= 8 || Number(h.sales) > 0);
        dashBar('dash-c-peak', hrs.map(h => `${h.hour}:00`), hrs.map(h => Number(h.orders)), DASH_COLORS[2], 'عدد الطلبات');
    }
    dashDonut('dash-c-cat', 'dash-l-cat', (d.categories || []).map(c => ({ label: c.name, value: Number(c.amount) })));
    dashDonut('dash-c-pay', 'dash-l-pay', (d.payments || []).map(p => ({ label: DASH_METHODS[p.method] || p.method, value: Number(p.amount) })));
}

// ---------------------------------------------------------------- كسبان ولا خسران (يوم بيوم في الشهر)
async function dashLoadPnl() {
    if (!dashState.month) dashState.month = dashLocal(0).slice(0, 7);
    const root = document.getElementById('dashboard-root');
    dashDestroyCharts();
    if (root) root.innerHTML = dashHeader() + '<div id="dash-pnl" class="mt-4"><p class="text-center text-slate-400 font-bold py-10">جاري الحساب...</p></div>';
    const res = await uiCall('pnl_daily_secure', { p_month: dashState.month + '-01', p_branch_id: dashState.branch });
    if (!res) return;
    dashState.pnl = res;
    dashRenderPnl();
}

function dashRenderPnl() {
    const box = document.getElementById('dash-pnl');
    const r = dashState.pnl;
    if (!box) return;
    if (!r) { dashLoadPnl(); return; }
    const cur = dashCur();
    const mtd = r.mtd || {}, fc = r.forecast;
    const good = Number(mtd.net) >= 0;
    let cum = 0;
    const days = (r.days || []).map(x => { cum += Number(x.net) || 0; return { ...x, cum }; });
    box.innerHTML = `
        <div class="flex flex-wrap items-center gap-2 mb-3"><span class="text-xs font-black">الشهر:</span>
            <input type="month" value="${uiEsc(dashState.month)}" onchange="dashState.month=this.value; dashLoadPnl()" class="${uiInputClass()}">
            <span class="text-[11px] font-bold text-slate-500">الأرقام مبدئية لحد ما الفواتير الفعلية تتسجل، وبعدها بتتعدل لوحدها.</span></div>
        <div class="grid grid-cols-2 lg:grid-cols-5 gap-3">
            ${dashTile('الإيراد (من غير ضريبة)', dashMoney(mtd.revenue), `${r.days_passed} يوم من ${r.days_in_month}`)}
            ${dashTile('الخامات + الهالك', dashMoney((Number(mtd.cogs) || 0) + (Number(mtd.waste) || 0)), '')}
            ${dashTile('المصاريف الثابتة (نصيب الأيام دي)', dashMoney(mtd.fixed), `${dashMoney(r.fixed_daily)} في اليوم`)}
            ${dashTile('مصاريف تانية', dashMoney(mtd.other_expenses), 'اللي اتسجلت فعلاً')}
            ${dashTile(good ? '✅ كسبان لحد النهارده' : '⚠️ خسران لحد النهارده', `<span class="${good ? 'text-emerald-700' : 'text-red-600'}">${dashMoney(Math.abs(mtd.net))}</span>`, fc ? `توقّع آخر الشهر: ${fc.net >= 0 ? 'كسبان' : 'خسران'} ${dashMoney(Math.abs(fc.net))}` : '', good ? 'border-emerald-300' : 'border-red-300')}
        </div>
        <div class="grid grid-cols-1 lg:grid-cols-3 gap-4 mt-4">
            ${dashCard('صافي كل يوم (بعد نصيبه من المصاريف الثابتة)', '<div class="h-64"><canvas id="dash-c-pnl"></canvas></div>', `<span style="color:${DASH_GOOD}">■ كسبان</span> <span style="color:${DASH_BAD}">■ خسران</span>`, 'lg:col-span-2')}
            ${dashCard('المصاريف الثابتة للشهر', uiTable(r.fixed_lines || [], [
                { label: 'البند', key: 'name' },
                { label: 'المتوقع', render: x => dashMoney(x.budget) },
                { label: 'الفعلي', render: x => Number(x.actual) ? dashMoney(x.actual) : '—' },
                { label: '', render: x => x.kind === 'actual' ? '<span class="text-emerald-700">✅ فعلي</span>' : '<span class="text-amber-700">⏳ تقديري</span>' }],
                'مفيش مصاريف متكررة متسجلة') + `<p class="text-[11px] font-bold text-slate-500 mt-2">المجموع ${dashMoney(r.fixed_month)} ${cur}. البنود دي بتتسجل من: المصروفات ← المصروفات المتكررة (مرتبات، إيجار، كهربا، غاز...).</p>`)}
        </div>
        ${dashCard('يوم بيوم', uiTable(days.slice().reverse(), [
            { label: 'اليوم', render: x => uiEsc(x.day) },
            { label: 'المبيعات', render: x => dashMoney(x.sales) },
            { label: 'الإيراد', render: x => dashMoney(x.revenue) },
            { label: 'الخامات', render: x => dashMoney(x.cogs) },
            { label: 'الهالك', render: x => dashMoney(x.waste) },
            { label: 'مجمل الربح', render: x => dashMoney(x.gross_profit) },
            { label: 'مصاريف تانية', render: x => dashMoney(x.other_expenses) },
            { label: 'نصيبه من الثابت', render: x => dashMoney(x.fixed_share) },
            { label: 'الصافي', render: x => `<span class="${x.net >= 0 ? 'text-emerald-700' : 'text-red-600'} font-black">${x.net >= 0 ? '▲' : '▼'} ${dashMoney(Math.abs(x.net))}</span>` },
            { label: 'من أول الشهر', render: x => `<span class="${x.cum >= 0 ? 'text-emerald-700' : 'text-red-600'}">${dashMoney(x.cum)}</span>` }], 'لسه مفيش أيام'), '', 'mt-4')}`;
    const el = document.getElementById('dash-c-pnl');
    if (el && typeof Chart !== 'undefined' && days.length) {
        dashState.charts.push(new Chart(el, {
            type: 'bar',
            data: { labels: days.map(x => String(x.day).slice(8)), datasets: [{ label: 'الصافي', data: days.map(x => x.net),
                backgroundColor: days.map(x => x.net >= 0 ? DASH_GOOD : DASH_BAD), borderRadius: 4, maxBarThickness: 28 }] },
            options: dashChartBase({ scales: { x: { grid: { display: false }, ticks: { font: { family: 'Cairo', size: 10 } } },
                y: { grid: { color: '#eceae6' }, border: { display: false }, ticks: { font: { family: 'Cairo', size: 10 } } } } })
        }));
    }
}
