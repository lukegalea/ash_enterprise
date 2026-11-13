defmodule Battery.Compliance.ArchivedEvidence do
  @moduledoc """
  The evidence archive (`ash_compliance`'s `{:evidence_archive, ...}`), named by
  `config :ash_compliance, evidence_archive:` so every read of evidence takes it with the
  hot table.
  """

  use Ash.Resource,
    domain: Battery.Domain,
    data_layer: AshPostgres.DataLayer

  use AshCompliance.Resources,
      {:evidence_archive, table: "battery_evidence_artifact_archive", repo: Battery.Repo}
end
