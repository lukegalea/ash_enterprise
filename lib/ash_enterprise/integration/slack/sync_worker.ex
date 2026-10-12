defmodule AshEnterprise.Integration.Slack.SyncWorker do
  @moduledoc """
  The Oban job that runs one `AshEnterprise.Integration.Slack.Syncer` step for
  one linked account.

      %{"user_id" => user_id, "linked_account_id" => linked_account_id}

  Args are string-keyed ids only (Iron Laws #08/#09): the user is re-read and
  their `ActorContext` rebuilt at run time, so a revoked grant or a deactivated
  linked account takes effect on the next run, not the next deploy. The job
  never carries a connection id, a token or content.

  **Idempotent** (Iron Law #07): every write is an upsert keyed on Slack's own
  ids, and the cursor only moves after the page it covers has landed, so a
  retried or duplicated run lands nothing twice. **Unique per linked account**
  while queued or running; enqueue through `Sync.request_sync/2`.

  Outcomes map onto Oban's:

    * a finished step → `:ok`;
    * a step that stopped on its budget with known outstanding work
      (`more?: true`: a pass left part-way, a conversation never visited, or
      members still due) → snooze `continue_after_seconds` (default 5) and
      carry on — snoozing keeps the one job, so uniqueness holds through a long
      backfill. Up-to-date conversations the budget did not reach are not
      outstanding work, so the job always reaches `:ok`;
    * Slack rate limiting → snooze for its `Retry-After`;
    * re-link / consent / grant / not-wired / inactive owner → `{:cancel,
      reason}`; for the reasons in `AshEnterprise.Integration.SyncBlock` the
      account is also blocked, so the scheduler stops polling it;
    * anything transient → `{:error, reason}`, retried with backoff.

  Reasons are atoms. Nothing a step returns carries content, so nothing Oban
  stores in `errors` does either.

  ## Building the actor

  By default the user is loaded by id and `ActorContext.build/2` precomputes
  their grants, exactly as `LoadActorContext` does for a request. The builder is
  configurable (`actor_loader: {Module, :function}`, called with the user id),
  which is how tests attach a context without seeding a role catalogue.
  """

  use Oban.Worker,
    queue: :ingestion,
    max_attempts: 10,
    unique: [
      period: :infinity,
      keys: [:linked_account_id],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  alias AshEnterprise.Integration.Slack.Syncer
  alias AshEnterprise.Integration.SyncBlock
  alias AshEnterprise.Security.ActorContext

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id, "linked_account_id" => linked_account_id}})
      when is_binary(user_id) and is_binary(linked_account_id) do
    case load_actor(user_id) do
      {:ok, actor} -> actor |> Syncer.step(linked_account_id) |> to_oban()
      {:error, reason} when is_atom(reason) -> {:cancel, reason}
      :error -> {:cancel, :unknown_user}
    end
    |> SyncBlock.after_result(linked_account_id)
  end

  def perform(%Oban.Job{}), do: {:cancel, :invalid_args}

  defp to_oban({:ok, %{more?: true}}), do: {:snooze, continue_after_seconds()}
  defp to_oban({:ok, _summary}), do: :ok
  defp to_oban({:snooze, seconds}), do: {:snooze, seconds}
  defp to_oban({:cancel, reason}), do: {:cancel, reason}
  defp to_oban({:error, reason}), do: {:error, reason}

  defp load_actor(user_id) do
    {module, function} = Keyword.get(config(), :actor_loader, {__MODULE__, :default_actor})
    apply(module, function, [user_id])
  end

  @doc false
  # The default actor loader: the user, with the authorization context a
  # request would carry. A trusted read: the worker is acting for this user.
  def default_actor(user_id) do
    case Ash.get(AshEnterprise.Accounts.User, user_id, authorize?: false) do
      # An offboarded person's syncs stop with them (SyncBlock).
      {:ok, %{lifecycle_status: status}} when status != :active -> {:error, :user_inactive}
      {:ok, user} -> {:ok, ActorContext.attach(user, ActorContext.build(user))}
      {:error, _} -> :error
    end
  end

  defp continue_after_seconds, do: Keyword.get(config(), :continue_after_seconds, 5)

  defp config, do: Application.get_env(:ash_enterprise, __MODULE__, [])
end
