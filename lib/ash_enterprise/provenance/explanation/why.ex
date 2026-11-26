defmodule AshEnterprise.Provenance.Explanation.Why do
  @moduledoc """
  `AshEnterprise.Provenance.Explanation`'s `why`: `explain`, read as rows
  (`AshEnterprise.Provenance.Why`). It answers through `explain`, so the tenant
  rule and every read the walk makes as the reader are `explain`'s.
  """

  use Ash.Resource.Actions.Implementation

  alias AshEnterprise.Provenance.Explanation.Explain
  alias AshEnterprise.Provenance.Why

  @impl true
  def run(input, opts, context) do
    with {:ok, %{explanation: explanation, correlation_ids: correlation_ids}} <-
           Explain.run(input, opts, context) do
      {:ok, Why.rows(explanation, correlation_ids)}
    end
  end
end
