defmodule AshEnterprise.Documents.Paper.Actions.IssueDraft do
  @moduledoc """
  The `PaperRun.issue_draft` pipeline (R10): an approved draft is issued exactly
  as rendered, and only while nothing it was made from has moved.

      issue_paper_draft!(draft_id, actor: person, tenant: org_id)

  1. **Read the draft as the person.** The draft is read with the caller's own
     authorization, so a person reaches only drafts their grants reach (their
     own, through the self-service read). Not found is a refusal.
  2. **It must be approved** (the fragment's guard, named first): a proposed,
     rejected, superseded or applied draft is refused, and so is an approved
     draft already marked stale.
  3. **Recompute against the current state**
     (`AshEnterprise.Documents.Paper.Fingerprint.moved/4`): the payload from
     the kind's rows for the draft's subject, re-read as the person; the
     binding and its pins, the admitted clause pins, the current published
     version of each decision definition, and the decisions themselves
     (re-evaluated without recording anything; the same include set and rule
     ids are required).
  4. **Moved:** `mark_stale` as machinery, and `{:draft_stale, moved}`. A later
     `apply` fails on the fragment's freshness guard.
  5. **Current:** `apply` as the person (human-only). Its host change,
     `AshEnterprise.Documents.Paper.Changes.IssueDraftRun`, moves the run to
     `:issued` in the same transaction with **no re-render**, after proving the
     stored bytes are the approved bytes.

  Every outcome is appended to the draft's `issue_outcomes`: `"issued"` and
  `"stale"` in the same write as `apply` and `mark_stale`, and `"refused"` (with
  why) through `record_issue_outcome` when nothing else is written. Nothing an
  issue tried is silent.
  """

  use Ash.Resource.Actions.Implementation

  alias AshEnterprise.Documents
  alias AshEnterprise.Documents.Paper.Error, as: PaperError
  alias AshEnterprise.Documents.Paper.Fingerprint
  alias AshEnterprise.Documents.PaperRun
  alias AshEnterprise.Platform.SystemActor

  @impl true
  def run(input, _opts, context) do
    tenant = context.tenant
    actor = context.actor

    case Documents.get_paper_draft(input.arguments.draft_id, actor: actor, tenant: tenant) do
      {:ok, draft} -> issue(draft, actor, tenant)
      {:error, _not_found} -> error({:draft_not_found, input.arguments.draft_id})
    end
  end

  @doc """
  Issues `draft` as `actor`: `{:ok, run}` with the run at
  `:issued`, or `{:error, %Paper.Error{}}` — `{:draft_stale, moved}`,
  `{:draft_not_approved, disposition}`, `{:draft_not_current, :stale}`,
  `{:draft_unreadable, reason}` or `{:draft_not_issued, message}`.
  """
  @spec issue(struct(), struct(), term()) :: {:ok, PaperRun.t()} | {:error, term()}
  def issue(draft, actor, tenant) do
    with :ok <- approved(draft),
         {:ok, fingerprint} <- fingerprint(draft, tenant),
         {:ok, run} <- Ash.get(PaperRun, draft.run_id, tenant: tenant, authorize?: false) do
      case Fingerprint.moved(fingerprint, run, actor, tenant) do
        [] -> apply_draft(draft, fingerprint, actor, tenant)
        moved -> stale(draft, moved, tenant)
      end
    else
      {:error, {:refused, reason}} -> refuse(draft, reason, tenant)
      {:error, other} -> refuse(draft, {:draft_not_issued, reason_text(other)}, tenant)
    end
  end

  # The fragment's guard, named first: only an approved, current draft is issued.
  defp approved(%{disposition: :approved, freshness: :current}), do: :ok

  defp approved(%{disposition: :approved, freshness: freshness}),
    do: {:error, {:refused, {:draft_not_current, freshness}}}

  defp approved(%{disposition: disposition}),
    do: {:error, {:refused, {:draft_not_approved, disposition}}}

  defp fingerprint(draft, tenant) do
    case Fingerprint.unseal(draft, tenant) do
      {:ok, fingerprint} -> {:ok, fingerprint}
      {:error, reason} -> {:error, {:refused, {:draft_unreadable, reason}}}
    end
  end

  defp apply_draft(draft, fingerprint, actor, tenant) do
    outcome = outcome("issued", %{"output_digest" => fingerprint["output_digest"]})

    case Documents.apply_paper_draft(draft, %{},
           actor: actor,
           tenant: tenant,
           context: %{paper: %{issue_outcome: outcome}}
         ) do
      {:ok, applied} ->
        Ash.get(PaperRun, applied.run_id, tenant: tenant, authorize?: false)

      {:error, error} ->
        refuse(draft, {:draft_not_issued, reason_text(error)}, tenant)
    end
  end

  defp stale(draft, moved, tenant) do
    outcome = outcome("stale", %{"moved" => Enum.map(moved, &Atom.to_string/1)})

    case Documents.mark_paper_draft_stale(draft, %{},
           actor: SystemActor.oban(),
           tenant: tenant,
           context: %{paper: %{issue_outcome: outcome}}
         ) do
      {:ok, _stale} ->
        error({:draft_stale, moved})

      {:error, error} ->
        refuse(draft, {:draft_not_issued, reason_text(error)}, tenant)
    end
  end

  # A refusal that writes nothing else is still recorded on the draft. When even
  # that write fails, its error is returned beside the refusal: never a silent one.
  defp refuse(draft, reason, tenant) do
    outcome = outcome("refused", %{"reason" => inspect(reason)})

    case Documents.record_paper_draft_outcome(draft, %{outcome: outcome},
           actor: SystemActor.oban(),
           tenant: tenant
         ) do
      {:ok, _recorded} -> error(reason)
      {:error, error} -> error({:outcome_not_recorded, reason, reason_text(error)})
    end
  end

  # Who acted is in the audit trail; the outcome, stored unsealed, names no one.
  defp outcome(kind, details) do
    Map.merge(
      %{"outcome" => kind, "at" => DateTime.to_iso8601(DateTime.utc_now())},
      details
    )
  end

  defp reason_text(%{__exception__: true} = error), do: Exception.message(error)
  defp reason_text(other), do: inspect(other)

  defp error(reason), do: {:error, PaperError.exception(reason: reason)}
end
