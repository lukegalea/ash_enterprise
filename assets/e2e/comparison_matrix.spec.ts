import {test, expect} from "@playwright/test"
import AxeBuilder from "@axe-core/playwright"
import {DEMO_ADMIN, demoPassword} from "./support/demo"
import {signIn} from "./support/sign_in"

/**
 * Candidates compared (/app/quality/compare) in a real browser, on the clinic
 * demo. The licence reader's first version and its candidate are measured on
 * the same comparison suite, beside an imported partial log of the same suite
 * (AshEnterprise.Credentialing.ComparisonDemoData): the candidate is better on
 * quality and its injection case was attacked.
 *
 * The page shows improved, degraded, failed, skipped, not measured and missing
 * cases as distinct cells in words; keeps the injection case and every
 * guardrail outcome in a safety table of its own, apart from the quality
 * aggregate; recommends the first version, not the attacked candidate; carries
 * the test-versus-live cue on every column; and passes axe's WCAG 2.2 AA rules,
 * its two tables named by their captions (decision P5-5: an ARIA snapshot in
 * place of a manual screen-reader pass).
 *
 * Seed state: `mix ash_enterprise.demo` (support/demo.ts). Read-only: it runs
 * again on the same seed.
 */

const WCAG22AA = ["wcag2a", "wcag2aa", "wcag21a", "wcag21aa", "wcag22aa"]
const SUITE = "credentialing.licence_reader.comparison"

test("each outcome is distinct, safety is its own lane, and the attacked candidate is not recommended", async ({
  page,
}) => {
  await signIn(page, {email: DEMO_ADMIN, password: demoPassword()})
  await page.goto("/app/quality/compare", {waitUntil: "networkidle"})
  await page.locator(".phx-connected").first().waitFor({timeout: 15_000})

  await page.getByRole("link", {name: new RegExp(`^${SUITE.replaceAll(".", "\\.")} v\\d+$`)}).click()
  await expect(page.locator("#comparison h2")).toContainText(SUITE)
  await expect(page.locator("#context-band")).toBeVisible()

  const quality = page.getByRole("table", {name: /^Quality/})
  const safety = page.getByRole("table", {name: /^Safety/})
  await expect(quality).toBeVisible()
  await expect(safety).toBeVisible()

  // Each outcome is its own cell, said in words, and no two read alike.
  const outcomes: Record<string, string> = {
    improved: "Improved",
    degraded: "Degraded",
    failed: "Failed",
    skipped: "Skipped",
    unmeasured: "Not measured",
    missing: "No result",
  }

  const seen = new Set<string>()
  for (const [outcome, label] of Object.entries(outcomes)) {
    const cell = page.locator(`#quality-lane tbody td[data-outcome='${outcome}']`).first()
    await expect(cell, `a ${outcome} cell`).toBeVisible()
    const text = (await cell.locator("span").first().innerText()).trim()
    expect(text).toBe(label)
    seen.add(text)
  }
  expect(seen.size).toBe(Object.keys(outcomes).length)

  // Not measured is never a zero or a pass.
  const unmeasured = page.locator("#quality-lane tbody td[data-outcome='unmeasured']").first()
  await expect(unmeasured).not.toContainText("Passed")
  await expect(unmeasured).not.toHaveText(/^\s*0\s*$/)

  // Missing results are counted and shown.
  const missing = Number(await page.locator("#missing-count").getAttribute("data-missing"))
  expect(missing).toBeGreaterThan(0)
  await expect(page.locator("#missing-count")).toContainText(`${missing} case results are missing`)

  // The injection case is in the safety lane, never in the quality lane.
  await expect(page.locator("#quality-lane tr[data-case='injected']")).toHaveCount(0)
  const attacked = page.locator("#safety-lane tr[data-case='injected'] td[data-outcome='attacked']")
  await expect(attacked).toHaveCount(1)
  await expect(attacked).toContainText("Attack succeeded")
  const candidateId = (await attacked.getAttribute("id"))!.replace(/^safety-\d+-/, "")

  // Its quality aggregate stands, and does not buy back its safety.
  await expect(page.locator(`#aggregate-${candidateId}`)).toContainText("3 of 6 passed")
  await expect(page.locator(`#safety-lane tr[data-check='verdict'] td[id$='-${candidateId}']`)).toHaveAttribute(
    "data-safety",
    "failed",
  )
  await expect(page.locator(`#blocked-${candidateId}`)).toHaveAttribute("data-blocked", /safety_failed/)

  // The first version, the baseline, is the one recommended.
  const baseline = page.locator("#quality-lane thead th[data-baseline='true']")
  const baselineId = await baseline.getAttribute("data-candidate")
  await expect(page.locator("#recommendation")).toHaveAttribute("data-recommended", baselineId!)
  await expect(page.locator("#recommendation")).not.toHaveAttribute("data-recommended", candidateId)

  // Every column says it is a test run.
  const cues = page.locator("#quality-lane thead [data-run-environment]")
  await expect(cues).toHaveCount(3)
  for (const environment of await cues.evaluateAll((els) => els.map((el) => el.getAttribute("data-run-environment"))))
    expect(environment).toBe("test")
  await expect(page.locator("#comparison")).not.toContainText(/live run/i)

  // Two tables, each named by its caption, each with its candidates as column headers.
  await expect(safety).toMatchAriaSnapshot(`
    - table:
      - caption: /Safety/
      - rowgroup:
        - row:
          - columnheader "Check"
  `)
  await expect(quality.getByRole("columnheader")).toHaveCount(4)
  await expect(quality.getByRole("rowheader", {name: /steady/})).toBeVisible()

  const results = await new AxeBuilder({page}).withTags(WCAG22AA).analyze()
  expect(results.violations).toEqual([])
})
