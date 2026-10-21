import {test, expect} from "@playwright/test"

/**
 * The process flight view in a real browser (PROD-10): mermaid loads on
 * demand (`loadMermaid`, its own bundle), draws the `morning.brief` process
 * as an SVG, and the live marker sits on the approval step.
 *
 * Seed state: the tenant seeder's administrator (admin@example.com) with
 * today's morning brief composed, so its run waits at "Approve the brief" —
 * `mix ash_enterprise.bpmn.publish`, then compose the brief from /app/today
 * (this spec composes it if the page offers the button).
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

test("the brief approval flight view draws the process with its marker", async ({page}) => {
  await signIn(page)

  await page.goto("/app/today", {waitUntil: "networkidle"})
  const compose = page.locator("#compose-brief")
  if (await compose.isVisible().catch(() => false)) {
    await compose.click()
    await page.waitForTimeout(2_000)
  }

  await page.goto("/app/flights/briefs", {waitUntil: "networkidle"})

  const diagram = page.locator("ash-admin-live-diagram")
  await expect(diagram).toBeVisible({timeout: 15_000})

  // Mermaid drew the process: an SVG holding the definition's own step names.
  const svg = diagram.locator("svg").first()
  await expect(svg).toBeVisible({timeout: 20_000})
  await expect(svg).toContainText("Approve the brief")

  // The live marker: waiting, on the approval step.
  const marker = diagram.locator('.marker[data-status="waiting"]').first()
  await expect(marker).toBeVisible()

  await page.screenshot({path: process.env.E2E_SCREENSHOT ?? "test-results/flight_view.png", fullPage: true})

  // The marker opens that run's own flight view, through the deep link.
  await marker.click()
  await page.waitForURL(/\/app\/flights\?ctx/, {timeout: 15_000})

  const run = page.locator("ash-admin-live-diagram")
  await expect(run.locator("svg").first()).toContainText("Approve the brief", {timeout: 20_000})
  await expect(run.locator('.marker[data-status="waiting"]')).toHaveCount(1)
})
