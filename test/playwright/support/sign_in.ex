defmodule AshEnterpriseWeb.Specs.SignIn do
  @moduledoc false

  alias Playwright.Locator
  alias Playwright.Page

  @doc "The tenant seeder's administrator (`mix ash_enterprise.seed`)."
  def seed_admin, do: %{email: "admin@example.com", password: "password1234"}

  @doc """
  Signs in through the sign-in page. The form is a LiveView: it is filled once
  it has connected, or the connected render resets the inputs and the submit
  goes out empty.
  """
  def sign_in(page, %{email: email, password: password} \\ seed_admin()) do
    Page.goto!(page, "/sign-in", wait_until: :networkidle)

    page
    |> Page.locator(".phx-connected")
    |> Locator.first()
    |> Locator.wait_for!(timeout: 15_000)

    Page.fill!(page, ~s(input[type="email"]), email)
    Page.fill!(page, ~s(input[type="password"]), password)
    Page.click!(page, ~s(button[type="submit"]))
    Page.wait_for_url!(page, &(!String.contains?(&1.path, "sign-in")), timeout: 15_000)
  end
end
