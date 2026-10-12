defmodule AshEnterprise.Integration.Calendar.SyncWorker do
  @moduledoc """
  One calendar sync step for one linked account, as an Oban job.

  Args are ids only and string-keyed (Iron Laws #08/#09):

      %{"user_id" => uuid, "linked_account_id" => uuid, "organization_id" => uuid}

  `perform/1` loads the user, attaches their precomputed `ActorContext`
  (`AshEnterprise.Integration.Calendar.ActorLoader`), and calls the
  `Sync.run_step` action as that user — so every provider call it makes is
  authorized as the person whose account it is, and the connection is
  resolved by the edge from that person's own linked account. Nothing in the
  args selects a connection, and an account the user does not own resolves to
  nothing.

  ## Idempotency (Iron Law #07)

  Unique per linked account while a job is available, scheduled, executing or
  retrying, so overlapping requests collapse into one job. Uniqueness only
  covers jobs: a `run_step` or `reset_sync` called directly can still overlap
  a running job. The cursor writes are compare-and-set for that reason (see
  `SyncCursor`, "Concurrent writers"). A retried step resumes from the persisted
  cursor; a page fetched twice is landed twice under the same source
  identity, which is an upsert.

  ## Outcomes

  | Step result | Job result |
  |---|---|
  | complete | `{:ok, summary}` |
  | page budget used up, more to fetch, or a cursor superseded mid-step | `{:snooze, 1}` — continue promptly |
  | `:rate_limited` | `{:snooze, retry_after}` (60s when the provider gave none) |
  | `:unauthorized`, `:forbidden`, `:connection_not_found`, `:no_linked_account`, `:ambiguous_linked_account`, `:not_configured`, a missing policy grant, a refused landing (not wired, scope shredded, cross-scope) | `{:cancel, reason}` — retrying cannot help |
  | anything else | `{:error, "calendar sync: <reason>"}` — Oban retries |

  Every error the job returns is a structural string or atom. Oban persists
  job errors, and an Ash error from a failed write can carry the payload it
  was writing, so none is ever returned verbatim.
  """

  use Oban.Worker,
    queue: :ingestion,
    max_attempts: 5,
    unique: [
      period: :infinity,
      keys: [:linked_account_id],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  alias AshEnterprise.Integration.Calendar.{ActorLoader, Sync, SyncError}
  alias AshEnterprise.Integration.ProxyError

  @cancel_reasons [
    :unauthorized,
    :forbidden,
    :connection_not_found,
    :no_linked_account,
    :ambiguous_linked_account,
    :not_configured
  ]

  @default_snooze_seconds 60

  @doc "The job args for a linked account: ids only."
  @spec args(struct()) :: %{String.t() => String.t()}
  def args(%{id: id, owner_id: owner_id, organization_id: organization_id}) do
    %{
      "user_id" => owner_id,
      "linked_account_id" => id,
      "organization_id" => organization_id
    }
  end

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{
          "user_id" => user_id,
          "linked_account_id" => linked_account_id,
          "organization_id" => organization_id
        }
      }) do
    case ActorLoader.load(user_id, organization_id) do
      {:ok, actor} -> run(actor, linked_account_id)
      {:error, reason} -> {:cancel, reason}
    end
  end

  def perform(%Oban.Job{}) do
    {:cancel, "calendar sync job requires user_id, linked_account_id and organization_id"}
  end

  defp run(actor, linked_account_id) do
    actor
    |> run_step(linked_account_id)
    |> outcome()
  end

  # A raise inside the step (a bug, a lost connection) must not hand Oban an
  # exception message to persist: messages of Ash errors can quote inputs.
  defp run_step(actor, linked_account_id) do
    Sync.run_step(%{linked_account_id: linked_account_id}, actor: actor)
  rescue
    exception -> {:raised, exception.__struct__}
  end

  defp outcome({:ok, %{status: :more}}), do: {:snooze, 1}
  defp outcome({:ok, summary}), do: {:ok, summary}

  defp outcome({:raised, module}), do: {:error, "calendar sync: raised #{inspect(module)}"}

  defp outcome({:error, error}) do
    if match?(%Ash.Error.Forbidden{}, Ash.Error.to_error_class(error)) do
      {:cancel, :forbidden_by_policy}
    else
      failure(ProxyError.unwrap(error), SyncError.unwrap(error))
    end
  end

  defp failure(%ProxyError{reason: :rate_limited, retry_after_ms: ms}, _sync_error),
    do: {:snooze, snooze_seconds(ms)}

  defp failure(%ProxyError{reason: reason}, _sync_error) when reason in @cancel_reasons,
    do: {:cancel, reason}

  defp failure(%ProxyError{reason: reason}, _sync_error), do: {:error, "calendar sync: #{reason}"}

  defp failure(nil, %SyncError{reason: :landing_refused, detail: detail}),
    do: {:cancel, "landing_refused: #{detail}"}

  defp failure(nil, %SyncError{reason: reason}), do: {:error, "calendar sync: #{reason}"}
  defp failure(nil, nil), do: {:error, "calendar sync: failed"}

  defp snooze_seconds(ms) when is_integer(ms) and ms > 0, do: max(div(ms + 999, 1000), 1)
  defp snooze_seconds(_ms), do: @default_snooze_seconds
end
