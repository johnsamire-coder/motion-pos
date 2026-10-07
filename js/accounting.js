// js/accounting.js - موديول الحسابات العامة والقيود والتقارير المالية - Motion POS

let accountingState = {
    accounts: [],
    selectedPeriod: null
};

// تهيئة موديول الحسابات
async function initAccountingModule() {
    await loadChartOfAccountsData();
    loadChartOfAccountsTree();
    loadTrialBalanceReportUI();
}

async function loadChartOfAccountsData() {
    const { data, error } = await _supabase.from('accounts').select('*').order('code', { ascending: true });
    if (error) {
        console.error('Chart of accounts query error:', error);
        showToast('تعذر تحميل دليل الحسابات: ' + error.message, 'error');
        accountingState.accounts = [];
        populateSelectOptions('exp-account-select', [], 'اختر حساب المصروف', 'تعذر تحميل الحسابات');
        return;
    }
    accountingState.accounts = data || [];
    // المصروف بيتسجل على بنود المصروفات (كل بند مربوط بحساب) من خلال السيرفر
    try {
        const res = await serverRpc('expense_categories_secure', { p_data: null });
        accountingState.categories = (res && res.ok && res.categories) ? res.categories.filter(c => c.is_active) : [];
    } catch (err) {
        accountingState.categories = [];
    }
    populateSelectOptions('exp-account-select', accountingState.categories, 'اختر بند المصروف', 'لا توجد بنود مصروفات', c => c.name);
}

// 1. عرض دليل الحسابات الشجري (Chart of Accounts Tree)
async function loadChartOfAccountsTree() {
    const tbody = document.getElementById('acc-coa-tbody');
    if (!tbody) return;

    if (accountingState.accounts.length === 0) {
        tbody.innerHTML = `<tr><td colspan="5" class="text-center p-4 text-slate-400 font-bold">لا يوجد حسابات بالدليل</td></tr>`;
        return;
    }

    const typeBadges = {
        'asset': '<span class="px-2 py-0.5 rounded text-[10px] font-bold bg-blue-100 text-blue-700">أصل Asset</span>',
        'liability': '<span class="px-2 py-0.5 rounded text-[10px] font-bold bg-purple-100 text-purple-700">خصم Liability</span>',
        'equity': '<span class="px-2 py-0.5 rounded text-[10px] font-bold bg-emerald-100 text-emerald-700">ملكية Equity</span>',
        'revenue': '<span class="px-2 py-0.5 rounded text-[10px] font-bold bg-teal-100 text-teal-700">إيراد Revenue</span>',
        'cogs': '<span class="px-2 py-0.5 rounded text-[10px] font-bold bg-amber-100 text-amber-700">تكلفة COGS</span>',
        'expense': '<span class="px-2 py-0.5 rounded text-[10px] font-bold bg-red-100 text-red-700">مصروف Expense</span>'
    };

    tbody.innerHTML = accountingState.accounts.map(acc => `
        <tr class="border-b border-slate-100 text-xs font-bold hover:bg-slate-50">
            <td class="p-3 text-slate-500 font-mono">${acc.code}</td>
            <td class="p-3 text-slate-800 font-black">${acc.name_ar} ${acc.name_en ? `<span class="text-slate-400 font-normal text-[10px]">(${acc.name_en})</span>` : ''}</td>
            <td class="p-3">${typeBadges[acc.account_type] || acc.account_type}</td>
            <td class="p-3 text-slate-600">${acc.normal_balance === 'debit' ? 'مدين (Debit)' : 'دائن (Credit)'}</td>
            <td class="p-3 text-center">
                ${acc.is_system_account ? '<span class="text-slate-400 text-[10px]">حساب نظام حتمي 🔒</span>' : '<span class="text-emerald-600 text-[10px]">نشط ✅</span>'}
            </td>
        </tr>
    `).join('');
}

// 2. تسجيل مصروف (على السيرفر: نفس قواعد شاشة المصروفات، الحد للمدير وفوقه رقم المالك)
async function submitExpenseAction() {
    const catId = document.getElementById('exp-account-select')?.value;
    const amount = parseFloat(document.getElementById('exp-amount-input')?.value);
    const method = document.getElementById('exp-method-select')?.value || 'cash';
    const desc = document.getElementById('exp-desc-input')?.value;

    if (!catId || !amount || amount <= 0 || !desc) {
        showToast('يرجى ملء جميع بيانات المصروف والمبلغ بشكل صحيح', 'error');
        return;
    }
    const res = await uiCall('expense_record_secure', {
        p_category_id: catId, p_amount: round2(amount), p_source: method === 'card' ? 'bank' : 'main_cash',
        p_description: desc, p_reference: '', p_vendor: '', p_recurring_id: null, p_owner_pin: null
    }, 'تم تسجيل المصروف وترحيل القيد ✅', 'p_owner_pin');
    if (res) {
        document.getElementById('exp-amount-input').value = '';
        document.getElementById('exp-desc-input').value = '';
        loadTrialBalanceReportUI();
    }
}

// 3. عرض ميزان المراجعة الشامل (Trial Balance UI)
async function loadTrialBalanceReportUI() {
    try {
        const endDate = new Date().toISOString().split('T')[0];
        const startDate = new Date(new Date().getFullYear(), 0, 1).toISOString().split('T')[0];

        let data = null;
        let error = null;
        try {
            const res = await serverRpc('trial_balance_secure', { p_from: startDate, p_to: endDate });
            if (res && res.ok) data = res.rows; else error = { message: serverReasonMessage(res) };
        } catch (err) {
            error = err;
        }

        const tbody = document.getElementById('acc-tb-tbody');
        if (!tbody) return;

        if (error) {
            console.error('Trial balance query error:', error);
            tbody.innerHTML = `<tr><td colspan="5" class="text-center p-4 text-red-500 font-bold">تعذر تحميل ميزان المراجعة: ${error.message}</td></tr>`;
            return;
        }
        if (!data || data.length === 0) {
            tbody.innerHTML = `<tr><td colspan="5" class="text-center p-4 text-slate-400 font-bold">لا يوجد قيود مرحلة للدفتر حتى الآن</td></tr>`;
            return;
        }

        let totalDebits = 0;
        let totalCredits = 0;

        tbody.innerHTML = data.map(row => {
            const deb = parseFloat(row.ending_debit) || 0;
            const cred = parseFloat(row.ending_credit) || 0;
            totalDebits += deb;
            totalCredits += cred;

            return `
                <tr class="border-b border-slate-100 text-xs font-bold hover:bg-slate-50">
                    <td class="p-3 text-slate-500 font-mono">${row.account_code}</td>
                    <td class="p-3 text-slate-800 font-black">${row.account_name_ar}</td>
                    <td class="p-3 text-slate-600">${row.account_type}</td>
                    <td class="p-3 text-blue-600 font-extrabold">${deb > 0 ? formatCurrency(deb) : '-'}</td>
                    <td class="p-3 text-purple-600 font-extrabold">${cred > 0 ? formatCurrency(cred) : '-'}</td>
                </tr>
            `;
        }).join('');

        const debEl = document.getElementById('tb-total-debit');
        const credEl = document.getElementById('tb-total-credit');
        if (debEl) debEl.innerText = formatCurrency(totalDebits);
        if (credEl) credEl.innerText = formatCurrency(totalCredits);

    } catch (err) {
        console.error('Trial Balance UI Error:', err);
    }
}
