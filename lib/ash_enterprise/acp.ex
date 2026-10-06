defmodule AshEnterprise.Acp do
  @moduledoc """
  Host seam for `ash_acp` (Productivity OS Dogfood epic E3; dogfood §7 mapping).

  Split across this module (shared tables + helpers), `AshEnterprise.Acp.SessionStore`
  (`AshAcp.SessionStore` + `AshAcp.PromptTarget`) and `AshEnterprise.Acp.Approvals`
  (`AshAcp.PermissionRequest`; separate module because its `resolve/3` collides with
  `PromptTarget.resolve/3`).

  **The stores here are deliberately in-memory ETS**, owned by the supervised
  `AshEnterprise.Acp.Store` process so they outlive any transient handler. E3's
  gate is the wire round-trip against real Ash actions; the durable
  `AgentSession` / approval resources that replace them arrive with epic E5
  (dogfood §6, ADR 0015). The swap is contained to these modules — nothing in
  `ash_acp` knows where sessions live.

  Mapping per §7: Prompt → a declared Ash action resolved from prompt text;
  permission request → a pending approval record until E5's approval resource
  exists; available actions pruned per actor with `Ash.can?/3` inside `ash_acp`.
  """

  @table :ash_enterprise_acp_sessions
  @approvals :ash_enterprise_acp_approvals

  @doc false
  def tables do
    %{sessions: @table, approvals: @approvals}
  end

  @doc false
  def approvals_table, do: @approvals

  @doc false
  def ensure_tables! do
    unless :ets.whereis(@table) == :undefined do
      :ok
    else
      :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    end

    if :ets.whereis(@approvals) == :undefined do
      :ets.new(@approvals, [:named_table, :set, :public, read_concurrency: true])
    end

    :ok
  end

  @doc """
  The actor ACP sessions run as: the deployment's seeded operator user
  (`admin@example.com`), read through the normal policies — a surface is
  client-visible data, so it must be produced under real authorization, never
  a bypass. Sessions are local-operator-only until authentication lands with
  E5 (stdio from the operator's console, or loopback HTTP).
  """
  def system_actor do
    # Raises if the deployment has not been seeded: an ACP session without a
    # real actor would silently render unauthorized empty surfaces.
    AshEnterprise.Accounts.get_user_by_email!("admin@example.com", authorize?: false)
  end

  @doc """
  The organization tenant an actor's data lives under: the actor's own
  organization when present, else the one their business unit belongs to.
  Same resolution `AshEnterprise.Security.ActorContext.build/2` uses.
  """
  def tenant_of(actor) do
    case Map.get(actor, :organization_id) do
      nil ->
        case Map.get(actor, :owning_business_unit_id) do
          nil ->
            nil

          bu_id ->
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

      organization_id ->
        organization_id
    end
  end
end
