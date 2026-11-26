defmodule AshEnterprise.Documents.Paper.Actions.Draft do
  @moduledoc """
  The `PaperRun.draft` pipeline (R10): the governed path's first step.

      draft_paper_run!(kind, subject, title, actor: person, tenant: org_id)

  1. **Render, as `issue` does** (`AshEnterprise.Documents.Paper.Actions.Issue.produce/3`):
     source, payload, binding pin, clause selection, render, ingest, read-back — the
     same steps and the same refusals, each recorded on the run. The run is
     recorded at stage `:draft`: its bytes are stored and read back, but it is
     not an issued document.
  2. **Propose.** One `AshEnterprise.Documents.PaperDraft` for the run (index 0),
     owned by the requester and sealed under the run's scope, holding the
     draft's fingerprint (`AshEnterprise.Documents.Paper.Fingerprint`), the
     subject included, so `issue_draft` re-reads the same rows.
  3. **Record the check.** The run's read-back is the draft's check:
     `:passed` is `:correct`, `:failed` is `:incorrect`, and a read-back that
     did not measure (or never ran) is `:incomplete` — never `:correct`, so the
     draft can never be approved.

  `propose` and `record_check` are machinery-only; this action performs them as
  the `oban` system actor, as its own bookkeeping. The self-service declaration
  on `draft` is the grant; this pipeline is its bounds. A person decides the
  rest: `approve` or `reject`, then `PaperRun.issue_draft`.
  """

  use Ash.Resource.Actions.Implementation

  alias AshEnterprise.Documents
  alias AshEnterprise.Documents.Paper.Actions.Issue
  alias AshEnterprise.Documents.Paper.Fingerprint
  alias AshEnterprise.Platform.SystemActor

  @impl true
  def run(input, _opts, context) do
    with {:ok, produced} <- Issue.produce(input.arguments, context, :draft),
         {:ok, fingerprint} <-
           Fingerprint.build(
             produced,
             input.arguments.title,
             Issue.subject(input.arguments),
             context.tenant
           ) do
      propose(produced.run, fingerprint, context.tenant)
    end
  end

  @doc """
  Proposes the run's draft with `fingerprint` and records its check from the
  run's read-back (`check_status/1`).
  """
  @spec propose(struct(), map(), term()) :: {:ok, struct()} | {:error, term()}
  def propose(run, fingerprint, tenant) do
    machinery = [actor: SystemActor.oban(), tenant: tenant]

    with {:ok, draft} <-
           Documents.propose_paper_draft(
             %{run_id: run.id, index: 0, assignments: Fingerprint.encode(fingerprint)},
             machinery
           ) do
      Documents.record_paper_draft_check(
        draft,
        %{check_status: check_status(run.read_back_status)},
        machinery
      )
    end
  end

  @doc """
  A run's read-back as a draft's check: only a read-back that `:passed` is
  `:correct`; `:failed` is `:incorrect`; anything that did not measure is
  `:incomplete`.
  """
  @spec check_status(atom()) :: :correct | :incorrect | :incomplete
  def check_status(:passed), do: :correct
  def check_status(:failed), do: :incorrect
  def check_status(_unmeasured_or_not_run), do: :incomplete
end
