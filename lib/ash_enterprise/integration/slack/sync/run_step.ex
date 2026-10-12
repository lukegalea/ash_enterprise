defmodule AshEnterprise.Integration.Slack.Sync.RunStep do
  @moduledoc """
  `Sync.sync_step`: run one `AshEnterprise.Integration.Slack.Syncer` step
  inline, as the actor. Every outcome is reported as a map of counts, ids and
  atoms — the step ran; whether Slack let it finish is data, not an exception.

      %{outcome: :ok, conversations: 3, messages: 41, users: 5, resets: 0, skipped: 0, more?: false}
      %{outcome: :rate_limited, retry_after_seconds: 30}
      %{outcome: :cancelled, reason: :unauthorized}
      %{outcome: :failed, reason: :server_error}
  """

  use Ash.Resource.Actions.Implementation

  alias AshEnterprise.Integration.Slack.Syncer

  @impl true
  def run(input, _opts, context) do
    result =
      case Syncer.step(context.actor, Map.get(input.arguments, :linked_account_id)) do
        {:ok, summary} -> Map.put(summary, :outcome, :ok)
        {:snooze, seconds} -> %{outcome: :rate_limited, retry_after_seconds: seconds}
        {:cancel, reason} -> %{outcome: :cancelled, reason: reason}
        {:error, reason} -> %{outcome: :failed, reason: reason}
      end

    {:ok, result}
  end
end
