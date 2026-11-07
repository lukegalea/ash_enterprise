import {test, expect, type Browser, type Page} from "@playwright/test"
import {DEMO_ADMIN, demoPassword} from "./support/demo"

/**
 * The recovery surface in a real browser (AGT-62): an activation whose answer the
 * registry lost, settled by a person, then simulated, rerun and cancelled.
 *
 * The uncertain outcome comes from the showcase's fault panel, the dev configuration's
 * demo-only controls (`config/dev.exs`, `fault_controls?: true`), never from seeded
 * history: the coordinator arms "Lose the registry's answer" and asks to activate a
 * credential; a committee member approves it; the registry accepts the activation and
 * the answer is lost, and the registry cannot say afterwards whether it took it. The
 * request is then uncertain and waits for a person.
 *
 * Seed state: the demo tenant (`mix ash_enterprise.demo`): the coordinator
 * rosa@example.com, the committee member kenji@example.com and the administrator
 * demo-admin@example.com, all with the demo password (support/demo.ts).
 *
 * The approval is applied by its minute sweep and the activation then runs as a job, so
 * the uncertain row can take a minute or more to appear.
 */

const COORDINATOR = "rosa@example.com"
const COMMITTEE = "kenji@example.com"
const ADMIN = DEMO_ADMIN

async function signedIn(browser: Browser, email: string): Promise<Page> {
  const context = await browser.newContext()
  const page = await context.newPage()
  await page.goto("/sign-in", {waitUntil: "networkidle"})
  // The sign-in form is a LiveView: fill it once it has connected.
  await page.locator(".phx-connected").first().waitFor({timeout: 15_000})
  await page.fill('input[type="email"]', email)
  await page.fill('input[type="password"]', demoPassword())
  await page.click('button[type="submit"]')
  await page.waitForURL((url) => !url.pathname.includes("sign-in"), {timeout: 15_000})
  return page
}

async function connected(page: Page, path: string) {
  await page.goto(path, {waitUntil: "networkidle"})
  await page.locator(".phx-connected").first().waitFor({timeout: 15_000})
}

test("an uncertain outcome is settled, simulated, rerun and cancelled, each act recorded", async ({
  browser,
}) => {
  test.setTimeout(300_000)

  // The coordinator arms the fault and asks to activate a credential.
  const rosa = await signedIn(browser, COORDINATOR)
  await connected(rosa, "/app/showcase/credentialing")
  await rosa.locator("#fault-lose").click()
  await expect(rosa.locator("#flash-info")).toContainText("Armed")

  const ask = rosa.locator('[id^="raise-"]').first()
  await ask.click()
  await expect(rosa.locator("#flash-info")).toContainText("waits for approval")

  // The newest request waiting for approval. Its approval is the committee's, so the
  // coordinator's tour shows the request but no link to the approval.
  const waitingRow = rosa.locator('#all-rows tr[data-status="awaiting_approval"]').first()
  await expect(waitingRow).toBeVisible({timeout: 15_000})
  const invocationId = (await waitingRow.getAttribute("id"))!.replace("all-", "")
  await expect(rosa.locator(`#all-approve-${invocationId}`)).toHaveCount(0)

  // A committee member opens it from the tour and approves it on the approvals surface.
  // The list holds every approval waiting on them, oldest first, and the seeded clinic
  // already has an activation waiting: this request is the newest row.
  const kenji = await signedIn(browser, COMMITTEE)
  await connected(kenji, "/app/showcase/credentialing")
  const approvalPath = (await kenji.locator(`#all-approve-${invocationId}`).getAttribute("href"))!
  await connected(kenji, approvalPath)
  const waiting = kenji
    .getByRole("table", {name: "approval"})
    .getByRole("row")
    .filter({hasText: "activate_credential"})
  await expect(waiting.last()).toBeVisible({timeout: 15_000})
  const before = await waiting.count()
  await waiting.last().getByRole("button", {name: "Approve", exact: true}).click()
  await expect(waiting).toHaveCount(before - 1, {timeout: 15_000})

  // The operator finds it uncertain on the recovery surface.
  const admin = await signedIn(browser, ADMIN)
  await connected(admin, "/app/recovery")
  await expect(admin.locator(`#uncertain-rows-${invocationId}`)).toBeVisible({timeout: 180_000})

  await connected(admin, `/app/recovery/${invocationId}`)
  await expect(admin.locator("#status")).toHaveAttribute("data-status", "uncertain")
  await expect(admin.locator("#settle-form")).toBeVisible({timeout: 60_000})
  await expect(admin.locator("#settle-succeeded")).toBeVisible()
  await expect(admin.locator("#settle-failed")).toBeVisible()
  await expect(admin.locator("#settle-retry")).toBeVisible()
  // No plain Retry, and no Rerun, while the outcome is uncertain.
  await expect(admin.getByRole("button", {name: /^retry$/i})).toHaveCount(0)
  await expect(admin.locator("#rerun-form")).toHaveCount(0)

  // Settled as not done, with a reason.
  await admin.locator("#settle-failed").check()
  await admin.locator("#settle-reason").fill("The registry has no record of it.")
  await admin.locator("#settle").click()
  await expect(admin.locator("#status")).toHaveAttribute("data-status", "failed", {timeout: 60_000})

  // Rerun says what will run again before anyone asks.
  const statement = admin.locator("#rerun-statement")
  await expect(statement).toContainText("new key")
  await expect(statement).toContainText("calls outside the application again")

  // Simulate creates nothing.
  await admin.locator("#simulate").click()
  await expect(admin.locator("#simulation")).toContainText("Nothing was created")
  await expect(admin.locator("#reruns")).toHaveCount(0)

  // Rerun: a new request with a new key, linked to the first.
  const firstKey = await admin.locator("#invocation-key").innerText()
  await admin.locator("#rerun-reason").fill("Ask the registry again.")
  await admin.locator("#rerun").click()
  await expect(admin.locator("#rerun-of")).toHaveAttribute("href", `/app/recovery/${invocationId}`, {
    timeout: 15_000,
  })
  await expect(admin.locator("#invocation-key")).not.toHaveText(firstKey)
  await expect(admin.locator("#invocation-key")).toContainText(`rerun:${invocationId}:`)
  await expect(admin.locator("#status")).toHaveAttribute("data-status", "waiting")

  // Cancel says completed effects are not reversed.
  await expect(admin.locator("#cancel-statement")).toContainText("Completed effects are not reversed")
  await admin.locator("#cancel-reason").fill("Asked twice by mistake.")
  await admin.locator("#cancel").click()
  await expect(admin.locator("#status")).toHaveAttribute("data-status", "cancelled", {timeout: 15_000})

  await admin.screenshot({
    path: process.env.E2E_SCREENSHOT ?? "test-results/recovery-rerun.png",
    fullPage: true,
  })

  // Every act on the first request, with who did it and why.
  await connected(admin, `/app/recovery/${invocationId}`)
  const settled = admin.locator('#interventions [data-act="resolve"]')
  await expect(settled).toContainText("The registry has no record of it.")
  await expect(settled.locator(".intervention-actor")).toHaveText(ADMIN)
  await expect(admin.locator('#interventions [data-act="rerun"]')).toContainText(
    "Ask the registry again.",
  )
  await expect(admin.locator("#reruns li").first()).toBeVisible()

  await admin.screenshot({
    path: process.env.E2E_SCREENSHOT_SETTLED ?? "test-results/recovery-settled.png",
    fullPage: true,
  })
})
