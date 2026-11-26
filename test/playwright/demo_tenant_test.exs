defmodule AshEnterpriseWeb.Specs.DemoTenantTest do
  use Playwright.Case, async: true

  import AshEnterpriseWeb.Specs.SignIn

  alias AshEnterpriseWeb.Specs.Demo

  # The seed every clinic spec stands on: the demo administrator signs in with
  # the demo password (support/demo.ex), the credentialing tour lists its
  # beats, and the fault panel is there, because the dev config compiles the
  # fault points in and turns the panel on. A spec that drives a fault (the
  # worker killed after the registry accepts, the outcome unknown until the
  # sweep settles it) fails here first, by name, when either is missing.
  #
  # Seed state: `mix ash_enterprise.demo`, with `--password-file` in CI.

  test "the demo administrator reaches the credentialing tour and its fault panel", %{page: page} do
    sign_in(page, %{email: Demo.admin(), password: Demo.password()})

    Page.goto!(page, "/app/showcase/credentialing", wait_until: :networkidle)
    Expect.to_be_visible!(Page.locator(page, "#beats"), timeout: 15_000)

    panel = Page.locator(page, "#fault-panel")
    Expect.to_be_visible!(panel)
    Expect.to_be_visible!(Locator.locator(panel, "#fault-kill"))
  end
end
