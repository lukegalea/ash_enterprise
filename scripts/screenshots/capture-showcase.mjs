// Captures the credentialing tour (/app/showcase/credentialing) and the records its index links
// to, on a server whose demo tenant was seeded with its history:
//
//   mix ash_enterprise.demo --history --password-file PATH      # once, on the server's database
//   node scripts/screenshots/capture-showcase.mjs --base-url URL --password-file PATH [--out DIR]
//
// Headless. It signs in as the demo's personas with the password in PATH, which it reads and
// never prints. It writes PNGs to DIR (default tmp/showcase-capture, which git ignores); the
// walkthrough (docs/showcase/credentialing-walkthrough.md) names the files its image slots take.
// Nothing here writes to docs/.
//
// A capture is only worth publishing if it shows the real thing, so every page is checked, and
// the script exits non-zero, naming each failure, when a page:
//
//   * shows a "demo build only" note, i.e. a beat with nothing on record;
//   * shows an empty table, a "None yet." where the history should have left a record, an index
//     failure the history covers with no record, or an empty explorer trace;
//   * shows an error: an HTTP status of 400 or more, an error flash, a "not found" landing, or
//     the LiveView's client or server error banner;
//   * shows any tenant but the demo's ("Riverside Demo") in its context band, anyone but a demo
//     persona as the person signed in, or the address of anyone who is not a demo persona.
//
// Run it only against a server you started yourself, on a database you seeded yourself.

import { chromium } from "playwright";
import { mkdirSync, readFileSync } from "node:fs";
import { resolve } from "node:path";
import { parseArgs } from "node:util";

const { values: args } = parseArgs({
  options: {
    "base-url": { type: "string" },
    "password-file": { type: "string" },
    out: { type: "string", default: "tmp/showcase-capture" },
  },
});

if (!args["base-url"] || !args["password-file"]) {
  console.error(
    "usage: capture-showcase.mjs --base-url URL --password-file PATH [--out DIR]",
  );
  process.exit(2);
}

const base = args["base-url"].replace(/\/$/, "");
const outDir = resolve(args.out);
// Read once, kept in this variable only: never logged, never put in a file name or an error.
const password = readFileSync(args["password-file"], "utf8").trim();

if (password === "") {
  console.error(`the password file is empty: ${args["password-file"]}`);
  process.exit(2);
}

// The demo tenant and its people (AshEnterprise.Platform.DemoTenant, Platform.DemoData,
// Credentialing.DemoData, Credentialing.LicenceDemoData). Anyone else on a page is a leak.
const TENANT = "Riverside Demo";
const PERSONAS = new Set([
  "demo-admin@example.com",
  "rosa@example.com",
  "kenji@example.com",
  "amaka@example.com",
  "ines@example.com",
  "omar@example.com",
  "dana@example.com",
  "ravi@example.com",
  "mei@example.com",
  "tomasz@example.com",
  "aisha@example.com",
  "jonas@example.com",
  "priya@example.com",
  "soren@example.com",
  "beatriz@example.com",
]);

const COORDINATOR = "rosa@example.com";
const ADMIN = "demo-admin@example.com";

// The failures the history records (AshEnterprise.Showcase.History), and the beats they are on.
const RECORDED = ["F1", "F2", "F3", "F4", "F5", "F6", "F7", "F10"];
const HISTORY_BEATS = [
  "beat-stale",
  "beat-revoked",
  "beat-reconciled",
  "beat-timeout",
  "beat-checks",
  "beat-webhook",
  "beat-routing",
  "beat-deploy",
];

const failures = [];
const fail = (where, what) => failures.push(`${where}: ${what}`);

mkdirSync(outDir, { recursive: true });

const browser = await chromium.launch({ headless: true });

async function session(email) {
  const context = await browser.newContext({
    viewport: { width: 1440, height: 900 },
    deviceScaleFactor: 2,
  });
  await context.route(/tidewave\.ai/, (route) => route.abort());
  const page = await context.newPage();

  await page.goto(`${base}/sign-in`, { waitUntil: "networkidle" });
  await page.locator(".phx-connected").first().waitFor({ timeout: 15000 });
  await page.fill('input[type="email"]', email);
  await page.fill('input[type="password"]', password);
  await page.click('button[type="submit"]');

  try {
    await page.waitForURL((u) => !u.pathname.includes("sign-in"), { timeout: 15000 });
  } catch {
    fail(email, "could not sign in (wrong password file, or the persona is not seeded)");
  }

  return { context, page, email };
}

// Opens `path` and checks it; returns the page for further checks, or null when it failed.
async function open({ page, email }, path) {
  const response = await page.goto(`${base}${path}`, { waitUntil: "networkidle" });
  const where = `${email} ${path}`;

  if (!response || response.status() >= 400) {
    fail(where, `HTTP ${response ? response.status() : "no response"}`);
    return null;
  }

  await page.locator(".phx-connected").first().waitFor({ timeout: 15000 }).catch(() => {
    fail(where, "the LiveView never connected");
  });
  await page.addStyleTag({
    content: `[id*="tidewave"], tidewave-toolbar { display: none !important; }`,
  });
  await page.waitForTimeout(500);

  await checkPage(page, where, email);
  return page;
}

async function visible(page, selector) {
  const all = page.locator(selector);
  const n = await all.count();
  for (let i = 0; i < n; i++) if (await all.nth(i).isVisible()) return true;
  return false;
}

async function checkPage(page, where, email) {
  const url = new URL(page.url());
  if (url.pathname === "/app" && (await visible(page, "#flash-error"))) {
    fail(where, "landed on the launcher with an error (not found, or not yours)");
  }

  if (await visible(page, "#flash-error")) fail(where, "shows an error flash");
  if (await visible(page, "#client-error")) fail(where, "shows the client error banner");
  if (await visible(page, "#server-error")) fail(where, "shows the server error banner");

  const text = await page.locator("body").innerText();

  if (/demo build only/i.test(text) || (await visible(page, ".demo-build-note"))) {
    fail(where, 'shows a "demo build only" note');
  }

  // Tables: a table with a body and no rows is an empty table.
  const tables = page.locator("table");
  for (let i = 0; i < (await tables.count()); i++) {
    const table = tables.nth(i);
    if ((await table.isVisible()) && (await table.locator("tbody").count()) > 0) {
      if ((await table.locator("tbody tr").count()) === 0) {
        fail(where, `shows an empty table (${(await table.getAttribute("id")) || `table ${i + 1}`})`);
      }
    }
  }

  // M10: the demo tenant, a demo persona, and nobody else's address.
  const tenant = page.locator("#context-tenant");
  if ((await tenant.count()) === 0) {
    fail(where, "has no context band");
  } else {
    const state = await tenant.getAttribute("data-tenant");
    const name = (await tenant.locator("dd").innerText()).trim();
    if (state !== "named" || name !== TENANT) fail(where, `tenant is "${name}" (${state}), not ${TENANT}`);

    const identity = (await page.locator("#context-identity dd").innerText()).trim();
    if (identity !== email || !PERSONAS.has(identity)) {
      fail(where, `signed in as "${identity}", not the demo persona ${email}`);
    }
  }

  const strangers = [...new Set(text.match(/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/g) || [])]
    .map((address) => address.toLowerCase())
    .filter((address) => !PERSONAS.has(address));
  if (strangers.length > 0) fail(where, `shows addresses outside the demo: ${strangers.join(", ")}`);
}

async function shot(page, name, selector) {
  const path = resolve(outDir, name);
  if (selector) await page.locator(selector).screenshot({ path });
  else await page.screenshot({ path, fullPage: true });
  console.log(`  ${name}`);
}

async function href(page, selector) {
  const link = page.locator(selector);
  return (await link.count()) === 1 ? link.getAttribute("href") : null;
}

// ── The tour, as the coordinator ───────────────────────────────────────────────
const coordinator = await session(COORDINATOR);
const tour = await open(coordinator, "/app/showcase/credentialing");
const links = {};

if (tour) {
  for (const failure of RECORDED) {
    const recorded = await tour.locator(`#index-${failure}`).getAttribute("data-recorded");
    if (recorded !== "true") fail(`tour index ${failure}`, "has no record: seed the history first");
    links[failure] = await href(tour, `#index-${failure}-explore`);
  }

  for (const beat of HISTORY_BEATS) {
    const card = tour.locator(`#${beat}`);
    if ((await card.count()) === 0) {
      fail(`tour #${beat}`, "is not on the page");
      continue;
    }
    if (await visible(tour, `#${beat} [id$="-none"]`)) fail(`tour #${beat}`, 'shows "None yet." or nothing to open');
  }

  await shot(tour, "tour-index.png", "#tour-index");
  for (const beat of HISTORY_BEATS) await shot(tour, `tour-${beat}.png`, `#${beat}`);
  links.recovery = await href(tour, '#beat-reconciled a[id^="reconciled-recover-"]');
}

// ── Each recorded failure in the explorer ──────────────────────────────────────
for (const failure of RECORDED) {
  if (!links[failure]) continue;
  const page = await open(coordinator, links[failure]);
  if (!page) continue;

  if (await visible(page, "#timeline-empty")) fail(`explorer ${failure}`, "the trace is empty");
  if ((await page.locator('[id^="entry-"]').count()) === 0) fail(`explorer ${failure}`, "no entries");
  await shot(page, `explorer-${failure}.png`);
}

await coordinator.context.close();

// ── The request whose outcome is unknown, on the recovery surface ──────────────
if (links.recovery) {
  const admin = await session(ADMIN);
  const page = await open(admin, links.recovery);
  if (page) {
    const status = await page.locator("#status").getAttribute("data-status").catch(() => null);
    if (status !== "uncertain") fail("recovery", `status is ${status}, not uncertain`);
    await shot(page, "recovery-F2.png");
  }
  await admin.context.close();
} else {
  fail("tour #beat-reconciled", "has no request to settle on the recovery surface");
}

await browser.close();

if (failures.length > 0) {
  console.error(`\n${failures.length} capture check(s) failed:`);
  for (const failure of failures) console.error(`  - ${failure}`);
  process.exit(1);
}

console.log(`\nAll captures checked, in ${outDir}`);
