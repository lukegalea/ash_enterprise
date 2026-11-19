defmodule AshEnterprise.Integration.Outbound.Changes.Deliver do
  @moduledoc """
  One attempt at a delivery: send its CloudEvent through
  `AshEnterprise.Integration.Outbound.Receiver.deliver`, as the `oban` system actor in the
  delivery's own tenant, then record what happened.

  | Outcome | State | Endpoint |
  |---|---|---|
  | 2xx | `delivered` | its run of dead letters resets |
  | refused before sending (disclosure gate, egress guard, a shredded secret) | `refused`, never retried | an egress refusal sets it `failing` |
  | anything else (a 4xx, a 5xx, a timeout, no connection) | `pending` again, after the next wait | |
  | anything else, on the sixth attempt | `dead` | three in a row set it `failing` |

  The waits are 1 minute, 5 minutes, 30 minutes, 2 hours and 12 hours: the first send and
  five retries. `last_status` and `last_reason` hold the status and a short code, never a
  response body.
  """

  use Ash.Resource.Change

  alias AshEnterprise.Integration.Outbound.{CloudEvent, Endpoint, Receiver}
  alias AshEnterprise.Platform.SystemActor

  @waits [
    :timer.minutes(1),
    :timer.minutes(5),
    :timer.minutes(30),
    :timer.hours(2),
    :timer.hours(12)
  ]

  @doc "The waits between attempts, in milliseconds."
  def waits, do: @waits

  @doc "How many attempts a delivery gets before it is dead."
  def max_attempts, do: length(@waits) + 1

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, &attempt/1)
  end

  defp attempt(changeset) do
    delivery = changeset.data
    attempt = delivery.attempts + 1

    arguments =
      delivery
      |> CloudEvent.arguments()
      |> Map.merge(%{
        endpoint_id: delivery.endpoint_id,
        message_id: delivery.event_id,
        disclosure_ref: delivery.endpoint_id
      })

    result =
      Receiver.deliver(arguments, actor: SystemActor.oban(), tenant: delivery.organization_id)

    changeset
    |> Ash.Changeset.force_change_attribute(:attempts, attempt)
    |> record(result, attempt, delivery)
  end

  defp record(changeset, {:ok, _body}, _attempt, delivery) do
    note(delivery, :delivered, nil)

    changeset
    |> Ash.Changeset.force_change_attribute(:state, :delivered)
    |> Ash.Changeset.force_change_attribute(:delivered_at, DateTime.utc_now())
    |> Ash.Changeset.force_change_attribute(:last_status, nil)
    |> Ash.Changeset.force_change_attribute(:last_reason, nil)
  end

  defp record(changeset, {:error, error}, attempt, delivery) do
    failure = AshOperations.Error.unwrap(error)
    {reason, code, status} = describe(failure)

    changeset =
      changeset
      |> Ash.Changeset.force_change_attribute(:last_status, status)
      |> Ash.Changeset.force_change_attribute(:last_reason, code || reason)

    cond do
      refused?(failure) ->
        if egress?(code), do: note(delivery, :egress_refused, code)
        Ash.Changeset.force_change_attribute(changeset, :state, :refused)

      attempt >= max_attempts() ->
        note(delivery, :dead, nil)
        Ash.Changeset.force_change_attribute(changeset, :state, :dead)

      true ->
        Ash.Changeset.force_change_attribute(
          changeset,
          :next_attempt_at,
          DateTime.add(DateTime.utc_now(), Enum.at(@waits, attempt - 1), :millisecond)
        )
    end
  end

  defp describe(%AshOperations.Error{reason: reason, provider_code: code, status: status}),
    do: {Atom.to_string(reason), code, status}

  # Not an operation error (an authorization failure, a crash in a step): kept as a short
  # class name and retried, so a fix lets it through.
  defp describe(_other), do: {"error", nil, nil}

  defp refused?(%AshOperations.Error{reason: reason})
       when reason in [:disclosure_refused, :not_configured],
       do: true

  defp refused?(_failure), do: false

  defp egress?("egress_" <> _), do: true
  defp egress?(_code), do: false

  # The endpoint's run of dead letters and its status. A delivered event touches the
  # endpoint only when there is a run to reset, so a healthy endpoint writes nothing here.
  defp note(delivery, outcome, code) do
    endpoint =
      Ash.get!(Endpoint, delivery.endpoint_id,
        tenant: delivery.organization_id,
        authorize?: false
      )

    unless outcome == :delivered and endpoint.consecutive_dead == 0 do
      endpoint
      |> Ash.Changeset.for_update(:note_outcome, %{outcome: outcome, code: code},
        actor: SystemActor.oban(),
        tenant: delivery.organization_id
      )
      |> Ash.update!()
    end

    :ok
  end
end
