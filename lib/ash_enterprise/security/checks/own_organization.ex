defmodule AshEnterprise.Security.Checks.OwnOrganization do
  @moduledoc """
  The organization row is the actor's own: `id` is the organization of the actor's
  `ActorContext`.

  `AshEnterprise.Accounts.Organization` is the tenant, so it is not tenant-scoped, and a
  `:global` grant on it reaches every tenant's row. An action that is an organization's
  decision about itself (`set_sole_administrator_approval`) declares this as its own
  policy beside the grant union: the union decides whether the actor may write an
  organization, and this decides which one. A person only; a system actor or a context
  with no organization reaches nothing here.

  ## Never queries

  The organization id is already on the actor's precomputed context.
  """

  use Ash.Policy.FilterCheck

  alias AshEnterprise.Security.ActorContext

  require Ash.Expr
  import Ash.Expr, only: [expr: 1]

  @impl true
  def describe(_opts), do: "the organization is the actor's own"

  @impl true
  def filter(actor, _authorizer, _opts) do
    case ActorContext.for_actor(actor) do
      %{system?: true} -> false
      %{user_id: nil} -> false
      %{organization_id: nil} -> false
      %{organization_id: organization_id} -> expr(id == ^organization_id)
    end
  end
end
