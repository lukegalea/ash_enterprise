defmodule AshEnterpriseBattery.MixProject do
  @moduledoc """
  The cross-substrate integration battery for the ash_enterprise platform
  (ADR 0009 family): the flows that span two or more ash_* substrate
  packages, exercised against the battery's OWN reference instantiation of
  those substrates. Single-dep semantics live in each dep's own suite; this
  app exists to prove the seams.

  Run it with `mix platform_battery` from this directory.
  """

  use Mix.Project

  def project do
    [
      app: :ash_enterprise_battery,
      version: "0.1.0",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      cli: cli()
    ]
  end

  def cli do
    [preferred_envs: [platform_battery: :test]]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # The 9 substrate deps, pinned exactly as ash_enterprise pins them
  # (same refs, so the battery resolves the same code the platform ships).
  # ash_events carries the platform's `override: true` fork declaration:
  # one package cannot resolve from both hex and git.
  defp deps do
    [
      # --- The judgment substrate (System One) --------------------------------
      {:ash_judgments, github: "lukegalea/ash_judgments", branch: "main"},
      # --- The evidence pipeline substrate (System One adjudication) ----------
      {:ash_evidence, github: "lukegalea/ash_evidence", branch: "main"},
      # --- Rules engine and the compliance plane it powers --------------------
      {:ash_rules, github: "lukegalea/ash_rules"},
      {:ash_compliance, github: "lukegalea/ash_compliance"},
      # --- Business processes and the decisions they route on -----------------
      # NOTE: ash_decisions brings boxic_dmn, which shells out to `xmllint`:
      # libxml2 must be on PATH (the devenv provides it).
      {:ash_bpmn, github: "lukegalea/ash_bpmn"},
      {:ash_decisions, github: "lukegalea/ash_decisions"},
      # --- The business-event ledger (BIZEV) -----------------------------------
      {:ash_discrete_business_events, github: "lukegalea/ash_discrete_business_events"},
      # --- Master data management (builds on the BIZEV raw layer) -------------
      {:ash_mdm, github: "lukegalea/ash_mdm"},
      # --- AshEvents (the audit log extension) ---------------------------------
      {:ash_events,
       github: "lukegalea/ash_events", branch: "temporal-as-of-support-0.7", override: true},

      # --- Platform base --------------------------------------------------------
      {:ash_postgres, "~> 2.0"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, ">= 0.0.0"},
      {:jason, "~> 1.4"},

      # Not optional: Ash's policy authorizer needs a SAT solver (the
      # platform pins the same).
      {:picosat_elixir, "~> 0.2"},

      # ash_judgments' telemetry metrics surface imports Telemetry.Metrics
      # unconditionally (it is an "optional" dep there, but the import is
      # not guarded) — the battery declares it like the platform does.
      {:telemetry_metrics, "~> 1.0"},

      # Formatter only: .formatter.exs runs Spark.Formatter, as the root does,
      # and Spark.Formatter needs sourceror. Declared as the platform declares it.
      {:sourceror, "~> 1.8", only: [:dev, :test]}
    ]
  end
end
