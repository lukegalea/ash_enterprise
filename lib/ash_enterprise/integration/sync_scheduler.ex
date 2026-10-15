defmodule AshEnterprise.Integration.SyncScheduler do
  @moduledoc """
  The cron driver for the provider syncs (epic E4): one job per vertical per
  tick, which enqueues one sync step for every *active* linked account of that
  integration.

      %{"integration" => "google-calendar" | "google-mail" | "slack"}

  Scheduled in `config :ash_enterprise, Oban` (`Oban.Plugins.Cron`).

  ## Over-enqueueing is harmless

  Each vertical's worker is unique per linked account across available,
  scheduled, executing and retryable jobs, so a tick that lands while an
  account's step is still queued, running, or snoozing through a long backfill
  collapses into that job. The scheduler therefore never checks "is a sync
  already running"; it enqueues and lets uniqueness decide.

  ## What it reads, and as whom

  The accounts are read as the `oban` system actor across tenants
  (`LinkedAccount.active_for_integration`): ids, owner and tenant only. Every
  step then runs as the human who owns the account, re-resolving it under that
  person's policies, so the scheduler cannot make a step reach anything its
  owner could not. A deactivated or unlinked account is simply not enqueued
  (see "Forgetting a linked account" in `docs/runbooks/crypto-shredding.md`),
  and neither is one whose last step cancelled for a reason only a person can
  fix — a revoked token, a deleted connection, a shredded scope, an inactive
  owner (`AshEnterprise.Integration.SyncBlock`) — until it is unblocked.

  Args are string-keyed ids (Iron Laws #08/#09); the result is counts only.
  """

  use Oban.Worker,
    queue: :ingestion,
    max_attempts: 1,
    unique: [period: 60, keys: [:integration]]

  alias AshEnterprise.Integration.{Calendar, Gmail, LinkedAccount, Slack}
  alias AshEnterprise.Platform.SystemActor

  @integrations ["google-calendar", "google-mail", "slack"]

  @doc "The integrations the scheduler knows how to sync."
  def integrations, do: @integrations

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"integration" => integration}})
      when integration in @integrations do
    {:ok, enqueue(integration)}
  end

  def perform(%Oban.Job{}), do: {:cancel, :unknown_integration}

  @doc """
  Enqueue one step for every active linked account of `integration`. Returns
  `%{integration:, accounts:, enqueued:, already_enqueued:}`.
  """
  @spec enqueue(String.t()) :: map()
  def enqueue(integration) when integration in @integrations do
    accounts =
      LinkedAccount.active_for_integration!(integration, actor: SystemActor.oban())

    results = Enum.map(accounts, &(integration |> job(&1) |> Oban.insert()))

    %{
      integration: integration,
      accounts: length(accounts),
      enqueued: Enum.count(results, &match?({:ok, %{conflict?: false}}, &1)),
      already_enqueued: Enum.count(results, &match?({:ok, %{conflict?: true}}, &1))
    }
  end

  @doc "The vertical's step job for one linked account. Ids only."
  @spec job(String.t(), LinkedAccount.t()) :: Oban.Job.changeset()
  def job("google-calendar", account),
    do: account |> Calendar.SyncWorker.args() |> Calendar.SyncWorker.new()

  def job("google-mail", account),
    do:
      Gmail.SyncWorker.new(
        Gmail.SyncWorker.args(%{owner_id: account.owner_id, linked_account_id: account.id})
      )

  def job("slack", account),
    do: Slack.SyncWorker.new(%{"user_id" => account.owner_id, "linked_account_id" => account.id})
end
