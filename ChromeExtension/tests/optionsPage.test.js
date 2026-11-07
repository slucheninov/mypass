const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');

const root = path.join(__dirname, '..');
const manifest = JSON.parse(fs.readFileSync(path.join(root, 'manifest.json'), 'utf8'));

assert.deepStrictEqual(manifest.options_ui, { page: 'app/app.html', open_in_tab: true });
assert.strictEqual(manifest.options_page, undefined, 'one options mechanism only');
// The standard Options entry is used. Chrome opens it without a hash, so the
// page itself normalises to #/page/settings.
assert.ok(!manifest.permissions.includes('contextMenus'), 'contextMenus must not be requested');

const router = require('../app/router.js');
assert.strictEqual(router.DEFAULT_ROUTE, '/page/settings');
for (const hash of ['', '#', '#/', '#/page/settings']) {
  assert.deepStrictEqual(router.parseRoute(hash), { name: 'settings' }, JSON.stringify(hash));
  assert.strictEqual(router.canonicalHash(hash), '#/page/settings', JSON.stringify(hash));
}
assert.deepStrictEqual(router.parseRoute('#/page/nope'), { name: 'notFound' });

const htmlPath = path.join(root, 'app', 'app.html');
assert.ok(fs.existsSync(htmlPath), 'app/app.html must exist');
const html = fs.readFileSync(htmlPath, 'utf8');
assert.ok(/<script[^>]+src="router\.js"/.test(html), 'router.js script tag');
assert.ok(/<script[^>]+src="app\.js"/.test(html), 'app.js script tag');
const scripts = html.match(/<script\b[^>]*>[\s\S]*?<\/script>/g) || [];
for (const tag of scripts) {
  assert.ok(/\bsrc="/.test(tag), 'inline script forbidden by MV3 CSP: ' + tag);
  assert.ok(/<script[^>]*>\s*<\/script>/.test(tag), 'script tag must have no body: ' + tag);
}
assert.ok(html.includes('id="page-settings"'), 'settings pane container');
console.log('optionsPage tests passed');
