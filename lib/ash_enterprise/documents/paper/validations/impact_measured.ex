defmodule AshEnterprise.Documents.Paper.Validations.ImpactMeasured do
  @moduledoc """
  The checker decides on a measured change: a clause version is admitted only
  when its `impact_report` was measured for exactly this version (its content
  hash) and no document in it failed (`AshEnterprise.Documents.Paper.Impact.gate/2`).

  A missing report, an errored one, a stale one (measured for another content
  hash), a malformed one, a case with an unknown outcome, or any `failed` case
  refuses, saying which. Zero affected documents is a measured report and
  admits. A validation of the action, never a `forbid_if` on rows; the clause
  table's publish applies the same gate through
  `AshEnterprise.Documents.Paper.ClauseTableVerifier`.
  """

  use Ash.Resource.Validation

  alias AshEnterprise.Documents.Paper.Impact

  @impl true
  def validate(changeset, _opts, _context) do
    data = changeset.data

    case Impact.gate(Map.get(data, :impact_report), Map.get(data, :content_hash)) do
      :ok -> :ok
      {:error, reason} -> {:error, field: :impact_report, message: Impact.refusal(reason)}
    end
  end
end
