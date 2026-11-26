defmodule AshEnterpriseWeb.Specs.FlightViewTest do
  use Playwright.Case, async: true

  import AshEnterpriseWeb.Specs.SignIn

  # The process flight view in a real browser (PROD-10): mermaid loads on
  # demand (`loadMermaid`, its own bundle), draws the `morning.brief` process
  # as an SVG, and the live marker sits on the approval step.
  #
  # Seed state: the tenant seeder's administrator (admin@example.com) with
  # today's morning brief composed, so its run waits at "Approve the brief" —
  # `mix ash_enterprise.bpmn.publish`, then compose the brief from /app/today
  # (this spec composes it if the page offers the button).

  test "the brief approval flight view draws the process with its marker", %{page: page} do
    sign_in(page)

    Page.goto!(page, "/app/today", wait_until: :networkidle)
    compose = Page.locator(page, "#compose-brief")

    if match?({:ok, true}, Locator.is_visible(compose)) do
      Locator.click!(compose)
      Page.wait_for_timeout!(page, 2_000)
    end

    Page.goto!(page, "/app/flights/briefs", wait_until: :networkidle)

    diagram = Page.locator(page, "ash-admin-live-diagram")
    Expect.to_be_visible!(diagram, timeout: 15_000)

    # Mermaid drew the process: an SVG holding the definition's own step names.
    svg = diagram |> Locator.locator("svg") |> Locator.first()
    Expect.to_be_visible!(svg, timeout: 20_000)
    Expect.to_contain_text!(svg, "Approve the brief")

    # The live marker: waiting, on the approval step.
    marker = diagram |> Locator.locator(~s(.marker[data-status="waiting"])) |> Locator.first()
    Expect.to_be_visible!(marker)

    Page.screenshot!(page,
      path: System.get_env("E2E_SCREENSHOT", "test-results/flight_view.png"),
      full_page: true
    )

    # The marker opens that run's own flight view, through the deep link.
    Locator.click!(marker)
    Page.wait_for_url!(page, ~r/\/app\/flights\?ctx/, timeout: 15_000)

    run = Page.locator(page, "ash-admin-live-diagram")

    Expect.to_contain_text!(run |> Locator.locator("svg") |> Locator.first(), "Approve the brief",
      timeout: 20_000
    )

    Expect.to_have_count!(Locator.locator(run, ~s(.marker[data-status="waiting"])), 1)
  end
end
