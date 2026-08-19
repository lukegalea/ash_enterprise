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
import { mkdirSync } from "node:fs";
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

async function shot(name, path, { wait = 1200, selector = null } = {}) {
  await page.goto(`${base}${path}`, { waitUntil: "networkidle" });
  await page.addStyleTag({ content: hideDevTooling });
  await page.waitForTimeout(wait);

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

await browser.close();

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
