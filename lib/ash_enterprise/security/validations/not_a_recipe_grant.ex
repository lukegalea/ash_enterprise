defmodule AshEnterprise.Security.Validations.NotARecipeGrant do
  @moduledoc """
  Refuses a start grant for a recipe's key (`recipe:<key>:<version>`) through `grant`.

  A recipe's start grant is what its standing grant runs under (ADR 0069), and it is the
  publisher's own act: `publish_granted` writes it for the person it stamps as accountable,
  with the review date `AshEnterprise.Bpmn.Subscription.Authority.grant_review_days/0`
  sets, through `AgentStartGrant`'s `grant_recipe`. Written through `grant`, an
  administrator could revive a revoked one, extend one past its review date, or hand one to
  a team the publisher belongs to, and a version would run again with no act by its
  publisher. So `grant` writes every other key and never this one.
  """

  use Ash.Resource.Validation

  alias AshEnterprise.Bpmn.Subscription.Authority

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :agent_key) do
      key when is_binary(key) ->
        if Authority.grant_key?(key),
          do:
            {:error,
             field: :agent_key,
             message:
               "a recipe's start grant is written by publishing the recipe with " <>
                 "publish_granted, never granted directly"},
          else: :ok

      _other ->
        :ok
    end
  end
end
