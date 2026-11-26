defmodule AshEnterpriseWeb.Specs.Demo do
  @moduledoc """
  The clinic-demo tenant (`mix ash_enterprise.demo`). Its administrator, and
  the password every demo person signs in with.

  CI seeds the tenant with `--password-file`, so the password is random and
  lives only in that file, which E2E_DEMO_PASSWORD_FILE names. Without it the
  task's local default applies: `mix ash_enterprise.demo` with no
  `--password-file` sets `password1234`.
  """

  def admin, do: "demo-admin@example.com"

  def password do
    case System.get_env("E2E_DEMO_PASSWORD_FILE") do
      nil -> "password1234"
      file -> file |> File.read!() |> String.trim()
    end
  end
end
