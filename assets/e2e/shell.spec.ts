import {test, expect} from "@playwright/test"

/**
 * The command palette (ctrl+p) and surface launcher (ctrl+k) in a real
 * browser (PROD-36): the keys open them from any page, the arrows and enter
 * work, `/open calendar` navigates, and a typed line reaches the agent.
 *
 * Seed state: the tenant seeder's administrator (admin@example.com).
 */

const EMAIL = "admin@example.com"
const PASSWORD = "password1234"

async function signIn(page) {
  await page.goto("/sign-in", {waitUntil: "networkidle"})
  // The sign-in form is a LiveView: fill it once it has connected, or the
  // connected render resets the inputs.
  await page.locator(".phx-connected").first().waitFor({timeout: 15_000})
  await page.fill('input[type="email"]', EMAIL)
  await page.fill('input[type="password"]', PASSWORD)
  await page.click('button[type="submit"]')
  await page.waitForURL((url) => !url.pathname.includes("sign-in"), {timeout: 15_000})
}

async function connected(page, path) {
  await page.goto(path, {waitUntil: "networkidle"})
  await page.locator(".phx-connected").first().waitFor({timeout: 15_000})
}

const shot = (name) => `${process.env.E2E_SCREENSHOT_DIR ?? "test-results"}/${name}.png`

test("ctrl+k opens the launcher, filters, and enter opens the surface", async ({page}) => {
  await signIn(page)
  await connected(page, "/app/today")

  await page.keyboard.press("Control+k")
  const dialog = page.locator("#a2ui-shell-dialog")
  await expect(dialog).toBeVisible()
  await expect(page.locator("#a2ui-shell-input")).toBeFocused()
  await expect(dialog).toContainText("Time travel")
  await expect(dialog).toContainText("Lineage")
  await page.screenshot({path: shot("shell_launcher")})

  await page.keyboard.type("time trav")
  await expect(page.locator("#a2ui-shell-item-0")).toContainText("Time travel")
  await expect(page.locator("#a2ui-shell-item-1")).toHaveCount(0)
  await page.keyboard.press("Enter")
  await page.waitForURL(/\/app\/time-travel/, {timeout: 15_000})
})

test("ctrl+p opens the palette; the arrows move; escape closes", async ({page}) => {
  await signIn(page)
  await connected(page, "/app/calendar")

  await page.keyboard.press("Control+p")
  const dialog = page.locator("#a2ui-shell-dialog")
  await expect(dialog).toBeVisible()
  await expect(dialog).toContainText("/today")
  await expect(dialog).toContainText("/approvals")
  await expect(page.locator('#a2ui-shell-item-0[aria-selected="true"]')).toBeVisible()

  await page.keyboard.press("ArrowDown")
  await expect(page.locator('#a2ui-shell-item-1[aria-selected="true"]')).toBeVisible()
  await page.screenshot({path: shot("shell_palette")})

  await page.keyboard.press("Escape")
  await expect(dialog).toHaveCount(0)
})

test("/open calendar navigates, and a typed line goes to the agent", async ({page}) => {
  await signIn(page)
  await connected(page, "/app")

  await page.keyboard.press("Control+p")
  await page.keyboard.type("/open calendar")
  await expect(page.locator("#a2ui-shell-item-0")).toContainText("Open Calendar")
  await page.keyboard.press("Enter")
  await page.waitForURL(/\/app\/calendar$/, {timeout: 15_000})

  await page.locator(".phx-connected").first().waitFor({timeout: 15_000})
  await page.locator("#nav-palette").click()
  await page.keyboard.type("what is on today")
  await expect(page.locator("#a2ui-shell-dialog")).toContainText("Ask the agent")
  await page.keyboard.press("Enter")
  await page.waitForURL(/\/app\/agent/, {timeout: 15_000})
})
