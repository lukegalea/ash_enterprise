// Captures the screenshots in docs/screenshots/, and fails if the browser console complains.
//
//   devenv shell -- mix ash_enterprise.bpmn.setup
//   devenv shell -- mix phx.server            # backgrounded; see docs/README.md
//   node scripts/screenshots/capture.mjs
//
// Two things this does beyond taking pictures, both deliberate:
//
// 1. **It signs in.** Every surface here is behind `live_user_required`, unlike the ash_bpmn
//    demo app this is adapted from, which has no auth at all.
//
// 2. **It watches the console and exits non-zero on a CSP violation.** Predicting a policy
//    from its directives is verifying the part; loading the page and reading what the browser
//    says is verifying the outcome. A violation that only breaks an editor's icons would
//    otherwise ship straight into a marketing capture.
//
// Browser: Firefox by default. `docs/README.md` records that Chromium could not rasterize in
// the sandbox these were first captured in; override with BROWSER=chromium if yours can.

import { chromium, firefox } from "playwright";
import { mkdirSync, readFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const outDir = resolve(here, "../../docs/screenshots");
const base = process.env.BASE_URL || "http://localhost:4000";
const email = process.env.EMAIL || "admin@example.com";
const password = process.env.PASSWORD || "password1234";
const engine = (process.env.BROWSER || "firefox") === "chromium" ? chromium : firefox;

mkdirSync(outDir, { recursive: true });

const violations = [];
const failures = [];
const browser = await engine.launch();
const page = await browser.newPage({
  viewport: { width: 1440, height: 900 },
  deviceScaleFactor: 2,
});

page.on("console", (m) => {
  if (m.type() !== "error") return;
  const text = m.text();
  // Content-Security-Policy refusals name the directive; that is what makes them worth
  // failing on rather than logging.
  if (/Content.Security.Policy|Refused to/i.test(text)) violations.push(text);
  else console.warn("  console error:", text.slice(0, 200));
});

async function signIn() {
  await page.goto(`${base}/sign-in`, { waitUntil: "networkidle" });
  await page.fill('input[type="email"]', email);
  await page.fill('input[type="password"]', password);
  await page.click('button[type="submit"]');
  await page.waitForURL((u) => !u.pathname.includes("sign-in"), { timeout: 15000 });
}

// Tidewave injects a floating toolbar in :dev. It is developer tooling that does not exist in
// a release, so leaving it in a documentation capture would show readers something they will
// never have. Hidden rather than disabled, so the app under capture is otherwise untouched.
const hideDevTooling = `
  [id*="tidewave"], tidewave-toolbar, #tidewave-toolbar { display: none !important; }
`;

// Every capture is wrapped: a step that throws costs its own screenshot and is recorded as a
// failure, rather than aborting the run and silently leaving every later shot at whatever the
// last commit produced. A half-finished capture that exits 0 is the failure mode this script
// exists to prevent.
async function shot(name, path, opts = {}) {
  try {
    await doShot(name, path, opts);
  } catch (err) {
    failures.push(`${name} (${path}): ${err.message.split("\n")[0]}`);
    console.error(`  ${name}  THREW: ${err.message.split("\n")[0]}`);
  }
}

async function doShot(name, path, { wait = 1200, selector = null, before = null } = {}) {
  await page.goto(`${base}${path}`, { waitUntil: "networkidle" });
  await page.addStyleTag({ content: hideDevTooling });
  await page.waitForTimeout(wait);

  // Interaction that has to happen after the page settles but before the shutter: selecting a
  // node, switching a tab, zooming out from under an overlay.
  if (before) await before();

  if (selector) {
    try {
      await page.waitForSelector(selector, { timeout: 8000 });
    } catch {
      console.warn(`  ${name}: ${selector} never appeared -- capturing anyway`);
    }
  }

  // A Phoenix error page screenshots perfectly happily, which is how a crashing task list got
  // captured and filed as a documentation image. A capture script that cannot tell a working
  // page from a stacktrace is worse than none: it produces confident-looking evidence of
  // something that does not work.
  const broken = await page.evaluate(() => {
    const body = document.body?.innerText || "";
    return (
      /\bat GET \//.test(body) ||
      /Internal Server Error/i.test(body) ||
      /Something went wrong/i.test(body) ||
      document.title.includes("Error")
    );
  });

  if (broken) {
    failures.push(`${name} (${path}) rendered an error page`);
    console.error(`  ${name}  ERROR PAGE`);
  } else {
    console.log(`  ${name}`);
  }

  await page.screenshot({ path: resolve(outDir, name), fullPage: false });
}

console.log(`signing in as ${email}`);
await signIn();

console.log("capturing:");
await shot("bpmn-task-list.png", "/app/tasks");
await shot("bpmn-process-catalog.png", "/app/processes");
await shot("bpmn-decision-catalog.png", "/app/decisions");
await shot("bpmn-trigger-list.png", "/app/triggers");

// The designer needs bpmn-js to boot and lay the diagram out; `.bjs-powered-by` is both the
// signal that it did and the bpmn.io watermark the licence requires stay visible. If it is
// missing the capture is worthless *and* non-compliant.
await shot("bpmn-designer.png", "/app/processes/access_request.grant/designer", {
  wait: 3000,
  selector: ".bjs-powered-by",
});

// The designer with a user task selected, so the properties panel has content: candidates,
// maker-checker exclusions, outcomes, timers. `ManagerApproval` rather than a start event
// because it is the node with something to say.
//
// bpmn-js fits the diagram edge to edge, which slides the leftmost element under the palette
// overlay -- hence the zoom-out before clicking anything. Selecting by the element's label
// rather than by position, for the same reason the ash_bpmn script does: a layout change
// must not silently reframe the capture on a different node.
await shot("bpmn-designer-user-task.png", "/app/processes/access_request.grant/designer", {
  wait: 3000,
  selector: ".bjs-powered-by",
  before: async () => {
    await page.evaluate(() => {
      document.querySelector('[title="Zoom out"], .bjs-zoom-out')?.click();
    });
    const node = page.locator('.djs-element[data-element-id="ManagerApproval"]').first();

    if (await node.count()) {
      // Offset from the centre on purpose. `Flow_mgr_rejected` runs vertically through
      // x=730, which is exactly the centre of a task box spanning 670..790 -- so a plain
      // centre click is intercepted by the flow's hit stroke and Playwright retries until it
      // times out. `force: true` would not help: the flow is genuinely the topmost element
      // there. Clicking the box's upper-left instead lands on the task.
      await node.click({ position: { x: 20, y: 15 } });
      await page.waitForTimeout(600);
    } else {
      console.warn("  bpmn-designer-user-task: ManagerApproval node not found");
    }
  },
});

// A running instance, with tokens on the diagram. Reached by clicking through from the
// catalogue rather than by a hardcoded id: the id changes every seed, and a capture script
// that needs one edited by hand is a capture script nobody re-runs.
await page.goto(`${base}/app/processes`, { waitUntil: "networkidle" });
const viewLink = page.locator("#instances-table a", { hasText: "View tokens" }).first();

if (await viewLink.count()) {
  const href = await viewLink.getAttribute("href");
  await shot("bpmn-viewer-running.png", href, {
    wait: 3000,
    selector: ".bjs-powered-by",
  });
} else {
  failures.push("bpmn-viewer-running.png: no running instance on /app/processes");
  console.error("  bpmn-viewer-running.png  NO RUNNING INSTANCE");
}

// The DMN editor. `access_request.risk` has to be *customized* in this tenant for the editor
// to open on it, which is the point of the fork-before-edit rule -- so click Customize if the
// row is still a baseline. dmn-js opens the decision-table view for a single-decision
// document, so this is the table shot; the DRD is one tab away.
await page.goto(`${base}/app/decisions`, { waitUntil: "networkidle" });
const customize = page
  .locator('#catalog-access_request\\.risk button', { hasText: "Customize" })
  .first();

if (await customize.count()) {
  await customize.click();
  await page.waitForURL((u) => u.pathname.includes("/editor"), { timeout: 15000 });
}

// The decision table is NOT the default view. dmn-js opens views[0], which is the DRD
// whenever the document carries DMNDI -- and this one now does. Before the layout was added
// there was no DRD view to open, dmn-js fell through to the decision table, and this shot
// happened to be right by accident.
//
// It stopped being right silently: the table capture became a byte-identical copy of the DRD
// capture, and two identical files were a hand-width away from shipping as two different
// figures on the marketing site. So the tab is clicked explicitly, and the two shots are
// checked for being distinct at the end of this script.
await shot("dmn-decision-table.png", "/app/decisions/access_request.risk/editor", {
  wait: 3500,
  before: async () => {
    const tab = page.locator("#decision-views button", { hasText: "Decision table" }).first();
    if (await tab.count()) {
      await tab.click();
      await page.waitForTimeout(2000);
    } else {
      throw new Error("no Decision table tab -- dmn-js reported no decision-table view");
    }
  },
});

// The requirements diagram, from the same document. The tabs are server-rendered -- dmn-js
// ships no view switcher -- so this is a click on our own button, not on the editor's.
await page.goto(`${base}/app/decisions/access_request.risk/editor`, {
  waitUntil: "networkidle",
});
await page.waitForTimeout(3000);
const drdTab = page.locator("#decision-views button", { hasText: "Requirements" }).first();

if (await drdTab.count()) {
  await drdTab.click();
  await page.waitForTimeout(2000);
  await page.addStyleTag({ content: hideDevTooling });
  await page.screenshot({ path: resolve(outDir, "dmn-drd.png"), fullPage: false });
  console.log("  dmn-drd.png");
} else {
  failures.push("dmn-drd.png: no Requirements tab -- dmn-js reported no views");
  console.error("  dmn-drd.png  NO VIEWS");
}

await browser.close();

// Two captures that are byte-identical mean one of them photographed the wrong thing. This
// has happened once already -- see the note above the decision-table shot -- and it is the
// kind of mistake that survives review, because both files exist and both look fine on their
// own.
const distinctPairs = [["dmn-decision-table.png", "dmn-drd.png"]];

for (const [a, bName] of distinctPairs) {
  try {
    const [ha, hb] = [a, bName].map((n) =>
      createHash("sha256").update(readFileSync(resolve(outDir, n))).digest("hex"),
    );
    if (ha === hb) failures.push(`${a} and ${bName} are byte-identical -- one is the wrong view`);
  } catch (err) {
    failures.push(`could not compare ${a} and ${bName}: ${err.message}`);
  }
}

if (failures.length) {
  console.error(`\n${failures.length} page(s) failed to render:`);
  for (const f of failures) console.error("  " + f);
}

if (violations.length) {
  console.error(`\n${violations.length} Content-Security-Policy violation(s):`);
  for (const v of violations) console.error("  " + v);
}

if (failures.length || violations.length) process.exit(1);

console.log("\nall pages rendered, no CSP violations");
