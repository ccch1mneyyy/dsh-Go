// Inventory package rows: status / error / unavailable (issue #32). No DSH needed.
//   node --test runtime/tests/bridge-inventory.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";

const { packageInventory, entryStatus, errorSummary, packageOf } =
  await import(new URL("../bridge/dsh-go-bridge/lib/inventory.js", import.meta.url));

const entry = (name, fiber, extra = {}) => ({ options: { name }, fiber, ...extra });
const failure = Object.assign(new Error("Cannot find module 'left-pad'\nRequire stack: ..."), {
  stack: "Error: Cannot find module 'left-pad'\n    at load (/root/.dsh/dsh-go/plugins/broken/lib/index.js:3:9)\n    at x (node:internal/x:1:1)",
});

test("entryStatus follows the loader entry and fiber state", () => {
  assert.equal(entryStatus(entry("a", { state: 2 })), "loaded");
  assert.equal(entryStatus(entry("a", { state: 3 })), "failed");
  assert.equal(entryStatus(entry("a", { state: 1 })), "inactive");
  assert.equal(entryStatus(entry("a", undefined)), "inactive");
  assert.equal(entryStatus(entry("a", { state: 2 }, { disabled: true })), "disabled");
  assert.equal(entryStatus(entry("a", {})), "loaded"); // fibers without a state keep the old meaning
});

test("errorSummary is the first line plus the first file location, bounded", () => {
  assert.equal(errorSummary(entry("a", { state: 3, error: failure })),
    "Cannot find module 'left-pad' (/root/.dsh/dsh-go/plugins/broken/lib/index.js:3:9)");
  assert.equal(errorSummary(entry("a", { state: 3, error: "boom\nmore" })), "boom");
  assert.equal(errorSummary(entry("a", { state: 3 })), undefined);
  assert.equal(errorSummary(entry("a", { state: 3, error: { nope: 1 } })), undefined);
  assert.ok(errorSummary(entry("a", { state: 3, error: "x".repeat(1000) })).length <= 300);
});

test("packages keeps its old membership and only gains status", () => {
  const graph = { entries: [{ id: "dsh-pet", rev: "p1" }] };
  const loader = [
    entry("dsh-pet/client", { state: 2 }),
    entry("@deepseek-ai/dsh-chat", { state: 2 }),
    entry("broken-demo", { state: 3, error: failure }),
    entry("off-plugin", { state: 2 }, { disabled: true }),
    entry("never-started", undefined),
    entry("./local/path", { state: 2 }),
  ];
  const { packages, unavailable } = packageInventory(() => loader, graph);
  assert.deepEqual(packages.map((p) => p.name), ["@deepseek-ai/dsh-chat", "broken-demo", "dsh-pet"]);
  assert.deepEqual(packages.find((p) => p.name === "dsh-pet"),
    { name: "dsh-pet", hasClient: true, rev: "p1", official: false, status: "loaded" });
  assert.deepEqual(packages.find((p) => p.name === "@deepseek-ai/dsh-chat"),
    { name: "@deepseek-ai/dsh-chat", hasClient: false, rev: null, official: true, status: "loaded" });
  const broken = packages.find((p) => p.name === "broken-demo");
  assert.equal(broken.status, "failed");
  assert.match(broken.error, /^Cannot find module 'left-pad' \(.*index\.js:3:9\)$/);
  assert.deepEqual(unavailable, [
    { name: "never-started", official: false, status: "inactive" },
    { name: "off-plugin", official: false, status: "disabled" },
  ]);
});

test("one package with several entries: any running entry keeps it in packages, failure wins", () => {
  const loader = [entry("multi", undefined), entry("multi/server", { state: 2 }), entry("multi/extra", { state: 3, error: "bad" })];
  const { packages, unavailable } = packageInventory(() => loader, null);
  assert.deepEqual(packages, [{ name: "multi", hasClient: false, rev: null, official: false, status: "failed", error: "bad" }]);
  assert.deepEqual(unavailable, []);
});

test("a throwing loader still returns the client graph and reports the error", () => {
  const seen = [];
  const { packages, unavailable } = packageInventory(() => { throw new Error("no loader"); }, { entries: [{ id: "a" }] }, (e) => seen.push(e.message));
  assert.deepEqual(packages.map((p) => [p.name, p.status]), [["a", "loaded"]]);
  assert.deepEqual(unavailable, []);
  assert.deepEqual(seen, ["no loader"]);
});

test("packageOf is unchanged", () => {
  assert.equal(packageOf("@scope/pkg/client"), "@scope/pkg");
  assert.equal(packageOf("pkg/client"), "pkg");
  assert.equal(packageOf("./x"), undefined);
  assert.equal(packageOf("@scope"), undefined);
});
