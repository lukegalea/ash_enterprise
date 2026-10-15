defmodule AshEnterprise.Integration.Landing do
  @moduledoc """
  The one call an adapter makes to land a fetched record, sealed under the
  erasure scope of the linked account it came through (ADR 0024):

      {:ok, scope} = Landing.open(linked_account)      # once per sync step
      Landing.land(%SourceRecord{...}, scope: scope)   # per record

  ## One scope per linked account

  The scope is `kind: :connection`, `ref:` the linked account's uuid
  (`scope/1`). That ref is opaque: never the Nango connection id, an email
  address or a channel name, because a scope's `ref` and `label` are
  structural, audited when the scope opens and readable after its shred.
  `mix ash_enterprise.integration.accounts` prints each account's ref, and
  `mix ash_enterprise.erasure.shred connection:<ref>` erases everything that
  came in through it — raw landings and every canonical row projected from
  them.

  ## Open once, then land

  `open/1` resolves (and, the first time, issues) the account's scope. It is a
  query, so a step calls it once, before its first provider request: a step
  whose scope is already shredded is refused with `{:error, :scope_shredded}`
  before it fetches anything. `land/2` then takes the opened scope. A bare ref
  string is accepted too and opened on the spot, which costs the lookup per
  record.

  ## The lander

  Pluggable (`config :ash_enterprise, AshEnterprise.Integration.Landing,
  lander: Module`). The configured one is `AshEnterprise.Integration.Landing.Scoped`,
  which seals into `AshEnterprise.Ingestion.SourceObject`. With no `:lander`
  configured the default is `AshEnterprise.Integration.Landing.NotWired`, which
  lands nothing and returns `{:error, :scoped_landing_not_wired}`; every
  vertical checks `wired?/0` before its first provider call.

  A lander implements `c:land/2` and, optionally, `c:open_scope/2`. A lander
  without `open_scope/2` (a test double) receives the bare ref string as its
  scope.
  """

  alias AshEnterprise.Integration.{LinkedAccount, SourceRecord}

  @doc """
  Resolve the scope `ref` names, opening it the first time with `attrs`
  (`label`). `{:error, :scope_shredded}` for a scope that has been shredded.
  """
  @callback open_scope(ref :: String.t(), attrs :: map()) :: {:ok, term()} | {:error, term()}

  @doc "Land one record under an opened scope (or a bare ref, see the moduledoc)."
  @callback land(SourceRecord.t(), scope :: term()) :: {:ok, term()} | {:error, term()}

  @optional_callbacks open_scope: 2

  @doc """
  Whether a real lander is configured. False means every landing is refused, so
  a vertical must not fetch content at all.
  """
  @spec wired?() :: boolean()
  def wired?, do: lander() != AshEnterprise.Integration.Landing.NotWired

  @doc """
  Open the linked account's scope, once per step. `{:ok, scope}`, or
  `{:error, :scoped_landing_not_wired | :scope_shredded | atom()}`.
  """
  @spec open(LinkedAccount.t()) :: {:ok, term()} | {:error, atom()}
  def open(%LinkedAccount{} = account) do
    lander = lander()
    ref = scope(account)

    cond do
      lander == AshEnterprise.Integration.Landing.NotWired ->
        {:error, :scoped_landing_not_wired}

      Code.ensure_loaded?(lander) and function_exported?(lander, :open_scope, 2) ->
        lander.open_scope(ref, %{label: label(account)})

      true ->
        {:ok, ref}
    end
  end

  @doc """
  Land one record under `scope:` (required — a record without a scope cannot be
  shredded, so there is no default).
  """
  @spec land(SourceRecord.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def land(%SourceRecord{} = record, opts) do
    case Keyword.fetch(opts, :scope) do
      {:ok, ref} when is_binary(ref) and ref != "" -> lander().land(record, ref)
      {:ok, %{} = opened} -> lander().land(record, opened)
      _ -> {:error, :scope_required}
    end
  end

  @doc """
  The erasure scope ref of a linked account: its uuid. Opaque and stable; never
  a connection id. The scope is `connection:<ref>` to the erasure tasks.
  """
  @spec scope(LinkedAccount.t() | String.t()) :: String.t()
  def scope(%LinkedAccount{id: id}), do: scope(id)
  def scope(id) when is_binary(id), do: id

  @doc "The erasure scope kind every linked account's scope has."
  @spec scope_kind() :: :connection
  def scope_kind, do: :connection

  @doc """
  The scope's label: the integration key and nothing else. Structural, like the
  ref — a person's label for their account ("work") could be their name.
  """
  @spec label(LinkedAccount.t()) :: String.t()
  def label(%LinkedAccount{provider_config_key: key}), do: "linked account (#{key})"

  defp lander do
    :ash_enterprise
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:lander, AshEnterprise.Integration.Landing.NotWired)
  end
end
