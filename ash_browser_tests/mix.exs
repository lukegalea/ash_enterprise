defmodule AshBrowserTests.MixProject do
  @moduledoc """
  Reusable real-browser tests for Phoenix and Ash applications: a Playwright case
  template, a sandbox hook that needs no router change, trace assertions over
  OpenTelemetry spans, fake outbound services, and a generator that derives a test
  for every surface a host declares.

  A sparse package of the ash_enterprise repository, for `:test` only. Run its own
  suite from this directory (`README.md`).
  """

  use Mix.Project

  def project do
    [
      app: :ash_browser_tests,
      version: "0.1.0",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: false,
      deps: deps(),
      cli: cli()
    ]
  end

  def cli do
    [preferred_envs: ["ash_browser_tests.test": :test]]
  end

  def application do
    [extra_applications: [:logger, :crypto, :inets]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # --- The browser harness -----------------------------------------------------
      {:phoenix_test, "~> 0.14"},
      {:phoenix_test_playwright, "~> 0.19", runtime: false},
      {:playwright_ex, "~> 0.16"},
      {:phoenix, "~> 1.8"},
      {:phoenix_live_view, "~> 1.1"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},

      # --- Fakes and backend adapters ------------------------------------------------
      {:bandit, "~> 1.5"},
      {:plug, "~> 1.16"},
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:nimble_options, "~> 1.1"},
      {:opentelemetry_api, "~> 1.4"}
    ] ++ telemetry_dep() ++ fixture_deps()
  end

  # The trace helpers read this repository's telemetry package. A host that takes
  # this package as a sparse git dependency declares the telemetry package itself;
  # here, the sibling directory is present and the suite uses it by path.
  defp telemetry_dep do
    if File.exists?(Path.expand("../telemetry/mix.exs", __DIR__)) do
      [{:ash_enterprise_telemetry, path: "../telemetry", only: :test}]
    else
      []
    end
  end

  # The fixture application in test/support: a real Postgres resource behind a
  # real LiveView, so the chain assertions run against spans a browser produced.
  defp fixture_deps do
    [
      {:ash, "~> 3.0", only: :test},
      {:ash_postgres, "~> 2.6", only: :test},
      {:oban, "~> 2.19", only: :test},
      {:postgrex, ">= 0.0.0", only: :test}
    ]
  end
end
