const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');

const manifestPath = path.join(__dirname, '..', 'manifest.json');
const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));

assert.strictEqual(manifest.manifest_version, 3, 'manifest_version must be 3');
assert.strictEqual(manifest.name, 'MyPass');
assert.ok(Array.isArray(manifest.permissions), 'permissions must be an array');
assert.ok(manifest.permissions.includes('nativeMessaging'), 'missing nativeMessaging permission');
assert.ok(manifest.permissions.includes('activeTab'), 'missing activeTab permission');
assert.ok(manifest.permissions.includes('scripting'), 'missing scripting permission');
assert.strictEqual(manifest.background.service_worker, 'background.js');
assert.strictEqual(manifest.action.default_popup, 'popup.html');
assert.strictEqual(manifest.content_scripts.length, 1);
assert.strictEqual(manifest.content_scripts[0].js[0], 'content.js');
assert.strictEqual(manifest.content_scripts[0].matches[0], '<all_urls>');
assert.strictEqual(manifest.content_scripts[0].run_at, 'document_idle');

console.log('manifest.json OK');
