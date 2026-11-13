defmodule AshEnterprise.Security.Checks.PlatformOperator do
  @moduledoc """
  True when the actor is the platform operator, as `AshEnterprise.Execution.Authority`
  names one: an active person holding `write` at `:global` on one of the operator-only
  resources, the grant `mix ash_enterprise.platform.grant_operator` makes.

  For rows that belong to the platform rather than to any tenant, such as the sign-in
  record (`AshEnterprise.Security.AuthenticationEvent`). A simple check: the answer does
  not depend on the record, and it never queries, because the operator's grants are
  already on the actor's precomputed `AshEnterprise.Security.ActorContext`.
  """

  use Ash.Policy.SimpleCheck

  alias AshEnterprise.Execution.Authority

  @impl true
  def describe(_opts), do: "actor is the platform operator"

  @impl true
  def match?(actor, _context, _opts), do: Authority.operator?(actor)
end
