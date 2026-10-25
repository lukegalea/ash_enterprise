defmodule Battery.Repo do
  @moduledoc """
  The battery's own repo: every reference-instantiated resource (judgments
  ledger and facts, BPMN graphs, DMN definitions, the BIZEV raw layer and
  ledger, the MDM tables, the compliance plane) lives on this repo, in the
  battery's own database. The evidence resources ride the package's own
  repo module (`AshEvidence.Repo`), pointed at the same database in
  `config/test.exs` — the posture ash_evidence's host-wiring contract
  prescribes.
  """

  use AshPostgres.Repo, otp_app: :ash_enterprise_battery, warn_on_missing_ash_functions?: false

  def installed_extensions,
    do: ["uuid-ossp", "citext", "ash-functions", "btree_gist", "vector"]

  def min_pg_version, do: %Version{major: 18, minor: 0, patch: 0}
end
