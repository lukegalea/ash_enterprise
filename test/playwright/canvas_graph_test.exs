defmodule AshEnterpriseWeb.Specs.CanvasGraphTest do
  use Playwright.Case, async: true

  import AshEnterpriseWeb.Specs.SignIn

  alias AshEnterpriseWeb.Specs.AxeBuilder

  # The dev-only /canvas surface: the `<ash-canvas-graph>` element (renderer
  # lane) renders the accessible tree; selection resolves a naked object
  # server-side and the server-rendered inspector shows it.
  #
  # Names pinned by docs/plans/2026-09-09-canvas-host-contract.md:
  # `role="tree"` / `role="treeitem"` with `data-id` + `aria-selected`; the
  # `canvas:select` client event; the `#canvas-inspector` region. Playwright's
  # engines pierce the element's open shadow roots natively.
  #
  # Progressive disclosure is part of the assertion: no record treeitem may
  # exist anywhere in the tree.

  describe "canvas graph" do
    setup %{page: page} do
      sign_in(page)

      Page.goto!(page, "/canvas", wait_until: :networkidle)
      # The element receives the graph payload over the LiveView push_event.
      tree = Page.locator(page, ~s([role="tree"]))
      Expect.to_be_visible!(tree, timeout: 15_000)
      :ok
    end

    test "renders domain and resource treeitems", %{page: page} do
      treeitems = Page.locator(page, ~s([role="treeitem"][data-id]))
      count = Locator.count!(treeitems)
      assert count > 0

      # Domain and resource kinds are both present (the payload's two most
      # numerous kinds); ids carry the contract's opaque-ref prefixes.
      ids =
        for i <- 0..(count - 1)//1 do
          treeitems |> Locator.nth(i) |> Locator.get_attribute!("data-id")
        end

      assert Enum.any?(ids, &String.starts_with?(&1, "domain:"))
      assert Enum.any?(ids, &String.starts_with?(&1, "resource:"))
    end

    test "no record treeitems exist", %{page: page} do
      treeitems = Page.locator(page, ~s([role="treeitem"][data-id]))
      count = Locator.count!(treeitems)

      for i <- 0..(count - 1)//1 do
        id = treeitems |> Locator.nth(i) |> Locator.get_attribute!("data-id")
        refute id =~ ~r/^record:/
      end
    end

    test "clicking a resource treeitem opens the inspector", %{page: page} do
      resource_item =
        page
        |> Page.locator(~s([role="treeitem"][data-id^="resource:"]))
        |> Locator.first()

      data_id = Locator.get_attribute!(resource_item, "data-id")
      Locator.click!(resource_item)
      Expect.to_have_attribute!(resource_item, "aria-selected", "true")

      inspector = Page.locator(page, "#canvas-inspector")
      Expect.to_be_visible!(inspector)
      Expect.to_contain_text!(inspector, "Capabilities")
      Expect.to_contain_text!(inspector, "Projections")
      Expect.to_contain_text!(inspector, data_id)
    end

    test "keyboard selection opens the inspector", %{page: page} do
      resource_item =
        page
        |> Page.locator(~s([role="treeitem"][data-id^="resource:"]))
        |> Locator.first()

      Locator.focus!(resource_item)
      page |> Page.keyboard() |> Keyboard.press!("Enter")
      Expect.to_have_attribute!(resource_item, "aria-selected", "true")

      inspector = Page.locator(page, "#canvas-inspector")
      Expect.to_contain_text!(inspector, "Capabilities")
    end

    test "axe: the canvas surface has no serious or critical violations", %{page: page} do
      results =
        AxeBuilder.new(page)
        |> AxeBuilder.with_tags(["wcag2a", "wcag2aa", "wcag21a", "wcag21aa", "wcag22aa"])
        |> AxeBuilder.analyze!()

      # Violations INSIDE <ash-canvas-graph> belong to the renderer lane (see
      # the lane-ownership split in the contract) and are asserted at the
      # combined verification; this scan holds the host-owned page to the
      # same bar.
      serious =
        results["violations"]
        |> Enum.filter(&(&1["impact"] in ["serious", "critical"]))
        |> Enum.reject(fn v ->
          Enum.all?(v["nodes"], fn n ->
            Enum.any?(n["target"], &String.contains?(js_string(&1), "ash-canvas-graph"))
          end)
        end)

      assert serious == []
    end
  end

  # JS's String(t): a shadow DOM target is an array of selectors.
  defp js_string(target) when is_list(target), do: Enum.join(target, ",")
  defp js_string(target), do: target
end
