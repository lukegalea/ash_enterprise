defmodule AshEnterprise.SystemOne.Checks.FactMaterialiser do
  @moduledoc """
  Passes when the facts materialiser is the caller.

  `AshJudgments.Facts.Materialiser` — the sole sanctioned writer of the
  facts fragment's machinery actions (`:materialise`, and — on the
  temporal fragment, AST-149 — the period verbs `:revise`/`:truncate`,
  plus its own `:for_subject` read) — deliberately passes no actor: the
  write is the admission pipeline's, attributed through the admission id
  the decision carries. With policies on, a plain `Ash.create!/1` with no
  actor would be forbidden, so the resource declares the materialiser's
  authority HERE:

      bypass AshEnterprise.SystemOne.Checks.FactMaterialiser do
        authorize_if always()
      end

  The marker is structural, not a flag: the machinery actions, called with
  NO actor, are the materialiser. Any caller PRESENTING an actor — a
  person, a system actor — matches nothing here and takes the ordinary
  paths (for a system actor, the platform bypass; for a person, nothing:
  facts are materialised by the pipeline, never hand-written). The same
  honest limitation as every engine bypass applies: code inside this BEAM
  can omit the actor too. What the bypass buys is that the materialiser's
  authority is declared in the policy set, where a host can read, reason
  about and replace it.
  """

  use Ash.Policy.SimpleCheck

  @machinery [:materialise, :revise, :truncate, :for_subject]

  @impl true
  def describe(_opts),
    do: "the facts materialiser (AshJudgments.Facts.Materialiser) is the caller"

  @impl true
  def match?(nil, authorizer, _opts) do
    authorizer |> action_name() |> then(&(&1 in @machinery))
  end

  def match?(_actor, _authorizer, _opts), do: false

  defp action_name(%{action: %{name: name}}), do: name
  defp action_name(_authorizer), do: nil
end
