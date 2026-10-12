defmodule AshEnterprise.Integration.Console do
  @moduledoc """
  What the operator mix tasks share (`mix ash_enterprise.integration.link`,
  `.accounts`, `.sync`): resolving a person into an actor, describing a linked
  account without its secrets, and running one sync step of any vertical.

  Everything here returns or prints **structure only** — ids, integration
  keys, statuses, counts and reason atoms. Never a connection id in full, never
  content: these run at a shell whose scrollback is outside every erasure scope.
  """

  alias AshEnterprise.Erasure
  alias AshEnterprise.Erasure.Scope
  alias AshEnterprise.Integration.{Calendar, Gmail, Landing, LinkedAccount, ProxyError, Slack}
  alias AshEnterprise.Security.ActorContext

  @integrations ["google-calendar", "google-mail", "slack"]

  @doc "The integration keys the console accepts."
  def integrations, do: @integrations

  @doc """
  The user with `email`, as an actor: their `ActorContext` precomputed exactly
  as a request would carry it. Every action the console runs for them runs
  under their own grants.
  """
  @spec actor_for_email(String.t()) :: {:ok, term()} | {:error, :no_such_user}
  def actor_for_email(email) do
    # Operator console: there is no actor until this lookup makes one.
    case AshEnterprise.Accounts.get_user_by_email(email, authorize?: false) do
      {:ok, user} -> {:ok, actor(user)}
      {:error, _} -> {:error, :no_such_user}
    end
  end

  @doc "The owner of `account`, as an actor (see `actor_for_email/1`)."
  @spec actor_for_owner(LinkedAccount.t()) :: {:ok, term()} | {:error, :no_such_user}
  def actor_for_owner(%LinkedAccount{owner_id: owner_id, organization_id: tenant}) do
    case Ash.get(AshEnterprise.Accounts.User, owner_id, authorize?: false) do
      {:ok, user} -> {:ok, ActorContext.attach(user, ActorContext.build(user, tenant: tenant))}
      {:error, _} -> {:error, :no_such_user}
    end
  end

  defp actor(user), do: ActorContext.attach(user, ActorContext.build(user))

  @doc """
  A linked account by id, read by the console (no actor yet; the step that
  follows runs as its owner). `{:error, :no_such_linked_account}` otherwise.
  """
  @spec linked_account(String.t()) :: {:ok, LinkedAccount.t()} | {:error, atom()}
  def linked_account(id) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         {:ok, %LinkedAccount{} = account} <-
           Ash.get(LinkedAccount, uuid, authorize?: false, not_found_error?: false) do
      {:ok, account}
    else
      _ -> {:error, :no_such_linked_account}
    end
  end

  @doc """
  A connection id with all but its last four characters masked; fully masked
  when it is too short for that to hide anything.
  """
  @spec masked(String.t() | nil) :: String.t()
  def masked(value) when is_binary(value) and byte_size(value) > 8,
    do: "****" <> String.slice(value, -4, 4)

  def masked(_value), do: "****"

  @doc """
  The erasure scope a linked account lands under, as the erasure tasks name it
  (`connection:<ref>`), and its status: `:active`, `:shredded`, or
  `:not_opened` (nothing has landed and the scope has not been opened yet).
  """
  @spec scope_of(LinkedAccount.t()) :: {String.t(), :active | :shredded | :not_opened}
  def scope_of(%LinkedAccount{} = account) do
    ref = Landing.scope(account)
    name = "#{Landing.scope_kind()}:#{ref}"

    case Erasure.scope_by_ref(Landing.scope_kind(), ref, authorize?: false) do
      {:ok, %Scope{status: status}} -> {name, status}
      _ -> {name, :not_opened}
    end
  end

  @doc """
  Run one sync step of `account`'s vertical as `actor` (its owner). Returns a
  flat map of counts, a `:status` (`:complete`, `:more`, `:rate_limited`,
  `:cancelled`, `:failed`) and, when it did not complete, a `:reason` atom or
  structural string. Never a payload.
  """
  @spec step(LinkedAccount.t(), term()) :: map()
  def step(%LinkedAccount{provider_config_key: "google-calendar", id: id}, actor) do
    case Calendar.Sync.run_step(%{linked_account_id: id}, actor: actor) do
      {:ok, summary} ->
        summary
        |> Map.take([:calendars, :pages, :landed, :resets, :superseded, :skipped_calendars])
        |> Map.merge(summary.projection)
        |> Map.put(:status, summary.status)

      {:error, error} ->
        %{status: :failed, reason: calendar_reason(error)}
    end
  end

  def step(%LinkedAccount{provider_config_key: "google-mail", id: id}, actor) do
    case Gmail.Sync.step(actor, id) do
      {:ok, summary} ->
        summary
        |> Map.take([:phase, :landed, :skipped, :reset?])
        |> Map.put(:status, if(summary.more?, do: :more, else: :complete))

      {:snooze, ms} ->
        %{status: :rate_limited, retry_after_ms: ms}

      {:cancel, reason} ->
        %{status: :cancelled, reason: reason}

      {:error, reason} ->
        %{status: :failed, reason: reason}
    end
  end

  def step(%LinkedAccount{provider_config_key: "slack", id: id}, actor) do
    case Slack.Sync.sync_step(%{linked_account_id: id}, actor: actor) do
      {:ok, %{outcome: :ok} = summary} ->
        summary
        |> Map.take([:conversations, :messages, :users, :resets, :skipped])
        |> Map.put(:status, if(summary.more?, do: :more, else: :complete))

      {:ok, %{outcome: :rate_limited, retry_after_seconds: seconds}} ->
        %{status: :rate_limited, retry_after_ms: seconds * 1000}

      {:ok, %{outcome: :cancelled, reason: reason}} ->
        %{status: :cancelled, reason: reason}

      {:ok, %{outcome: :failed, reason: reason}} ->
        %{status: :failed, reason: reason}

      {:error, error} ->
        %{status: :failed, reason: forbidden_or(error, :step_failed)}
    end
  end

  def step(%LinkedAccount{}, _actor), do: %{status: :failed, reason: :unknown_integration}

  defp calendar_reason(error) do
    case {ProxyError.unwrap(error), Calendar.SyncError.unwrap(error)} do
      {%ProxyError{reason: reason}, _} -> reason
      {nil, %Calendar.SyncError{reason: reason, detail: nil}} -> reason
      {nil, %Calendar.SyncError{reason: reason, detail: detail}} -> "#{reason}: #{detail}"
      {nil, nil} -> forbidden_or(error, :step_failed)
    end
  end

  defp forbidden_or(error, fallback) do
    if match?(%Ash.Error.Forbidden{}, Ash.Error.to_error_class(error)),
      do: :forbidden_by_policy,
      else: fallback
  end

  @doc "A step result as one line: `key=value` pairs, sorted, status first."
  @spec format(map()) :: String.t()
  def format(%{status: status} = result) do
    rest =
      result
      |> Map.delete(:status)
      |> Enum.sort()
      |> Enum.map_join(" ", fn {key, value} -> "#{key}=#{value}" end)

    String.trim("status=#{status} #{rest}")
  end
end
