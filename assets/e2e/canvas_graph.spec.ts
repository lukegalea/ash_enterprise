import {test, expect} from "@playwright/test"
import AxeBuilder from "@axe-core/playwright"

/**
 * The dev-only /canvas surface: the `<ash-canvas-graph>` element (renderer
 * lane) renders the accessible tree; selection resolves a naked object
 * server-side and the server-rendered inspector shows it.
 *
 * Names pinned by docs/plans/2026-09-09-canvas-host-contract.md:
 * `role="tree"` / `role="treeitem"` with `data-id` + `aria-selected`; the
 * `canvas:select` client event; the `#canvas-inspector` region. Playwright's
 * engines pierce the element's open shadow roots natively.
 *
 * Progressive disclosure is part of the assertion: no record treeitem may
 * exist anywhere in the tree.
 */

test.describe("canvas graph", () => {
  let page

  test.beforeEach(async ({browser}) => {
    const context = await browser.newContext()
    page = await context.newPage()

    await page.goto("/sign-in", {waitUntil: "networkidle"})
    await page.fill('input[type="email"]', "admin@example.com")
    await page.fill('input[type="password"]', "password1234")
    await page.click('button[type="submit"]')
    await page.waitForURL((url) => !url.pathname.includes("sign-in"), {timeout: 15_000})

    await page.goto("/canvas", {waitUntil: "networkidle"})
    // The element receives the graph payload over the LiveView push_event.
    const tree = page.locator('[role="tree"]')
    await expect(tree).toBeVisible({timeout: 15_000})
  })

  test.afterEach(async () => {
    await page.close()
  })

  test("renders domain and resource treeitems", async () => {
    const treeitems = page.locator('[role="treeitem"][data-id]')
    const count = await treeitems.count()
    expect(count).toBeGreaterThan(0)

    // Domain and resource kinds are both present (the payload's two most
    // numerous kinds); ids carry the contract's opaque-ref prefixes.
    const ids = []
    for (let i = 0; i < count; i++) {
      ids.push(await treeitems.nth(i).getAttribute("data-id"))
    }

    expect(ids.some((id) => id.startsWith("domain:"))).toBe(true)
    expect(ids.some((id) => id.startsWith("resource:"))).toBe(true)
  })

  test("no record treeitems exist", async () => {
    const treeitems = page.locator('[role="treeitem"][data-id]')
    const count = await treeitems.count()

    for (let i = 0; i < count; i++) {
      const id = await treeitems.nth(i).getAttribute("data-id")
      expect(id).not.toMatch(/^record:/)
    }
  })

  test("clicking a resource treeitem opens the inspector", async () => {
    const resourceItem = page
      .locator('[role="treeitem"][data-id^="resource:"]')
      .first()

    const dataId = await resourceItem.getAttribute("data-id")
    await resourceItem.click()
    await expect(resourceItem).toHaveAttribute("aria-selected", "true")

    const inspector = page.locator("#canvas-inspector")
    await expect(inspector).toBeVisible()
    await expect(inspector).toContainText("Capabilities")
    await expect(inspector).toContainText("Projections")
    await expect(inspector).toContainText(dataId)
  })

  test("keyboard selection opens the inspector", async () => {
    const resourceItem = page
      .locator('[role="treeitem"][data-id^="resource:"]')
      .first()

    await resourceItem.focus()
    await page.keyboard.press("Enter")
    await expect(resourceItem).toHaveAttribute("aria-selected", "true")

    const inspector = page.locator("#canvas-inspector")
    await expect(inspector).toContainText("Capabilities")
  })

  test("axe: the canvas surface has no serious or critical violations", async () => {
    const results = await new AxeBuilder({page})
      .withTags(["wcag2a", "wcag2aa", "wcag21a", "wcag21aa"])
      .analyze()

    // Violations INSIDE <ash-canvas-graph> belong to the renderer lane (see
    // the lane-ownership split in the contract) and are asserted at the
    // combined verification; this scan holds the host-owned page to the
    // same bar.
    const serious = results.violations
      .filter((v) => ["serious", "critical"].includes(v.impact ?? ""))
      .filter(
        (v) =>
          !v.nodes.every((n) =>
            n.target.some((t) => String(t).includes("ash-canvas-graph"))
          )
      )
    expect(serious).toEqual([])
  })
})
