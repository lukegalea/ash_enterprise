defmodule AshEnterpriseWeb.Specs.ShellTest do
  use Playwright.Case, async: true

  import AshEnterpriseWeb.Specs.SignIn

  # The command palette (ctrl+p) and surface launcher (ctrl+k) in a real
  # browser (PROD-36): the keys open them from any page, the arrows and enter
  # work, `/open calendar` navigates, and a typed line reaches the agent.
  #
  # Seed state: the tenant seeder's administrator (admin@example.com).

  defp connected(page, path) do
    Page.goto!(page, path, wait_until: :networkidle)

    page
    |> Page.locator(".phx-connected")
    |> Locator.first()
    |> Locator.wait_for!(timeout: 15_000)
  end

  defp shot(name), do: "#{System.get_env("E2E_SCREENSHOT_DIR", "test-results")}/#{name}.png"

  test "ctrl+k opens the launcher, filters, and enter opens the surface", %{page: page} do
    sign_in(page)
    connected(page, "/app/today")

    page |> Page.keyboard() |> Keyboard.press!("Control+k")
    dialog = Page.locator(page, "#a2ui-shell-dialog")
    Expect.to_be_visible!(dialog)
    Expect.to_be_focused!(Page.locator(page, "#a2ui-shell-input"))
    Expect.to_contain_text!(dialog, "Time travel")
    Expect.to_contain_text!(dialog, "Lineage")
    Page.screenshot!(page, path: shot("shell_launcher"))

    page |> Page.keyboard() |> Keyboard.type!("time trav")
    Expect.to_contain_text!(Page.locator(page, "#a2ui-shell-item-0"), "Time travel")
    Expect.to_have_count!(Page.locator(page, "#a2ui-shell-item-1"), 0)
    page |> Page.keyboard() |> Keyboard.press!("Enter")
    Page.wait_for_url!(page, ~r/\/app\/time-travel/, timeout: 15_000)
  end

  test "ctrl+p opens the palette; the arrows move; escape closes", %{page: page} do
    sign_in(page)
    connected(page, "/app/calendar")

    page |> Page.keyboard() |> Keyboard.press!("Control+p")
    dialog = Page.locator(page, "#a2ui-shell-dialog")
    Expect.to_be_visible!(dialog)
    Expect.to_contain_text!(dialog, "/today")
    Expect.to_contain_text!(dialog, "/approvals")
    Expect.to_be_visible!(Page.locator(page, ~s(#a2ui-shell-item-0[aria-selected="true"])))

    page |> Page.keyboard() |> Keyboard.press!("ArrowDown")
    Expect.to_be_visible!(Page.locator(page, ~s(#a2ui-shell-item-1[aria-selected="true"])))
    Page.screenshot!(page, path: shot("shell_palette"))

    page |> Page.keyboard() |> Keyboard.press!("Escape")
    Expect.to_have_count!(dialog, 0)
  end

  test "/open calendar navigates, and a typed line goes to the agent", %{page: page} do
    sign_in(page)
    connected(page, "/app")

    page |> Page.keyboard() |> Keyboard.press!("Control+p")
    page |> Page.keyboard() |> Keyboard.type!("/open calendar")
    Expect.to_contain_text!(Page.locator(page, "#a2ui-shell-item-0"), "Open Calendar")
    page |> Page.keyboard() |> Keyboard.press!("Enter")
    Page.wait_for_url!(page, ~r/\/app\/calendar$/, timeout: 15_000)

    page
    |> Page.locator(".phx-connected")
    |> Locator.first()
    |> Locator.wait_for!(timeout: 15_000)

    page |> Page.locator("#nav-palette") |> Locator.click!()
    page |> Page.keyboard() |> Keyboard.type!("what is on today")
    Expect.to_contain_text!(Page.locator(page, "#a2ui-shell-dialog"), "Ask the agent")
    page |> Page.keyboard() |> Keyboard.press!("Enter")
    Page.wait_for_url!(page, ~r/\/app\/agent/, timeout: 15_000)
  end
end
