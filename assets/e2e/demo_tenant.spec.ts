import {test, expect} from "@playwright/test"
import {DEMO_ADMIN, demoPassword} from "./support/demo"
import {signIn} from "./support/sign_in"

/**
 * The seed every clinic spec stands on: the demo administrator signs in with
 * the demo password (support/demo.ts), the credentialing tour lists its
 * beats, and the fault panel is there, because the dev config compiles the
 * fault points in and turns the panel on. A spec that drives a fault (the
 * worker killed after the registry accepts, the outcome unknown until the
 * sweep settles it) fails here first, by name, when either is missing.
 *
 * Seed state: `mix ash_enterprise.demo`, with `--password-file` in CI.
 */

test("the demo administrator reaches the credentialing tour and its fault panel", async ({page}) => {
  await signIn(page, {email: DEMO_ADMIN, password: demoPassword()})

  await page.goto("/app/showcase/credentialing", {waitUntil: "networkidle"})
  await expect(page.locator("#beats")).toBeVisible({timeout: 15_000})

  const panel = page.locator("#fault-panel")
  await expect(panel).toBeVisible()
  await expect(panel.locator("#fault-kill")).toBeVisible()
})
