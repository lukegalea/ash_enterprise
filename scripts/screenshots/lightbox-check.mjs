import { firefox } from "playwright";

const base = "http://localhost:4321/ash_enterprise/";
const results = [];
const errors = [];

const browser = await firefox.launch();
const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });
page.on("console", (m) => { if (m.type() === "error") errors.push(m.text().slice(0, 200)); });
page.on("pageerror", (e) => errors.push("pageerror: " + e.message.slice(0, 200)));

await page.goto(base, { waitUntil: "networkidle" });

const check = (name, ok, detail = "") => { results.push({ name, ok, detail }); };

const dialog = page.locator("#ae-lightbox");
const lbImage = page.locator("#ae-lightbox-image");
const triggers = page.locator("a[data-lightbox-src]");

check("triggers exist", (await triggers.count()) > 0, `count=${await triggers.count()}`);
check("dialog is closed initially", !(await dialog.evaluate((d) => d.open)));

// --- open via click on the first screenshot ---------------------------------
const first = triggers.first();
await first.scrollIntoViewIfNeeded();
const expectedSrc = await first.getAttribute("data-lightbox-src");
await first.click();
await page.waitForTimeout(400);

check("dialog opens on click", await dialog.evaluate((d) => d.open));
check("dialog is in the top layer", await dialog.evaluate((d) => d.matches(":modal")));

const shown = await lbImage.getAttribute("src");
check("lightbox shows the large variant", shown === expectedSrc, `${shown}`);

const box = await lbImage.boundingBox();
const inlineBox = await first.locator("img").boundingBox();
check(
  "lightbox image is larger than the inline one",
  box && inlineBox && box.width > inlineBox.width,
  `lightbox=${Math.round(box?.width)} inline=${Math.round(inlineBox?.width)}`,
);
check("lightbox image fits the viewport height", box && box.height <= 900, `h=${Math.round(box?.height)}`);
check("caption is populated", ((await page.locator("#ae-lightbox-caption").textContent()) || "").length > 10);
check("page cannot scroll behind", (await page.evaluate(() => document.documentElement.style.overflow)) === "hidden");

// --- Escape ----------------------------------------------------------------
await page.keyboard.press("Escape");
await page.waitForTimeout(400);
check("Escape closes", !(await dialog.evaluate((d) => d.open)));
check("scroll restored after Escape", (await page.evaluate(() => document.documentElement.style.overflow)) !== "hidden");

// Each step below reopens, so a step that fails to close must not leak into the
// next one: the first version did, and the report blamed the *image* for
// intercepting a click on a trigger that was simply underneath a modal that had
// never closed. `settle` makes each check independent and reports honestly.
async function settle() {
  await dialog.evaluate((d) => d.open && d.close());
  await page.waitForTimeout(300);
}

// --- backdrop click --------------------------------------------------------
await settle();
await first.click();
await page.waitForTimeout(350);

// A point genuinely outside the dialog box, computed rather than guessed. (20,20)
// was used at first and is inside the dialog whenever it is not centred, which is
// how the missing `margin: auto` was found.
const dbox = await dialog.boundingBox();
const outside = { x: Math.max(4, dbox.x / 2), y: Math.max(4, dbox.y / 2) };
check(
  "the chosen point is outside the dialog",
  outside.x < dbox.x || outside.y < dbox.y,
  `point=(${Math.round(outside.x)},${Math.round(outside.y)}) dialog=(${Math.round(dbox.x)},${Math.round(dbox.y)})`,
);
await page.mouse.click(outside.x, outside.y);
await page.waitForTimeout(400);
check("clicking the backdrop closes", !(await dialog.evaluate((d) => d.open)));

// --- close button ----------------------------------------------------------
await settle();
await first.click();
await page.waitForTimeout(350);
await page.locator("#ae-lightbox-close").click();
await page.waitForTimeout(400);
check("close button closes", !(await dialog.evaluate((d) => d.open)));

// --- clicking the image itself must NOT close ------------------------------
await settle();
await first.click();
await page.waitForTimeout(350);
await lbImage.click({ position: { x: 10, y: 10 } });
await page.waitForTimeout(300);
check("clicking the image does not close", await dialog.evaluate((d) => d.open));

// --- the dialog is centred ------------------------------------------------
const centred = await page.evaluate(() => {
  const d = document.getElementById("ae-lightbox").getBoundingClientRect();
  const dx = Math.abs(d.left - (window.innerWidth - d.right));
  const dy = Math.abs(d.top - (window.innerHeight - d.bottom));
  return { dx: Math.round(dx), dy: Math.round(dy) };
});
check("dialog is centred", centred.dx <= 2 && centred.dy <= 2, `off by ${centred.dx}x${centred.dy}px`);

// --- modifier click falls through -----------------------------------------
await settle();
await first.click({ modifiers: ["Control"] });
await page.waitForTimeout(400);
check("ctrl-click does not open the dialog", !(await dialog.evaluate((d) => d.open)));

// --- the animated figure --------------------------------------------------
await settle();
const gif = page.locator('a[data-lightbox-src$=".gif"]').first();
if ((await gif.count()) > 0) {
  await gif.scrollIntoViewIfNeeded();
  await gif.click();
  await page.waitForTimeout(400);
  const src = await lbImage.getAttribute("src");
  check("gif opens in the lightbox", (await dialog.evaluate((d) => d.open)) && src.endsWith(".gif"), src);
  await page.keyboard.press("Escape");
  await page.waitForTimeout(300);
} else {
  check("gif trigger present", false, "no .gif trigger found");
}

// --- keyboard reachable ---------------------------------------------------
await settle();
await first.focus();
await page.keyboard.press("Enter");
await page.waitForTimeout(400);
check("Enter on a focused trigger opens it", await dialog.evaluate((d) => d.open));
await page.keyboard.press("Escape");

// --- a page with no figures must not break -------------------------------
await page.goto(base + "roadmap/", { waitUntil: "networkidle" });
await page.waitForTimeout(300);
check("a figure-less page still renders", (await page.locator("main").count()) === 1);

await browser.close();

let failed = 0;
for (const r of results) {
  console.log(`${r.ok ? "  ok  " : "  FAIL"} ${r.name}${r.detail ? "  [" + r.detail + "]" : ""}`);
  if (!r.ok) failed++;
}
if (errors.length) {
  console.log("\nconsole errors:");
  for (const e of errors) console.log("  " + e);
}
console.log(`\n${results.length - failed}/${results.length} checks passed`);
process.exit(failed || errors.length ? 1 : 0);
