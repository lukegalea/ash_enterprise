import type {Page} from "@playwright/test"

/** The tenant seeder's administrator (`mix ash_enterprise.seed`). */
export const SEED_ADMIN = {email: "admin@example.com", password: "password1234"}

/**
 * Signs in through the sign-in page. The form is a LiveView: it is filled once
 * it has connected, or the connected render resets the inputs and the submit
 * goes out empty.
 */
export async function signIn(page: Page, {email, password} = SEED_ADMIN) {
  await page.goto("/sign-in", {waitUntil: "networkidle"})
  await page.locator(".phx-connected").first().waitFor({timeout: 15_000})
  await page.fill('input[type="email"]', email)
  await page.fill('input[type="password"]', password)
  await page.click('button[type="submit"]')
  await page.waitForURL((url) => !url.pathname.includes("sign-in"), {timeout: 15_000})
}
