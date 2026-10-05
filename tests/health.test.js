const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');

const root = path.resolve(__dirname, '..');
const html = fs.readFileSync(path.join(root, 'index.html'), 'utf8');
const jsFiles = fs.readdirSync(path.join(root, 'js'))
    .filter(file => file.endsWith('.js'))
    .map(file => path.join(root, 'js', file));
const source = [html, ...jsFiles.map(file => fs.readFileSync(file, 'utf8'))].join('\n');

test('local scripts referenced by the page exist', () => {
    const sources = [...html.matchAll(/<script\b[^>]*\bsrc=["']([^"']+)["']/gi)]
        .map(match => match[1])
        .filter(src => !/^(?:https?:)?\/\//i.test(src));

    assert.ok(sources.length > 0, 'expected local script references');
    for (const src of sources) {
        assert.ok(fs.existsSync(path.join(root, src)), `missing local script: ${src}`);
    }
});

test('every workspace tab has a matching view and loader', () => {
    const tabs = ['pos', 'kds', 'inventory', 'purchase', 'cost', 'reports', 'accounting', 'settings'];
    for (const tab of tabs) {
        assert.match(html, new RegExp(`id=["']view-${tab}-workspace["']`), `missing view for ${tab}`);
        assert.match(html, new RegExp(`switchMainTab\\('${tab}'\\)`), `missing navigation for ${tab}`);
    }
    for (const loader of [
        'loadKDSOrders', 'loadInventoryOptions', 'loadPurchaseOptions',
        'loadFinancialDashboard', 'initAccountingModule', 'initSettingsModule'
    ]) {
        assert.match(source, new RegExp(`function\\s+${loader}\\s*\\(`), `missing module loader ${loader}`);
    }
});

test('static HTML IDs are unique', () => {
    const ids = [...html.matchAll(/\bid=["']([^"']+)["']/g)].map(match => match[1]);
    const duplicates = ids.filter((id, index) => ids.indexOf(id) !== index);
    assert.deepEqual([...new Set(duplicates)], []);
});

test('functions referenced by inline event handlers are defined', () => {
    const functions = new Set([
        ...source.matchAll(/\bfunction\s+([A-Za-z_$][\w$]*)\s*\(/g)
    ].map(match => match[1]));
    const builtIns = new Set(['alert', 'confirm', 'parseFloat', 'parseInt', 'prompt']);
    const missing = new Set();

    for (const [, handler] of html.matchAll(/\b(?:onclick|onchange|onsubmit)=["']([^"']*)["']/gi)) {
        for (const [, name] of handler.matchAll(/\b([A-Za-z_$][\w$]*)\s*\(/g)) {
            if (!functions.has(name) && !builtIns.has(name)) missing.add(name);
        }
    }
    assert.deepEqual([...missing].sort(), []);
});
