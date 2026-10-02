defmodule AshEnterprise.Security.Checks.SystemActor do
  @moduledoc """
  True when the actor is a non-human system actor — except `ai`, which is an
  attribution label with no authority and never matches (ADR 0043, AST-136).

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
  def describe(_opts), do: "actor is a system actor (never `ai`)"

  @impl true
  # ADR 0043: the `ai` system actor is an attribution label, not an authority.
  # It never bypasses grants — model-driven work runs as the requesting human,
  # or as an automation principal holding grant rows. This clause must stay
  # above the general one.
  def match?(%AshEnterprise.Platform.SystemActor{name: :ai}, _authorizer, _opts), do: false

  def match?(%AshEnterprise.Platform.SystemActor{}, _authorizer, _opts), do: true
  def match?(%ActorContext{system?: true}, _authorizer, _opts), do: true

  def match?(actor, _authorizer, _opts) do
    case actor do
      %{__ash_enterprise_context__: %ActorContext{system?: true}} -> true
      _ -> false
    end
  end
end
