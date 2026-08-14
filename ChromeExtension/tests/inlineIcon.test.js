const assert = require('node:assert');

function fakeInput(attrs = {}, extra = {}) {
  return {
    getAttribute: (name) => (Object.prototype.hasOwnProperty.call(attrs, name) ? attrs[name] : null),
    offsetParent: extra.hidden ? null : {},
    disabled: !!extra.disabled,
    readOnly: !!extra.readOnly,
    closest: (sel) => (sel === 'form' ? extra.form || null : null),
    tagName: 'INPUT',
  };
}

function fakeScope(inputs) {
  return {
    querySelectorAll: (selector) => {
      if (selector === 'input[type="password"]') {
        return inputs.filter((i) => i.getAttribute('type') === 'password');
      }
      // findOtpField's selector — unfiltered, exercised on every findFillableFields/
      // findLoginForm call below since both call findOtpField internally.
      if (selector === 'input, textarea') return inputs;
      // the username selector
      return inputs.filter((i) => {
        const t = i.getAttribute('type');
        return t === 'text' || t === 'email' || (i.getAttribute('autocomplete') || '').includes('username');
      });
    },
  };
}

const { isFieldVisible, findFillableFields, findLoginForm } = require('../content.js');

// isFieldVisible
assert.strictEqual(isFieldVisible(fakeInput({ type: 'text' })), true, 'plain visible input is fillable');
assert.strictEqual(isFieldVisible(fakeInput({ type: 'text' }, { hidden: true })), false, 'offsetParent null is not fillable');
assert.strictEqual(isFieldVisible(fakeInput({ type: 'text', disabled: '' })), false, 'disabled attribute excluded');
assert.strictEqual(isFieldVisible(fakeInput({ type: 'text' }, { readOnly: true })), false, 'readOnly property excluded');
console.log('inlineIcon.test.js: isFieldVisible OK');

// findFillableFields
const pw = fakeInput({ type: 'password' });
const user = fakeInput({ type: 'text', name: 'username' });
const kinds = (fields) => fields.map((f) => f.kind).sort();

assert.deepStrictEqual(
  kinds(findFillableFields(fakeScope([user, pw]))),
  ['password', 'username'],
  'password outside any form still yields both fields'
);

const userOnly = findFillableFields(fakeScope([fakeInput({ type: 'email', name: 'email' })]));
assert.deepStrictEqual(kinds(userOnly), ['username'], 'identifier-first page with no password field still gets a username field');

assert.deepStrictEqual(
  findFillableFields(fakeScope([fakeInput({ type: 'password' }, { hidden: true })])),
  [],
  'hidden password field yields nothing'
);

// MIN_USERNAME_FIELD_SCORE — the floor applies ONLY when the page has no password field.
// A bare `<input type="text">` (score 1) is a search box or a comment field, not a login.
assert.deepStrictEqual(
  findFillableFields(fakeScope([fakeInput({ type: 'text' })])),
  [],
  'a bare text input with no password field on the page gets NO icon'
);
assert.deepStrictEqual(
  findFillableFields(fakeScope([fakeInput({ type: 'text' }), fakeInput({ type: 'text' })])),
  [],
  'several bare text inputs still get nothing — the floor is on the best candidate'
);
// But a password field's presence is itself the evidence, so the floor is waived there:
// dropping this would regress applyFill on a bare `<input type="text">` +
// `<input type="password">` login form.
assert.deepStrictEqual(
  kinds(findFillableFields(fakeScope([fakeInput({ type: 'text' }), fakeInput({ type: 'password' })]))),
  ['password', 'username'],
  'a bare text input ALONGSIDE a password field still gets a username icon'
);
// The floor lets through the weakest intentional identifier-first signals.
assert.deepStrictEqual(
  kinds(findFillableFields(fakeScope([fakeInput({ type: 'text', name: 'login' })]))),
  ['username'],
  'name=login scores 3 and clears the floor with no password field present'
);
assert.deepStrictEqual(
  kinds(findFillableFields(fakeScope([fakeInput({ type: 'text', autocomplete: 'username' })]))),
  ['username'],
  'autocomplete=username clears the floor with no password field present'
);

// An OTP field also matches the username selector — OTP must win, and the field
// must appear exactly once.
const otp = fakeInput({ type: 'text', autocomplete: 'one-time-code' });
const otpFields = findFillableFields(fakeScope([otp]));
assert.deepStrictEqual(kinds(otpFields), ['otp'], 'one-time-code field is classified otp, not username');
assert.strictEqual(otpFields.length, 1, 'a field is never emitted twice');
console.log('inlineIcon.test.js: findFillableFields OK');

// findLoginForm — reads the global `document`, so stub it per case and restore it after.
const originalDocument = global.document;

// 1. Password field inside a <form> yields {form, passwordInput, usernameInput} with a
// non-null form and both inputs identified correctly.
const formInputs = [];
const formEl = Object.assign(fakeScope(formInputs), { tagName: 'FORM' });
const pwInForm = fakeInput({ type: 'password' }, { form: formEl });
const userInForm = fakeInput({ type: 'text', name: 'username' }, { form: formEl });
formInputs.push(pwInForm, userInForm);
global.document = fakeScope([userInForm, pwInForm]);
const withForm = findLoginForm();
assert.notStrictEqual(withForm, null, 'password field inside a form yields a result');
assert.strictEqual(withForm.form, formEl, 'form is the enclosing <form> element');
assert.strictEqual(withForm.passwordInput, pwInForm, 'passwordInput is the password field');
assert.strictEqual(withForm.usernameInput, userInForm, 'usernameInput is the username field');

// 2. Password field with NO enclosing <form> — deliberate behaviour change from the old
// findLoginForm, which returned null here and silently made applyFill do nothing on such
// pages. The new findLoginForm returns a non-null result with form: null so applyFill can
// still fill the password.
const pwNoForm = fakeInput({ type: 'password' });
global.document = fakeScope([pwNoForm]);
const withoutForm = findLoginForm();
assert.notStrictEqual(withoutForm, null, 'password field with no enclosing form still yields a result');
assert.strictEqual(
  withoutForm.form,
  null,
  'deliberate behaviour change: a password field outside any <form> now returns form: null instead of the old null result, so applyFill can still fill it'
);
assert.strictEqual(withoutForm.passwordInput, pwNoForm, 'passwordInput is set even without a form');

// 3. No password field on the page.
global.document = fakeScope([fakeInput({ type: 'text', name: 'username' })]);
assert.strictEqual(findLoginForm(), null, 'no password field on the page yields null');

// 4. Password plus a username field — usernameInput must be the username field, not the
// password field.
const pw2 = fakeInput({ type: 'password' });
const user2 = fakeInput({ type: 'text', name: 'username' });
global.document = fakeScope([pw2, user2]);
const withUsername = findLoginForm();
assert.strictEqual(withUsername.usernameInput, user2, 'usernameInput is the username field, not the password field');
assert.notStrictEqual(withUsername.usernameInput, withUsername.passwordInput, 'password and username inputs are distinct fields');

global.document = originalDocument;
console.log('inlineIcon.test.js: findLoginForm OK');

const { chooseInlinePanel } = require('../content.js');

const withTotp = { id: '1', title: 'Example', username: 'alice', hasTotp: true };
const noTotp = { id: '2', title: 'Other', username: 'bob', hasTotp: false };
const listResponse = { type: 'credentialList', credentials: [withTotp, noTotp] };

assert.deepStrictEqual(
  chooseInlinePanel(listResponse, 'password'),
  { panel: 'entries', entries: [withTotp, noTotp] },
  'password field lists every match'
);

assert.deepStrictEqual(
  chooseInlinePanel(listResponse, 'otp'),
  { panel: 'entries', entries: [withTotp] },
  'otp field lists only entries that have a TOTP secret'
);

assert.deepStrictEqual(
  chooseInlinePanel({ type: 'credentialList', credentials: [noTotp] }, 'otp'),
  { panel: 'empty', entries: [] },
  'a non-empty list with no TOTP entries renders empty on an otp field'
);

assert.deepStrictEqual(
  chooseInlinePanel({ type: 'credentialList', credentials: [] }, 'password'),
  { panel: 'empty', entries: [] },
  'no matches for this site'
);

assert.strictEqual(chooseInlinePanel({ type: 'locked' }, 'password').panel, 'locked');
assert.strictEqual(chooseInlinePanel({ type: 'pairingRequired' }, 'password').panel, 'pairingRequired');
assert.strictEqual(chooseInlinePanel({ type: 'error' }, 'password').panel, 'unavailable');
assert.strictEqual(chooseInlinePanel(null, 'password').panel, 'unavailable', 'no response is treated as app unavailable');
assert.strictEqual(chooseInlinePanel({ type: 'somethingNew' }, 'password').panel, 'unavailable', 'unknown response never renders entries');
console.log('inlineIcon.test.js: chooseInlinePanel OK');

const { isTrustedActivation, handleEntrySelect, handleIconActivate } = require('../content.js');

assert.strictEqual(isTrustedActivation({ isTrusted: true }), true);
assert.strictEqual(isTrustedActivation({ isTrusted: false }), false, 'synthetic events are rejected');
assert.strictEqual(isTrustedActivation({}), false, 'a missing isTrusted is rejected, not assumed true');
assert.strictEqual(isTrustedActivation(null), false, 'no event is rejected');

// handleEntrySelect: the ONLY message it may send, and only on a trusted event.
const sent = [];
const record = (message) => sent.push(message);

assert.strictEqual(
  handleEntrySelect({ isTrusted: false }, 'entry-1', 'https://example.com', record),
  false,
  'synthetic click does not fill'
);
assert.deepStrictEqual(sent, [], 'synthetic click sends nothing at all');

assert.strictEqual(handleEntrySelect({ isTrusted: true }, 'entry-1', 'https://example.com', record), true);
assert.deepStrictEqual(
  sent,
  [{ type: 'fillCredential', id: 'entry-1', url: 'https://example.com' }],
  'fill message is exactly what popup.js sends — no secret, no extra field'
);

// handleIconActivate
let opened = 0;
assert.strictEqual(handleIconActivate({ isTrusted: false }, () => { opened += 1; }), false);
assert.strictEqual(opened, 0, 'synthetic click does not open the panel');
assert.strictEqual(handleIconActivate({ isTrusted: true }, () => { opened += 1; }), true);
assert.strictEqual(opened, 1);
console.log('inlineIcon.test.js: trusted-event gate OK');

const {
  buildShadowHost, buildIconHost, buildPanelHost, positionHostToField, KEY_ICON_PATH_D,
  ICON_HOST_STYLE, PANEL_HOST_STYLE,
} = require('../content.js');

const SVG_NS_EXPECTED = 'http://www.w3.org/2000/svg';

// Records setProperty's THIRD argument. Without it the entire `!important` page-CSS defence
// could be deleted from content.js and every suite in this file would stay green.
function fakeStyle() {
  const style = {
    priority: {},
    setProperty(prop, value, priority) {
      style[prop] = value;
      style.priority[prop] = priority || '';
    },
  };
  return style;
}

function fakeElement(tag) {
  const el = {
    tagName: tag.toUpperCase(),
    style: fakeStyle(),
    children: [],
    attributes: {},
    shadowMode: null,
    setAttribute(name, value) { this.attributes[name] = value; },
    getAttribute(name) { return Object.prototype.hasOwnProperty.call(this.attributes, name) ? this.attributes[name] : null; },
    appendChild(child) { this.children.push(child); return child; },
    listeners: {},
    addEventListener(type, handler) {
      (this.listeners[type] || (this.listeners[type] = [])).push(handler);
    },
    dispatch(type, event) {
      (this.listeners[type] || []).forEach((handler) => handler(event));
    },
    attachShadow(options) {
      this.shadowMode = options.mode;
      const root = fakeElement('shadow-root');
      this.__shadow = root;
      return root;
    },
  };
  return el;
}

const fakeDocument = {
  createElement: (tag) => fakeElement(tag),
  createElementNS: (ns, tag) => {
    const el = fakeElement(tag);
    el.namespaceURI = ns;
    return el;
  },
};

const built = buildIconHost(fakeDocument);
assert.strictEqual(built.host.shadowMode, 'closed', 'shadow root MUST be closed so the page cannot read the panel');
assert.ok(built.shadow, 'a shadow root is returned');
assert.ok(built.button, 'a clickable button lives inside the shadow root');
assert.ok(/^M/.test(KEY_ICON_PATH_D), 'the glyph is SVG path data');
assert.ok(!/chrome-extension:/.test(KEY_ICON_PATH_D), 'the glyph never references an extension URL');
const glyph = built.button.children[0];
assert.strictEqual(glyph.namespaceURI, SVG_NS_EXPECTED, 'the svg element is namespaced, not an HTML element');
assert.strictEqual(glyph.children[0].getAttribute('d'), KEY_ICON_PATH_D, 'the path carries the key glyph data');
assert.strictEqual(built.button.innerHTML, undefined, 'the icon is built from DOM nodes, never innerHTML — Trusted Types sites throw on innerHTML');

// Every layout property on the host must carry `!important`: a page rule such as
// [data-mypass-inline-icon]{display:none!important} beats a plain inline style.
for (const prop of ['position', 'z-index', 'display', 'pointer-events']) {
  assert.strictEqual(
    built.host.style.priority[prop],
    'important',
    `host ${prop} is set !important so a page !important rule cannot override it`
  );
}

// positioning writes only to the host's own style — the page's input is untouched.
// scrollX/scrollY are deliberately NON-ZERO so dropping scroll compensation fails here,
// and the expected values are pinned exactly so the arithmetic cannot drift.
const host = fakeElement('div');
positionHostToField(host, { top: 100, left: 50, width: 200, height: 30 }, { scrollX: 40, scrollY: 200 });
assert.strictEqual(host.style.position, 'absolute');
// top  = rect.top(100)  + scrollY(200) + (height(30) - size(20)) / 2      = 305
// left = rect.left(50)  + scrollX(40)  + width(200) - size(20) - inset(6) = 264
assert.strictEqual(host.style.top, '305px', 'top = rect.top + scrollY + (height - 20) / 2');
assert.strictEqual(host.style.left, '264px', 'left = rect.left + scrollX + width - 20 - 6');
assert.strictEqual(host.style.priority.top, 'important', 'top is set !important');
assert.strictEqual(host.style.priority.left, 'important', 'left is set !important');
assert.strictEqual(host.style.priority.position, 'important', 'position is set !important');

// The same field with no scroll — proves the two offsets above really came from
// scrollX/scrollY rather than from constants that happen to match.
const unscrolledHost = fakeElement('div');
positionHostToField(unscrolledHost, { top: 100, left: 50, width: 200, height: 30 }, { scrollX: 0, scrollY: 0 });
assert.strictEqual(unscrolledHost.style.top, '105px', 'without scroll the top is 200px higher');
assert.strictEqual(unscrolledHost.style.left, '224px', 'without scroll the left is 40px further left');
console.log('inlineIcon.test.js: icon host OK');

// buildShadowHost is the bare scaffolding shared by the icon and the panel — the panel
// is a list, not a button, and must never end up with the icon's glyph inside it.
const bareHost = buildShadowHost(fakeDocument, 'data-mypass-inline-panel', PANEL_HOST_STYLE);
assert.strictEqual(bareHost.host.shadowMode, 'closed', 'bare host shadow root MUST be closed too');
assert.strictEqual(bareHost.shadow.children.length, 1, 'bare shadow root contains only the style element');
assert.strictEqual(bareHost.shadow.children[0].tagName, 'STYLE', 'the sole child is the style element');
assert.ok(
  !bareHost.shadow.children.some((child) => child.tagName === 'BUTTON'),
  'no button anywhere in the bare shadow root'
);
assert.strictEqual(bareHost.host.getAttribute('data-mypass-inline-panel'), '', 'the bare host carries whichever marker it was given');
assert.strictEqual(bareHost.host.getAttribute('data-mypass-inline-icon'), null, 'the bare host does not also carry the icon marker');

const iconHostBuilt = buildIconHost(fakeDocument);
assert.strictEqual(iconHostBuilt.host.getAttribute('data-mypass-inline-icon'), '', 'the icon host carries the icon marker');
assert.strictEqual(iconHostBuilt.shadow.children.length, 2, 'icon shadow root still contains both the style and the button');
assert.ok(iconHostBuilt.shadow.children.some((child) => child.tagName === 'STYLE'), 'icon shadow root still contains the style element');
assert.ok(iconHostBuilt.shadow.children.includes(iconHostBuilt.button), 'icon shadow root still contains the button');
assert.strictEqual(iconHostBuilt.button.children[0].namespaceURI, SVG_NS_EXPECTED, 'the button still carries the namespaced svg glyph');

// Each surface installs ITS OWN stylesheet. Handing the panel the icon's sheet rendered
// every panel row as a 20x20 transparent box with overflowing text. buildPanelHost is what
// the browser-only togglePanel actually calls, so asserting on it pins the real pairing.
const panelHostBuilt = buildPanelHost(fakeDocument);
assert.strictEqual(panelHostBuilt.host.getAttribute('data-mypass-inline-panel'), '', 'the panel host carries the panel marker');
assert.strictEqual(panelHostBuilt.host.getAttribute('data-mypass-inline-icon'), null, 'the panel host does not carry the icon marker');
assert.strictEqual(panelHostBuilt.host.shadowMode, 'closed', 'the panel shadow root is closed');
assert.strictEqual(
  panelHostBuilt.shadow.children[0].textContent,
  PANEL_HOST_STYLE,
  'the panel host installs the PANEL stylesheet, not the icon one'
);
assert.strictEqual(
  iconHostBuilt.shadow.children.find((child) => child.tagName === 'STYLE').textContent,
  ICON_HOST_STYLE,
  'the icon host installs the ICON stylesheet'
);
assert.strictEqual(bareHost.shadow.children[0].textContent, PANEL_HOST_STYLE, 'buildShadowHost installs whichever sheet it is given');
assert.notStrictEqual(PANEL_HOST_STYLE, ICON_HOST_STYLE, 'the two stylesheets are genuinely different');

// What the panel stylesheet must actually provide — it is a list surface, not a 20x20 glyph.
assert.ok(/:host\{all:initial\}/.test(PANEL_HOST_STYLE), 'the panel keeps :host{all:initial} isolation');
assert.ok(/\.panel\{[^}]*background:#ffffff/.test(PANEL_HOST_STYLE), 'the panel has an opaque background');
assert.ok(/\.panel\{[^}]*border:1px solid/.test(PANEL_HOST_STYLE), 'the panel has a border');
assert.ok(/\.panel\{[^}]*border-radius:/.test(PANEL_HOST_STYLE), 'the panel has a border radius');
assert.ok(/\.panel\{[^}]*min-width:/.test(PANEL_HOST_STYLE), 'the panel has a min width');
assert.ok(/\.panel\{[^}]*max-width:/.test(PANEL_HOST_STYLE), 'the panel has a max width');
assert.ok(/\.panel\{[^}]*padding:/.test(PANEL_HOST_STYLE), 'the panel has padding');
assert.ok(/\.row\{[^}]*width:100%/.test(PANEL_HOST_STYLE), 'panel rows are full width');
assert.ok(/\.row\{[^}]*text-align:left/.test(PANEL_HOST_STYLE), 'panel rows are left aligned');
assert.ok(/\.row:hover/.test(PANEL_HOST_STYLE), 'panel rows have a hover state');
assert.ok(!/\.row\{[^}]*height:20px/.test(PANEL_HOST_STYLE), 'panel rows are never the icon-sized 20x20 box');
console.log('inlineIcon.test.js: shadow host separation OK');

const { buildPanelContent } = require('../content.js');

const selectCalls = [];
const entriesPanel = buildPanelContent(
  fakeDocument,
  { panel: 'entries', entries: [withTotp, noTotp] },
  { onSelect: (event, entryId) => selectCalls.push({ event, entryId }), onUnlock: () => {} }
);
assert.strictEqual(entriesPanel.rows.length, 2, 'one row per entry');
assert.strictEqual(entriesPanel.rows[0].textContent, 'Example — alice', 'row text is title, em dash, username');
// The rows are styled by PANEL_HOST_STYLE's class rules, so they must carry those classes.
assert.strictEqual(entriesPanel.root.getAttribute('class'), 'panel', 'the panel root carries the .panel class');
assert.strictEqual(entriesPanel.rows[0].getAttribute('class'), 'row', 'each entry row carries the .row class');
assert.strictEqual(entriesPanel.rows[1].getAttribute('class'), 'row', 'every entry row carries it, not just the first');

const firstClickEvent = { type: 'click', target: entriesPanel.rows[0] };
entriesPanel.rows[0].dispatch('click', firstClickEvent);
assert.strictEqual(selectCalls.length, 1, 'clicking the first row invokes onSelect');
assert.strictEqual(selectCalls[0].event, firstClickEvent, 'onSelect receives the click event');
assert.strictEqual(selectCalls[0].entryId, '1', 'the first row reports the first entry id');

const secondClickEvent = { type: 'click', target: entriesPanel.rows[1] };
entriesPanel.rows[1].dispatch('click', secondClickEvent);
assert.strictEqual(selectCalls.length, 2, 'clicking the second row invokes onSelect again');
assert.strictEqual(selectCalls[1].entryId, '2', 'the second row reports the second entry id, not the first (no closure-capture bug)');

const emptyPanel = buildPanelContent(fakeDocument, { panel: 'empty', entries: [] }, { onSelect: () => {}, onUnlock: () => {} });
assert.strictEqual(emptyPanel.rows.length, 0, 'the empty state has no selectable rows');
assert.strictEqual(emptyPanel.root.children[0].textContent, 'No entries for this site', 'the empty state renders its message');
assert.strictEqual(emptyPanel.root.children[0].getAttribute('class'), 'message', 'the message carries the .message class');

const unlockCalls = [];
const lockedPanel = buildPanelContent(fakeDocument, { panel: 'locked', entries: [] }, { onSelect: () => {}, onUnlock: (event) => unlockCalls.push(event) });
assert.strictEqual(lockedPanel.rows.length, 0, 'the locked state offers no entries');
assert.ok(lockedPanel.unlockButton, 'the locked state offers an unlock button');
assert.strictEqual(lockedPanel.unlockButton.getAttribute('class'), 'unlock', 'the unlock button carries the .unlock class');
assert.strictEqual(lockedPanel.root.children[0].textContent, 'MyPass is locked', 'the locked state renders its message');

const unlockClickEvent = { type: 'click' };
lockedPanel.unlockButton.dispatch('click', unlockClickEvent);
assert.strictEqual(unlockCalls.length, 1, 'clicking the unlock button invokes onUnlock');
assert.strictEqual(unlockCalls[0], unlockClickEvent, 'onUnlock receives the click event');

const pairingPanel = buildPanelContent(fakeDocument, { panel: 'pairingRequired', entries: [] }, { onSelect: () => {}, onUnlock: () => {} });
assert.strictEqual(pairingPanel.unlockButton, null, 'the pairing state offers no unlock button');
assert.strictEqual(pairingPanel.root.children[0].textContent, 'Pair MyPass to use it here', 'the pairing state renders its message');

const unavailablePanel = buildPanelContent(fakeDocument, { panel: 'unavailable', entries: [] }, { onSelect: () => {}, onUnlock: () => {} });
assert.strictEqual(unavailablePanel.unlockButton, null, 'the unavailable state offers no unlock button');
assert.strictEqual(unavailablePanel.root.children[0].textContent, 'MyPass is not running', 'the unavailable state renders its message');

const unknownPanel = buildPanelContent(fakeDocument, { panel: 'someUnknownState', entries: [] }, { onSelect: () => {}, onUnlock: () => {} });
assert.strictEqual(unknownPanel.root.children[0].textContent, 'MyPass is not running', 'an unrecognized panel value falls back to the unavailable message');
console.log('inlineIcon.test.js: panel content OK');

// resolveFillTargets — the clicked-field-only fill decision. Clicking an icon must fill ONLY
// the field whose icon was clicked; the popup's own fill path never calls this function at
// all (it has no clicked target and falls back to findLoginForm), so that path is unaffected.
const { resolveFillTargets } = require('../content.js');

function fakeFillInput(name) {
  return { tagName: 'INPUT', name };
}

// 1. Clicking a password field fills only the password.
const pwOnly = fakeFillInput('password-field');
const pwTargets = resolveFillTargets({ input: pwOnly, kind: 'password' });
assert.strictEqual(pwTargets.passwordInput, pwOnly, 'a password-initiated fill targets the clicked password input');
assert.strictEqual(pwTargets.usernameInput, null, 'a password-initiated fill must not also target a username');
assert.strictEqual(pwTargets.otpInput, null, 'a password-initiated fill must not also target an otp field');

// 2. Clicking a username field fills only the username.
const usernameOnly = fakeFillInput('username-field');
const userTargets = resolveFillTargets({ input: usernameOnly, kind: 'username' });
assert.strictEqual(userTargets.usernameInput, usernameOnly, 'a username-initiated fill targets the clicked username input');
assert.strictEqual(userTargets.passwordInput, null, 'a username-initiated fill must not also target a password');
assert.strictEqual(userTargets.otpInput, null, 'a username-initiated fill must not also target an otp field');

// 3. Clicking an otp field fills only the otp code.
const otpOnly = fakeFillInput('otp-field');
const otpTargets = resolveFillTargets({ input: otpOnly, kind: 'otp' });
assert.strictEqual(otpTargets.otpInput, otpOnly, 'an otp-initiated fill targets the clicked otp input');
assert.strictEqual(otpTargets.usernameInput, null, 'an otp-initiated fill must not also target a username');
assert.strictEqual(otpTargets.passwordInput, null, 'an otp-initiated fill must not also target a password');

// 4. THE MANUAL-WALK DEFECT, pinned under the new behaviour: a page with two separate login
// groups. Clicking the SECOND group's password must resolve to that exact input, by identity,
// and must leave the first group's inputs completely untouched. This is the same defect
// confirmed live in Chrome on inline-icon-noform.html (four password fields, wrong one filled
// every time) — a future refactor that reintroduces any cross-group lookup must fail this.
const group1Pw = fakeFillInput('group1-password');
const group1User = fakeFillInput('group1-username');
const group2Pw = fakeFillInput('group2-password');
const group2User = fakeFillInput('group2-username');

const secondGroupTargets = resolveFillTargets({ input: group2Pw, kind: 'password' });
assert.strictEqual(
  secondGroupTargets.passwordInput, group2Pw,
  'manual-walk defect (multi-form fill-targeting bug): clicking the second group\'s password must fill that exact input'
);
assert.strictEqual(
  secondGroupTargets.usernameInput, null,
  'manual-walk defect (multi-form fill-targeting bug): clicking a password must never also fill a username, in any group'
);
assert.notStrictEqual(
  secondGroupTargets.passwordInput, group1Pw,
  'manual-walk defect (multi-form fill-targeting bug): must never fill the first group\'s password field'
);
assert.notStrictEqual(
  secondGroupTargets.passwordInput, group1User,
  'manual-walk defect (multi-form fill-targeting bug): must never touch the first group\'s username field either'
);
// Resolving the first group's own password proves the behaviour is symmetric: it too
// resolves to itself and only itself, not just group 2's field from above.
const firstGroupTargets = resolveFillTargets({ input: group1Pw, kind: 'password' });
assert.strictEqual(
  firstGroupTargets.passwordInput, group1Pw,
  'the first group\'s own password-initiated fill targets that exact input'
);
assert.strictEqual(
  firstGroupTargets.usernameInput, null,
  'the first group\'s password-initiated fill must not also target a username'
);
assert.strictEqual(
  firstGroupTargets.otpInput, null,
  'the first group\'s password-initiated fill must not also target an otp field'
);

// 5. A null/malformed target yields all three null.
assert.deepStrictEqual(
  resolveFillTargets(null),
  { usernameInput: null, passwordInput: null, otpInput: null },
  'a null target resolves to no fill targets'
);
assert.deepStrictEqual(
  resolveFillTargets({}),
  { usernameInput: null, passwordInput: null, otpInput: null },
  'a malformed target with no input resolves to no fill targets'
);
assert.deepStrictEqual(
  resolveFillTargets({ kind: 'password' }),
  { usernameInput: null, passwordInput: null, otpInput: null },
  'a target missing its input resolves to no fill targets even with a kind present'
);

console.log('inlineIcon.test.js: fill targeting OK');

// isFillTargetUsable — the consume-once/TTL lifecycle. This wiring (setPendingFillTarget/
// takePendingFillTarget) lives inside the browser-only message listener and is otherwise
// untestable from node, which is exactly where the stale-target bug hid: a fillCredential
// request that never gets an applyFill response (locked vault, native error, hostname
// mismatch) used to leave the target set forever for a later, unrelated fill — including a
// popup-initiated one with no clicked field — to inherit.
const { isFillTargetUsable } = require('../content.js');

const TTL_MS = 5000;
const connectedInput = { isConnected: true };
const disconnectedInput = { isConnected: false };

assert.strictEqual(isFillTargetUsable(null, 1000, TTL_MS), false, 'no target at all is unusable');
assert.strictEqual(
  isFillTargetUsable({ input: disconnectedInput, kind: 'password', at: 1000 }, 1000, TTL_MS),
  false,
  'a target whose input left the document is unusable, even with no time elapsed'
);
// These two pin the boundary exactly: (now - at) === ttlMs must be usable and
// (now - at) === ttlMs + 1 must not, which distinguishes a `<=` comparison from a `<` one —
// swapping the operator flips the first assertion below without touching the second.
assert.strictEqual(
  isFillTargetUsable({ input: connectedInput, kind: 'password', at: 1000 }, 1000 + TTL_MS, TTL_MS),
  true,
  'a target at exactly the TTL boundary (now - at === ttlMs) is still usable'
);
assert.strictEqual(
  isFillTargetUsable({ input: connectedInput, kind: 'password', at: 1000 }, 1000 + TTL_MS + 1, TTL_MS),
  false,
  'a target one millisecond past the TTL boundary is unusable — an unanswered fillCredential must not linger forever'
);
assert.strictEqual(
  isFillTargetUsable({ input: connectedInput, kind: 'password', at: 1000 }, 1200, TTL_MS),
  true,
  'a fresh, connected target within the TTL is usable'
);
console.log('inlineIcon.test.js: fill target lifecycle OK');
