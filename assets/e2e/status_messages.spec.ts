import {test, expect} from "@playwright/test"
import AxeBuilder from "@axe-core/playwright"
import {SEED_ADMIN, signIn} from "./support/sign_in"

/**
 * Status messages and the context band in a real browser (WCAG 2.2 SC 4.1.3,
 * https://www.w3.org/WAI/WCAG22/Understanding/status-messages.html).
 *
 * A status message is announced without moving focus, so its live region must
 * already be on the page when the message arrives: these tests find the region
 * before anything is said, then make the page say something while focus is in
 * the input, and check that focus never left it. The regions and the band pass
 * axe's WCAG 2.2 AA rules.
 *
 * Seed state: the tenant seeder's administrator (admin@example.com).
 */

const EMAIL = SEED_ADMIN.email
const WCAG22AA = ["wcag2a", "wcag2aa", "wcag21a", "wcag21aa", "wcag22aa"]

async function connected(page, path) {
  await page.goto(path, {waitUntil: "networkidle"})
  await page.locator(".phx-connected").first().waitFor({timeout: 15_000})
}

const focusedId = (page) => page.evaluate(() => document.activeElement?.id ?? null)

const shot = (name) => `${process.env.E2E_SCREENSHOT_DIR ?? "test-results"}/${name}.png`

test("the context band names the tenant and the person signed in", async ({page}) => {
  await signIn(page)
  await connected(page, "/app/today")

  const band = page.locator("#context-band")
  await expect(band).toBeVisible()
  await expect(page.locator("#context-tenant")).toHaveAttribute("data-tenant", "named")
  await expect(page.locator("#context-identity")).toContainText("Signed in as")
  await expect(page.locator("#context-identity")).toContainText(EMAIL)
  await expect(page.locator("#context-impersonation")).toHaveCount(0)

  // Read as a definition list: each term with its value.
  await expect(band).toMatchAriaSnapshot(`
    - term: Tenant
    - definition
    - term: Signed in as
    - definition: ${EMAIL}
  `)

  const results = await new AxeBuilder({page}).include("#context-band").withTags(WCAG22AA).analyze()
  expect(results.violations).toEqual([])
})

test("Today's status regions are on the page before they have anything to say", async ({page}) => {
  await signIn(page)
  await connected(page, "/app/today")

  for (const id of ["inbox-notice", "brief-prompt"]) {
    const region = page.locator(`#${id}-region`)
    await expect(region).toHaveCount(1)
    await expect(region).toHaveAttribute("role", "status")
    // The role carries its own politeness; nothing overrides it.
    await expect(region).not.toHaveAttribute("aria-live")
  }
})

test("the launcher announces what it found and keeps focus in the input", async ({page}) => {
  await signIn(page)
  await connected(page, "/app")

  const region = page.locator("#launch-results")
  await expect(region).toHaveAttribute("role", "status")
  // Present and silent before anything is typed.
  await expect(region).toHaveText("")

  const input = page.locator("#launch-filter input[type=search]")
  await input.click()
  const inputId = await focusedId(page)
  expect(inputId).toBeTruthy()

  // The filter leaves nothing on the grid: the region says so, focus stays put.
  await input.pressSequentially("zz-no-such-thing")
  await expect(region).toContainText("No app or record matches")
  expect(await focusedId(page)).toBe(inputId)

  // Enter looks the text up as a record; nothing is found, and focus still stays.
  await input.press("Enter")
  await expect(page.locator("#launch-found")).toBeVisible()
  await expect(region).toContainText("Records")
  await expect(region).toContainText("No app or record matches")
  expect(await focusedId(page)).toBe(inputId)
  await expect(input).toHaveValue("zz-no-such-thing")
  await page.screenshot({path: shot("status_messages_launcher")})

  const results = await new AxeBuilder({page})
    .include("#launch-results")
    .include("#launch-search-failed-region")
    .include("#context-band")
    .withTags(WCAG22AA)
    .analyze()
  expect(results.violations).toEqual([])
})
