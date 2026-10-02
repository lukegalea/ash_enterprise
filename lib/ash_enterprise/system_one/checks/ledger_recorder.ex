defmodule AshEnterprise.SystemOne.Checks.LedgerRecorder do
  @moduledoc """
  Passes when the judgment recorder is the caller.

  `AshJudgments.Ledger.Record` — the registry's recorder — creates ledger
  rows from inside a judge action, and it deliberately passes no actor:
  the observation is the recording machinery's write, not the requester's
  (RFC v0 §5.2 records who *asked*; the row is the pipeline's). With
  policies on, a plain `Ash.create/1` with no actor would be forbidden,
  and the judge action's `record: :must` posture would fail closed on
  every judgment. So the recorder marks its own call instead — it passes
  the judge action's context through to the create (`context:` carries the
  `:judgments` hand-off map), and this check recognises it:

      bypass AshEnterprise.SystemOne.Checks.LedgerRecorder do
        authorize_if always()
      end

  This is the same pattern — and the same honest limitation — as the
  engine bypasses (`AshBpmn.Checks.AshBpmnInteraction`,
  `AshDecisions.Checks.AshDecisionsInteraction`): one named, greppable,
  testable thing in the policy set rather than an anonymous
  `authorize?: false`, and *not* a security boundary against code running
  inside this BEAM, because anything that can set that context could
  equally have set it lying. What it buys is that the recorder's authority
  is declared here, where a host can read, reason about and replace it.

  A hand-written `:record` create — no `:judgments` context — gets nothing
  from this check: system actors still go through their own bypass, and
  everyone else fails closed.
  """

  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_opts), do: "the judgment recorder (AshJudgments.Ledger.Record) is the caller"

  @impl true
  def match?(_actor, %{subject: %{context: %{judgments: judgments}}}, _opts)
      when is_map(judgments),
      do: true

  def match?(_actor, _context, _opts), do: false
end
