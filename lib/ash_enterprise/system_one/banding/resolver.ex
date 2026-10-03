defmodule AshEnterprise.SystemOne.Banding.Resolver do
  @moduledoc """
  The default host band-table resolver: WHICH versioned band table runs
  for a family, evaluated through `ash_decisions` (ADR 0041 — tenant-aware
  resolution is host-side, the `Process.DecisionResolver` seam pattern).

  For `(family, tenant, inputs)` it resolves the published definition,
  evaluates it through `AshEnterprise.Decisions.evaluate/3` (which records
  the `Evaluation` row — the banding's `decision_evaluation_id` — with the
  host's correlation attribution), and returns the evaluation map the
  banding step consumes:

      %{
        band_table: %{
          "definition_key" => key, "definition_version" => version,
          "content_hash" => hash, "definition_id" => id, "tenant_fork" => nil
        },
        outputs: %{...},                       # the DMN outputs (band contract)
        matched_rule_ids: [...],               # Evaluation.matched_rule_ids — empty is a refusal
        decision_evaluation_id: uuid
      }

  The definition-key convention: the band table for family `F` is the
  definition `judgments_band_<F with dots as underscores>` (the
  `judgments:family:<F>` tagging from `AshJudgments.Bridge.Dmn.band_contract/0`,
  spelled as a definition key). Override per family with
  `config :ash_enterprise, :band_table_keys, %{family => key}`.

  Tests stub the whole seam (an arity-3 function); this module exists so
  the live path is compile-checked and one place.
  """

  require Ash.Query

  alias AshEnterprise.Decisions
  alias AshEnterprise.Process.Resolver

  @spec band_table(String.t(), term(), map()) ::
          {:ok, map()} | {:error, term()}
  def band_table(family, tenant, inputs) do
    key = band_table_key(family)

    with {:ok, definition} <- Resolver.resolve(:decision, key, tenant),
         {:ok, result} <-
           Decisions.evaluate(key, inputs,
             tenant: tenant,
             record: true
           ),
         {:ok, recorded} <- recorded_evaluation(key, tenant) do
      # matched_rule_ids and the evaluation id come from the RECORDED row
      # (the evidence), not from the in-memory result: the banding stores
      # what the Evaluation proves.
      {:ok,
       %{
         band_table: %{
           "definition_key" => recorded.definition_key,
           "definition_version" => to_string(recorded.definition_version),
           "content_hash" => definition_content_hash(definition),
           "definition_id" => recorded.definition_id,
           "tenant_fork" => nil
         },
         outputs: result.outputs,
         matched_rule_ids: recorded.matched_rule_ids,
         decision_evaluation_id: recorded.id
       }}
    end
  end

  # The just-recorded Evaluation row: latest for the definition key in the
  # tenant. The evaluator records inside evaluate/3, so "latest" is this
  # call's row on any sane clock; the in-memory result carries the same
  # matched rules and is used only as the fallback when the row cannot be
  # read back.
  defp recorded_evaluation(definition_key, tenant) do
    AshEnterprise.Decisions.Evaluation
    |> Ash.Query.filter(definition_key == ^definition_key)
    |> Ash.Query.sort(created_on: :desc)
    |> Ash.read_one!(tenant: tenant, authorize?: false)
    |> case do
      nil -> {:error, "the band-table evaluation was not recorded (definition #{definition_key})"}
      evaluation -> {:ok, evaluation}
    end
  end

  @doc """
  The definition key the family's band table publishes under - the same
  key the publication flow (S1-62) and this resolver both resolve.
  """
  def band_table_key(family) do
    configured = Application.get_env(:ash_enterprise, :band_table_keys, %{})
    Map.get(configured, family, "judgments_band_#{String.replace(family, ".", "_")}")
  end

  defp definition_content_hash(definition) do
    Map.get(definition, :content_hash) || Map.get(definition, "content_hash")
  end
end
