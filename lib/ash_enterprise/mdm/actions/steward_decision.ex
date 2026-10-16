defmodule AshEnterprise.Mdm.Actions.StewardDecision do
  @moduledoc """
  `MatchCandidate.confirm_match` / `.reject_match` / `.mark_unsure`: the
  steward surface's buttons, named for what they say. Each reads the
  candidate as the actor and runs the person-gated update it stands for
  (`:confirm`, `:reject`, `:escalate`) as the actor, so the update's
  policies — the person gate and the update grant — decide, and the verdict
  recorded is the update's own name.

  Nothing here grants anything on its own account: a candidate the actor
  cannot read is "not found", and one they cannot update is the update's
  `Forbidden`. One thing is refused here: **Confirm match** when the actor
  may not read the golden the staged record would merge into. Nobody
  confirms a merge into a record they cannot see — the queue does not list
  such a candidate (`:review_queue`), and a click by id is refused the same
  way, as `Forbidden`.
  """

  use Ash.Resource.Actions.Implementation

  alias AshEnterprise.Mdm.MatchCandidate

  @impl true
  def run(input, opts, context) do
    verdict = Keyword.fetch!(opts, :verdict)
    ash_opts = Ash.Context.to_opts(context)

    with {:ok, candidate} <- Ash.get(MatchCandidate, input.arguments.record_id, ash_opts),
         :ok <- golden_readable(verdict, candidate, ash_opts),
         {:ok, _decided} <-
           candidate
           |> Ash.Changeset.for_update(verdict, %{}, ash_opts)
           |> Ash.update(ash_opts) do
      {:ok, message(verdict)}
    end
  end

  # `golden` loaded as the actor, under Person's read policy: absent means
  # they may not read it (or it is gone), and either way it is not theirs to
  # merge into.
  defp golden_readable(:confirm, candidate, opts) do
    case Ash.load(candidate, :golden, opts) do
      {:ok, %{golden: %{id: _}}} -> :ok
      {:ok, _no_readable_golden} -> {:error, Ash.Error.Forbidden.exception([])}
      {:error, error} -> {:error, error}
    end
  end

  defp golden_readable(_verdict, _candidate, _opts), do: :ok

  defp message(:confirm), do: "Match confirmed: the staged record merged into the golden record."
  defp message(:reject), do: "Match rejected: the staged record stays a record of its own."

  defp message(:escalate),
    do: "Marked unsure: the candidate stays open for a senior steward."
end
