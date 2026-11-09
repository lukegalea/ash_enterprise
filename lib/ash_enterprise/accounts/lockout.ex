defmodule AshEnterprise.Accounts.Lockout do
  @moduledoc """
  Lockout after repeated failed sign-ins, backed by Postgres
  (`AshEnterprise.Accounts.SignInLockout`) so it holds across nodes.

  Limits are read at call time and a host sets them:

      config :ash_enterprise, AshEnterprise.Accounts.Lockout,
        max_attempts: 5,        # failures that lock the identity
        window_seconds: 900,    # failures further apart than this start a new count
        lockout_seconds: 900    # how long a lock lasts

  A setting that is not a positive integer raises; it never turns the lockout off.

  What is unknown counts as locked: if the counter cannot be read, the sign-in is
  refused (`status_or_locked/1`).

  Nothing here says whether an address is registered. A refusal looks like a
  wrong password.
  """

  alias AshEnterprise.Accounts.SignInLockout

  @defaults [max_attempts: 5, window_seconds: 900, lockout_seconds: 900]
  @interaction %{private: %{ash_authentication?: true}}

  @type status :: :open | {:locked, DateTime.t()} | {:error, term()}

  @doc "The limits in force: `%{max_attempts:, window_seconds:, lockout_seconds:}`."
  @spec limits() :: %{
          max_attempts: pos_integer(),
          window_seconds: pos_integer(),
          lockout_seconds: pos_integer()
        }
  def limits do
    configured = Application.get_env(:ash_enterprise, __MODULE__, [])

    for {name, default} <- @defaults, into: %{} do
      case Keyword.get(configured, name, default) do
        n when is_integer(n) and n > 0 ->
          {name, n}

        other ->
          raise ArgumentError,
                "config :ash_enterprise, #{inspect(__MODULE__)}, #{name}: must be a positive " <>
                  "integer, got: #{inspect(other)}"
      end
    end
  end

  @doc """
  The stored key for an identity: a digest of the trimmed, lower-cased text.
  Anything that is not text (nil, a number, a map) and a blank string share one
  bucket rather than escaping the count.
  """
  @spec key(term()) :: String.t()
  def key(identity) when is_binary(identity) or is_struct(identity, Ash.CiString) do
    normalized = identity |> to_string() |> String.trim() |> String.downcase()
    :sha256 |> :crypto.hash(normalized) |> Base.encode16(case: :lower)
  end

  def key(_other), do: key("")

  @doc "Counts one failed sign-in for `identity`. Options: `:now`."
  @spec record_failure(term(), keyword()) :: {:ok, SignInLockout.t()} | {:error, term()}
  def record_failure(identity, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    %{max_attempts: max, window_seconds: window, lockout_seconds: lock} = limits()

    input = %{
      key: key(identity),
      now: now,
      window_cutoff: DateTime.add(now, -window, :second),
      lock_until: DateTime.add(now, lock, :second),
      max_attempts: max
    }

    upsert_with_retry(input, 3)
  end

  # A concurrent first insert of the same key can lose the race to the unique index.
  # The row exists by the time the retry runs, so the retry takes the update path.
  defp upsert_with_retry(input, attempts_left) do
    SignInLockout
    |> Ash.Changeset.for_create(:record_failure, input, context: @interaction)
    |> Ash.create()
    |> case do
      {:error, _} when attempts_left > 1 -> upsert_with_retry(input, attempts_left - 1)
      other -> other
    end
  end

  @doc "`:open`, `{:locked, until}` or `{:error, reason}`. Options: `:now`."
  @spec status(term(), keyword()) :: status()
  def status(identity, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    case fetch(identity) do
      {:ok, %{locked_until: %DateTime{} = until}} ->
        if DateTime.compare(until, now) == :gt, do: {:locked, until}, else: :open

      {:ok, _} ->
        :open

      {:error, _} = error ->
        error
    end
  end

  @doc """
  `status/2` collapsed for a gate: anything but a clean `:open` is locked. An
  unreadable store is `{:locked, :unknown}`. Takes an identity or a function
  returning a status.
  """
  @spec status_or_locked(term()) :: :open | {:locked, DateTime.t() | :unknown}
  def status_or_locked(fun) when is_function(fun, 0), do: fun.() |> collapse()
  def status_or_locked(identity), do: identity |> status() |> collapse()

  defp collapse(:open), do: :open
  defp collapse({:locked, _} = locked), do: locked
  defp collapse(_unknown), do: {:locked, :unknown}

  @doc "The failures stored for `identity` (0 when there is no row)."
  @spec failures(term()) :: non_neg_integer()
  def failures(identity) do
    case fetch(identity) do
      {:ok, %{failed_count: count}} -> count
      _ -> 0
    end
  end

  @doc "Forgets the count for `identity`, as a successful sign-in does."
  @spec clear(term()) :: :ok | {:error, term()}
  def clear(identity) do
    case fetch(identity) do
      {:ok, nil} ->
        :ok

      {:ok, row} ->
        case Ash.destroy(row, context: @interaction) do
          :ok -> :ok
          {:ok, _} -> :ok
          {:error, _} = error -> error
        end

      {:error, _} = error ->
        error
    end
  end

  defp fetch(identity) do
    SignInLockout
    |> Ash.Query.for_read(:by_key, %{key: key(identity)}, context: @interaction)
    |> Ash.read_one()
  end
end
