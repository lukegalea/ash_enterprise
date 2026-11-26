defmodule AshEnterpriseWeb.Specs.A2uiAdminExperienceTest do
  use Playwright.Case, async: true

  import AshEnterpriseWeb.Specs.SignIn

  alias AshEnterpriseWeb.Specs.AxeBuilder

  # The A2UI experience layer (v2 + admin catalog) on a real surface.
  #
  # Target surface: /app/teams. Deliberately NOT /app/users -- that surface is
  # browse-only (the users table has no form component, and the User resource's
  # write actions are the authentication flows, not a generic update), so it
  # cannot exercise the create/view/edit task modes. Teams declares a form with
  # both actions, which is what the task-mode contract needs.
  #
  # Everything below asserts INSIDE the Lit components: the renderer uses open
  # shadow roots and Playwright's engines pierce those natively, so the
  # locators read the semantic components' rendered DOM (the `<table>` inside
  # `ash-admin-data-grid`, the `<dl>` inside `ash-admin-record-panel`, ...).
  # Inputs are found by their labels. The component ids
  # (`form_input_name`, `query_search_input`) are the encoder's contract, but the
  # `<id>-input` DOM ids the admin catalog derived from them are the renderer's
  # to assign: the pinned 1.0 renderer gives the element inside a form section its
  # own `a2ui-n<N>` id, so a label is the stable handle.
  #
  # Seed state: the tenant seeder provisions one team ("Example Corp (All
  # Users)"). The edit flow runs against a team THIS spec creates, so the run
  # is repeatable; it leaves its QA team behind (the surface has no delete
  # row action -- destroying data is out of scope for a browse tier).

  @wcag22aa ["wcag2a", "wcag2aa", "wcag21a", "wcag21aa", "wcag22aa"]

  # The surface mounts over a LiveView push-event round trip, so the grid is
  # what says the page is ready. Not `networkidle`: the live connection can
  # keep the network busy past any idle window, and the wait then never ends.
  defp name_input(page) do
    page
    |> Page.locator("ash-admin-record-panel")
    |> Locator.get_by_role(:textbox, name: "Name", exact: true)
  end

  defp goto_teams(page) do
    Page.goto!(page, "/app/teams")
    grid = Page.locator(page, "ash-admin-data-grid table")
    Expect.to_be_visible!(grid, timeout: 15_000)
  end

  defp serious(results) do
    Enum.filter(results["violations"], &(&1["impact"] in ["serious", "critical"]))
  end

  # Serial in the JS spec, but its tests share nothing: each signs in on a
  # context of its own (Playwright.Case's, an explicit one, as AxeBuilder needs).
  describe "a2ui admin experience" do
    setup %{page: page} do
      sign_in(page)
      :ok
    end

    test "entity page renders a semantic admin surface", %{page: page} do
      goto_teams(page)

      # The page shell is the semantic EntityPage, and the grid is a REAL
      # table with an accessible name derived from the surface's collection
      # label.
      Expect.to_be_visible!(Page.locator(page, "ash-admin-entity-page"))
      table = Page.locator(page, "ash-admin-data-grid table")
      Expect.to_be_visible!(table)
      Expect.to_have_attribute!(table, "aria-label", "team")
      Expect.to_contain_text!(Locator.locator(table, "thead th"), ["Name", "Team type"])

      # Row identity is stable: each row carries the record id in its DOM id.
      first_row = table |> Locator.locator("tbody tr") |> Locator.first()
      row_id = Locator.get_attribute!(first_row, "id")
      assert row_id =~ ~r/^row-[0-9a-f-]+$/
      Page.wait_for_timeout!(page, 500)
      assert Locator.get_attribute!(first_row, "id") == row_id
    end

    test "no pagination chrome for the small dataset", %{page: page} do
      goto_teams(page)

      # One seeded team, page size 25: the semantic Pagination is bound but
      # renders nothing when the query state says visible=false. The element
      # exists in the tree; the CHROME must not.
      Expect.not_to_be_visible!(Page.locator(page, "ash-admin-pagination"))
      Expect.not_to_be_visible!(Page.locator(page, "ash-admin-empty-state"))
    end

    test "create flow: affordance, labeled panel, cancel returns to browse", %{page: page} do
      goto_teams(page)

      # No panel while browsing.
      Expect.not_to_be_visible!(Page.locator(page, "ash-admin-record-panel"))

      page |> Page.get_by_role(:button, name: "Create team") |> Locator.click!()
      panel = Page.locator(page, "ash-admin-record-panel")
      Expect.to_be_visible!(panel)

      # Mode heading: an accessible, focused panel title.
      Expect.to_have_attribute!(
        Locator.locator(panel, "section.panel"),
        "aria-label",
        "Create team"
      )

      Expect.to_have_text!(Locator.locator(panel, "[data-panel-heading]"), "Create team")

      # The primary action is the action bar's own button -- distinct from the
      # page-level create affordance.
      page
      |> Page.locator("ash-admin-action-bar")
      |> Locator.get_by_role(:button, name: "Create team")
      |> Expect.to_be_visible!()

      # Cancel returns to browse.
      page
      |> Page.locator("ash-admin-action-bar")
      |> Locator.get_by_role(:button, name: "Cancel")
      |> Locator.click!()

      Expect.not_to_be_visible!(panel)
    end

    test "view flow: read-only definition list, no submit control", %{page: page} do
      goto_teams(page)

      page |> Page.get_by_role(:button, name: "View") |> Locator.first() |> Locator.click!()
      panel = Page.locator(page, "ash-admin-record-panel")
      Expect.to_be_visible!(panel)

      Expect.to_have_attribute!(
        Locator.locator(panel, "section.panel"),
        "aria-label",
        "View team"
      )

      # Read-only values render as a definition list of field displays -- text
      # semantics, never disabled inputs.
      fields = Locator.locator(panel, "dl.panel-fields")
      Expect.to_be_visible!(fields)

      Expect.to_be_visible!(
        fields
        |> Locator.locator("ash-admin-field-display")
        |> Locator.first()
      )

      Expect.to_have_count!(Locator.locator(panel, "input, select, textarea"), 0)

      # And no submit control anywhere in view mode.
      page
      |> Page.locator("ash-admin-action-bar")
      |> Locator.get_by_role(:button, name: ~r/Save|Create/)
      |> Expect.to_have_count!(0)
    end

    test "edit flow: save changes round-trip lands with typed feedback", %{page: page} do
      goto_teams(page)

      # Create a team of our own so the edit target is deterministic and the
      # seeded tenant data is not renamed out from under the next run.
      team_name = "QA Team #{System.system_time(:millisecond)}"

      page |> Page.get_by_role(:button, name: "Create team") |> Locator.click!()
      page |> name_input() |> Locator.fill!(team_name)

      page
      |> Page.locator("ash-admin-action-bar")
      |> Locator.get_by_role(:button, name: "Create team")
      |> Locator.click!()

      banner = Page.locator(page, "ash-admin-status-banner")
      Expect.to_be_visible!(banner)
      Expect.to_contain_text!(banner, "Created successfully")

      # The success path closes the panel and refreshes the collection.
      Expect.not_to_be_visible!(Page.locator(page, "ash-admin-record-panel"))

      created_row =
        page
        |> Page.locator("ash-admin-data-grid tbody tr")
        |> Locator.filter(has_text: team_name)

      Expect.to_have_count!(created_row, 1)

      # Edit it: the panel opens in edit mode with the record's values.
      created_row |> Locator.get_by_role(:button, name: "Edit") |> Locator.click!()
      panel = Page.locator(page, "ash-admin-record-panel")

      Expect.to_have_attribute!(
        Locator.locator(panel, "section.panel"),
        "aria-label",
        "Edit team"
      )

      Expect.to_have_value!(name_input(page), team_name)

      # A real edit round-trip.
      renamed = "#{team_name} (renamed)"
      page |> name_input() |> Locator.fill!(renamed)

      page
      |> Page.locator("ash-admin-action-bar")
      |> Locator.get_by_role(:button, name: "Save changes")
      |> Locator.click!()

      Expect.to_be_visible!(banner)
      Expect.to_contain_text!(banner, "Updated successfully")
      Expect.not_to_be_visible!(Page.locator(page, "ash-admin-record-panel"))

      page
      |> Page.locator("ash-admin-data-grid tbody tr")
      |> Locator.filter(has_text: renamed)
      |> Expect.to_have_count!(1)
    end

    test "empty state replaces the grid for a nonsense search", %{page: page} do
      goto_teams(page)

      page
      |> Page.get_by_role(:textbox, name: "Search", exact: true)
      |> Locator.fill!("zzz-no-such-team-zzz")

      page |> Page.get_by_text("Apply", exact: true) |> Locator.click!()

      empty = Page.locator(page, "ash-admin-empty-state")
      Expect.to_be_visible!(empty)
      Expect.to_contain_text!(empty, "No team records yet.")

      # Still no pagination chrome -- and no rows.
      Expect.not_to_be_visible!(Page.locator(page, "ash-admin-pagination"))
      Expect.to_have_count!(Page.locator(page, "ash-admin-data-grid tbody tr"), 0)
    end

    test "axe: browse state has no serious or critical violations", %{page: page} do
      goto_teams(page)

      results = AxeBuilder.new(page) |> AxeBuilder.with_tags(@wcag22aa) |> AxeBuilder.analyze!()

      assert serious(results) == []
    end

    test "axe: open create panel has no serious or critical violations", %{page: page} do
      goto_teams(page)

      page |> Page.get_by_role(:button, name: "Create team") |> Locator.click!()
      Expect.to_be_visible!(Page.locator(page, "ash-admin-record-panel"))

      results = AxeBuilder.new(page) |> AxeBuilder.with_tags(@wcag22aa) |> AxeBuilder.analyze!()

      assert serious(results) == []
    end
  end
end
