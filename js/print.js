// js/print.js - الطباعة والتصدير
// الفاتورة وورقة المطبخ بتتطبع من المتصفح على أي طابعة متعرّفة على ويندوز (58 أو 80 مم).
// التقارير: PDF من شاشة طباعة مترتبة (اختار "حفظ كـ PDF")، وExcel بلوجو الشركة واسمها.

function appSet(section, key, fallback) {
    const s = (typeof appSettings !== 'undefined' && appSettings && appSettings[section]) || {};
    return (s[key] === undefined || s[key] === null) ? fallback : s[key];
}

function printHtml(html, pageCss) {
    const frame = document.createElement('iframe');
    frame.style.cssText = 'position:fixed;right:0;bottom:0;width:0;height:0;border:0;';
    document.body.appendChild(frame);
    const doc = frame.contentWindow.document;
    doc.open();
    doc.write(`<!DOCTYPE html><html dir="rtl" lang="ar"><head><meta charset="utf-8"><style>
        * { box-sizing: border-box; } body { font-family: Tahoma, Arial, sans-serif; margin: 0; color: #000; }
        table { width: 100%; border-collapse: collapse; } ${pageCss || ''}</style></head><body>${html}</body></html>`);
    doc.close();
    const go = () => { try { frame.contentWindow.focus(); frame.contentWindow.print(); } finally { setTimeout(() => frame.remove(), 2000); } };
    const imgs = [...doc.images];
    if (!imgs.length) return setTimeout(go, 200);
    let left = imgs.length;
    imgs.forEach(img => { if (img.complete) { if (--left === 0) setTimeout(go, 100); } else { img.onload = img.onerror = () => { if (--left === 0) setTimeout(go, 100); }; } });
}

function receiptPageCss() {
    const mm = Number(appSet('receipt', 'paper_mm', 80)) === 58 ? 58 : 80;
    return `@page { size: ${mm}mm auto; margin: 0; } body { width: ${mm - 4}mm; padding: 2mm; font-size: ${mm === 58 ? 10 : 12}px; }
        .c { text-align: center; } .b { font-weight: bold; } .big { font-size: 1.6em; } .line { border-top: 1px dashed #000; margin: 4px 0; }
        td { padding: 1px 0; vertical-align: top; } .num { text-align: left; white-space: nowrap; } img.logo { max-width: 60%; max-height: 70px; }`;
}

const PRINT_TYPE_NAMES = { dine_in: 'صالة', takeaway: 'تيك أواي', delivery: 'توصيل', pickup: 'استلام' };
const PRINT_METHOD_NAMES = { cash: 'كاش', card: 'كارت', instapay: 'إنستاباي', wallet: 'محفظة', on_account: 'آجل' };
const PRINT_STATION_NAMES = { kitchen: 'المطبخ', bar: 'البار', shisha: 'الشيشة' };

function buildReceiptHtml(o, s) {
    const g = s.general || {};
    const r = s.receipt || {};
    const money = v => (Number(v) || 0).toFixed(2);
    const paid = o.status === 'closed';
    const items = (o.items || []).map(i => `<tr><td>${uiEsc(i.name)}${(i.modifiers || []).length ? `<br><small>+ ${uiEsc(i.modifiers.join('، '))}</small>` : ''}${i.notes ? `<br><small>📝 ${uiEsc(i.notes)}</small>` : ''}</td>
        <td class="num">${uiEsc(i.quantity)}×${money(i.unit_price)}</td><td class="num">${money(i.total_price)}</td></tr>`).join('');
    const pays = (o.payments || []).filter(p => Number(p.amount) > 0).map(p => `<tr><td>${uiEsc(PRINT_METHOD_NAMES[p.method] || p.method)}</td><td class="num">${money(p.amount)}</td></tr>`).join('');
    return `
        ${r.show_logo !== false && g.logo ? `<div class="c"><img class="logo" src="${uiEsc(g.logo)}"></div>` : ''}
        <div class="c b big">${uiEsc(g.company_name || '')}</div>
        ${o.branch ? `<div class="c">${uiEsc(o.branch)}</div>` : ''}
        ${g.address ? `<div class="c">${uiEsc(g.address)}</div>` : ''}
        ${g.phone ? `<div class="c">ت: ${uiEsc(g.phone)}</div>` : ''}
        ${r.show_tax_number !== false && g.tax_number ? `<div class="c">رقم ضريبي: ${uiEsc(g.tax_number)}</div>` : ''}
        ${g.commercial_register ? `<div class="c">س.ت: ${uiEsc(g.commercial_register)}</div>` : ''}
        ${r.header ? `<div class="c">${uiEsc(r.header)}</div>` : ''}
        <div class="line"></div>
        <div class="c b">${paid ? 'فاتورة' : 'حساب (غير مدفوع)'} ${uiEsc(o.order_number || '')}</div>
        <div>${uiEsc(uiDate(o.created_at))} | ${uiEsc(PRINT_TYPE_NAMES[o.order_type] || o.order_type || '')}${o.table_number ? ' | طاولة ' + uiEsc(o.table_number) : ''}</div>
        ${o.waiter ? `<div>الويتر: ${uiEsc(o.waiter)}</div>` : ''}${o.cashier ? `<div>الكاشير: ${uiEsc(o.cashier)}</div>` : ''}
        ${o.customer ? `<div>العميل: ${uiEsc(o.customer)}</div>` : ''}
        <div class="line"></div>
        <table>${items}</table>
        <div class="line"></div>
        <table>
            <tr><td>المجموع</td><td class="num">${money(o.sub_total)}</td></tr>
            ${Number(o.discount_amount) ? `<tr><td>الخصم</td><td class="num">-${money(o.discount_amount)}</td></tr>` : ''}
            ${Number(o.service_charge_amount) ? `<tr><td>الخدمة</td><td class="num">${money(o.service_charge_amount)}</td></tr>` : ''}
            ${Number(o.tax_amount) ? `<tr><td>ضريبة القيمة المضافة</td><td class="num">${money(o.tax_amount)}</td></tr>` : ''}
            <tr class="b big"><td>الإجمالي</td><td class="num">${money(o.total_amount)} ${uiEsc(g.currency || '')}</td></tr>
        </table>
        ${pays ? `<div class="line"></div><table>${pays}</table>` : ''}
        <div class="line"></div>
        ${r.footer ? `<div class="c">${uiEsc(r.footer)}</div>` : ''}`;
}

function buildKitchenTicketHtml(o, station) {
    const items = (o.items || []).filter(i => !station || i.station === station);
    if (!items.length) return '';
    return `<div class="c b big">${uiEsc(PRINT_STATION_NAMES[station] || 'المطبخ')}</div>
        <div class="c b big">${uiEsc(o.order_number || '')}</div>
        <div class="c">${uiEsc(PRINT_TYPE_NAMES[o.order_type] || '')}${o.table_number ? ' | طاولة ' + uiEsc(o.table_number) : ''}${o.waiter ? ' | ' + uiEsc(o.waiter) : ''}</div>
        <div class="c">${uiEsc(uiDate(new Date().toISOString()))}</div><div class="line"></div>
        <table>${items.map(i => `<tr><td class="b big">${uiEsc(i.quantity)} ×</td><td class="b big">${uiEsc(i.name)}
            ${(i.modifiers || []).length ? `<br><small>+ ${uiEsc(i.modifiers.join('، '))}</small>` : ''}
            ${i.notes ? `<br><small>📝 ${uiEsc(i.notes)}</small>` : ''}</td></tr>`).join('')}</table>`;
}

async function loadPrintData(orderId) {
    const res = await uiCall('order_print_data_secure', { p_order_id: orderId });
    if (res && res.settings && typeof appSettings !== 'undefined') appSettings = res.settings;
    return res;
}

async function printOrderReceipt(orderId) {
    const res = await loadPrintData(orderId);
    if (!res) return;
    const copies = Math.max(1, Math.min(5, Number(appSet('receipt', 'copies', 1)) || 1));
    const one = buildReceiptHtml(res.order, res.settings);
    printHtml(Array.from({ length: copies }, () => one).join('<div style="page-break-after:always"></div>'), receiptPageCss());
}

async function printKitchenTickets(orderId) {
    const res = await loadPrintData(orderId);
    if (!res) return;
    const stations = [...new Set((res.order.items || []).map(i => i.station))];
    const html = stations.map(st => buildKitchenTicketHtml(res.order, st)).filter(Boolean).join('<div style="page-break-after:always"></div>');
    if (html) printHtml(html, receiptPageCss());
}

// -----------------------------------------
// التقارير: PDF (شاشة طباعة) و Excel بلوجو الشركة
// -----------------------------------------
function reportCellText(col, value) {
    if (value === null || value === undefined) return '';
    if (col.type === 'm') return (Number(value) || 0).toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
    if (col.type === 'p') return (Number(value) || 0).toFixed(1) + '%';
    if (col.type === 'n') return String(Number(value));
    return String(value);
}

function printReportPdf(rep) {
    const g = (typeof appSettings !== 'undefined' && appSettings && appSettings.general) || {};
    const landscape = (rep.columns || []).length > 7;
    const head = (rep.columns || []).map(c => `<th>${uiEsc(c.label)}</th>`).join('');
    const body = (rep.rows || []).map(r => '<tr>' + rep.columns.map(c => `<td class="${['m', 'n', 'p'].includes(c.type) ? 'num' : ''}">${uiEsc(reportCellText(c, r[c.key]))}</td>`).join('') + '</tr>').join('');
    const totals = reportTotals(rep);
    const foot = totals ? '<tr class="tot">' + rep.columns.map((c, i) => `<td class="num">${i === 0 ? 'الإجمالي' : (totals[c.key] !== undefined ? uiEsc(reportCellText(c, totals[c.key])) : '')}</td>`).join('') + '</tr>' : '';
    printHtml(`
        <div class="hdr">
            ${g.logo ? `<img src="${uiEsc(g.logo)}">` : ''}
            <div><div class="co">${uiEsc(g.company_name || '')}</div>
            <div class="sub">${uiEsc([g.address, g.phone, g.tax_number ? 'رقم ضريبي ' + g.tax_number : ''].filter(Boolean).join(' | '))}</div></div>
        </div>
        <h1>${uiEsc(rep.title)}</h1>
        <div class="meta">الفترة: ${uiEsc(rep.from)} إلى ${uiEsc(rep.to)} | الفرع: ${uiEsc(rep.branch || '')} | اتطبع: ${uiEsc(uiDate(new Date().toISOString()))} بواسطة ${uiEsc(currentUser?.name || '')}</div>
        <table><thead><tr>${head}</tr></thead><tbody>${body || `<tr><td colspan="${rep.columns.length}" class="c">لا توجد بيانات</td></tr>`}${foot}</tbody></table>`,
        `@page { size: A4 ${landscape ? 'landscape' : 'portrait'}; margin: 12mm; } body { font-size: 11px; }
         .hdr { display: flex; align-items: center; gap: 12px; border-bottom: 3px solid #1d4ed8; padding-bottom: 8px; margin-bottom: 10px; }
         .hdr img { max-height: 60px; max-width: 160px; } .co { font-size: 20px; font-weight: bold; color: #1e3a8a; } .sub { color: #555; }
         h1 { font-size: 16px; margin: 6px 0; color: #1e3a8a; } .meta { color: #555; margin-bottom: 8px; }
         th { background: #1d4ed8; color: #fff; padding: 5px; border: 1px solid #1d4ed8; } td { padding: 4px 5px; border: 1px solid #ddd; }
         tr:nth-child(even) td { background: #f3f6fb; } .num { text-align: left; white-space: nowrap; } .c { text-align: center; }
         .tot td { font-weight: bold; background: #e0e7ff !important; } thead { display: table-header-group; }`);
}

function reportTotals(rep) {
    const sumCols = (rep.columns || []).filter(c => c.type === 'm' || (c.type === 'n' && !/avg|days_left|hours|change/.test(c.key)));
    if (!sumCols.length || !(rep.rows || []).length || ['sales_compare', 'stock_turnover'].includes(rep.key)) return null;
    const t = {};
    sumCols.forEach(c => { if (!/avg|unit_cost|min|max|price|per_guest|cost_per_unit|credit_limit|balance_after|difference_qty/.test(c.key)) t[c.key] = rep.rows.reduce((s, r) => s + (Number(r[c.key]) || 0), 0); });
    return Object.keys(t).length ? t : null;
}

function loadScriptOnce(src) {
    return new Promise((resolve, reject) => {
        if (document.querySelector(`script[src="${src}"]`)) return resolve();
        const s = document.createElement('script');
        s.src = src; s.onload = resolve; s.onerror = () => reject(new Error('تعذر تحميل مكتبة التصدير.'));
        document.head.appendChild(s);
    });
}

async function exportReportExcel(rep) {
    try {
        await loadScriptOnce('vendor/exceljs.min.js');
        const g = (typeof appSettings !== 'undefined' && appSettings && appSettings.general) || {};
        const wb = new ExcelJS.Workbook();
        wb.creator = 'Motion POS';
        const ws = wb.addWorksheet((rep.title || 'تقرير').slice(0, 30), { views: [{ rightToLeft: true, state: 'frozen', ySplit: 6 }] });
        const n = Math.max(rep.columns.length, 3);
        let startCol = 1;
        if (g.logo && /^data:image\/(png|jpe?g);base64,/.test(g.logo)) {
            const ext = g.logo.includes('image/png') ? 'png' : 'jpeg';
            const imgId = wb.addImage({ base64: g.logo, extension: ext });
            ws.addImage(imgId, { tl: { col: 0, row: 0 }, ext: { width: 110, height: 60 } });
            startCol = 2;
        }
        ws.mergeCells(1, startCol, 1, n); ws.getCell(1, startCol).value = g.company_name || '';
        ws.getCell(1, startCol).font = { bold: true, size: 16, color: { argb: 'FF1E3A8A' } };
        ws.mergeCells(2, startCol, 2, n); ws.getCell(2, startCol).value = [g.address, g.phone, g.tax_number ? 'رقم ضريبي ' + g.tax_number : ''].filter(Boolean).join(' | ');
        ws.mergeCells(3, startCol, 3, n); ws.getCell(3, startCol).value = rep.title;
        ws.getCell(3, startCol).font = { bold: true, size: 13 };
        ws.mergeCells(4, startCol, 4, n); ws.getCell(4, startCol).value = `الفترة: ${rep.from} إلى ${rep.to} | الفرع: ${rep.branch || ''} | اتطبع: ${uiDate(new Date().toISOString())}`;
        ws.getRow(1).height = 26; ws.getRow(2).height = 18;
        const headerRow = ws.getRow(6);
        rep.columns.forEach((c, i) => {
            const cell = headerRow.getCell(i + 1);
            cell.value = c.label;
            cell.font = { bold: true, color: { argb: 'FFFFFFFF' } };
            cell.fill = { type: 'pattern', pattern: 'solid', fgColor: { argb: 'FF1D4ED8' } };
            cell.alignment = { horizontal: 'center', vertical: 'middle', wrapText: true };
            cell.border = { top: { style: 'thin' }, bottom: { style: 'thin' }, left: { style: 'thin' }, right: { style: 'thin' } };
            ws.getColumn(i + 1).width = Math.max(12, Math.min(40, String(c.label).length + 6));
        });
        headerRow.height = 22;
        (rep.rows || []).forEach((r, ri) => {
            const row = ws.getRow(7 + ri);
            rep.columns.forEach((c, i) => {
                const cell = row.getCell(i + 1);
                const v = r[c.key];
                cell.value = ['m', 'n', 'p'].includes(c.type) && v !== null && v !== undefined && v !== '' ? Number(v) : (v ?? '');
                if (c.type === 'm') cell.numFmt = '#,##0.00';
                if (c.type === 'p') cell.numFmt = '0.0"%"';
                cell.border = { bottom: { style: 'hair', color: { argb: 'FFCCCCCC' } } };
                if (ri % 2 === 1) cell.fill = { type: 'pattern', pattern: 'solid', fgColor: { argb: 'FFF3F6FB' } };
            });
        });
        const totals = reportTotals(rep);
        if (totals) {
            const row = ws.getRow(7 + rep.rows.length);
            row.getCell(1).value = 'الإجمالي';
            rep.columns.forEach((c, i) => { if (totals[c.key] !== undefined) { row.getCell(i + 1).value = totals[c.key]; if (c.type === 'm') row.getCell(i + 1).numFmt = '#,##0.00'; } });
            row.font = { bold: true };
            row.eachCell(cell => { cell.fill = { type: 'pattern', pattern: 'solid', fgColor: { argb: 'FFE0E7FF' } }; });
        }
        ws.autoFilter = { from: { row: 6, column: 1 }, to: { row: 6, column: rep.columns.length } };
        const buf = await wb.xlsx.writeBuffer();
        const blob = new Blob([buf], { type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' });
        const a = document.createElement('a');
        a.href = URL.createObjectURL(blob);
        a.download = `${rep.title} ${rep.from} - ${rep.to}.xlsx`.replace(/[\\/:*?"<>|]/g, '-');
        document.body.appendChild(a); a.click(); a.remove();
        setTimeout(() => URL.revokeObjectURL(a.href), 5000);
    } catch (err) {
        console.error('Excel export error:', err);
        showToast('تعذر التصدير لإكسل: ' + (err.message || ''), 'error');
    }
}
