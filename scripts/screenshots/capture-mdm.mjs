// Captures the MDM demo: import a CSV, review the AI-proposed mapping, run
// the batch, confirm the match in the steward queue, and shoot the golden
// surface with its merge lineage.
//
//   devenv shell -- mix phx.server            # backgrounded
//   devenv shell -- node scripts/screenshots/capture-mdm.mjs
//
// Must run inside `devenv shell` (Playwright + the devenv Postgres export,
// same reasoning as capture-live.mjs).
//
// Signs in as admin@example.com — the SEEDED tenant, which is the one that
// owns the MDM demo data (`mix ash_enterprise.demo` puts it there). The
// legacy capture script's admin@legacy.example trap does not apply here:
// signing in as the wrong tenant shows an empty steward queue, correctly.
//
// Produces:
//   docs/screenshots/mdm-import-mapping.png   the mapping step with the AI proposal
//   docs/screenshots/mdm-steward-queue.png    the side-by-side diff card
//   docs/screenshots/mdm-golden-lineage.png   the golden surface after the confirm
//
// Each run uploads fresh rows (one carries a timestamp suffix), so re-running
// leaves a new pending candidate instead of colliding with the demo seed's.

import { firefox } from "playwright";
import { mkdirSync, writeFileSync, rmSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const outDir = resolve(here, "../../docs/screenshots");
const workDir = resolve(here, "../../tmp/mdm-capture");
const base = process.env.BASE_URL || "http://localhost:4000";
// The seeded tenant's administrator — the tenant that owns the demo data.
const email = process.env.EMAIL || "admin@example.com";
const password = process.env.PASSWORD || "password1234";

mkdirSync(outDir, { recursive: true });
rmSync(workDir, { recursive: true, force: true });
mkdirSync(workDir, { recursive: true });

const failures = [];

const suffix = Date.now().toString(36);
// Deliberately no row matching the seeded Ann golden: the steward queue
// already holds the demo seed's pending candidate, and a second identical
// Ann candidate would photograph as a duplicated card. These rows are all
// genuinely new people — they become goldens of their own on the run.
const csv = [
  "Email,Full Name,Notes",
  `priya.${suffix}@x.io,Priya Shah,webinar signup`,
  `casey.${suffix}@x.io,Casey Reyes,uploaded by capture-mdm`,
].join("\n");

const csvPath = resolve(workDir, "upload.csv");
writeFileSync(csvPath, csv);

const browser = await firefox.launch();
const context = await browser.newContext({ viewport: { width: 1440, height: 1000 } });
const page = await context.newPage();

// Dev-only tooling has no place in a README screenshot (same reasoning as
// capture-live.mjs).
await context.route(/tidewave\.ai/, (route) => route.abort());
const hideDevTooling = `[id*="tidewave"], tidewave-toolbar, #tidewave-toolbar { display: none !important; }`;

await page.goto(`${base}/sign-in`, { waitUntil: "networkidle" });
// The form is a LiveView: fills before the socket joins are dropped, and a
// cold dev server's first render can take a while to connect.
await page.waitForSelector("[data-phx-main].phx-connected", { timeout: 30000 });
// The page also carries register and reset forms — scope to the sign-in one.
const signInForm = page.locator("#user-password-sign-in-with-password");
await signInForm.locator('input[type="email"]').fill(email);
await signInForm.locator('input[type="password"]').fill(password);
await signInForm.locator("button").first().click();
await page.waitForURL((u) => !u.pathname.includes("sign-in"), { timeout: 30000 });

// ── 1. upload → propose → the mapping step ────────────────────────────────

await page.goto(`${base}/app/mdm/import`, { waitUntil: "networkidle" });
await page.addStyleTag({ content: hideDevTooling });
// The LiveSocket joins after the dead render; input changes before the join
// are dropped, so wait for the connected view and the enabled button.
await page.waitForSelector("main .phx-connected, [data-phx-main].phx-connected", { timeout: 15000 });

await page.setInputFiles('input[type="file"]', csvPath);
await page.waitForSelector("#preview-btn:not([disabled])", { timeout: 15000 });
await page.click("#preview-btn");
await page.waitForSelector("#propose-btn", { timeout: 10000 });

await page.click("#propose-btn");
// The flash confirms the proposal loaded; the mapping table now carries it.
await page.waitForSelector("text=AI proposal loaded", { timeout: 10000 });
await page.waitForTimeout(600);
// The toast overlaps the nav; the shot is about the mapping table.
await page.evaluate(() =>
  document.querySelectorAll('[role="alert"], .alert').forEach((el) => el.remove())
);

await page.screenshot({ path: resolve(outDir, "mdm-import-mapping.png"), fullPage: true });
console.log("  mdm-import-mapping.png");

// ── 2. activate → run → the steward queue ─────────────────────────────────

await page.click("#validate-activate-btn");
await page.waitForSelector("text=Mapping activated", { timeout: 10000 });

await page.click("#run-batch-btn");
await page.waitForSelector("text=Import finished", { timeout: 60000 });
console.log("  import finished");

await page.goto(`${base}/app/mdm`, { waitUntil: "networkidle" });
await page.addStyleTag({ content: hideDevTooling });
await page.waitForSelector("#batch-progress, [id^='candidate-']", { timeout: 15000 });
await page.waitForTimeout(1200);
await page.evaluate(() =>
  document.querySelectorAll('[role="alert"], .alert').forEach((el) => el.remove())
);

if (!(await page.$("[id^='confirm-']"))) {
  failures.push("no pending candidate in the steward queue — the import did not band to review");
}

await page.screenshot({ path: resolve(outDir, "mdm-steward-queue.png"), fullPage: true });
console.log("  mdm-steward-queue.png");

// ── 3. confirm → the golden surface with lineage ───────────────────────────

await page.click("[id^='confirm-']");
await page.waitForSelector("text=Match confirmed", { timeout: 15000 });

await page.goto(`${base}/app/mdm/golden`, { waitUntil: "networkidle" });
await page.addStyleTag({ content: hideDevTooling });
await page.waitForTimeout(1500);

// The golden surface lists name + email only — merge lineage itself lives
// in the data (merged/master_id) and the steward diff, not on this table.
await page.screenshot({ path: resolve(outDir, "mdm-golden-lineage.png"), fullPage: true });
console.log("  mdm-golden-lineage.png");

await context.close();
await browser.close();

if (failures.length) {
  for (const failure of failures) console.error(`FAIL: ${failure}`);
  process.exit(1);
}

console.log("\nmdm demo captured");
