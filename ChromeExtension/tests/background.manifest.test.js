const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');

const manifestPath = path.join(__dirname, '..', 'manifest.json');
const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));

assert.strictEqual(manifest.manifest_version, 3, 'manifest_version must be 3');
assert.strictEqual(manifest.name, 'MyPass');
assert.strictEqual(
  manifest.key,
  'MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA3g4jQjrf7R0zDFOQTwQGRpzY/Zl1iOChwlpfDJav6F6e5GiRJPy7S9/cC8yFvhJZsVLs49hQgLg+HqL206KziXRnSTFT1+SbxFzIGqwGjW1Q9u0koXFEzpE82kPQlxG6zeFqtjm35cPfhkCu6oqGFtImLBzP9JR2s4n5IMEQabVvKH2KxsKF84RK7+3MkBLJ/0bluRxXv+VpeG20QN6rQr/VTmC0B5YoIChLdM0ObWhBjzJl8VA64VCAYcaPfLVQ4ZSkLdrIFfNIi5Sc8/8Mtil8wJCON+W/ilWZnYakMvV5Y83fafu8lTHCeuNzbxGAObJFWeIoeaILkoiD1PCuRQIDAQAB',
  'pinned key must match unpacked extension ID hjijbabodfldconmhdcdphlbgaajkejn'
);
assert.ok(Array.isArray(manifest.permissions), 'permissions must be an array');
assert.ok(manifest.permissions.includes('nativeMessaging'), 'missing nativeMessaging permission');
assert.ok(manifest.permissions.includes('activeTab'), 'missing activeTab permission');
assert.ok(manifest.permissions.includes('webAuthenticationProxy'), 'missing webAuthenticationProxy permission');
assert.ok(
  manifest.permissions.includes('alarms'),
  'the passkey ceremony watchdog runs on chrome.alarms — a setTimeout does not survive service-worker termination'
);
assert.strictEqual(
  manifest.minimum_chrome_version,
  '127',
  'webAuthenticationProxy needs 115, but chrome.action.openPopup() is policy-installed-only on 118-126 and the confirm popup is not optional'
);
assert.ok(
  !manifest.permissions.includes('scripting'),
  'scripting permission is unused (content_scripts already covers injection) and should not be requested'
);
assert.strictEqual(manifest.background.service_worker, 'background.js');
assert.strictEqual(manifest.action.default_popup, 'popup.html');
assert.strictEqual(manifest.content_scripts.length, 1);
assert.strictEqual(manifest.content_scripts[0].js[0], 'vendor/jsQR.js', 'jsQR must load before content.js so the global jsQR function is defined');
assert.strictEqual(
  manifest.content_scripts[0].js[1],
  'shared/entry-visuals.js',
  'entry-visuals.js must load before content.js so letterFromTitle/colorForTitle are defined globals'
);
assert.strictEqual(manifest.content_scripts[0].js[2], 'content.js');
assert.strictEqual(manifest.content_scripts[0].matches[0], '<all_urls>');
assert.strictEqual(manifest.content_scripts[0].run_at, 'document_idle');

const iconsDir = path.join(__dirname, '..', 'icons');
const expectedSizes = ['16', '32', '48', '128'];
assert.ok(manifest.icons, 'manifest must define top-level icons');
assert.ok(manifest.action.default_icon, 'manifest.action must define default_icon');
for (const size of expectedSizes) {
  const relPath = `icons/icon${size}.png`;
  assert.strictEqual(manifest.icons[size], relPath, `manifest.icons["${size}"] must be ${relPath}`);
  assert.strictEqual(manifest.action.default_icon[size], relPath, `action.default_icon["${size}"] must be ${relPath}`);
  const absPath = path.join(__dirname, '..', relPath);
  assert.ok(fs.existsSync(absPath), `${relPath} must exist on disk`);
  const stat = fs.statSync(absPath);
  assert.ok(stat.size > 0, `${relPath} must be non-empty`);
}

console.log('manifest.json OK');
