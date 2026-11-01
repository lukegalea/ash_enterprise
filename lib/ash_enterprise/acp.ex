defmodule AshEnterprise.Acp do
  @moduledoc """
  Host seam for `ash_acp` (Productivity OS Dogfood epic E3; dogfood §7 mapping).

  Split across this module (the session table and helpers),
  `AshEnterprise.Acp.SessionStore` (`AshAcp.SessionStore` + `AshAcp.PromptTarget`),
  `AshEnterprise.Acp.Approvals` (`AshAcp.PermissionRequest`; separate module because its
  `resolve/3` collides with `PromptTarget.resolve/3`) and `AshEnterprise.Acp.ExtMethods`
  (the `ash` extension methods: list surfaces, open one — a record selected — without a
  model turn, and act on it, writes behind a permission request).

  **Sessions are in-memory ETS**, owned by the supervised `AshEnterprise.Acp.Store`
  process so they outlive any transient handler; a restart empties them. **Approvals
  are not**: a prompt's permission request is an `AshEnterprise.Execution.Invocation`
  waiting on its approval task (ADR 0055), so it survives the session, the connection
  and a restart, and a client asking again finds it (`AshEnterprise.Acp.Approvals`).
  Nothing in `ash_acp` knows where either lives.

  Mapping per §7: Prompt → a declared Ash action resolved from prompt text, or, when its
  declaration asks for an approval, a request of it; permission request → that
  request's invocation; available actions pruned per actor with `Ash.can?/3` inside
  `ash_acp`.
  """

  @table :ash_enterprise_acp_sessions

  @doc false
  def tables do
    %{sessions: @table}
  end

  @doc false
  def ensure_tables! do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    end

    :ok
  end

  @doc """
  The actor ACP sessions run as: the deployment's operator user, named by
  `config :ash_enterprise, :acp_operator_email` (`ACP_OPERATOR_EMAIL` at boot,
  see `config/runtime.exs`; default `admin@example.com`), read through the
  normal policies — a surface is client-visible data, so it must be produced
  under real authorization, never a bypass. Sessions are local-operator-only
  until authentication lands with E5 (stdio from the operator's console —
  `mix ash_acp.stdio`, or `scripts/acp-attach` into a running node — or
  loopback HTTP).
  """
  def system_actor do
    # Raises if the deployment has not been seeded: an ACP session without a
    # real actor would silently render unauthorized empty surfaces.
    email =
      Application.get_env(:ash_enterprise, :acp_operator_email, "admin@example.com")

    AshEnterprise.Accounts.get_user_by_email!(email, authorize?: false)
  end

  @doc """
  Whether ACP asks the person (`session/request_permission`) before running
  `action` on `resource`, even when policy allows it (dogfood §5: every
  consequential action is an approval).

  Read from the action's `AshAgent.Effects` declaration (ADR 0057): it asks
  unless the declaration says `approval: :none`. An undeclared action asks,
  MCP's cautious default, unless it is an Ash `:read` action, which cannot
  write.
  """
  @spec asks_first?(Ash.Resource.t(), atom()) :: boolean()
  def asks_first?(resource, action) do
    case AshAgent.Effects.Info.effect(resource, action) do
      %{approval: approval} -> approval != :none
      nil -> not read?(resource, action)
    end
  end

  @doc """
  The ACP tool kind of `action` on `resource`: its declared `kind`, or for an
  undeclared action `ash_acp`'s own default (`read` for an Ash `:read`
  action, `execute` otherwise).
  """
  @spec kind(Ash.Resource.t(), atom()) :: AshAgent.Effects.Effect.kind()
  def kind(resource, action) do
    case AshAgent.Effects.Info.effect(resource, action) do
      %{kind: kind} -> kind
      nil -> if read?(resource, action), do: :read, else: :execute
    end
  end

  defp read?(resource, action),
    do: match?(%{type: :read}, Ash.Resource.Info.action(resource, action))

  @doc """
  The organization tenant an actor's data lives under: the actor's own
  organization when present, else the one their business unit belongs to.
  Same resolution `AshEnterprise.Security.ActorContext.build/2` uses.
  """
  def tenant_of(actor) do
    case Map.get(actor, :organization_id) do
      nil -> business_unit_tenant(Map.get(actor, :owning_business_unit_id))
      organization_id -> organization_id
    end
  end

  defp business_unit_tenant(nil), do: nil

  defp business_unit_tenant(bu_id) do
    require Ash.Query

    AshEnterprise.Accounts.BusinessUnit
    |> Ash.Query.select([:organization_id])
    |> Ash.Query.filter(id == ^bu_id)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, %{organization_id: organization_id}} -> organization_id
      _ -> nil
    end
  end
end
