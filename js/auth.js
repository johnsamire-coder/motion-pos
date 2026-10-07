// js/auth.js - نظام تسجيل الدخول بالـ PIN المرن والمحصن
// الدخول بيتم على السيرفر (staff_login): المتصفح بيبعت الرقم بس، والسيرفر بيرد ببيانات الموظف وتذكرة وردية.
// التذكرة بتتحفظ في ذاكرة الصفحة بس، وبتتبعت مع أي عملية حساسة على السيرفر.

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
                showToast('الرقم السري ده مكرر لأكتر من موظف. كلم المالك يغيّره.', 'error');
            } else {
                showToast('رقم PIN غير صحيح', 'error');
            }
            clearPin();
            return;
        }

        // 2. بيانات الموظف والدور والفرع جاية جاهزة من السيرفر
        const roleName = (loginRes.role && loginRes.role.name) || 'كاشير';
        const branchData = loginRes.branch || { name: 'الفرع الرئيسي', has_tables: true };
        staffSessionToken = loginRes.session_token || null;

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

        showToast(`أهلا بك ${currentUser.name}`);
        clearPin();

        if (typeof applyTabPermissions === 'function') await applyTabPermissions();
        if (typeof initPOSModule === 'function') initPOSModule();

    } catch (err) {
        console.error('Login error:', err);
        showToast('حدث خطأ أثناء الاتصال بالسيرفر', 'error');
    }
}

function logout() {
    if (typeof paymentSubmissionInProgress !== 'undefined' && paymentSubmissionInProgress) {
        showToast('جارٍ تسجيل الدفعة، انتظر حتى تظهر نتيجة العملية قبل تسجيل الخروج.', 'error');
        return;
    }
    if (typeof orderSubmissionInProgress !== 'undefined' && orderSubmissionInProgress) {
        showToast('جارٍ حفظ الطلب، انتظر حتى تظهر نتيجة العملية قبل تسجيل الخروج.', 'error');
        return;
    }
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
