defmodule AshEnterpriseWeb.Specs.StatusMessagesTest do
  use Playwright.Case, async: true

  import AshEnterpriseWeb.Specs.SignIn

  alias AshEnterpriseWeb.Specs.AxeBuilder

  # Status messages and the context band in a real browser (WCAG 2.2 SC 4.1.3,
  # https://www.w3.org/WAI/WCAG22/Understanding/status-messages.html).
  #
  # A status message is announced without moving focus, so its live region must
  # already be on the page when the message arrives: these tests find the region
  # before anything is said, then make the page say something while focus is in
  # the input, and check that focus never left it. The regions and the band pass
  # axe's WCAG 2.2 AA rules.
  #
  # Seed state: the tenant seeder's administrator (admin@example.com).

  @email seed_admin().email
  @wcag22aa ["wcag2a", "wcag2aa", "wcag21a", "wcag21aa", "wcag22aa"]

  defp connected(page, path) do
    Page.goto!(page, path, wait_until: :networkidle)

    page
    |> Page.locator(".phx-connected")
    |> Locator.first()
    |> Locator.wait_for!(timeout: 15_000)
  end

  defp focused_id(page), do: Page.evaluate!(page, "() => document.activeElement?.id ?? null")

  defp shot(name), do: "#{System.get_env("E2E_SCREENSHOT_DIR", "test-results")}/#{name}.png"

  test "the context band names the tenant and the person signed in", %{page: page} do
    sign_in(page)
    connected(page, "/app/today")

    band = Page.locator(page, "#context-band")
    Expect.to_be_visible!(band)
    Expect.to_have_attribute!(Page.locator(page, "#context-tenant"), "data-tenant", "named")
    Expect.to_contain_text!(Page.locator(page, "#context-identity"), "Signed in as")
    Expect.to_contain_text!(Page.locator(page, "#context-identity"), @email)
    Expect.to_have_count!(Page.locator(page, "#context-impersonation"), 0)

    # Read as a definition list: each term with its value.
    Expect.to_match_aria_snapshot!(band, """
    - term: Tenant
    - definition
    - term: Signed in as
    - definition: #{@email}
    """)

    results =
      AxeBuilder.new(page)
      |> AxeBuilder.include("#context-band")
      |> AxeBuilder.with_tags(@wcag22aa)
      |> AxeBuilder.analyze!()

    assert results["violations"] == []
  end

  test "Today's status regions are on the page before they have anything to say", %{page: page} do
    sign_in(page)
    connected(page, "/app/today")

    for id <- ["inbox-notice", "brief-prompt"] do
      region = Page.locator(page, "##{id}-region")
      Expect.to_have_count!(region, 1)
      Expect.to_have_attribute!(region, "role", "status")
      # The role carries its own politeness; nothing overrides it.
      Expect.not_to_have_attribute!(region, "aria-live")
    end
  end

  test "the launcher announces what it found and keeps focus in the input", %{page: page} do
    sign_in(page)
    connected(page, "/app")

    region = Page.locator(page, "#launch-results")
    Expect.to_have_attribute!(region, "role", "status")
    # Present and silent before anything is typed.
    Expect.to_have_text!(region, "")

    input = Page.locator(page, "#launch-filter input[type=search]")
    Locator.click!(input)
    input_id = focused_id(page)
    assert input_id not in [:null, ""]

    # The filter leaves nothing on the grid: the region says so, focus stays put.
    Locator.press_sequentially!(input, "zz-no-such-thing")
    Expect.to_contain_text!(region, "No app or record matches")
    assert focused_id(page) == input_id

    # Enter looks the text up as a record; nothing is found, and focus still stays.
    Locator.press!(input, "Enter")
    Expect.to_be_visible!(Page.locator(page, "#launch-found"))
    Expect.to_contain_text!(region, "Records")
    Expect.to_contain_text!(region, "No app or record matches")
    assert focused_id(page) == input_id
    Expect.to_have_value!(input, "zz-no-such-thing")
    Page.screenshot!(page, path: shot("status_messages_launcher"))

    results =
      AxeBuilder.new(page)
      |> AxeBuilder.include("#launch-results")
      |> AxeBuilder.include("#launch-search-failed-region")
      |> AxeBuilder.include("#context-band")
      |> AxeBuilder.with_tags(@wcag22aa)
      |> AxeBuilder.analyze!()

    assert results["violations"] == []
  end
end
