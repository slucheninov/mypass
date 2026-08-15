// popup.html loads shared/entry-visuals.js and popup.js as two SEPARATE classic <script>
// tags, back to back, with no module/type="module" wrapper. Classic scripts in the same
// document share ONE global scope (one GlobalEnvironmentRecord): every top-level `function`,
// `var`, `const`, or `let` in the first script lands in that shared scope before the second
// script's own top-level declarations are processed.
//
// entry-visuals.js declares `letterFromTitle` and `colorForTitle` as top-level function
// declarations. If popup.js ALSO declares a top-level lexical binding (`const`/`let`, including
// via destructuring) with either of those names, the browser's GlobalDeclarationInstantiation
// step for popup.js throws a SyntaxError — "Identifier 'X' has already been declared" — before
// a single statement of popup.js runs. This is exactly what shipped: popup.js used
// `const { letterFromTitle, colorForTitle } = ...` at top level, which collided with the
// function declarations entry-visuals.js had already put in the shared global scope, and the
// entire popup went dead in the browser.
//
// No node test could catch this directly: under `require`, popup.js and entry-visuals.js are
// each loaded as their own CommonJS module with a private module scope, so the `require`
// branch of popup.js's shim is taken and there is no global-scope collision to observe.
// `vm.runInContext` doesn't reproduce it either — a fresh context still permits a lexical
// declaration to shadow a `var`/function-declared global rather than throwing, because that
// collision is a load-time GlobalDeclarationInstantiation check across the SPECIFIC "two
// classic scripts in one document" sequence, not a generic runtime property lookup.
//
// So this test works statically instead: it parses the top-level declared names out of both
// files' SOURCE TEXT (function/const/let/var declarations starting at column 0 — i.e. actually
// top-level, not nested in a block or IIFE) and asserts the two name sets never intersect. If
// they ever do, popup.js will throw exactly the SyntaxError this bug shipped with, the moment
// popup.html loads it after entry-visuals.js.

const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');

function topLevelDeclaredNames(source) {
  const names = new Set();

  // Top-level `function NAME(...)` and `function* NAME(...)` declarations (column 0).
  const fnRe = /^function\*?\s+([A-Za-z_$][\w$]*)/gm;
  let m;
  while ((m = fnRe.exec(source))) names.add(m[1]);

  // Top-level `const`/`let`/`var` declarations (column 0), including destructuring.
  // Matches the declarator list start; handles simple names and `{ a, b: c, ...rest }` /
  // `[a, b]` patterns across the (possibly multi-line) binding target.
  const lexRe = /^(?:const|let|var)\s+([\s\S]*?)(?:=|;|$)/gm;
  while ((m = lexRe.exec(source))) {
    const target = m[1];
    if (/^[A-Za-z_$][\w$]*\s*$/.test(target)) {
      // Simple `const NAME = ...` / `const NAME;`
      names.add(target.trim());
      continue;
    }
    if (/^[{[]/.test(target.trim())) {
      // Destructuring: pull out bound identifiers, ignoring object keys before ':'.
      // `{ letterFromTitle, colorForTitle }` -> both names.
      // `{ letterFromTitle: lft }` -> only `lft` (the actual binding).
      const bindingRe = /(?:^|[,{[]\s*)(?:\.\.\.)?([A-Za-z_$][\w$]*)\s*(?::\s*([A-Za-z_$][\w$]*))?/g;
      let bm;
      while ((bm = bindingRe.exec(target))) {
        const bound = bm[2] || bm[1];
        if (bound) names.add(bound);
      }
    }
  }

  return names;
}

const entryVisualsSource = fs.readFileSync(
  path.join(__dirname, '..', 'shared', 'entry-visuals.js'),
  'utf8'
);
const popupSource = fs.readFileSync(path.join(__dirname, '..', 'popup.js'), 'utf8');

const entryVisualsNames = topLevelDeclaredNames(entryVisualsSource);
const popupNames = topLevelDeclaredNames(popupSource);

assert.ok(entryVisualsNames.has('letterFromTitle'), 'sanity: parser sees entry-visuals.js top-level function letterFromTitle');
assert.ok(entryVisualsNames.has('colorForTitle'), 'sanity: parser sees entry-visuals.js top-level function colorForTitle');

const collisions = [...popupNames].filter((name) => entryVisualsNames.has(name));

assert.deepStrictEqual(
  collisions,
  [],
  `popup.js declares a top-level lexical/var name that collides with a top-level name ` +
    `entry-visuals.js already declares: ${collisions.join(', ')}. popup.html loads both as ` +
    `classic scripts sharing one global scope, so this is a load-time SyntaxError in the ` +
    `browser ("Identifier already been declared") that kills the whole popup before any ` +
    `statement of popup.js runs. Bind through a namespace object instead of destructuring ` +
    `these names at top level.`
);

console.log('scriptScopes.test.js: no global scope collisions OK');
