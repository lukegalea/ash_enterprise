defmodule AshEnterprise.Security.Checks.SystemActor do
  @moduledoc """
  True when the actor is a non-human system actor.

  Used as a `bypass` rather than as another `authorize_if` in the union, because
  it is categorically different from the grant paths: it is not "this actor has
  been granted this", it is "this actor is not subject to grants".

  A simple check rather than a filter check — the answer does not depend on the
  record, so there is no filter to build and reads are not narrowed.

  See `AshEnterprise.Platform.SystemActor` for why system actors are compile-time
  constants rather than rows with a superuser role, and
  `AshEnterprise.Security.Policies` for where this sits in the policy set.
  """

  use Ash.Policy.SimpleCheck

  alias AshEnterprise.Security.ActorContext

  @impl true
  def describe(_opts), do: "actor is a system actor"

  @impl true
  def match?(%AshEnterprise.Platform.SystemActor{}, _authorizer, _opts), do: true
  def match?(%ActorContext{system?: true}, _authorizer, _opts), do: true

  def match?(actor, _authorizer, _opts) do
    case actor do
      %{__ash_enterprise_context__: %ActorContext{system?: true}} -> true
      _ -> false
    end
  end
end
