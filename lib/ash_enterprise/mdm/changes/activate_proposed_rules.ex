defmodule AshEnterprise.Mdm.Changes.ActivateProposedRules do
  @moduledoc """
  A person adopts a match-rule proposal (`MatchRuleProposal.activate`, ADR
  0047): its draft rule set goes through `MatchRuleSet.activate` as that same
  person, in the proposal's transaction, so the rule set's own person gate, its
  grants and ash_mdm's refusals (unknown survivorship, rules that cannot
  score) all apply. A refusal there refuses the proposal too.

  A proposal is stale once the rule set it was replayed against is no longer
  the active one: its replay compared the draft with rules that no longer
  match anything, so it cannot be activated. Checked in the transaction,
  before the activation.
  """

  use Ash.Resource.Change

  alias AshEnterprise.Mdm.MatchRuleSet

  @impl true
  def change(changeset, _opts, context) do
    Ash.Changeset.before_action(changeset, &activate(&1, context))
  end

  defp activate(changeset, context) do
    proposal = changeset.data
    write = [tenant: changeset.tenant, actor: context.actor, authorize?: context.authorize?]

    with :ok <- current(proposal, changeset.tenant),
         {:ok, %MatchRuleSet{} = draft} <- rule_set(proposal.rule_set_id, changeset.tenant),
         {:ok, _active} <-
           draft |> Ash.Changeset.for_update(:activate, %{}, write) |> Ash.update() do
      changeset
    else
      {:error, :stale} ->
        Ash.Changeset.add_error(changeset,
          field: :base_rule_set_id,
          message: "the rule set this proposal was replayed against is no longer active"
        )

      {:ok, nil} ->
        Ash.Changeset.add_error(changeset,
          field: :rule_set_id,
          message: "the proposed rule set is gone"
        )

      {:error, error} ->
        Ash.Changeset.add_error(changeset, error)
    end
  end

  defp current(proposal, tenant) do
    case rule_set(proposal.base_rule_set_id, tenant) do
      {:ok, %MatchRuleSet{status: :active}} -> :ok
      {:ok, _not_active} -> {:error, :stale}
      {:error, error} -> {:error, error}
    end
  end

  defp rule_set(id, tenant), do: MatchRuleSet.by_id(id, tenant: tenant, authorize?: false)
end
