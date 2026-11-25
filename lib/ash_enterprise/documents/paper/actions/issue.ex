defmodule AshEnterprise.Documents.Paper.Actions.Issue do
  @moduledoc """
  The `PaperRun.issue` pipeline, in the order the kernel's phases read:
  source → payload → run → clause selection → requirement → render → ingest → record → read back → record.

      issue_paper_run!(kind, subject, title, actor: person, tenant: org_id)

  0. **Source.** The kind (`AshEnterprise.Documents.Paper.Kind`) reads its own
     rows for `subject`, server-side, as the actor (`source/2`): nothing the
     caller passes is printed. A malformed subject or nothing to read is
     `{:source, reason}`, before any row exists.
  1. **Payload.** `AshPaper.Payload.build/3` reads only the paths the kind's
     schema names out of that source map, in the kind's locale (`locale/1`),
     and freezes display strings beside typed facts. A required value that is
     absent, a bare decimal without a currency, a wrong type: the issue fails
     naming each problem, before any row exists.
  2. **Binding pin.** The tenant's binding for `(kind, "paper.render")` is
     read as of now; the theme it pins is resolved by key and every pinned
     hash is checked against what the host has now. Unbound, a pinned theme
     the host no longer knows, or hashes that no longer match: refused,
     never rendered against a guess. A rebinding decides what the next run
     renders.
  3. **Run.** A `PaperRun` row opens (`start`), stamped with the requester
     as owner and, as the sealer of `payload`/`facts`, the erasure scope the
     kind names for the subject (`sealing_scope/2`,
     `AshEnterprise.Documents.Paper.SealingScope`) or else the requester's
     own, carrying the binding's id. A named scope that is shredded or
     unknown, or a kind that cannot say, is `{:sealing_scope, reason}`
     before the row opens. Its axes say what happened from here on:
     a run whose read-back never ran stays `:not_run`.
  4. **Clause selection.** Between the payload and the render
     (`AshEnterprise.Documents.Paper.Clauses.select/5`): for each candidate
     clause key of the kind that the binding pins — a document carries only
     the clauses its binding activated, so a binding that pins none decides
     nothing — the tenant's `paper.clause.<key>` table says
     whether the clause is in and why, in the matched rule's description; the
     wording is the binding's pinned admitted version in the payload's
     locale. Any refusal is a `:failed` run with its problems, recorded and
     returned — nothing is dropped silently.
  5. **Requirement.** The kind's requirement, if it has one, is evaluated
     against the payload (`AshEnterprise.Documents.Paper.Interview.check/3`):
     a rule that cannot be decided blocks with `{:missing_facts, entries}` —
     the questions a person answers with `PaperAnswer.answer` — and a rule
     that fires blocks with `{:requirement_failed, entries}`. Either is a
     `:failed` run with one problem per entry, recorded and returned; an
     unknown is never read as satisfied.
  6. **Render.** `AshPaper.Render.render/5` with explicit limits
     (`AshEnterprise.Documents.Paper.limits/0`) and the selected clauses. A
     failure is recorded (`record_render_failure`) and returned; a render that
     fails is a `:failed` run with its problems, never a document.
  7. **Ingest.** The bytes are stored as an `AshEvidence.DocumentVersion`
     under `upsert?: true` on `:unique_content`, so issuing the same
     document twice lands on the same version row.
  8. **Record.** `record_render` freezes what produced the bytes: the
     snapshot (schema, layout, theme, clauses, the clause decisions — hashes
     and references only, its payload hash keyed with a fresh secret sealed
     beside them as `payload_hash_key`), the output digest, the display
     strings, the typed facts, the stored bytes' `document_version_id`, and
     `clause_reasons` — which rule put each clause there, in its author's words.
  9. **Read back.** `AshPaper.Verify.read_back/5` checks every labelled
     block in the issued bytes against the payload, the selected clauses
     included (the letter prints them after its tables). The outcome is recorded
     twice: as a closed `AshEvidence.ParseRun` (instrument
     `"ash_paper.read_back"`, the per-block outcomes in its config — written
     closed in one insert, so no run is left pending) and on the
     run row via `record_read_back`, whose status is `:passed`, `:failed`
     or `:unmeasured` — a check that could not measure is never a pass.

  Each step is a named function here, so a step's failure is observable at
  that step; `run/3` composes them. The fragment's axis actions are
  machinery-only; this action performs them with `authorize?: false` as its
  own bookkeeping, named with the actor — the self-service declaration on
  `issue` is the grant and this pipeline is its bounds.
  """

  use Ash.Resource.Actions.Implementation

  alias AshEnterprise.Documents.Paper
  alias AshEnterprise.Documents.Paper.Clauses
  alias AshEnterprise.Documents.Paper.Error, as: PaperError
  alias AshEnterprise.Documents.Paper.Interview
  alias AshEnterprise.Documents.Paper.SealingScope
  alias AshEnterprise.Documents.{PaperBinding, PaperRun}

  @instrument "ash_paper.read_back"

  @impl true
  def run(input, _opts, context) do
    with {:ok, produced} <- produce(input.arguments, context, :issued) do
      {:ok, produced.run}
    end
  end

  @doc """
  The whole pipeline, for a run at `stage` (`:issued` for `issue`, `:draft` for
  `PaperRun.draft`): `{:ok, %{run:, binding:, payload:, selection:}}` with the
  run read back and recorded, or the step's error. `draft` builds a draft's
  fingerprint from what this returns.
  """
  @spec produce(map(), map(), :issued | :draft) :: {:ok, map()} | {:error, term()}
  def produce(arguments, context, stage) do
    opts =
      context
      |> Ash.Context.to_opts()
      |> Keyword.take([:actor, :tenant, :tracer])

    kind = arguments.document_kind

    with {:ok, schema, layout, _default_theme} <- Paper.definition(kind),
         {:ok, payload} <- payload(kind, subject(arguments), arguments.title, opts),
         {:ok, binding} <- resolve_binding(kind, context.tenant),
         {:ok, theme} <- pinned_theme(binding, schema, layout),
         {:ok, scope_id} <- sealing_scope(kind, subject(arguments), opts),
         {:ok, run} <- start_run(kind, binding.id, opts, stage, scope_id),
         {:ok, selected} <- select_clauses(run, kind, payload, binding, context.tenant),
         :ok <- require_facts(run, kind, payload, context.tenant),
         {:ok, rendered} <- render(run, layout, theme, payload, clauses: selected.resolved),
         {:ok, version} <- ingest(context.tenant, rendered.bytes),
         {:ok, run} <-
           record_render(run, schema, layout, theme, payload, rendered, selected, version.id),
         {:ok, run} <-
           read_back_and_record(
             run,
             version.id,
             payload,
             rendered.bytes,
             rendered.marks,
             theme,
             selected.resolved
           ) do
      {:ok, %{run: run, binding: binding, payload: payload, selection: selected}}
    end
  end

  @doc """
  The payload for `kind` and `subject`: the kind's source read as the actor in
  `opts` (`:actor`, `:tenant`), built in the kind's locale. Fails naming every
  problem before any row exists.
  """
  @spec payload(String.t(), map(), String.t(), keyword()) ::
          {:ok, AshPaper.Payload.t()} | {:error, PaperError.t()}
  def payload(kind, subject, title, opts) do
    with {:ok, module} <- Paper.kind(kind),
         {:ok, source} <- read_source(module, subject, opts) do
      build_payload(module, subject, source, title)
    end
  end

  @doc """
  Builds `kind_module`'s payload from `source` in the kind's locale for
  `subject`, or fails naming every problem.
  """
  @spec build_payload(module(), map(), map(), String.t()) ::
          {:ok, AshPaper.Payload.t()} | {:error, PaperError.t()}
  def build_payload(kind_module, subject, source, title) do
    case AshPaper.Payload.build(kind_module.schema(), source,
           title: title,
           locale: kind_module.locale(subject)
         ) do
      {:ok, payload} -> {:ok, payload}
      {:error, problems} -> error({:payload, problems})
    end
  end

  @doc "A subject as the run records it: string keys, so it survives JSON."
  @spec subject(map()) :: map()
  def subject(%{subject: subject}) when is_map(subject),
    do: Map.new(subject, fn {key, value} -> {to_string(key), value} end)

  def subject(_arguments), do: %{}

  # The kind's own rows, read as the actor: the only road a value takes into
  # a document.
  defp read_source(module, subject, opts) do
    case module.source(subject, Keyword.take(opts, [:actor, :tenant])) do
      {:ok, source} when is_map(source) -> {:ok, source}
      {:error, reason} -> error({:source, reason})
      other -> error({:source, {:unexpected, other}})
    end
  end

  @doc "The tenant's binding for `(kind, #{Paper.binding_purpose()})`, read as of now."
  @spec resolve_binding(String.t(), term()) :: {:ok, PaperBinding.t()} | {:error, PaperError.t()}
  def resolve_binding(kind, tenant) do
    AshEnterprise.Documents.get_paper_binding_by_selector(Paper.binding_selector(kind),
      tenant: tenant,
      authorize?: false
    )
    |> case do
      {:ok, binding} -> {:ok, binding}
      {:error, %Ash.Error.Query.NotFound{}} -> error(:not_bound)
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  The theme the binding pins, checked against what the host has now: the
  pinned theme resolves to a known theme whose current hash matches the
  pin, and the pinned schema and layout hashes match the host's current
  content for those keys. Anything else is stale, and the issue is refused
  with the binding's whole stored selection — a run never renders against
  a guess, and a rebinding decides what the next run renders.
  """
  @spec pinned_theme(PaperBinding.t(), module(), module() | AshPaper.Layout.t()) ::
          {:ok, AshPaper.Theme.t()} | {:error, PaperError.t()}
  def pinned_theme(binding, schema, layout) do
    case AshPaper.Binding.check(binding.selection, schema, layout, &Paper.theme_by_key/1) do
      {:ok, theme} -> {:ok, theme}
      {:error, reason} -> error(reason)
    end
  end

  @doc """
  The erasure scope the kind names for `subject` (`sealing_scope/2`), read as
  the actor: `{:ok, nil}` when it names none, so the requester's own scope
  seals the run; `{:ok, scope_id}` for a live scope; or the refusal,
  `{:sealing_scope, reason}`, before any row exists.
  """
  @spec sealing_scope(String.t(), map(), keyword()) ::
          {:ok, Ecto.UUID.t() | nil} | {:error, PaperError.t()}
  def sealing_scope(kind, subject, opts) do
    with {:ok, module} <- Paper.kind(kind) do
      case SealingScope.resolve(module, subject, opts) do
        {:ok, scope_id} -> {:ok, scope_id}
        {:error, reason} -> error({:sealing_scope, reason})
      end
    end
  end

  @doc """
  Opens the run row: the requester owns it, and `erasure_scope_id` (the
  scope `sealing_scope/3` resolved), or else the requester's own scope, seals
  its payload. A run at stage `:draft` is a draft's rendering, never an
  issued document, until a person's `apply` of its approved draft moves it to
  `:issued`.
  """
  @spec start_run(String.t(), Ecto.UUID.t(), keyword(), :issued | :draft, Ecto.UUID.t() | nil) ::
          {:ok, PaperRun.t()} | {:error, term()}
  def start_run(kind, binding_id, opts, stage \\ :issued, erasure_scope_id \\ nil)
      when stage in [:issued, :draft] do
    PaperRun
    |> Ash.Changeset.for_create(:start, %{document_kind: kind}, opts)
    |> Ash.Changeset.force_change_attribute(:paper_binding_id, binding_id)
    |> Ash.Changeset.force_change_attribute(:stage, stage)
    |> seal_under(erasure_scope_id)
    |> Ash.create(Keyword.put(opts, :authorize?, false))
  end

  # The requester's scope came from `ScopeAndOwner`; a scope the kind named
  # takes its place. The owner stays the requester.
  defp seal_under(changeset, nil), do: changeset

  defp seal_under(changeset, scope_id),
    do: Ash.Changeset.force_change_attribute(changeset, :erasure_scope_id, scope_id)

  @doc """
  Renders with explicit limits. A failed render is recorded on the run
  (`render_status: :failed`, the problem in `problems`) and returned: a
  compile failure, a page-limit breach or a timeout is a `:failed` run,
  never a document.
  """
  @spec render(
          PaperRun.t(),
          module() | AshPaper.Layout.t(),
          AshPaper.Theme.t(),
          AshPaper.Payload.t(),
          keyword()
        ) :: {:ok, AshPaper.Render.Rendered.t()} | {:error, PaperError.t()}
  def render(run, layout, theme, payload, opts \\ []) do
    clauses = Keyword.get(opts, :clauses, [])
    limits = Keyword.merge(Paper.limits(), Keyword.take(opts, [:max_pages, :timeout_ms]))

    case AshPaper.Render.render(layout, theme, payload, clauses, limits) do
      {:ok, rendered} ->
        {:ok, rendered}

      {:error, reason} ->
        record_render_failure(run, reason)
        error({:render_failed, reason})
    end
  end

  @doc """
  Stores the issued bytes in the tenant, content-addressed: the same bytes
  are the same version row (`upsert?: true` on `:unique_content`).
  """
  @spec ingest(term(), binary()) ::
          {:ok, AshEvidence.DocumentVersion.t()} | {:error, PaperError.t()}
  def ingest(tenant, bytes) when is_binary(bytes) do
    sha256 = Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

    AshEvidence.DocumentVersion
    |> Ash.Changeset.for_create(
      :ingest,
      %{kind: "application/pdf", bytes: bytes, sha256: sha256},
      upsert?: true,
      upsert_identity: :unique_content,
      tenant: tenant,
      authorize?: false
    )
    |> Ash.create()
    |> case do
      {:ok, version} -> {:ok, version}
      {:error, reason} -> error({:ingest_failed, reason})
    end
  end

  @doc """
  Selection at issue, between the payload and the render
  (`AshEnterprise.Documents.Paper.Clauses.select/5`): the tenant's
  `paper.clause.*` tables say, per candidate key the binding pins, whether the
  clause is in and why. A refusal — a missing decision input, an undecided
  clause, a UNIQUE violation, a rule with no reason, a stale or missing clause
  pin, wording
  with no variant in the payload's locale — is recorded on the run as a failed
  render and returned: nothing is dropped silently.
  """
  @spec select_clauses(
          PaperRun.t(),
          String.t(),
          AshPaper.Payload.t(),
          PaperBinding.t(),
          term()
        ) :: {:ok, map()} | {:error, PaperError.t()}
  def select_clauses(run, kind, payload, binding, tenant) do
    case Clauses.select(kind, payload, binding, run, tenant) do
      {:ok, selection} ->
        {:ok, selection}

      # The resolve's refusals, one per clause it could not fill.
      {:error, blocks} when is_list(blocks) ->
        record_render_failure(run, blocks)
        error({:clause_selection, blocks})

      {:error, block} ->
        record_render_failure(run, block)
        error(block)
    end
  end

  @doc """
  The requirement gate, between clause selection and the render
  (`AshEnterprise.Documents.Paper.Interview.check/3`). A block is recorded on
  the run as a failed render, one problem per missing fact (`"missing_fact"`,
  carrying the question, the rule's message and evidence, and the scope and
  digest an answer is recorded under) or per fired rule
  (`"requirement_failed"`), and returned.
  """
  @spec require_facts(PaperRun.t(), String.t(), AshPaper.Payload.t(), term()) ::
          :ok | {:error, PaperError.t()}
  def require_facts(run, kind, payload, tenant) do
    case Interview.check(kind, payload, tenant) do
      :ok ->
        :ok

      {:blocked, reason} ->
        record_render_failure(run, blocked_problems(reason))
        error(reason)
    end
  end

  defp blocked_problems({:missing_facts, entries}), do: Enum.map(entries, &{:missing_fact, &1})

  defp blocked_problems({:requirement_failed, entries}),
    do: Enum.map(entries, &{:requirement_failed, &1})

  defp blocked_problems(other), do: [other]

  @doc """
  Freezes what produced the bytes on the run: the snapshot (hashes and
  references only), the output digest, the display strings and the typed
  facts — sealed on write, and the fresh key the snapshot's payload hash
  was keyed with, sealed beside them (`payload_hash_key`), never in the
  unsealed snapshot.

  The selection rides along: the pinned clause wording joins the snapshot's
  definitions, each clause decision the run consulted is one snapshot input
  (the definition read, hashed), the decision definitions are pinned beside
  the schema and theme, and the reason maps are recorded as `clause_reasons`
  — so "why is this clause here" is one read of the run.
  """
  @spec record_render(
          PaperRun.t(),
          module(),
          module() | AshPaper.Layout.t(),
          AshPaper.Theme.t(),
          AshPaper.Payload.t(),
          AshPaper.Render.Rendered.t(),
          map(),
          Ecto.UUID.t() | nil
        ) :: {:ok, PaperRun.t()} | {:error, term()}
  def record_render(
        run,
        schema,
        layout,
        theme,
        payload,
        rendered,
        selection \\ Clauses.empty(),
        document_version_id \\ nil
      ) do
    key = :crypto.strong_rand_bytes(32)

    snapshot =
      AshPaper.Snapshot.build(
        id: run.id,
        schema: schema,
        layout: layout,
        theme: theme,
        payload: payload,
        clauses: selection.clauses,
        pins: rendered.pins,
        at: DateTime.utc_now(),
        # The snapshot is stored unsealed: it names the tenant and nobody in it.
        # Who asked is the run's own `owner_id`, which a shred leaves as the
        # row's owner and not as a field of what the document was.
        authority: %{tenant: run.organization_id, completeness: :complete},
        hash_key: key,
        inputs: selection.inputs,
        definitions: selection.definitions
      )

    # The key, the stored bytes' id and the clause reasons are the run
    # fragment's own `record_render` inputs: the key is sealed beside
    # `payload` and `facts` (it is a cloaked, accepted attribute, so
    # `SealUnderScope` seals it as an argument) and never enters the unsealed
    # snapshot.
    run
    |> Ash.Changeset.for_update(:record_render, %{
      snapshot: AshPaper.Snapshot.stored(snapshot),
      output_digest: rendered.digest,
      payload: AshPaper.Payload.document(payload, selection.resolved),
      facts: payload.facts,
      payload_hash_key: Base.encode64(key),
      document_version_id: document_version_id,
      clause_reasons: selection.reasons
    })
    |> Ash.update(authorize?: false)
  end

  @doc """
  Reads `bytes` back and checks every labelled block against the payload and
  `clauses` (the resolved clauses the render printed),
  recording the outcome twice: a closed `AshEvidence.ParseRun` (the
  per-block outcomes in its config) and the run's `read_back_status`.
  """
  @spec read_back_and_record(
          PaperRun.t(),
          Ecto.UUID.t(),
          AshPaper.Payload.t(),
          binary(),
          [map()],
          AshPaper.Theme.t(),
          [map()]
        ) :: {:ok, PaperRun.t()} | {:error, term()}
  def read_back_and_record(run, version_id, payload, bytes, marks, theme, clauses \\ []) do
    outcome = AshPaper.Verify.read_back(bytes, marks, payload, clauses, theme)
    problems = Enum.map(outcome.problems, &AshPaper.Fragment.Run.problem/1)

    config = %{
      "outcome" => to_string(outcome.status),
      "checked" => outcome.checked,
      "problems" => problems,
      "document_kind" => run.document_kind,
      "output_digest" => run.output_digest
    }

    with {:ok, _parse_run} <-
           close_parse_run(version_id, config, outcome.status, run.organization_id) do
      run
      |> Ash.Changeset.for_update(:record_read_back, %{
        read_back_status: outcome.status,
        problems: problems
      })
      |> Ash.update(authorize?: false)
    end
  end

  # The ParseRun is the evidence store's record of the pass: one closed run,
  # written in one insert (`record_check`), so a run is never left pending,
  # with the per-block outcomes as its result. Only `:passed` is recorded as a
  # pass; `:failed` and `:unmeasured` are both a failed check.
  defp close_parse_run(version_id, config, status, tenant) do
    AshEvidence.Domain.record_check(version_id, @instrument, config, status == :passed,
      tenant: tenant,
      authorize?: false
    )
  end

  defp record_render_failure(run, reason) do
    problems = reason |> List.wrap() |> Enum.map(&AshPaper.Fragment.Run.problem/1)

    run
    |> Ash.Changeset.for_update(:record_render_failure, %{problems: problems})
    |> Ash.update(authorize?: false)
  end

  defp error(reason), do: {:error, PaperError.exception(reason: reason)}
end
