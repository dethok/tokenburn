// Headless self-check: stubs the Scriptable API, runs TokenBurn.js end-to-end
// against fake snapshot data (fresh, stale, missing, empty-codex), asserts
// Script.setWidget was reached each time. Run: node selftest.mjs
import { readFileSync } from "node:fs";
import assert from "node:assert";

const src = readFileSync(new URL("./TokenBurn.js", import.meta.url), "utf8");

function makeStubs(fileContent) {
  let setWidgetCalled = false;
  const el = () => ({
    font: null, textColor: null, size: null, cornerRadius: 0,
    backgroundColor: null, spacing: 0, backgroundGradient: null, imageSize: null,
    layoutVertically() {}, layoutHorizontally() {},
    centerAlignContent() {}, bottomAlignContent() {},
    setPadding() {},
    addStack() { return el(); },
    addText() { return el(); },
    addDate() { return el(); },
    addImage() { return el(); },
    addSpacer() { return el(); },
    applyTimerStyle() {},
    async presentMedium() {},
  });
  const stubs = {
    Color: Object.assign(class { constructor(hex, a) { this.hex = hex; this.a = a; } },
      { white: () => ({}) }),
    LinearGradient: class { },
    Size: class { constructor(w, h) { this.w = w; this.h = h; } },
    Font: { systemFont: () => ({}), boldSystemFont: () => ({}), mediumSystemFont: () => ({}), heavySystemFont: () => ({}) },
    ListWidget: class { constructor() { Object.assign(this, el()); } },
    FileManager: {
      iCloud: () => ({
        documentsDirectory: () => "/icloud",
        joinPath: (a, b) => `${a}/${b}`,
        fileExists: () => fileContent !== null,
        downloadFileFromiCloud: async () => {
          if (fileContent === null) throw new Error("no such file");
        },
        readString: () => fileContent,
        listContents: () => (fileContent !== null ? ["tokenburn-status.json"] : []),
      }),
    },
    config: { widgetFamily: "medium", runsInApp: false },
    Script: { setWidget: () => { setWidgetCalled = true; }, complete: () => {} },
    Point: class { constructor(x, y) { this.x = x; this.y = y; } },
    Rect: class { constructor(x, y, w, h) { Object.assign(this, { x, y, w, h }); } },
    Path: class { addLines() {} addRoundedRect() {} },
    DateFormatter: class { string(d) { return d.toISOString().slice(11, 16); } },
    DrawContext: class {
      constructor() { this.size = null; this.opaque = true; this.respectScreenScale = false; }
      setLineWidth() {} setStrokeColor() {} strokeEllipse() {}
      setFont() {} setTextColor() {} setTextAlignedCenter() {} setTextAlignedLeft() {}
      setFillColor() {} fillPath() {} fillRect() {}
      drawTextInRect() {} addPath() {} strokePath() {}
      getImage() { return {}; }
    },
  };
  return { stubs, wasSet: () => setWidgetCalled };
}

async function run(fileContent, family) {
  const { stubs, wasSet } = makeStubs(fileContent);
  stubs.config.widgetFamily = family;
  const fn = new Function(...Object.keys(stubs), `return (async () => { ${src} })()`);
  await fn(...Object.values(stubs));
  return wasSet();
}

const now = Date.now();
const samples = Array.from({ length: 60 }, (_, i) => ({
  ts: new Date(now - (60 - i) * 5 * 60 * 1000).toISOString(),
  sessionPct: Math.min(100, i * 1.5),
  weeklyPct: 40,
}));
const fresh = JSON.stringify({
  generatedAt: new Date(now - 2 * 60 * 1000).toISOString(),
  claudePlan: "max 20x",
  claude: [
    { id: "session", label: "Session (5h)", usedPct: 9, resetsAt: new Date(now + 3 * 3600e3).toISOString() },
    { id: "weekly_all", label: "Weekly · all models", usedPct: 61, resetsAt: new Date(now + 2 * 86400e3).toISOString() },
    { id: "weekly_scoped:Fable", label: "Weekly · Fable", usedPct: 59, resetsAt: new Date(now + 2 * 86400e3).toISOString() },
  ],
  codex: [{ id: "Weekly", label: "Weekly", usedPct: 4, resetsAt: new Date(now + 6 * 86400e3).toISOString() }],
  costTodayUSD: { claude: 12.34, codex: 1.2 },
  samples,
});
const stale = JSON.stringify({ ...JSON.parse(fresh), generatedAt: new Date(now - 3 * 3600e3).toISOString() });
const bare = JSON.stringify({ generatedAt: new Date().toISOString(), claude: [], codex: [], samples: [] });

assert.ok(await run(fresh, "medium"), "medium/fresh renders");
assert.ok(await run(fresh, "small"), "small/fresh renders");
assert.ok(await run(stale, "medium"), "stale renders");
assert.ok(await run(bare, "medium"), "empty windows renders");
assert.ok(await run(null, "medium"), "missing file → setup widget");
assert.ok(await run("not json{", "medium"), "corrupt file → setup widget");
console.log("selftest: 6/6 OK");
