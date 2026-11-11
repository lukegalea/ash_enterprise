defmodule AshEnterpriseTelemetry.MixProject do
  @moduledoc """
  Runtime observability for Ash and Phoenix applications: one setup call that
  attaches tracing, correlation, background-job context, a browser span ingest
  and error reporting in the order those pieces depend on.

  A sparse package of the ash_enterprise repository: it has no dependency on
  the ash_enterprise application, so any application can take it as a
  `sparse: "telemetry"` git dependency. Run its own suite from this directory.
  """

  use Mix.Project

  def project do
    [
      app: :ash_enterprise_telemetry,
      version: "0.1.0",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {AshEnterprise.Telemetry.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # --- The OpenTelemetry pipeline -------------------------------------------
      {:opentelemetry, "~> 1.5"},
      {:opentelemetry_api, "~> 1.4"},
      {:opentelemetry_exporter, "~> 1.8"},
      # OTLP logs and metrics. Pre-1.0 upstream; the wiring in this package is
      # the only place that touches it.
      {:opentelemetry_experimental, "~> 0.6"},
      {:opentelemetry_api_experimental, "~> 0.6"},

      # --- Instrumentation libraries --------------------------------------------
      {:opentelemetry_ash, "~> 0.1"},
      {:opentelemetry_bandit, "~> 0.3"},
      {:opentelemetry_phoenix, "~> 2.0"},
      {:opentelemetry_ecto, "~> 1.2"},
      {:opentelemetry_oban, "~> 1.2"},
      {:opentelemetry_req, "~> 1.0"},
      {:opentelemetry_telemetry, "~> 1.1"},

      # --- Error reporting and background metrics --------------------------------
      {:sentry, "~> 14.0"},
      {:telemetry_poller, "~> 1.0"},

      # --- Platform -------------------------------------------------------------
      {:oban, "~> 2.19"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, ">= 0.0.0"},
      {:plug, "~> 1.16"},
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:nimble_options, "~> 1.1"},
      {:ash, "~> 3.0"},

      # --- Test only: a real LiveView and Bandit endpoint ------------------------
      {:phoenix, "~> 1.8", only: :test},
      {:phoenix_live_view, "~> 1.1", only: :test},
      {:bandit, "~> 1.5", only: :test},
      {:lazy_html, ">= 0.1.0", only: :test}
    ]
  end
end
