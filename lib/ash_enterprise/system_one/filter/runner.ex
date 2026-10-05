defmodule AshEnterprise.SystemOne.Filter.Runner do
  @moduledoc """
  The run path (S1-65; S1-56 §3.4): a person-APPROVED document compiles
  deterministically and runs over the facts surface as the actor, through
  the facts surface's own policies.

  The order is the whole safety argument:

  1. **The gate.** Only a proposal whose status is `:approved` runs —
     never a proposed, refused, rejected or superseded one, and nothing
     runs by itself (a run is this explicit call). The stored document is
     also re-validated against the CURRENT declared vocabulary (the
     queryables digest is re-checked), so a declaration change between
     edit and run is a refusal, never a drift.
  2. **The read.** One ordinary Ash read of the facts surface's `:current`
     action, as the caller's actor, through `AshEnterprise.SystemOne.Fact`'s
     policies — the model is never in this path (law 15), and a judged
     predicate cannot widen what the actor may see: the fold only ever
     sees rows the actor's own read returned. The request-time parameters
     ride here: `:min_grade` (Q19 admission-grade floor, default `:grant`)
     filters the read; `:scope` exact-matches in the fold.
  3. **The fold.** `Filter.Compiler` evaluates the document three-valuedly
     per subject and returns the three partitions with counts. The
     `unknown` partition is never folded away — it is returned as data,
     and the result carries the assess action's existence: the unknown
     partition IS its input (the assess action itself is the facts
     surface's S1-53 scope, not wired in this slice, and the result says
     so honestly).
  4. **The audit.** One `FilterExecution` row: the final post-edit
     document, the compiled plan, the partition counts, the request-time
     parameters, and the seed links (the proposal version, the translation
     observation's wire hash, the NL digest). S1-56 §3.5.
  """

  require Ash.Query

  alias AshEnterprise.SystemOne.Fact
  alias AshEnterprise.SystemOne.Filter
  alias AshEnterprise.SystemOne.Filter.Compiler
  alias AshEnterprise.SystemOne.Filter.Document
  alias AshEnterprise.SystemOne.Filter.Queryables
  alias AshEnterprise.SystemOne.FilterExecution
  alias AshEnterprise.SystemOne.FilterProposal

  @doc """
  Runs one approved proposal over the facts surface.

  Required opts: `:actor` (the run is an explicit act by someone), `:tenant`
  (the proposal and execution are tenanted platform rows). Optional:
  `:min_grade` (default `:grant`), `:scope` (default `nil`).

  Returns `{:ok, %{partitions: %{in: [...], out: [...], unknown: [...]},
  counts: %{...}, assess: %{...}, execution: row}}`, or `{:error, reason}`
  when the gate refuses (not approved, vocabulary drifted, undecodable).
  """
  @spec run(FilterProposal.t() | Ash.UUID.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def run(proposal_or_id, opts) do
    actor = Keyword.fetch!(opts, :actor)
    tenant = Keyword.fetch!(opts, :tenant)

    with {:ok, proposal} <- fetch(proposal_or_id, actor, tenant),
         :ok <- gate(proposal),
         :ok <- vocabulary(proposal),
         {:ok, ast} <- decode(proposal) do
      min_grade = Keyword.get(opts, :min_grade, :grant)
      scope = Keyword.get(opts, :scope)
      now = DateTime.utc_now()

      {:ok, plan} = Compiler.compile(ast, min_grade: min_grade, scope: scope)

      facts_by_subject = read_facts(actor, min_grade)
      partitions = Compiler.fold(ast, facts_by_subject, scope, now)
      counts = Enum.map(partitions, fn {k, v} -> {k, length(v)} end) |> Map.new()

      {:ok, execution} =
        record_execution(proposal, plan, counts, min_grade, scope, actor, tenant)

      {:ok,
       %{
         partitions: partitions,
         counts: counts,
         assess: assess(partitions),
         execution: execution
       }}
    end
  end

  defp fetch(proposal, _actor, _tenant) when is_struct(proposal, FilterProposal),
    do: {:ok, proposal}

  defp fetch(id, actor, tenant) when is_binary(id) do
    case FilterProposal
         |> Ash.Query.for_read(:read, %{}, actor: actor, tenant: tenant)
         |> Ash.Query.filter(id == ^id)
         |> Ash.read_one() do
      {:ok, nil} -> {:error, "no such proposal: #{id}"}
      {:ok, proposal} -> {:ok, proposal}
      {:error, error} -> {:error, error}
    end
  end

  # THE GATE: only a person-approved document runs. This is the
  # "never auto-run, never unedited" clause in executable form (S1-56
  # §3.1, ADR 0048's foreclosure of executing unedited model output).
  defp gate(%FilterProposal{status: :approved}), do: :ok

  defp gate(%FilterProposal{status: status}) do
    {:error,
     "proposal is not approved (status: #{status}) — a filter runs only on a person-approved document"}
  end

  # The stored document validated against the vocabulary of ITS version;
  # the run re-validates against the CURRENT one. A declaration change in
  # between is a refusal — a stored document never runs under a vocabulary
  # it was never checked against.
  defp vocabulary(%FilterProposal{queryables_hash: hash}) do
    current = Queryables.digest()

    if hash == current do
      :ok
    else
      {:error,
       "the declared queryables changed since this version was validated — edit the document to re-validate"}
    end
  end

  defp decode(%FilterProposal{document: document}) do
    case Document.decode(document, Queryables.all()) do
      {:ok, ast} -> {:ok, ast}
      {:error, reason} -> {:error, "the stored document no longer decodes: " <> reason}
    end
  end

  # One ordinary read, as the actor, through the facts surface's policies.
  # No tenant: the facts surface is not multitenant (scope rides in the
  # fact data). The admission-grade floor is the Q19 request-time
  # parameter, applied IN the read — a person-grade floor never reads
  # grant rows to widen anything; it narrows.
  defp read_facts(actor, min_grade) do
    grades = Compiler.grades_at_least(min_grade)

    Fact
    |> Ash.Query.for_read(:current, %{}, actor: actor)
    |> Ash.Query.filter(admission_grade in ^grades)
    |> Ash.read!()
    |> Enum.group_by(&{&1.subject_type, &1.subject_id}, fn fact ->
      {fact.predicate, fact}
    end)
    |> Map.new(fn {subject, predicates} -> {subject, Map.new(predicates)} end)
  end

  defp record_execution(proposal, plan, counts, min_grade, scope, actor, tenant) do
    FilterExecution
    |> Ash.Changeset.for_create(
      :execute,
      %{
        proposal_id: proposal.id,
        proposal_version: proposal.version,
        document: proposal.document,
        plan: plan,
        in_count: counts.in,
        out_count: counts.out,
        unknown_count: counts.unknown,
        min_grade: min_grade,
        scope: scope,
        wire_question_hash: proposal.wire_question_hash,
        nl_digest: proposal.nl_digest
      },
      actor: actor,
      tenant: tenant
    )
    |> Ash.create()
  end

  # The unknown partition surfaces the assess action's existence (S1-56
  # §3.4): the partition is returned, never folded away, and the result
  # names the action it feeds. The action itself is the facts surface's
  # S1-53 scope — not wired in this slice, and reported as such rather
  # than pretended.
  defp assess(%{unknown: unknown}) do
    %{
      action: :assess,
      pending: length(unknown),
      wired?: false,
      note:
        "the unknown partition is the assess action's input; the assess action itself is S1-53 scope"
    }
  end

  @doc "Re-exported for tests and tooling: the mechanism's prompt builder."
  defdelegate build_prompt(nl_text, queryables), to: Filter
end
