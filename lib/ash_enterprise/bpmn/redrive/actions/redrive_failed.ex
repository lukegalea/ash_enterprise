defmodule AshEnterprise.Bpmn.Redrive.Actions.RedriveFailed do
  @moduledoc """
  Finds the failed start dispatches whose event lies in a range of the tenant's log and
  drives each again through `AshEnterprise.Bpmn.Redrive.record`, as the calling person.

  The range is by event sequence (`from_sequence`/`to_sequence`, inclusive), by when the
  events happened (`since` inclusive, `until` exclusive), or both. At least one bound is
  required: a re-drive of everything a tenant ever failed is not a thing to do by accident.

  One event that failed more than once has several failed rows; it is driven once, from its
  newest. Each re-drive is its own transaction, so one that raises leaves the others done.
  Only the tenant's own dispatches are read.
  """

  use Ash.Resource.Actions.Implementation

  require Ash.Query

  alias AshEnterprise.Bpmn.{Dispatch, Redrive}

  @bounds [:from_sequence, :to_sequence, :since, :until]

  @impl true
  # Without a tenant the dispatch read would span every organization's ledger.
  def run(%{tenant: nil}, _opts, _context), do: {:error, "a re-drive needs a tenant"}

  def run(input, _opts, context) do
    if Enum.all?(@bounds, &is_nil(Ash.ActionInput.get_argument(input, &1))) do
      {:error,
       Ash.Error.Invalid.exception(
         errors: [
           Ash.Error.Changes.InvalidArgument.exception(
             field: :from_sequence,
             message: "give a range: a sequence bound, a time bound, or both"
           )
         ]
       )}
    else
      input
      |> failed(input.tenant)
      |> redrive_each(context.actor, input.tenant)
    end
  end

  defp redrive_each(dispatches, actor, tenant) do
    dispatches
    |> Enum.reduce_while([], fn dispatch, acc ->
      case Redrive.record(dispatch.id, actor: actor, tenant: tenant) do
        {:ok, redrive} -> {:cont, [redrive | acc]}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:error, error} -> {:error, error}
      redrives -> {:ok, Enum.reverse(redrives)}
    end
  end

  # The newest failed row of each (subscription, event), oldest event first.
  defp failed(input, tenant) do
    Dispatch
    |> Ash.Query.filter(status == :failed and kind == :start and not is_nil(subscription_id))
    |> bound(:from_sequence, Ash.ActionInput.get_argument(input, :from_sequence))
    |> bound(:to_sequence, Ash.ActionInput.get_argument(input, :to_sequence))
    |> bound(:since, Ash.ActionInput.get_argument(input, :since))
    |> bound(:until, Ash.ActionInput.get_argument(input, :until))
    |> Ash.Query.sort(event_sequence: :asc, inserted_at: :desc)
    |> Ash.read!(authorize?: false, tenant: tenant)
    |> Enum.uniq_by(&{&1.subscription_id, &1.event_id})
  end

  defp bound(query, _bound, nil), do: query
  defp bound(query, :from_sequence, n), do: Ash.Query.filter(query, event_sequence >= ^n)
  defp bound(query, :to_sequence, n), do: Ash.Query.filter(query, event_sequence <= ^n)
  defp bound(query, :since, at), do: Ash.Query.filter(query, event_occurred_at >= ^at)
  defp bound(query, :until, at), do: Ash.Query.filter(query, event_occurred_at < ^at)
end
