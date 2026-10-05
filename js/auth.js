// js/auth.js - نظام تسجيل الدخول بالـ PIN المرن والمحصن

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
        // 1. جلب بيانات الموظف برقم الـ PIN
        const { data: staffMember, error } = await _supabase
            .from('staff')
            .select('*')
            .eq('pin_code', pin)
            .maybeSingle();

        if (error || !staffMember) {
            showToast('رقم PIN غير صحيح أو غير موجود بالداتا بيز', 'error');
            clearPin();
            return;
        }

        // 2. جلب اسم الدور
        let roleName = 'كاشير';
        if (staffMember.role_id) {
            const { data: roleData } = await _supabase.from('roles').select('name').eq('id', staffMember.role_id).maybeSingle();
            if (roleData) roleName = roleData.name;
        }

        // 3. جلب بيانات الفرع
        let branchData = { name: 'الفرع الرئيسي', has_tables: true };
        if (staffMember.branch_id) {
            const { data: bData } = await _supabase.from('branches').select('*').eq('id', staffMember.branch_id).maybeSingle();
            if (bData) branchData = bData;
        }

        currentUser = {
            ...staffMember,
            roles: { name: roleName },
            branches: branchData
        };
        if (typeof isManagerUnlocked !== 'undefined') isManagerUnlocked = false;
        if (typeof pendingTabTarget !== 'undefined') pendingTabTarget = null;
        currentBranch = branchData;

        // 4. جلب إعدادات الضرائب والخدمة للفرع
        if (currentUser.branch_id) {
            const { data: taxData } = await _supabase
                .from('branch_tax_settings')
                .select('*')
                .eq('branch_id', currentUser.branch_id)
                .maybeSingle();

            if (taxData) {
                taxSettings.vat_percentage = parseFloat(taxData.vat_percentage) || 0;
                taxSettings.service_charge_percentage = parseFloat(taxData.service_charge_percentage) || 0;
                taxSettings.enable_vat = taxSettings.vat_percentage > 0;
                taxSettings.enable_service = taxSettings.service_charge_percentage > 0;
            }
        }

        // 5. فتح الواجهة الرئيسية
        document.getElementById('login-screen').classList.add('hidden');
        document.getElementById('app').classList.remove('hidden');

        document.getElementById('staff-name-display').innerText = `الموظف: ${currentUser.name}`;
        document.getElementById('staff-role-display').innerText = `الدور: ${roleName}`;
        document.getElementById('branch-badge').innerText = branchData.name;

        showToast(`أهلا بك ${currentUser.name}`);
        clearPin();

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
    ['pin-auth-modal', 'payments-modal', 'split-modal', 'modifiers-modal'].forEach(id => {
        document.getElementById(id)?.classList.add('hidden');
    });
    if (typeof switchMainTab === 'function') switchMainTab('pos');
    clearPin();
    document.getElementById('login-screen').classList.remove('hidden');
    document.getElementById('app').classList.add('hidden');
    showToast('تم تسجيل الخروج');
}
