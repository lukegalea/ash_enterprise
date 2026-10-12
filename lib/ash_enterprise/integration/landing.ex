defmodule AshEnterprise.Integration.Landing do
  @moduledoc """
  The one call an adapter makes to land a fetched record:

      Landing.land(%SourceRecord{...}, scope: Landing.scope(linked_account))

  The scope names the linked account the record was fetched through, so that
  crypto-shredding (ADR 0024) can encrypt it under that account's key and
  erase the account by destroying the key.

  ## Refuses until wired

  The lander is pluggable (`config :ash_enterprise, AshEnterprise.Integration.Landing,
  lander: Module`) and the default, `AshEnterprise.Integration.Landing.NotWired`,
  lands **nothing** and returns `{:error, :scoped_landing_not_wired}`. Real
  message, email and event content must not be persisted before scoped
  encryption is on main; the integration step points `:lander` at the
  "land under scope X" implementation. Tests configure a stub lander.

  A lander implements `c:land/2`.
  """

  alias AshEnterprise.Integration.{LinkedAccount, SourceRecord}

  @doc "Land one record under a scope."
  @callback land(SourceRecord.t(), scope_ref :: String.t()) :: {:ok, term()} | {:error, term()}

  @doc """
  Land one record under `scope:` (required — a record without a scope cannot be
  shredded, so there is no default).
  """
  @spec land(SourceRecord.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def land(%SourceRecord{} = record, opts) do
    case Keyword.fetch(opts, :scope) do
      {:ok, scope_ref} when is_binary(scope_ref) and scope_ref != "" ->
        lander().land(record, scope_ref)

      _ ->
        {:error, :scope_required}
    end
  end

  @doc """
  The scope reference for a linked account: stable, opaque, carries no
  connection id. `"integration.linked_account:<uuid>"`.
  """
  @spec scope(struct() | String.t()) :: String.t()
  def scope(%LinkedAccount{id: id}), do: scope(id)
  def scope(id) when is_binary(id), do: "integration.linked_account:" <> id

  defp lander do
    :ash_enterprise
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:lander, AshEnterprise.Integration.Landing.NotWired)
  end
end
