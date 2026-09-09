import {test, expect} from "@playwright/test"
import AxeBuilder from "@axe-core/playwright"

/**
 * The A2UI experience layer (v2 + admin catalog) on a real surface.
 *
 * Target surface: /app/teams. Deliberately NOT /app/users -- that surface is
 * browse-only (the users table has no form component, and the User resource's
 * write actions are the authentication flows, not a generic update), so it
 * cannot exercise the create/view/edit task modes. Teams declares a form with
 * both actions, which is what the task-mode contract needs.
 *
 * Everything below asserts INSIDE the Lit components: the renderer uses open
 * shadow roots and Playwright's engines pierce those natively, so the
 * locators read the semantic components' rendered DOM (the `<table>` inside
 * `ash-admin-data-grid`, the `<dl>` inside `ash-admin-record-panel`, ...).
 * A few selectors lean on the encoder's frozen id contract
 * (`form_input_name-input`, `query_search_input`) -- those ids are part of
 * the wire contract, not implementation detail.
 *
 * Seed state: the tenant seeder provisions one team ("Example Corp (All
 * Users)"). The edit flow runs against a team THIS spec creates, so the run
 * is repeatable; it leaves its QA team behind (the surface has no delete
 * row action -- destroying data is out of scope for a browse tier).
 */

const EMAIL = "admin@example.com"
const PASSWORD = "password1234"

async function signIn(page) {
  await page.goto("/sign-in", {waitUntil: "networkidle"})
  await page.fill('input[type="email"]', EMAIL)
  await page.fill('input[type="password"]', PASSWORD)
  await page.click('button[type="submit"]')
  await page.waitForURL((url) => !url.pathname.includes("sign-in"), {timeout: 15_000})
}

/** The surface mounts over a LiveView push-event round trip; give it a beat. */
async function gotoTeams(page) {
  await page.goto("/app/teams", {waitUntil: "networkidle"})
  const grid = page.locator("ash-admin-data-grid table")
  await expect(grid).toBeVisible({timeout: 15_000})
}

test.describe.serial("a2ui admin experience", () => {
  let context
  let page

  test.beforeEach(async ({browser}) => {
    // An explicit context: @axe-core/playwright refuses to run against a
    // page whose context was created implicitly by browser.newPage().
    context = await browser.newContext()
    page = await context.newPage()
    await signIn(page)
  })

  test.afterEach(async () => {
    await context.close()
  })

  test("entity page renders a semantic admin surface", async () => {
    await gotoTeams(page)

    // The page shell is the semantic EntityPage, and the grid is a REAL
    // table with an accessible name derived from the surface's collection
    // label.
    await expect(page.locator("ash-admin-entity-page")).toBeVisible()
    const table = page.locator('ash-admin-data-grid table[aria-label="Team"]')
    await expect(table).toBeVisible()
    await expect(table.locator("thead th")).toContainText(["Name", "Team type"])

    // Row identity is stable: each row carries the record id in its DOM id.
    const firstRow = table.locator("tbody tr").first()
    const rowId = await firstRow.getAttribute("id")
    expect(rowId).toMatch(/^row-[0-9a-f-]+$/)
    await page.waitForTimeout(500)
    expect(await firstRow.getAttribute("id")).toEqual(rowId)
  })

  test("no pagination chrome for the small dataset", async () => {
    await gotoTeams(page)

    // One seeded team, page size 25: the semantic Pagination is bound but
    // renders nothing when the query state says visible=false. The element
    // exists in the tree; the CHROME must not.
    await expect(page.locator("ash-admin-pagination")).not.toBeVisible()
    await expect(page.locator("ash-admin-empty-state")).not.toBeVisible()
  })

  test("create flow: affordance, labeled panel, cancel returns to browse", async () => {
    await gotoTeams(page)

    // No panel while browsing.
    await expect(page.locator("ash-admin-record-panel")).not.toBeVisible()

    await page.getByRole("button", {name: "Create Team"}).click()
    const panel = page.locator("ash-admin-record-panel")
    await expect(panel).toBeVisible()

    // Mode heading: an accessible, focused panel title.
    await expect(panel.locator("section.panel")).toHaveAttribute("aria-label", "Create Team")
    await expect(panel.locator("[data-panel-heading]")).toHaveText("Create Team")

    // The primary action is the action bar's own button -- distinct from the
    // page-level create affordance.
    await expect(
      page.locator("ash-admin-action-bar").getByRole("button", {name: "Create Team"})
    ).toBeVisible()

    // Cancel returns to browse.
    await page.locator("ash-admin-action-bar").getByRole("button", {name: "Cancel"}).click()
    await expect(panel).not.toBeVisible()
  })

  test("view flow: read-only definition list, no submit control", async () => {
    await gotoTeams(page)

    await page.getByRole("button", {name: "View"}).first().click()
    const panel = page.locator("ash-admin-record-panel")
    await expect(panel).toBeVisible()
    await expect(panel.locator("section.panel")).toHaveAttribute("aria-label", "View Team")

    // Read-only values render as a definition list of field displays -- text
    // semantics, never disabled inputs.
    const fields = panel.locator("dl.panel-fields")
    await expect(fields).toBeVisible()
    await expect(fields.locator("ash-admin-field-display").first()).toBeVisible()
    await expect(panel.locator("input, select, textarea")).toHaveCount(0)

    // And no submit control anywhere in view mode.
    await expect(
      page.locator("ash-admin-action-bar").getByRole("button", {name: /Save|Create/})
    ).toHaveCount(0)
  })

  test("edit flow: save changes round-trip lands with typed feedback", async () => {
    await gotoTeams(page)

    // Create a team of our own so the edit target is deterministic and the
    // seeded tenant data is not renamed out from under the next run.
    const teamName = `QA Team ${Date.now()}`

    await page.getByRole("button", {name: "Create Team"}).click()
    await page.locator("#form_input_name-input").fill(teamName)
    await page.locator("ash-admin-action-bar").getByRole("button", {name: "Create Team"}).click()

    const banner = page.locator("ash-admin-status-banner")
    await expect(banner).toBeVisible()
    await expect(banner).toContainText("Created successfully")

    // The success path closes the panel and refreshes the collection.
    await expect(page.locator("ash-admin-record-panel")).not.toBeVisible()
    const createdRow = page
      .locator("ash-admin-data-grid tbody tr")
      .filter({hasText: teamName})
    await expect(createdRow).toHaveCount(1)

    // Edit it: the panel opens in edit mode with the record's values.
    await createdRow.getByRole("button", {name: "Edit"}).click()
    const panel = page.locator("ash-admin-record-panel")
    await expect(panel.locator("section.panel")).toHaveAttribute("aria-label", "Edit Team")
    await expect(page.locator("#form_input_name-input")).toHaveValue(teamName)

    // A real edit round-trip.
    const renamed = `${teamName} (renamed)`
    await page.locator("#form_input_name-input").fill(renamed)
    await page
      .locator("ash-admin-action-bar")
      .getByRole("button", {name: "Save changes"})
      .click()

    await expect(banner).toBeVisible()
    await expect(banner).toContainText("Updated successfully")
    await expect(page.locator("ash-admin-record-panel")).not.toBeVisible()
    await expect(
      page.locator("ash-admin-data-grid tbody tr").filter({hasText: renamed})
    ).toHaveCount(1)
  })

  test("empty state replaces the grid for a nonsense search", async () => {
    await gotoTeams(page)

    await page.locator("#query_search_input-input").fill("zzz-no-such-team-zzz")
    await page.locator("a2ui-basic-button").filter({hasText: "Apply"}).click()

    const empty = page.locator("ash-admin-empty-state")
    await expect(empty).toBeVisible()
    await expect(empty).toContainText("No Team records yet.")

    // Still no pagination chrome -- and no rows.
    await expect(page.locator("ash-admin-pagination")).not.toBeVisible()
    await expect(page.locator("ash-admin-data-grid tbody tr")).toHaveCount(0)
  })

  test("axe: browse state has no serious or critical violations", async () => {
    await gotoTeams(page)

    const results = await new AxeBuilder({page})
      .withTags(["wcag2a", "wcag2aa", "wcag21a", "wcag21aa"])
      .analyze()

    const serious = results.violations.filter((v) =>
      ["serious", "critical"].includes(v.impact ?? "")
    )
    expect(serious).toEqual([])
  })

  test("axe: open create panel has no serious or critical violations", async () => {
    await gotoTeams(page)

    await page.getByRole("button", {name: "Create Team"}).click()
    await expect(page.locator("ash-admin-record-panel")).toBeVisible()

    const results = await new AxeBuilder({page})
      .withTags(["wcag2a", "wcag2aa", "wcag21a", "wcag21aa"])
      .analyze()

    const serious = results.violations.filter((v) =>
      ["serious", "critical"].includes(v.impact ?? "")
    )
    expect(serious).toEqual([])
  })
})
