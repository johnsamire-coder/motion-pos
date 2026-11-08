// js/auth.js - نظام تسجيل الدخول بالـ PIN المرن والمحصن
// الدخول بيتم على السيرفر (staff_login): المتصفح بيبعت الرقم بس، والسيرفر بيرد ببيانات الموظف وتذكرة وردية.
// التذكرة بتتحفظ في التاب ده بس (sessionStorage)، وبتتبعت مع أي عملية حساسة على السيرفر.

let staffSessionToken = null;

function appendPin(num) {
    const input = document.getElementById('login-pin');
    if (input && input.value.length < 4) {
        input.value += num;
    }
}

function clearPin() {
    const input = document.getElementById('login-pin');
    if (input) input.value = '';
}

// شاشة الحضور والانصراف: أي موظف يكتب رقمه السري من أي جهاز (شاشة الدخول، أو زرار ⏱️ فوق وحد تاني داخل)،
// تظهر باسمه وفيها زرارين: حضور وانصراف. المفتوح بس اللي ينفع: بعد الحضور، الحضور يتقفل والانصراف يتفتح.
// بيتعمل دخول مؤقت برقمه (تذكرة لوحدها) وبيتقفل لما الشاشة تتقفل. اللي داخل على الجهاز مايتأثرش.
let attState = { tok: null, pin: null, timer: null };

function attModal() {
    let m = document.getElementById('att-modal');
    if (!m) {
        m = document.createElement('div');
        m.id = 'att-modal';
        m.className = 'fixed inset-0 bg-slate-900/70 z-[60] flex items-center justify-center p-4';
        m.setAttribute('dir', 'rtl');
        document.body.appendChild(m);
    }
    m.classList.remove('hidden');
    return m;
}

async function attClose() {
    clearTimeout(attState.timer);
    document.getElementById('att-modal')?.classList.add('hidden');
    const tok = attState.tok;
    attState = { tok: null, pin: null, timer: null };
    if (tok) { try { await _supabase.rpc('staff_logout', { p_token: tok }); } catch (e) { /* ignore */ } }
}

// الخطوة 1: الرقم السري
function attendanceScreen(pin) {
    attClose();
    if (pin && /^[0-9]{4}$/.test(String(pin))) return attOpenWithPin(String(pin));
    const m = attModal();
    m.innerHTML = `<div class="bg-white rounded-3xl shadow-2xl p-6 w-full max-w-sm text-center space-y-4">
        <div class="text-3xl">⏱️</div><h3 class="font-black text-lg text-slate-800">الحضور والانصراف</h3>
        <p class="text-xs font-bold text-slate-500">اكتب رقمك السري</p>
        <input id="att-pin" type="password" inputmode="numeric" maxlength="4" autocomplete="off" placeholder="****"
            class="w-full text-center text-3xl font-black tracking-widest bg-slate-50 border-2 border-slate-200 p-3 rounded-2xl focus:outline-none"
            onkeydown="if (event.key === 'Enter') attOpenWithPin(this.value)">
        <div class="flex gap-2"><button onclick="attOpenWithPin(document.getElementById('att-pin').value)" class="flex-1 bg-blue-600 text-white py-3 rounded-2xl font-black text-sm">متابعة</button>
        <button onclick="attClose()" class="flex-1 bg-slate-100 text-slate-600 py-3 rounded-2xl font-bold text-sm">إلغاء</button></div></div>`;
    setTimeout(() => document.getElementById('att-pin')?.focus(), 50);
}

// الخطوة 2: دخول مؤقت برقمه، ونعرف هو حاضر ولا لأ
async function attOpenWithPin(pin) {
    pin = String(pin || '').trim();
    if (!/^[0-9]{4}$/.test(pin)) { showToast('الرقم السري 4 أرقام', 'error'); return; }
    try {
        const { data: lg, error } = await _supabase.rpc('staff_login', { p_pin: pin });
        if (error || !lg) throw error || new Error('no_reply');
        if (!lg.ok) {
            showToast(lg.reason === 'locked' ? 'متوقف مؤقتًا بسبب محاولات خاطئة كثيرة. انتظر 10 دقائق'
                : lg.reason === 'pin_duplicate' ? 'الرقم السري مكرر لأكثر من موظف. اتصل بالمالك لتغييره.' : 'الرقم السري غلط', 'error');
            const inp = document.getElementById('att-pin'); if (inp) { inp.value = ''; inp.focus(); }
            return;
        }
        attState.tok = lg.session_token;
        attState.pin = pin;
        const st = await attCall('status');
        if (st) attRender(st);
    } catch (err) {
        console.error('Attendance error:', err);
        showToast('حدث خطأ أثناء الاتصال بالسيرفر', 'error');
    }
}

async function attCall(action) {
    const { data: res, error } = await _supabase.rpc('attendance_action_secure', { p_token: attState.tok, p_pin: attState.pin, p_action: action });
    if (error || !res) { showToast('حدث خطأ أثناء الاتصال بالسيرفر', 'error'); return null; }
    if (!res.ok) {
        const msg = { already_in: 'انت مسجل حضور بالفعل', not_in: 'انت مش مسجل حضور، سجّل حضور الأول' }[res.reason];
        showToast(msg || serverReasonMessage(res, 'تعذر التسجيل'), 'error');
        return null;
    }
    return res;
}

function attTime(ts) { return ts ? new Date(ts).toLocaleTimeString('ar-EG', { hour: '2-digit', minute: '2-digit' }) : ''; }

// الشاشة: الاسم + الحالة + زرار حضور وزرار انصراف (اللي مايتنفعش بيبقى مقفول)
function attRender(st, done) {
    const m = attModal();
    const open = !!st.open;
    const btn = (label, action, on, color) => `<button ${on ? `onclick="attDo('${action}')"` : 'disabled'}
        class="flex-1 py-6 rounded-2xl font-black text-xl ${on ? color + ' text-white shadow-lg' : 'bg-slate-100 text-slate-300 cursor-not-allowed'}">${label}</button>`;
    const status = open ? `<p class="text-sm font-black text-emerald-700 bg-emerald-50 rounded-xl py-2">🟢 حاضر من الساعة ${uiEsc(attTime(st.clock_in))}</p>`
        : `<p class="text-sm font-black text-slate-500 bg-slate-50 rounded-xl py-2">⚪ مش مسجل حضور دلوقتي</p>`;
    m.innerHTML = `<div class="bg-white rounded-3xl shadow-2xl p-6 w-full max-w-sm text-center space-y-4">
        <div class="text-3xl">⏱️</div><h3 class="font-black text-lg text-slate-800">أهلاً ${uiEsc(st.name || '')}</h3>
        ${done ? `<p class="text-base font-black ${done.action === 'in' ? 'text-emerald-700' : 'text-red-700'}">${done.action === 'in' ? '✅ تم تسجيل الحضور' : '👋 تم تسجيل الانصراف'} الساعة ${uiEsc(attTime(done.at))}${done.minutes ? ` (${Math.floor(done.minutes / 60)} ساعة و ${done.minutes % 60} دقيقة)` : ''}</p>` : status}
        <div class="flex gap-3">${btn('حضور', 'in', !open, 'bg-emerald-600 hover:bg-emerald-700')}${btn('انصراف', 'out', open, 'bg-red-600 hover:bg-red-700')}</div>
        <button onclick="attClose()" class="w-full bg-slate-100 text-slate-600 py-2.5 rounded-2xl font-bold text-sm">${done ? 'تمام' : 'إغلاق'}</button></div>`;
}

async function attDo(action) {
    const res = await attCall(action);
    if (!res) { const st = await attCall('status'); if (st) attRender(st); return; }
    showToast(`${res.name}: ${action === 'in' ? 'تم تسجيل الحضور ✅' : 'تم تسجيل الانصراف 👋'} ${attTime(res.at)}`);
    attRender({ name: res.name, open: action === 'in', clock_in: action === 'in' ? res.at : null }, res);
    clearTimeout(attState.timer);
    attState.timer = setTimeout(attClose, 6000);
}

// من شاشة الدخول: لو كتب رقمه في الخانة بيفتح على اسمه على طول
function punchFromLogin() {
    const input = document.getElementById('login-pin');
    const pin = input ? input.value : '';
    clearPin();
    attendanceScreen(pin);
}

// من الشريط اللي فوق: أي موظف على جهاز حد تاني داخل عليه
function openAttendancePunch() { attendanceScreen(''); }

async function loginWithPin() {
    const pinInput = document.getElementById('login-pin');
    if (!pinInput) return;

    const pin = pinInput.value;
    if (pin.length < 4) {
        showToast('أدخل 4 أرقام للـ PIN', 'error');
        return;
    }

    try {
        // 1. الدخول على السيرفر: الرقم بيتراجع هناك، ومفيش أي رقم أو بصمة بترجع للمتصفح
        const { data: loginRes, error } = await _supabase.rpc('staff_login', { p_pin: String(pin) });

        if (error || !loginRes) {
            console.error('Login error:', error);
            showToast('حدث خطأ أثناء الاتصال بالسيرفر', 'error');
            clearPin();
            return;
        }

        if (!loginRes.ok) {
            if (loginRes.reason === 'locked') {
                showToast('تم إيقاف الدخول مؤقتاً بسبب محاولات خاطئة كثيرة. حاول مرة أخرى بعد 10 دقائق.', 'error');
            } else if (loginRes.reason === 'pin_duplicate') {
                showToast('الرقم السري مكرر لأكثر من موظف. اتصل بالمالك لتغييره.', 'error');
            } else {
                showToast('رقم PIN غير صحيح', 'error');
            }
            clearPin();
            return;
        }

        await motionApplyLogin(loginRes);
    } catch (err) {
        console.error('Login error:', err);
        showToast('حدث خطأ أثناء الاتصال بالسيرفر', 'error');
    }
}

// بيانات الدخول بتتحفظ في التاب ده بس (sessionStorage)، عشان تحديث الصفحة (F5) ميخرّجش الموظف.
// التذكرة نفسها بتتراجع على السيرفر عند كل فتح، ولو انتهت بيرجع لشاشة الرقم.
async function motionApplyLogin(loginRes, quiet = false) {
    try {
            // 2. بيانات الموظف والدور والفرع جاية جاهزة من السيرفر
            const roleName = (loginRes.role && loginRes.role.name) || 'كاشير';
            const branchData = loginRes.branch || { name: 'الفرع الرئيسي', has_tables: true };
            staffSessionToken = loginRes.session_token || null;
            try { sessionStorage.setItem('motionpos_login', JSON.stringify(loginRes)); } catch (e) { /* private mode */ }

            currentUser = {
                ...loginRes.staff,
                roles: { name: roleName },
                branches: branchData
            };
            if (typeof isManagerUnlocked !== 'undefined') isManagerUnlocked = false;
            if (typeof pendingTabTarget !== 'undefined') pendingTabTarget = null;
            currentBranch = branchData;

            // 3. إعدادات الضرائب والخدمة للفرع (جاية مع رد الدخول)
            const taxData = loginRes.tax;
            if (taxData) {
                taxSettings.vat_percentage = parseFloat(taxData.vat_percentage) || 0;
                taxSettings.service_charge_percentage = parseFloat(taxData.service_charge_percentage) || 0;
                taxSettings.enable_vat = taxSettings.vat_percentage > 0;
                taxSettings.enable_service = taxSettings.service_charge_percentage > 0;
            }

            // 5. فتح الواجهة الرئيسية
            document.getElementById('login-screen').classList.add('hidden');
            document.getElementById('app').classList.remove('hidden');

            document.getElementById('staff-name-display').innerText = `الموظف: ${currentUser.name}`;
            document.getElementById('staff-role-display').innerText = `الدور: ${roleName}`;
            document.getElementById('branch-badge').innerText = branchData.name;

            if (!quiet) showToast(`أهلا بك ${currentUser.name}`);
            clearPin();

            if (typeof applyTabPermissions === 'function') await applyTabPermissions();
            if (typeof initPOSModule === 'function' && (typeof canOpenTab !== 'function' || canOpenTab('pos'))) initPOSModule();
            if (quiet) motionRestoreTab(motionSavedTab);
    } catch (err) {
        console.error('Login apply error:', err);
    }
}

// بعد التحديث (F5): يرجع لنفس الشاشة (ونفس قسم الإعدادات) اللي كان واقف فيها، لو لسه مسموحله
// اتقري أول ما الصفحة تفتح، قبل ما الدخول يفتح الشاشة الأولى ويكتب فوقها
let motionSavedTab = null, motionSavedSec = null;
try { motionSavedTab = sessionStorage.getItem('motionpos_tab'); motionSavedSec = sessionStorage.getItem('motionpos_settab'); } catch (e) { /* private mode */ }
function motionRestoreTab(tab) {
    const sec = motionSavedSec;
    if (!tab || typeof switchMainTab !== 'function' || (typeof canOpenTab === 'function' && !canOpenTab(tab))) return;
    switchMainTab(tab);
    if (tab === 'settings' && sec && typeof switchSettingsSection === 'function') {
        let n = 0;
        const t = setInterval(() => {
            if (document.getElementById('btn-set-' + sec) || ++n > 40) { clearInterval(t); if (document.getElementById('btn-set-' + sec)) switchSettingsSection(sec); }
        }, 150);
    }
}

async function motionResumeLogin() {
    let saved = null;
    try { saved = JSON.parse(sessionStorage.getItem('motionpos_login') || 'null'); } catch (e) { saved = null; }
    if (!saved || !saved.session_token) return;
    staffSessionToken = saved.session_token;
    try {
        const chk = await serverRpc('pos_settings_list_secure');
        if (!chk || !chk.ok) throw new Error('expired');
    } catch (e) {
        staffSessionToken = null;
        try { sessionStorage.removeItem('motionpos_login'); } catch (x) { /* ignore */ }
        document.getElementById('motion-resume-style')?.remove();
        return;
    }
    await motionApplyLogin(saved, true);
    document.getElementById('motion-resume-style')?.remove();
}
window.addEventListener('DOMContentLoaded', motionResumeLogin);
// شاشة الرقم السري متظهرش لحظة وهو بيرجع لوحده بعد التحديث
try {
    if (sessionStorage.getItem('motionpos_login')) {
        const st = document.createElement('style'); st.id = 'motion-resume-style'; st.textContent = '#login-screen{visibility:hidden}';
        document.head.appendChild(st);
        setTimeout(() => { const x = document.getElementById('motion-resume-style'); if (x) x.remove(); }, 8000);
    }
} catch (e) { /* ignore */ }

function logout() {
    if (typeof paymentSubmissionInProgress !== 'undefined' && paymentSubmissionInProgress) {
        showToast('جارٍ تسجيل الدفعة، انتظر حتى تظهر نتيجة العملية قبل تسجيل الخروج.', 'error');
        return;
    }
    if (typeof orderSubmissionInProgress !== 'undefined' && orderSubmissionInProgress) {
        showToast('جارٍ حفظ الطلب، انتظر حتى تظهر نتيجة العملية قبل تسجيل الخروج.', 'error');
        return;
    }
    try { sessionStorage.removeItem('motionpos_login'); sessionStorage.removeItem('motionpos_tab'); sessionStorage.removeItem('motionpos_settab'); } catch (e) { /* ignore */ }
    if (staffSessionToken) {
        _supabase.rpc('staff_logout', { p_token: staffSessionToken }).then(() => {}, () => {});
    }
    staffSessionToken = null;
    currentUser = null;
    currentBranch = null;
    if (typeof isManagerUnlocked !== 'undefined') isManagerUnlocked = false;
    if (typeof pendingTabTarget !== 'undefined') pendingTabTarget = null;
    if (typeof resetActiveCart === 'function') resetActiveCart();
    if (typeof posState !== 'undefined') {
        posState.selectedOrderType = 'dine_in';
        posState.activeCategory = null;
        posState.pendingModifierProduct = null;
        posState.selectedModifiers = [];
        posState.selectedTable = null;
        posState.selectedAreaId = null;
        posState.areas = [];
        posState.tables = [];
        posState.categories = [];
        posState.products = [];
        posState.waiters = [];
        posState.customers = [];
        posState.cancelReasons = [];
        posState.discounts = [];
    }
    if (typeof kdsOrders !== 'undefined') kdsOrders = [];
    if (typeof stopWaiterFeed === 'function') stopWaiterFeed();
    appSettings = null;
    document.querySelectorAll('.main-tab-btn').forEach(btn => btn.classList.remove('hidden'));
    ['pin-auth-modal', 'payments-modal', 'split-modal', 'modifiers-modal'].forEach(id => {
        document.getElementById(id)?.classList.add('hidden');
    });
    if (typeof switchMainTab === 'function') switchMainTab('pos');
    clearPin();
    document.getElementById('login-screen').classList.remove('hidden');
    document.getElementById('app').classList.add('hidden');
    showToast('تم تسجيل الخروج');
}
