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
      # `Rows` and `Tables` live in `lib/` and call modules this package only
      # takes for its own suite: `ash` is `only: :test` here, and `ash_a2ui` is
      # optional on top of that. Compiling anywhere those are absent emits
      # "Ash.Query.for_read/2 is undefined" and friends — true, harmless, and
      # fatal under the `mix compile --warnings-as-errors` that hosts gate on.
      elixirc_options: [
        no_warn_undefined: [Ash, Ash.Query, AshA2ui.Manifest]
      ],
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
      {:fluffy, "~> 0.9.0-rc.7"},
      {:playwright, "~> 1.65.0-rc.6", hex: :playwright_ex},
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
      {:opentelemetry_api, "~> 1.4"},

      # --- A2UI, optional ------------------------------------------------------------
      # `Rows` and `Tables` call `AshA2ui.Manifest.visible?/2` and
      # `filter_input/1` — pure functions over manifest data — so the table and
      # row generators need it present. `optional: true` keeps it out of the
      # dependency graph of a host driving a plain Phoenix application, and
      # defers to the host's own pin where there is one rather than forcing this
      # version on it.
      #
      # `only: :test` to match `:ash` below, which `ash_a2ui` itself requires
      # unrestricted: an environment that has `ash_a2ui` and not `ash` does not
      # resolve. Everything here is test-only in a host anyway.
      #
      # Deliberately a dependency of the *test harness* on the UI library, never
      # the reverse: `ash_a2ui` must not grow a dependency on
      # `fluffy` and `bandit` in order to be testable.
      {:ash_a2ui, github: "lukegalea/ash_a2ui", optional: true, only: :test}
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
