defmodule AshEnterprise.Documents.Paper.Impact.Rerender do
  @moduledoc """
  The re-rendering half of `AshEnterprise.Documents.Paper.Impact`: which
  issued runs a clause candidate is measured against, and each one's frozen
  inputs as a baseline for `AshPaper.Compare.compare/3`, which re-renders it
  as it was and with the candidate and compares the two block by block.

  A **sample** is what one render needs, frozen: the payload (display strings
  and typed facts), the theme, the layout, the resolved clauses it carried and
  its output digest, which the re-render must reproduce or the case is
  `:unreproducible` (`AshPaper.Compare`'s baseline control). `sample/1`
  rebuilds one from a run.
  """

  alias AshEnterprise.Documents.Paper
  alias AshEnterprise.Documents.{PaperClause, PaperRun}
  alias AshEnterprise.Erasure.Shredded

  require Ash.Query

  @result_keys [:outcome, :reason, :blocks, :collateral, :pages]

  @doc """
  The cases for clause candidate `clause`: the tenant's newest issued runs
  (rendered, read back passed) whose snapshot pins `clause`'s key in its
  locale, at most `cap`, each re-rendered with the candidate in its place.
  """
  @spec clause_cases(PaperClause.t(), term(), pos_integer()) ::
          {:ok, [map()], map()} | {:error, term()}
  def clause_cases(%PaperClause{} = clause, tenant, cap) do
    {runs, truncated?} = runs_carrying(clause.key, clause.locale, tenant, cap)
    cases = Enum.map(runs, &clause_case(&1, clause))
    {:ok, cases, %{taken: length(runs), truncated: truncated?}}
  end

  # Issued documents only, newest first, one more than the cap so a cut sample
  # is said, never silent. Read as the machinery: a person measuring wording
  # holds no grant on other people's runs, and the measure action they run is
  # the grant (the issue pipeline's own bound). The pins are the snapshot's own
  # definitions (`AshPaper.Snapshot`): a clause the document carried.
  defp runs_carrying(key, locale, tenant, cap) do
    pin = Jason.encode!([%{"kind" => "clause", "key" => "#{key}/#{locale}"}])

    runs =
      PaperRun
      |> Ash.Query.filter(
        stage == :issued and render_status == :rendered and read_back_status == :passed and
          fragment("((?)->'snapshot'->'definitions') @> ((?)::text)::jsonb", snapshot, ^pin)
      )
      |> Ash.Query.sort(created_on: :desc, id: :desc)
      |> Ash.Query.limit(cap + 1)
      |> Ash.Query.load([:payload, :facts])
      |> Ash.read!(tenant: tenant, authorize?: false)

    {Enum.take(runs, cap), length(runs) > cap}
  end

  # The run re-rendered with the candidate's wording in place of its key
  # (`clause:`), filled from the same payload: a hole the payload cannot fill
  # is the candidate's failure, a document that could no longer be issued.
  defp clause_case(run, clause) do
    case sample(run) do
      {:ok, sample} ->
        case AshPaper.Compare.compare(
               sample,
               [clause: PaperClause.to_kernel(clause)],
               Paper.limits()
             ) do
          {:ok, result} -> Map.merge(base(run, sample.title), Map.take(result, @result_keys))
          {:error, reason} -> outcome(base(run, sample.title), :failed, {:invalid_sample, reason})
        end

      {:unreproducible, reason} ->
        outcome(base(run, nil), :unreproducible, reason)
    end
  end

  @doc """
  The frozen inputs of an issued run as a sample, or
  `{:unreproducible, reason}`: its payload or facts erased (`:erased`), a kind
  the host no longer issues (`:unknown_kind`), a theme the host no longer has
  at the pinned hash (`:theme_gone`), or a payload missing a part
  (`:payload_incomplete`).
  """
  @spec sample(PaperRun.t()) :: {:ok, map()} | {:unreproducible, atom()}
  def sample(%PaperRun{} = run) do
    with {:ok, document} <- frozen(run.payload),
         {:ok, facts} <- frozen(run.facts),
         {:ok, schema, layout} <- definition(run.document_kind),
         {:ok, theme} <- pinned_theme(run.snapshot),
         {:ok, payload} <- payload(document, facts, schema) do
      {:ok,
       %{
         id: run.id,
         title: payload.title,
         payload: payload,
         theme: theme,
         layout: layout,
         clauses: AshPaper.Payload.document_clauses(document),
         digest: run.output_digest
       }}
    end
  end

  defp frozen(%Shredded{}), do: {:unreproducible, :erased}
  defp frozen(value) when is_map(value), do: {:ok, value}
  defp frozen(_absent), do: {:unreproducible, :erased}

  defp definition(kind) do
    case Paper.definition(kind) do
      {:ok, schema, layout, _theme} -> {:ok, schema, layout}
      {:error, _unknown} -> {:unreproducible, :unknown_kind}
    end
  end

  defp pinned_theme(snapshot) do
    with [%{"key" => key, "content_hash" => hash} | _] <-
           AshPaper.Snapshot.pinned(snapshot, :theme),
         %AshPaper.Theme{} = theme <- Paper.theme_by_key(key),
         true <- AshPaper.Theme.hash(theme) == hash do
      {:ok, theme}
    else
      _gone -> {:unreproducible, :theme_gone}
    end
  end

  # The document map the run sealed (`AshPaper.Payload.document/2`) and its
  # typed facts, back into the payload the render reads.
  defp payload(document, facts, schema) do
    case AshPaper.Payload.from_document(document, facts, schema) do
      {:ok, payload} -> {:ok, payload}
      {:error, _missing} -> {:unreproducible, :payload_incomplete}
    end
  end

  defp base(run, title) do
    %{
      run_id: run.id,
      issued_at: run.created_on,
      erasure_scope_id: run.erasure_scope_id,
      title: title,
      outcome: nil,
      reason: nil,
      blocks: [],
      collateral: [],
      pages: nil
    }
  end

  defp outcome(base, outcome, reason), do: %{base | outcome: outcome, reason: reason}
end
