defmodule AshEnterprise.SystemOne.BandTablePublication do
  @moduledoc """
  The activation flow for a family's band table (S1-62; RFC §8.2, ADR
  0041): the publish-time verifier runs FIRST — a person's certification,
  a compliant calibration run, the same model digest/runtime version/
  region, an eval-set hash, and a run young enough for the family — and
  only then does the ash_decisions lifecycle publish the definition.

  Nothing here certifies (the certification row is an INPUT — a person
  made it through the person-only certification resource), and nothing
  here activates by judgement: publishing is `ash_decisions`' own
  `:publish` action on a DRAFT definition, run under the caller's actor
  through the resource's ordinary policies. The banding step's resolver
  picks the published table up by its definition key
  (`judgments_band_<family>` — `Banding.Resolver.band_table_key/1`), so
  from this moment the family's live bandings flow through the earned
  thresholds.

  The verifier's refusal paths (`AshJudgments.Calibration.verify/4`):
  `:not_certified`, `:no_calibration_run`, `:n_below_min`,
  `:n_per_class_below_min`, digest/runtime mismatch, region mismatch,
  a missing eval-set hash, and run age — each returned as structured
  findings, never a guess.
  """

  require Ash.Query

  alias AshEnterprise.Decisions.Definition
  alias AshEnterprise.SystemOne.Banding.Resolver
  alias AshJudgments.Calibration

  @doc """
  Publishes a family's band-table definition after the publish-time
  verifier passes.

  `definition_ref` carries what the verifier matches against the run:
  `%{family:, model_digest:, runtime_version:, region:}` (the definition
  KEY is derived by the host convention — the same key the banding step's
  resolver resolves). `certification` and `run` are the person's
  certification row and the calibration run row. The actor is who
  publishes — a person; the definition's own policies govern.

  Returns `{:ok, published_definition}`, `{:error, {:not_verified,
  findings}}`, or `{:error, term}`.
  """
  @spec publish(map(), map() | nil, map() | nil, keyword()) ::
          {:ok, Definition.t()} | {:error, term()}
  def publish(definition_ref, certification, run, opts \\ []) do
    ref =
      definition_ref
      |> Map.new()
      |> Map.put(:definition_key, Resolver.band_table_key(definition_ref.family))

    publish_opts = Keyword.take(opts, [:actor, :tenant])

    with {:ok, draft} <- verified_definition(ref, certification, run) do
      {:ok, Definition.publish!(draft, %{}, publish_opts)}
    end
  end

  defp verified_definition(ref, certification, run) do
    with :ok <- Calibration.verify(ref, certification, run),
         {:ok, draft} <- draft_definition(ref.definition_key) do
      {:ok, draft}
    else
      {:error, findings} when is_list(findings) -> {:error, {:not_verified, findings}}
      {:error, error} -> {:error, error}
    end
  end

  defp draft_definition(key) do
    Definition
    |> Ash.Query.filter(key == ^key and status == ^:draft)
    |> Ash.Query.sort(version: :desc)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, nil} ->
        {:error,
         ArgumentError.exception(
           "no draft definition for #{key} — the proposed table's DMN draft is rendered " <>
             "by the calibration harness (S1-25) and saved before publication"
         )}

      {:ok, draft} ->
        {:ok, draft}

      {:error, error} ->
        {:error, error}
    end
  end
end
