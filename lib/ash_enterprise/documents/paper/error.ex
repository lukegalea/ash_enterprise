defmodule AshEnterprise.Documents.Paper.Error do
  @moduledoc """
  An issuing step that stopped for a reason the caller can act on.

  | `reason` | Meaning |
  |---|---|
  | `{:unknown_kind, kind}` | `kind` is not a kind this host can issue (`AshEnterprise.Documents.Paper.kinds/0`) |
  | `{:source, reason}` | the kind could not read its source for the subject as the actor (a malformed subject, nothing the actor may read); no run row exists |
  | `{:payload, problems}` | `AshPaper.Payload.build/3` refused the source: `{:missing, name}`, `{:no_currency, name}`, `{:wrong_type, name}` or `{:not_loaded, name}` per problem |
  | `{:sealing_scope, reason}` | the kind's `sealing_scope/2` could not name a live scope: `{:shredded, id}`, `{:not_found, id}`, `{:unavailable, reason}` (the kind's error) or `{:invalid, returned}`; never sealed under a fallback, and no run row exists |
  | `:not_bound` | the tenant has no binding for `(kind, "paper.render")` — bind one first |
  | `{:binding_stale, selection}` | the binding's pinned hashes no longer match what the host would render — schema, layout, theme, or the admitted clause versions (one admitted or retired since binding); `selection` is the binding's whole stored selection |
  | `{:missing_decision_input, key, input}` | the `paper.clause.<key>` table declares an input `Paper.decision_inputs/2` does not produce; the run records the refusal |
  | `{:clause_undecided, key}` | the table answered nothing for the payload: no matched rule, nil outputs, or no published table; the run records the refusal |
  | `{:clause_decision_failed, key, reason}` | the decision failed — a UNIQUE violation (two rules matched), a timeout, or the evaluation could not be recorded (`record: :required`); the run records the refusal |
  | `{:clause_reason_missing, key}` | the matched rule has no description, so the clause cannot say why it is there; the run records the refusal |
  | `{:clause_not_pinned, key, locale}` | the clause is selected but the binding pins no admitted version in the payload's locale — only a draft exists, or no variant in that locale; the run records the refusal |
  | `{:clause_selection, problems}` | the selected clauses could not be filled (`AshPaper.Clause.resolve/3`: `{:unfilled_holes, key, fields}` per clause); the run records every problem |
  | `{:missing_facts, entries}` | the kind's requirement cannot decide a rule: each entry names the asked `"predicate"`, its `"subject"`, the `"rule"`, the rule's `"message"` and `"evidence"`, the `"question"`, the `"reason"` it is asked (`no_fact`, `stale`, `expired`, `below_grade`) and the `"scope"` and `"digest"` an answer is recorded under; the run records one problem per entry. Answer with `PaperAnswer.answer` and issue again |
  | `{:requirement_failed, entries}` | a rule of the kind's requirement fired on a recorded answer (`"rule"`, `"status"`, `"message"`, `"gap"`, `"severity"` per entry); the run records them. Not asked again: the answer decided it |
  | `{:requirement_undecided, rules}` | the requirement is undecided with nothing a person can answer; the run records the refusal |
  | `{:requirement_error, detail}` | the requirement could not be evaluated (facts outside its schema, a bad bundle); the run records the refusal |
  | `{:render_failed, reason}` | the Typst render failed; the run row records `render_status: :failed` with the problem |
  | `{:draft_not_found, id}` | `issue_draft` named a draft the caller cannot read |
  | `{:draft_not_approved, disposition}` | `issue_draft` on a draft that is not approved (proposed, rejected, superseded or already applied); recorded on the draft |
  | `{:draft_not_current, :stale}` | `issue_draft` on an approved draft already marked stale; recorded on the draft |
  | `{:draft_unreadable, reason}` | the draft's sealed fingerprint cannot be read (`:shredded`, `:unreadable`); recorded on the draft |
  | `{:draft_stale, moved}` | something the draft was made from moved — `moved` lists `:payload`, `:binding`, `:clause_pins`, `:decision_definitions`, `:decisions` (the payload re-read from the kind's rows as the person); the draft is marked stale and can never be applied |
  | `{:draft_not_issued, message}` | `apply` or `mark_stale` refused (a guard, a grant, bytes that are not the approved bytes); recorded on the draft |
  | `{:outcome_not_recorded, reason, message}` | a refusal whose record on the draft also failed: both are returned |
  | `{:ingest_failed, reason}` | the bytes could not be stored as an `AshEvidence.DocumentVersion`; the run row stays `:pending` |

  Fields are structural only — a problem's field name, a hash, an error term —
  never a document's content.
  """

  use Splode.Error, fields: [:reason], class: :unknown

  @type t :: %__MODULE__{}

  @impl true
  def message(%__MODULE__{reason: reason}), do: "paper issue: #{inspect(reason)}"

  @doc "The `Paper.Error` inside an action's error, or nil."
  def unwrap(%__MODULE__{} = error), do: error
  def unwrap(_other), do: nil
end
