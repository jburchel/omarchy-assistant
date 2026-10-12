// Run: node tests/model.test.js
const fs = require("fs");
const path = require("path");
const assert = require("assert");
const src = fs.readFileSync(path.join(__dirname, "..", "Model.js"), "utf8").replace(/^\.pragma library\s*/, "");
const module_ = { exports: {} };
new Function("module", src)(module_);
const M = module_.exports;
let n = 0;
function test(name, fn) { fn(); n++; }

test("defaults: ask before taking a key, pick the backend automatically", () => {
  assert.deepStrictEqual(M.normalize({}), { keybinding: "ask", backend: "auto" });
  assert.deepStrictEqual(M.normalize({ keybinding: "yes", backend: "gpt" }), { keybinding: "ask", backend: "auto" });
  assert.deepStrictEqual(M.normalize({ keybinding: "on", backend: "codex" }), { keybinding: "on", backend: "codex" });
});

test("SUPER+ALT+A: someone else's binding counts as taken, ours doesn't", () => {
  const theirs = [{ modmask: 72, key: "A", description: "Grok" }];
  const ours = [{ modmask: 72, key: "a", description: "Omarchy Assistant" }];
  assert.strictEqual(M.keyTaken(theirs), true);
  assert.strictEqual(M.keyTaken(ours), false);
  assert.strictEqual(M.keyRegistered(ours), true);
  assert.strictEqual(M.keyTaken([{ modmask: 64, key: "A", description: "Exposé" }]), false, "SUPER+A alone is a different key");
  assert.strictEqual(M.keyTaken([]), false);
});

test("settings are read from the bar entry the shell writes", () => {
  const cfg = { bar: { layout: { right: [{ id: "io.github.jburchel.omarchy-assistant", keybinding: "on" }] } } };
  assert.strictEqual(M.normalize(M.entryFromConfig(cfg, "io.github.jburchel.omarchy-assistant")).keybinding, "on");
});

test("diff lines are classified for colouring", () => {
  assert.strictEqual(M.diffKind("+++ a"), "skip");
  assert.strictEqual(M.diffKind("--- a"), "skip");
  assert.strictEqual(M.diffKind("@@ -1 +1 @@"), "hunk");
  assert.strictEqual(M.diffKind("+gaps_in = 2"), "add");
  assert.strictEqual(M.diffKind("-gaps_in = 5"), "del");
  assert.strictEqual(M.diffKind(" context"), "ctx");
});

console.log(`model: ${n} tests passed`);
