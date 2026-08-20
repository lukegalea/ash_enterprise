// Captures the projection demo: a plain SQL INSERT into the legacy table, and the surface over
// this application's OWN table updating without a reload.
//
//   devenv shell -- mix phx.server            # backgrounded
//   devenv shell -- node scripts/screenshots/capture-live.mjs
//
// Must run inside `devenv shell`, because it shells out to `psql` and needs $PGPORT — devenv
// shifts the port when 5432 is taken, so hardcoding it produces a connection refused on some
// machines and, worse, a connection to somebody else's Postgres on others.
//
// The INSERT is deliberately made by `psql` and not through the application. A demo where the
// application writes its own row and then notices proves nothing: the whole claim is that a
// process which has never heard of Ash can write, and this UI updates.
//
// Produces:
//   docs/screenshots/directory-projected.png     the surface, steady state
//   docs/screenshots/directory-live-update.png   the same surface moments after the INSERT
//   docs/screenshots/directory-live-update.gif   the two seconds around it
//
// The GIF is ffmpeg over Playwright's webm; Playwright cannot emit GIF directly. The palette
// pass is not decoration — without it the banner's amber washes out to grey in 256 colours,
// which loses the only thing the frame is there to show.

import { firefox } from "playwright";
import { execFileSync } from "node:child_process";
import { mkdirSync, rmSync, readdirSync } from "node:fs";
import { dirname, resolve, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const outDir = resolve(here, "../../docs/screenshots");
const videoDir = resolve(here, "../../tmp/live-capture");
const base = process.env.BASE_URL || "http://localhost:4000";
// The LEGACY estate's administrator, not `admin@example.com`.
//
// This is not a detail. The legacy rows belong to the `legacy` organization, and both surfaces
// are tenant-scoped like every other resource here, so the example tenant's admin sees an empty
// table on `/app/legacy-users` and `/app/directory` alike -- correctly, and confusingly, since
// an empty table looks exactly like a broken projection. Signing in as the tenant that owns the
// data is what makes the capture show anything at all.
const email = process.env.EMAIL || "admin@legacy.example";
const password = process.env.PASSWORD || "password1234";
const pgPort = process.env.PGPORT;
const database = process.env.PGDATABASE || "ash_enterprise_dev";

if (!pgPort) {
  console.error("PGPORT is not set. Run this inside `devenv shell` -- see the header comment.");
  process.exit(1);
}

mkdirSync(outDir, { recursive: true });
rmSync(videoDir, { recursive: true, force: true });
mkdirSync(videoDir, { recursive: true });

const failures = [];

function insertLegacyUser(login) {
  // A row the legacy application would write: integer key, first_name/last_name, its own state
  // machine's vocabulary. Nothing here mentions uuids, tenants or lifecycle statuses.
  const sql = `
    INSERT INTO legacy.users
      (login, email, first_name, last_name, crypted_password, salt, state, company_id,
       created_at, updated_at)
    VALUES
      ('${login}', '${login}@corp.example', 'Ngozi', 'Okafor', 'deadbeef', 'aa11bb',
       'active', 1, now(), now())
    RETURNING id;
  `;

  return execFileSync("psql", ["-p", pgPort, "-U", "postgres", "-d", database, "-Atc", sql], {
    encoding: "utf8",
    env: { ...process.env, PGPASSWORD: process.env.PGPASSWORD || "postgres" },
  }).trim();
}

function psql(sql) {
  return execFileSync("psql", ["-p", pgPort, "-U", "postgres", "-d", database, "-Atc", sql], {
    encoding: "utf8",
    env: { ...process.env, PGPASSWORD: process.env.PGPASSWORD || "postgres" },
  }).trim();
}

const countProjected = () => Number(psql("SELECT count(*) FROM projected_users"));
const projectedLogins = () => psql("SELECT login FROM projected_users");

// Remove the rows earlier runs of THIS script left behind, from both sides.
//
// Every run inserts a user, and nothing was cleaning up: by the fourth run the demo showed three
// Ngozi Okafors stacked above the seeded people, which reads as a projection duplicating rows
// rather than as a script without a teardown.
//
// Deleted from `legacy.users` first and deliberately: that is a real legacy DELETE, so it
// exercises the projector's destroy path and removes the projected row the same way a legacy
// application would. The second statement is the belt-and-braces for a run where the listener
// was not up.
function cleanPreviousRuns() {
  psql("DELETE FROM legacy.users WHERE login LIKE 'n.okafor.%'");
  psql("DELETE FROM projected_users WHERE login LIKE 'n.okafor.%'");
}

const browser = await firefox.launch();
const context = await browser.newContext({
  viewport: { width: 1440, height: 900 },
  deviceScaleFactor: 2,
  recordVideo: { dir: videoDir, size: { width: 1440, height: 900 } },
});
const page = await context.newPage();

// Block the dev-only Tidewave toolbar's requests outright, rather than only hiding the element.
//
// Hiding it with CSS is enough for a still. It is not enough for a video: Firefox paints
// "Transferring data from tidewave.ai..." into the bottom-left of the viewport while the request
// is in flight, and that lands in the recording as a caption on a marketing GIF. The toolbar is
// developer tooling that does not exist in a release, so nothing here needs it.
await context.route(/tidewave\.ai/, (route) => route.abort());

const hideDevTooling = `[id*="tidewave"], tidewave-toolbar, #tidewave-toolbar { display: none !important; }`;

cleanPreviousRuns();

await page.goto(`${base}/sign-in`, { waitUntil: "networkidle" });
await page.fill('input[type="email"]', email);
await page.fill('input[type="password"]', password);
await page.click('button[type="submit"]');
await page.waitForURL((u) => !u.pathname.includes("sign-in"), { timeout: 15000 });

// The legacy read model first, so the *last* thing on screen before the INSERT is the surface
// the GIF is about. Captured in the other order at first, and the six-second window then opened
// on a half-loaded page navigating back -- a demo whose first frame is blank.
await page.goto(`${base}/app/legacy-users`, { waitUntil: "networkidle" });
await page.addStyleTag({ content: hideDevTooling });
await page.waitForTimeout(2500);
await page.screenshot({ path: resolve(outDir, "legacy-read-model.png"), fullPage: false });
console.log("  legacy-read-model.png");

await page.goto(`${base}/app/directory`, { waitUntil: "networkidle" });
await page.addStyleTag({ content: hideDevTooling });
await page.waitForTimeout(2500);

// A surface with no rows would make the "after" frame indistinguishable from a first load, so
// this is checked rather than hoped for -- in the database, not the DOM.
//
// The DOM is not available to check: A2UI's components render into shadow roots, so
// `innerText` on the surface returns the page chrome and nothing else, and a traversal that
// walks `shadowRoot` does not reach them either. An earlier version of this script asserted on
// that text and reported "looks empty" for a page rendering nine rows perfectly well.
if (countProjected() === 0) {
  failures.push("projected_users is empty -- run `mix ash_enterprise.legacy.project` first");
}

await page.screenshot({ path: resolve(outDir, "directory-projected.png"), fullPage: false });
console.log("  directory-projected.png");

// Settled, and deliberately longer than it needs to be. The GIF is the last six seconds of the
// recording, so this pause is what puts a populated table in its opening frames instead of a
// page still loading.
await page.waitForTimeout(3500);

const login = `n.okafor.${Date.now().toString(36)}`;
const legacyId = insertLegacyUser(login);
console.log(`  INSERT INTO legacy.users -> id ${legacyId}`);

// The banner is raised on the renderer's debounced refresh, so it cannot appear instantly. Wait
// for the element rather than for a duration: a fixed sleep either races the debounce or
// outlasts the six-second fade, and both produce a frame with nothing in it.
try {
  await page.waitForSelector('[id^="projected-cue-"]', { timeout: 20000 });
} catch {
  failures.push("no cue banner appeared -- the projection or the pubsub chain is broken");
}

await page.waitForTimeout(800);
await page.screenshot({ path: resolve(outDir, "directory-live-update.png"), fullPage: false });
console.log("  directory-live-update.png");

// Verified, not just photographed. A screenshot of a banner proves a banner fired; this proves
// the row actually arrived in the table the surface reads.
if (!projectedLogins().includes(login)) {
  failures.push(`${login} reached legacy.users but never reached projected_users`);
}

await page.waitForTimeout(1200);
await context.close();
await browser.close();

// ── GIF ────────────────────────────────────────────────────────────────────────
const webm = readdirSync(videoDir).find((f) => f.endsWith(".webm"));

if (webm) {
  const input = join(videoDir, webm);
  const palette = join(videoDir, "palette.png");
  const gif = resolve(outDir, "directory-live-update.gif");

  // Matched to `legacy-live-update.gif`'s budget: 1000px wide, 6 seconds, 5fps, ~80kB. The
  // first version was 16 seconds and 2.1MB, because Playwright records a context for its whole
  // life and that includes signing in and navigating -- fourteen seconds of nothing happening,
  // at 25x the file size of the frames that matter.
  //
  // `-sseof -6` takes the last six seconds rather than seeking from the start: the INSERT is the
  // last thing the script does, and an offset measured from the beginning would move every time
  // sign-in took a moment longer.
  const filters = "fps=5,scale=1000:-1:flags=lanczos";
  const trim = ["-sseof", "-6"];

  try {
    // 64 colours, not the default 256. This is a flat UI -- a handful of greys, one amber, one
    // orange -- so the extra 192 entries buy nothing and cost most of the file. Bayer dithering
    // rather than the default error-diffusion for the same reason: diffusion invents per-frame
    // noise in large flat areas, and noise is exactly what a GIF cannot compress.
    execFileSync(
      "ffmpeg",
      ["-y", ...trim, "-i", input, "-vf", `${filters},palettegen=max_colors=64`, palette],
      { stdio: "ignore" },
    );
    execFileSync(
      "ffmpeg",
      // The palette is a still, so only the video is trimmed.
      [
        "-y",
        ...trim,
        "-i",
        input,
        "-i",
        palette,
        "-lavfi",
        `${filters} [x]; [x][1:v] paletteuse=dither=bayer:bayer_scale=5`,
        gif,
      ],
      { stdio: "ignore" },
    );
    console.log("  directory-live-update.gif");
  } catch (err) {
    failures.push(`ffmpeg failed: ${err.message.split("\n")[0]}`);
  }
} else {
  failures.push("playwright recorded no video, so there is no GIF");
}

rmSync(videoDir, { recursive: true, force: true });

if (failures.length) {
  console.error(`\n${failures.length} problem(s):`);
  for (const f of failures) console.error("  " + f);
  process.exit(1);
}

console.log("\nlive update captured");
