defmodule AshEnterprise.Canonical.Commitments.SweepWorker do
  @moduledoc """
  The commitment sweep's cron (`AshEnterprise.Canonical.Commitments.sweep/1`):
  every ten minutes, a batch of unread sent messages and ended meetings is
  read and their proposals written. On the `:system_one` queue, with the
  other model-bound work; one at a time (`unique`), and idempotent — a
  record is read once, and a rerun finds it scanned.
  """

  use Oban.Worker, queue: :system_one, max_attempts: 3, unique: [period: 300]

  require Logger

  alias AshEnterprise.Canonical.Commitments

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    result = Commitments.sweep()

    if result.messages + result.meetings > 0 do
      Logger.info(
        "commitments: read #{result.messages} messages, #{result.meetings} meetings; " <>
          "proposed #{result.proposed}"
      )
    end

    # No in-zone target: the messages wait, every tick, without a word sent.
    if result.skipped, do: Logger.debug("commitments: messages not read (#{result.skipped})")

    :ok
  end
end
