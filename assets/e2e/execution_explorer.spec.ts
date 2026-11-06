import {test, expect, type Browser, type Page} from "@playwright/test"
import AxeBuilder from "@axe-core/playwright"
import {DEMO_ADMIN, demoPassword} from "./support/demo"
import {signIn} from "./support/sign_in"

/**
 * The execution explorer (/app/explorer) in a real browser, on the clinic
 * demo. The coordinator does a piece of work from the credentialing tour, in
 * one page and so under one correlation id: opens a credential's case and
 * routes it (a process run and a decision), has the licence reader read
 * another credential's documents (the evidence, and the judgments on it), and
 * asks to activate that credential. A committee member approves it; the
 * activation runs and the registry records it (the effect).
 *
 * The administrator then starts from the activation, and walks from its effect
 * to its approval, and from everything recorded with it to the decision's
 * matched rule, a judgment and the evidence it cites; the timeline, the
 * diagram and the detail show one selection; the page and the timeline pass
 * axe's WCAG 2.2 AA rules, and the timeline's accessibility tree is a log of
 * buttons (decision P5-5: an ARIA snapshot in place of a manual screen-reader
 * pass). The canvas being unavailable (QX-02) is the LiveView test's: it
 * sends the viewer's import error and selects from the timeline alone.
 *
 * Seed state: `mix ash_enterprise.demo` (support/demo.ts). The spec picks
 * whichever credentials are still unopened and pending, and follows the
 * request it raised itself, so it runs again on the same seed while the
 * clinic has a case left to open (four on a fresh seed). It runs one at a time
 * with recovery.spec.ts (playwright.config.ts): both run an activation.
 */

const WCAG22AA = ["wcag2a", "wcag2aa", "wcag21a", "wcag21aa", "wcag22aa"]
const COORDINATOR = "rosa@example.com"
const COMMITTEE = "kenji@example.com"

const shot = (name: string) => `${process.env.E2E_SCREENSHOT_DIR ?? "test-results"}/${name}.png`

async function connected(page: Page, path: string) {
  await page.goto(path, {waitUntil: "networkidle"})
  await page.locator(".phx-connected").first().waitFor({timeout: 15_000})
}

async function as(browser: Browser, email: string): Promise<Page> {
  const page = await (await browser.newContext()).newPage()
  await signIn(page, {email, password: demoPassword()})
  return page
}

/** The coordinator's work, in one tour page. Returns the activation's invocation id. */
async function work(page: Page): Promise<string> {
  await connected(page, "/app/showcase/credentialing")

  // A case, opened and routed: the process run and the decision.
  const unopened = page.locator("li[id^=unopened-]").first()
  await expect(unopened).toBeVisible()
  const caseNumber = (await unopened.locator("a").first().innerText()).trim()
  await unopened.locator("button").click()
  const routed = page.locator("li[id^=routed-]", {hasText: caseNumber})
  await expect(routed).toBeVisible({timeout: 30_000})
  await routed.locator("button[id^=route-]").click()
  await expect(page.locator("#flash-info, [role=status]").first()).toBeAttached()

  // A credential that is still pending and has a recorded reading.
  const readable = page.locator("li[id^=readable-]")
  const numbers = await readable.locator("a").allInnerTexts()
  const pending = await page.locator("li[id^=pending-] a").allInnerTexts()
  const number = numbers.map((n) => n.trim()).find((n) => pending.map((p) => p.trim()).includes(n))
  expect(number, "a pending credential with a recorded reading").toBeTruthy()

  await readable.filter({hasText: number!}).locator("button[id^=read-]").click()

  // The request this run raises: the awaiting row that was not there before.
  const rows = page.locator("#awaiting-rows tr[id^=awaiting-]")
  const before = new Set(await rows.evaluateAll((trs) => trs.map((tr) => tr.id)))
  await page.locator("li[id^=pending-]", {hasText: number!}).locator("button[id^=raise-]").click()

  let id = ""
  await expect(async () => {
    const now = await rows.evaluateAll((trs) => trs.map((tr) => tr.id))
    id = now.find((rowId) => !before.has(rowId)) ?? ""
    expect(id, "the new request waits for approval").not.toEqual("")
  }).toPass({timeout: 15_000})

  return id.replace("awaiting-", "")
}

test("from the activation's effect to its approval, the matched rule, the judgment and the evidence", async ({browser}) => {
  test.setTimeout(240_000)

  const coordinator = await as(browser, COORDINATOR)
  const invocation = await work(coordinator)

  // A committee member approves it on the approvals surface (its row is the task's).
  const member = await as(browser, COMMITTEE)
  await connected(member, "/app/showcase/credentialing")
  await member.locator(`#awaiting-approve-${invocation}`).click()
  await expect(member).toHaveURL(/ctx(\[|%5B)task(\]|%5D)=/)
  const task = new URL(member.url()).searchParams.get("ctx[task]")
  await member.locator(`#row-${task}`).getByRole("button", {name: "Approve", exact: true}).click()
  const confirm = member.getByRole("dialog").getByRole("button", {name: /^Approve/})
  if (await confirm.isVisible().catch(() => false)) await confirm.click()
  await expect(member.locator(`#row-${task}`)).toHaveCount(0, {timeout: 15_000})

  // The activation runs within a minute of the approval.
  const admin = await as(browser, DEMO_ADMIN)
  const ref = `invocation:${invocation}`
  const effect = admin.locator(`#timeline [data-ref='effect:${invocation}']`)

  await expect(async () => {
    await connected(admin, `/app/explorer?root=${ref}`)
    // Ran and recorded, not only accepted: an effect whose outcome is unknown is uncertain.
    await expect(effect).toHaveAttribute("data-status", "succeeded", {timeout: 2_000})
  }).toPass({timeout: 150_000, intervals: [5_000]})

  // The effect, then the operation it belongs under, then its approval.
  await effect.click()
  await expect(admin.locator("#explorer-detail")).toHaveAttribute("data-ref", `effect:${invocation}`)
  await expect(effect).toHaveAttribute("aria-current", "true")
  await expect(admin.locator("#detail-run-mode")).toHaveAttribute("data-run-environment", "live")

  await admin.locator(`#detail-parent [data-ref='${ref}']`).click()
  await expect(admin.locator("#explorer-detail")).toHaveAttribute("data-ref", ref)

  const approval = admin.locator("#detail-children [data-ref^='human_task:']").first()
  await approval.click()
  await expect(admin.locator("#detail-record")).toHaveAttribute("data-record", "human_task")
  await expect(admin.locator("#detail-record")).toContainText("approved")

  // Everything recorded with the activation.
  await admin.locator(`#timeline [data-ref='${ref}']`).click()
  await admin.locator("#detail-correlation a").click()
  await expect(admin).toHaveURL(/correlation_id=/)

  // The decision and the rule that matched.
  await admin.locator("#timeline [data-kind=decision]").first().click()
  await expect(admin.locator("#detail-record")).toHaveAttribute("data-record", "evaluation")
  await expect(admin.locator("#detail-record")).toContainText("rule_route")

  // A judgment and the evidence it cites.
  await admin.locator("#timeline [data-ref^='judgment:']").first().click()
  await expect(admin.locator("#detail-record")).toHaveAttribute("data-record", "judgment")
  await expect(admin.locator("#detail-evidence li").first()).toBeVisible()

  // The evidence read: the reader's tool result.
  await admin.locator("#timeline [data-kind=observation][data-ref^='step:']").first().click()
  await expect(admin.locator("#detail-record")).toHaveAttribute("data-record", "step")

  // One selection: a process event is highlighted on the diagram and in the detail.
  await expect(admin.locator("[id^=explorer-bpmn-]")).toBeVisible()
  const events = admin.locator("#timeline [data-kind=process_event]")
  const count = await events.count()
  let node: string | null = null
  for (let i = 0; i < count && !node; i++) {
    await events.nth(i).click()
    node = await admin.locator("#diagram-selection").getAttribute("data-node")
  }
  expect(node, "a process event on an element of the diagram").toBeTruthy()
  await expect(admin.locator(`[id^=explorer-bpmn-] [data-element-id='${node}'].ash-bpmn-highlight`)).toBeVisible()
  await expect(admin.locator("#detail-record")).toHaveAttribute("data-record", "process_event")
  await admin.screenshot({path: shot("execution_explorer"), fullPage: true})

  // The timeline is a log of buttons, reachable from the keyboard.
  await expect(admin.locator("#timeline")).toMatchAriaSnapshot(`
    - log:
      - list:
        - listitem:
          - button
  `)
  const first = admin.locator("#timeline button").first()
  await first.focus()
  await admin.keyboard.press("Enter")
  await expect(first).toHaveAttribute("aria-current", "true")

  const results = await new AxeBuilder({page: admin}).withTags(WCAG22AA).analyze()
  expect(results.violations).toEqual([])
})
