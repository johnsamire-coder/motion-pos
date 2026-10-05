// js/auth.js - نظام تسجيل الدخول بالـ PIN والصلاحيات الحقيقية

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
        const { data, error } = await _supabase
            .from('staff')
            .select('*, roles(name), branches(name, has_tables)')
            .eq('pin_code', pin)
            .eq('is_active', true)
            .maybeSingle();

        if (error || !data) {
            showToast('رقم PIN غير صحيح أو الموظف غير مفعل', 'error');
            clearPin();
            return;
        }

        currentUser = data;
        currentBranch = data.branches;

        // جلب إعدادات الضرائب والخدمة الخاصة بالفرع من الداتا بيز
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

        document.getElementById('login-screen').classList.add('hidden');
        document.getElementById('app').classList.remove('hidden');

        const nameDisp = document.getElementById('staff-name-display');
        const roleDisp = document.getElementById('staff-role-display');
        const branchBadge = document.getElementById('branch-badge');

        if (nameDisp) nameDisp.innerText = الموظف: ;
        if (roleDisp) roleDisp.innerText = الدور: ;
        if (branchBadge) branchBadge.innerText = currentBranch ? currentBranch.name : 'الفرع الرئيسي';

        showToast(أهلا بك );
        clearPin();

        // تشغيل موديول الكاشير
        if (typeof initPOSModule === 'function') initPOSModule();

    } catch (err) {
        console.error('Login error:', err);
        showToast('حدث خطأ أثناء الاتصال بالسيرفر', 'error');
    }
}

function logout() {
    currentUser = null;
    currentBranch = null;
    clearPin();
    document.getElementById('login-screen').classList.remove('hidden');
    document.getElementById('app').classList.add('hidden');
    showToast('تم تسجيل الخروج');
}
