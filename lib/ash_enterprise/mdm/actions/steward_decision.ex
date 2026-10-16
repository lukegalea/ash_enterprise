defmodule AshEnterprise.Mdm.Actions.StewardDecision do
  @moduledoc """
  `MatchCandidate.confirm_match` / `.reject_match` / `.mark_unsure`: the
  steward surface's buttons, named for what they say. Each reads the
  candidate as the actor and runs the person-gated update it stands for
  (`:confirm`, `:reject`, `:escalate`) as the actor, so the update's
  policies — the person gate and the update grant — decide, and the verdict
  recorded is the update's own name.

  Nothing here is authorized on its own account: a candidate the actor
  cannot read is "not found", and one they cannot update is the update's
  `Forbidden`.
  """

  use Ash.Resource.Actions.Implementation

  alias AshEnterprise.Mdm.MatchCandidate

  @impl true
  def run(input, opts, context) do
    verdict = Keyword.fetch!(opts, :verdict)
    ash_opts = Ash.Context.to_opts(context)

    with {:ok, candidate} <- Ash.get(MatchCandidate, input.arguments.record_id, ash_opts),
         {:ok, _decided} <-
           candidate
           |> Ash.Changeset.for_update(verdict, %{}, ash_opts)
           |> Ash.update(ash_opts) do
      {:ok, message(verdict)}
    end
  end

  defp message(:confirm), do: "Match confirmed: the staged record merged into the golden record."
  defp message(:reject), do: "Match rejected: the staged record stays a record of its own."

  defp message(:escalate),
    do: "Marked unsure: the candidate stays open for a senior steward."
end
