defmodule AshEnterprise.BusinessEvents.Recorder do
  @moduledoc """
  Records the facts `AshEnterprise.BusinessEvents.Derivation` derives from a
  canonical row into `AshEnterprise.BusinessEvents.Ledger`, as that row's
  owner and in its tenant.

  The one place that reads before deriving: a calendar event's last fact
  (`Ledger.by_subject/4`), which the derivation diffs against. Everything
  else is the ledger's own `record` — locked, chained, delivery-idempotent.

  Recording is machinery, like the projection that triggers it, so it runs
  with `authorize?: false`; who a fact belongs to is its `context["owner"]`
  (`AshEnterprise.BusinessEvents.Changes.StampOwner`), never the caller.
  """

  alias AshEnterprise.BusinessEvents
  alias AshEnterprise.BusinessEvents.{Derivation, Ledger}
  alias AshEnterprise.Canonical.Conversation

  require Ash.Query

  @doc "Record what a calendar event's current state implies."
  @spec calendar_event(map()) :: {:ok, [Ash.Resource.record()]} | {:error, term()}
  def calendar_event(event) do
    with {:ok, last} <- last_fact(event) do
      event
      |> Derivation.calendar_event(last)
      |> record_all(event)
    end
  end

  @doc "Record what a message implies (and its conversation's start)."
  @spec message(map()) :: {:ok, [Ash.Resource.record()]} | {:error, term()}
  def message(message) do
    with {:ok, conversation} <- conversation(message) do
      message
      |> Derivation.message(conversation)
      |> record_all(message)
    end
  end

  defp record_all(facts, row) do
    facts
    |> Enum.reduce_while({:ok, []}, fn fact, {:ok, acc} ->
      case record(fact, row) do
        {:ok, event} -> {:cont, {:ok, [event | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, events} -> {:ok, Enum.reverse(events)}
      error -> error
    end
  end

  defp record(fact, row) do
    fact
    |> Map.merge(%{
      region: BusinessEvents.region(),
      residency_tag: BusinessEvents.residency_tag(),
      context: %{
        "owner" => %{
          "user_id" => row.owner_id,
          "business_unit_id" => row.owning_business_unit_id
        },
        "organization_id" => row.organization_id
      }
    })
    |> Ledger.record(tenant: row.organization_id, authorize?: false)
  end

  defp last_fact(event) do
    with {:ok, stream} <- Map.fetch(Derivation.streams(), event.external_system),
         true <- is_binary(event.external_id) do
      case Ledger.by_subject(BusinessEvents.region(), event.external_id, stream,
             tenant: event.organization_id,
             authorize?: false
           ) do
        {:ok, facts} ->
          {:ok, facts |> Enum.filter(&(&1.subject_type == "calendar_event")) |> List.last()}

        {:error, _} = error ->
          error
      end
    else
      _not_derivable -> {:ok, nil}
    end
  end

  defp conversation(%{conversation_id: nil}), do: {:ok, nil}

  defp conversation(%{conversation_id: id, organization_id: tenant}) do
    Conversation
    |> Ash.Query.for_read(:read, %{}, tenant: tenant, authorize?: false)
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.select([:id, :external_system, :external_id, :kind, :erasure_scope_id])
    |> Ash.read_one()
  end
end
