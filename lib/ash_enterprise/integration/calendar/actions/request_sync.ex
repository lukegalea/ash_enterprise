defmodule AshEnterprise.Integration.Calendar.Actions.RequestSync do
  @moduledoc """
  `Sync.request_sync`: enqueue a `SyncWorker` step for one of the actor's own
  Google Calendar accounts.

  The account is resolved under the actor's policies before anything is
  enqueued, so a job can only ever name an account its user owns. The job
  carries ids only — user, linked account, organization — never a struct,
  token or connection (Iron Laws #08/#09; ADR 0011).

  Returns `%{linked_account_id: id, job_id: id, already_enqueued: boolean}`.
  """

  use Ash.Resource.Actions.Implementation

  alias AshEnterprise.Integration.Calendar.{Step, SyncWorker}

  @impl true
  def run(input, _opts, context) do
    with {:ok, account} <-
           Step.resolve_account(context.actor, Map.get(input.arguments, :linked_account_id)),
         {:ok, job} <- account |> SyncWorker.args() |> SyncWorker.new() |> Oban.insert() do
      {:ok,
       %{
         linked_account_id: account.id,
         job_id: job.id,
         already_enqueued: Map.get(job, :conflict?, false)
       }}
    end
  end
end
