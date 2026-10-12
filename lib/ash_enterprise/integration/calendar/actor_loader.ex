defmodule AshEnterprise.Integration.Calendar.ActorLoader do
  @moduledoc """
  Turns a sync job's `user_id` back into an actor: the user with their
  `ActorContext` precomputed and attached, exactly as
  `AshEnterpriseWeb.Plugs.LoadActorContext` does for a request — policy
  checks downstream never query.

  The organization comes from the job args (a user does not carry a tenant).
  A wrong one is harmless: grants and linked accounts are both read inside
  that tenant, so the step resolves nothing and cancels.

  The loader is swappable (`config :ash_enterprise,
  AshEnterprise.Integration.Calendar, actor_loader: Module`, a module with
  `load/2`) so tests can attach hand-built grants for resources whose
  privileges are not seeded yet. Deployment config, never job args.
  """

  alias AshEnterprise.Accounts.User
  alias AshEnterprise.Security.ActorContext

  @callback load(user_id :: Ash.UUID.t(), organization_id :: Ash.UUID.t()) ::
              {:ok, term()} | {:error, atom()}

  @doc "Load the actor through the configured loader."
  @spec load(Ash.UUID.t(), Ash.UUID.t()) :: {:ok, term()} | {:error, atom()}
  def load(user_id, organization_id) do
    case configured() do
      __MODULE__ -> default_load(user_id, organization_id)
      module -> module.load(user_id, organization_id)
    end
  end

  # Identity lookup in a trusted worker: there is no actor yet to authorize as
  # — building one is the point. User is not tenant-scoped.
  defp default_load(user_id, organization_id) do
    case Ash.get(User, user_id, authorize?: false) do
      # An offboarded person's syncs stop with them, whatever roles they
      # still hold (`AshEnterprise.Integration.SyncBlock`).
      {:ok, %User{lifecycle_status: status}} when status != :active ->
        {:error, :user_inactive}

      {:ok, user} ->
        {:ok, ActorContext.attach(user, ActorContext.build(user, tenant: organization_id))}

      {:error, _} ->
        {:error, :user_not_found}
    end
  end

  defp configured do
    :ash_enterprise
    |> Application.get_env(AshEnterprise.Integration.Calendar, [])
    |> Keyword.get(:actor_loader, __MODULE__)
  end
end
