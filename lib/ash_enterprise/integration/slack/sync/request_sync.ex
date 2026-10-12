defmodule AshEnterprise.Integration.Slack.Sync.RequestSync do
  @moduledoc """
  `Sync.request_sync`: resolve the actor's own Slack linked account and enqueue
  one `SyncWorker` step for it. The job carries the user id and the linked
  account id — ids only, never a connection or a struct (Iron Laws #08/#09).
  """

  use Ash.Resource.Actions.Implementation

  alias AshEnterprise.Integration.LinkedAccount
  alias AshEnterprise.Integration.Slack.SyncWorker
  alias AshEnterprise.Security.ActorContext

  @impl true
  def run(input, _opts, context) do
    actor_context = ActorContext.for_actor(context.actor)

    with {:ok, user_id, tenant} <- human(actor_context),
         {:ok, account} <-
           resolve(Map.get(input.arguments, :linked_account_id), context, tenant),
         {:ok, job} <- enqueue(user_id, account.id) do
      {:ok, %{job_id: job.id, linked_account_id: account.id, conflict?: job.conflict? == true}}
    end
  end

  defp human(%ActorContext{user_id: user_id, organization_id: tenant})
       when is_binary(user_id) and is_binary(tenant),
       do: {:ok, user_id, tenant}

  defp human(_), do: {:error, "a Slack sync is requested by the human who owns the account"}

  defp resolve(linked_account_id, context, tenant) do
    opts =
      context
      |> Ash.Context.to_opts()
      |> Keyword.put(:tenant, tenant)

    case LinkedAccount.for_operation("slack", linked_account_id, opts) do
      {:ok, [account]} -> {:ok, account}
      {:ok, []} -> {:error, "no active Slack linked account for this actor"}
      {:ok, [_ | _]} -> {:error, "several active Slack linked accounts; pass linked_account_id"}
      {:error, error} -> {:error, error}
    end
  end

  defp enqueue(user_id, linked_account_id) do
    %{"user_id" => user_id, "linked_account_id" => linked_account_id}
    |> SyncWorker.new()
    |> Oban.insert()
  end
end
