defmodule AshEnterprise.Canonical.Validations.ByAPerson do
  @moduledoc """
  Refuses a write whose actor is not a person — a real user row. Deciding a
  proposal (accepting or dismissing it) is its owner's act (ADR 0047): a
  proposer, or any other system actor, cannot accept what it proposed, even
  where it runs with authorization off.

  Positive, like `AshEnterprise.SystemOne.Checks.PersonActor`: anything that
  is not an `AshEnterprise.Accounts.User` is refused, so a future actor kind
  fails closed. Not a policy: the self-service moves run their update with
  authorization off after finding the row as the actor, and this must hold
  there too. Decided from the actor alone, so it is atomic.
  """

  use Ash.Resource.Validation

  @impl true
  def validate(_changeset, _opts, context), do: check(context)

  @impl true
  def atomic(_changeset, _opts, context), do: check(context)

  defp check(%{actor: %AshEnterprise.Accounts.User{}}), do: :ok
  defp check(_context), do: {:error, message: "only the person it was proposed to can decide it"}
end
