defmodule AshEnterprise.Integration.Gmail.SyncWorker do
  @moduledoc """
  One Gmail sync step for one linked account, as an Oban job (epic E4).

  Args are ids only and string-keyed (Iron Laws #08, #09):

      %{"user_id" => owner_id, "linked_account_id" => linked_account_id}

  The job loads the user, attaches a freshly built `ActorContext` (roles and
  grants as they are *now*, not as they were at enqueue time) and runs
  `AshEnterprise.Integration.Gmail.Sync.step/3` as that human. The Nango
  connection is never in the args: the edge derives it from the actor's own
  linked account.

  ## Idempotent, unique per account

  Unique on `linked_account_id` across available, scheduled, executing and
  retryable jobs, so a second request while a step is queued or running
  collapses into it. Re-running a completed step re-reads from the committed
  cursor and lands nothing it already landed; a step that failed part-way
  re-lands at most the page it was on, which the lander's upsert absorbs.

  ## Outcomes

  | `Sync.step/3` | Job result |
  |---|---|
  | `{:ok, %{more?: false}}` | `:ok` |
  | `{:ok, %{more?: true}}` (stopped on the page budget) | `{:snooze, 1}`, continue shortly |
  | `{:snooze, ms}` (rate limited) | `{:snooze, seconds}` |
  | `{:cancel, reason}` (needs a person: re-link, consent, landing not wired) | `{:cancel, reason}` |
  | `{:error, reason}` | `{:error, reason}`, retried with backoff |

  Nothing is logged by this module; Oban records the outcome, and every
  reason is an atom, never a response body.

  Enqueue through `SyncState.request_sync/2` (which also creates the cursor
  row) rather than inserting directly.
  """

  use Oban.Worker,
    queue: :ingestion,
    max_attempts: 10,
    unique: [
      period: :infinity,
      keys: [:linked_account_id],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  alias AshEnterprise.Accounts.User
  alias AshEnterprise.Integration.Gmail.Sync
  alias AshEnterprise.Security.ActorContext

  @doc "The job args for a cursor row (or anything carrying owner and account ids)."
  @spec args(%{owner_id: Ash.UUID.t(), linked_account_id: Ash.UUID.t()}) :: map()
  def args(%{owner_id: user_id, linked_account_id: linked_account_id}) do
    %{"user_id" => user_id, "linked_account_id" => linked_account_id}
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id, "linked_account_id" => linked_account_id}})
      when is_binary(user_id) and is_binary(linked_account_id) do
    case load_actor(user_id) do
      {:ok, actor} -> actor |> Sync.step(linked_account_id) |> outcome()
      :error -> {:cancel, :no_such_user}
    end
  end

  def perform(%Oban.Job{}), do: {:cancel, :invalid_args}

  # Loading the actor is the one read that cannot run as the actor: it is how
  # the actor comes to exist. Everything after it runs under the user's own
  # policies.
  defp load_actor(user_id) do
    case Ash.get(User, user_id, authorize?: false) do
      {:ok, %User{} = user} -> {:ok, ActorContext.attach(user, ActorContext.build(user))}
      _ -> :error
    end
  end

  defp outcome({:ok, %{more?: true}}), do: {:snooze, 1}
  defp outcome({:ok, _summary}), do: :ok
  defp outcome({:snooze, ms}), do: {:snooze, max(1, div(ms + 999, 1000))}
  defp outcome({:cancel, reason}), do: {:cancel, reason}
  defp outcome({:error, reason}), do: {:error, reason}
end
