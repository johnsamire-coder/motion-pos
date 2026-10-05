// js/reports.js - موديول التقارير الكوست كنترول والـ P&L المالي - Motion POS

async function loadFinancialDashboard() {
    try {
        const { data, error } = await _supabase.rpc('get_financial_summary');
        if (error || !data || data.length === 0) return;

        const res = data[0];
        const sSales = document.getElementById('stat-sales');
        const sCogs = document.getElementById('stat-cogs');
        const sWaste = document.getElementById('stat-waste');
        const sNet = document.getElementById('stat-net');

        if (sSales) sSales.innerText = formatCurrency(res.total_sales);
        if (sCogs) sCogs.innerText = formatCurrency(res.total_cogs);
        if (sWaste) sWaste.innerText = formatCurrency(res.total_waste_loss);
        if (sNet) sNet.innerText = formatCurrency(res.net_profit);

    } catch (err) {
        console.error('P&L Error:', err);
    }
}

async function loadCostAnalysis() {
    try {
        const { data: prods } = await _supabase.from('products').select('*');
        const { data: recipes } = await _supabase.from('recipes').select('*, ingredients(*)');

        const tbody = document.getElementById('cost-table-body');
        if (!tbody || !prods || !recipes) return;

        tbody.innerHTML = prods.map(prod => {
            const prodRecipes = recipes.filter(r => r.product_id === prod.id);
            let totalCost = 0;
            prodRecipes.forEach(r => {
                const unitCost = r.ingredients ? parseFloat(r.ingredients.cost_per_unit) : 0;
                totalCost += parseFloat(r.quantity_required) * unitCost;
            });

            const price = parseFloat(prod.price) || 1;
            const costPercentage = ((totalCost / price) * 100).toFixed(1);
            const profit = (price - totalCost).toFixed(2);
            let badge = costPercentage > 35 ? "bg-red-100 text-red-700" : "bg-emerald-100 text-emerald-700";

            return `
                <tr class="border-b border-slate-100 text-xs font-bold hover:bg-slate-50">
                    <td class="p-3 text-slate-800">${prod.name}</td>
                    <td class="p-3 font-extrabold">${formatCurrency(price)}</td>
                    <td class="p-3 text-blue-600 font-extrabold">${formatCurrency(totalCost)}</td>
                    <td class="p-3 font-extrabold ${costPercentage > 35 ? 'text-red-600' : 'text-emerald-600'}">${costPercentage}%</td>
                    <td class="p-3 font-extrabold text-emerald-600">${formatCurrency(profit)}</td>
                    <td class="p-3"><span class="px-2 py-0.5 rounded-full text-[10px] font-extrabold ${badge}">${costPercentage > 35 ? "تكلفة مرتفعة" : "ربحية ممتازة"}</span></td>
                </tr>
            `;
        }).join('');

    } catch (err) {
        console.error('Cost Analysis Error:', err);
    }
}

async function loadWasteReport() {
    try {
        const { data, error } = await _supabase
            .from('waste_logs')
            .select('*, ingredients(name, unit)')
            .order('created_at', { ascending: false });

        const tbody = document.getElementById('waste-report-body');
        if (!tbody) return;

        if (error || !data || data.length === 0) {
            tbody.innerHTML = `<tr><td colspan="5" class="text-center p-4 text-slate-400 font-bold">لا يوجد سجل خسائر مسجل حتى الآن</td></tr>`;
            return;
        }

        let totalLoss = 0;
        tbody.innerHTML = data.map(log => {
            totalLoss += parseFloat(log.cost_loss || 0);
            const date = new Date(log.created_at).toLocaleDateString('ar-EG');
            return `
                <tr class="border-b border-slate-100 text-xs font-bold hover:bg-slate-50">
                    <td class="p-3 text-slate-500">${date}</td>
                    <td class="p-3 text-slate-800 font-extrabold">${log.ingredients ? log.ingredients.name : 'مادة'}</td>
                    <td class="p-3">${log.quantity} ${log.ingredients ? log.ingredients.unit : ''}</td>
                    <td class="p-3 text-slate-600">${log.reason}</td>
                    <td class="p-3 font-extrabold text-red-600">${formatCurrency(log.cost_loss)}</td>
                </tr>
            `;
        }).join('');

        const badge = document.getElementById('total-loss-badge');
        if (badge) badge.innerText = `إجمالي الخسارة: ${formatCurrency(totalLoss)}`;

    } catch (err) {
        console.error('Waste Report Error:', err);
    }
}
