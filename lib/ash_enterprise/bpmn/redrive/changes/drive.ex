defmodule AshEnterprise.Bpmn.Redrive.Changes.Drive do
  @moduledoc """
  Drives one failed dispatch again and records what came of it on the `Redrive` row.

  In order: the row must be a `:failed` start dispatch of this tenant that names a
  subscription; an event the version already started is `:already_started`; a disabled
  version is `:not_started`; a `:standing_grant` version whose grant no longer holds now is
  `:no_authority`. Otherwise the funnel runs again for the event, under that version alone
  (`AshBpmn.Triggers.Correlator.dispatch_event/4` with `redrive: true`), in this action's
  transaction, so the start, its dispatch row and this row commit together.

  A `before_action` hook, so it runs after authorization: a person the policy refuses
  re-drives nothing. The rows it reads are read without authorization, scoped to the
  changeset's tenant: deciding what the re-drive may do is what this is for (the claim logic
  `AshEnterprise.Process.RecipeAuthority` uses), and the tenant is what keeps another
  organization's dispatches out of reach.
  """

  use Ash.Resource.Change

  require Ash.Query

  alias AshBpmn.Triggers.Correlator
  alias AshEnterprise.Audit.{EventLog, EventSource}
  alias AshEnterprise.Bpmn.{Dispatch, Subscription}
  alias AshEnterprise.Bpmn.Subscription.Authority
  alias AshEnterprise.Execution.Identity
  alias AshEnterprise.Platform.SystemActor

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      tenant = changeset.tenant
      id = Ash.Changeset.get_attribute(changeset, :failed_dispatch_id)

      with {:ok, failed} <- failed_dispatch(id, tenant),
           {:ok, subscription} <- subscription(failed.subscription_id, tenant) do
        changeset
        |> Ash.Changeset.force_change_attributes(%{
          subscription_id: subscription.id,
          event_id: failed.event_id,
          event_sequence: failed.event_sequence
        })
        |> Ash.Changeset.force_change_attributes(drive(failed, subscription, tenant))
      else
        {:error, message} ->
          Ash.Changeset.add_error(changeset, field: :failed_dispatch_id, message: message)
      end
    end)
  end

  @doc """
  The context the trigger sweep builds for one tenant (`AshBpmn.Triggers.SweepWorker`), for
  the funnel to run in outside a sweep.
  """
  @spec sweep_context(Ash.UUID.t()) :: map()
  def sweep_context(tenant) do
    {domain, resources} = AshBpmn.Triggers.Resources.resolve!(nil)
    scope = AshBpmn.Scope.from_job(%{"tenant" => tenant}, :sweep)

    %{
      scope: %{scope | domain: domain},
      tenant: tenant,
      domain: domain,
      resources: resources,
      event_source: EventSource
    }
  end

  defp drive(failed, subscription, tenant) do
    with :none <- started(subscription.id, failed.event_id, tenant),
         :ok <- enabled(subscription),
         :ok <- authority(subscription, tenant),
         {:ok, event} <- event(failed.event_id, tenant) do
      before = failed_ids(subscription.id, failed.event_id, tenant)

      :ok =
        Correlator.dispatch_event(event, [subscription], sweep_context(tenant), redrive: true)

      outcome(subscription.id, failed.event_id, tenant, before)
    else
      {:started, dispatch_id} -> %{outcome: :already_started, dispatch_id: dispatch_id}
      {:not_started, reason} -> %{outcome: :not_started, reason: reason}
      {:no_authority, reason} -> %{outcome: :no_authority, reason: text(reason)}
    end
  end

  # What the funnel did this time: a start, or the row it wrote instead.
  defp outcome(subscription_id, event_id, tenant, before) do
    case started(subscription_id, event_id, tenant) do
      {:started, dispatch_id} ->
        %{outcome: :started, dispatch_id: dispatch_id}

      :none ->
        reason =
          subscription_id
          |> rows(event_id, tenant)
          |> Enum.reject(&(&1.id in before))
          |> Enum.map(&(&1.reason || &1.status))
          |> List.first(:no_dispatch)

        %{outcome: :not_started, reason: text(reason)}
    end
  end

  defp failed_dispatch(id, tenant) do
    case Ash.get(Dispatch, id, authorize?: false, tenant: tenant, not_found_error?: false) do
      {:ok, %Dispatch{status: :failed, kind: :start, subscription_id: sid} = dispatch}
      when is_binary(sid) ->
        {:ok, dispatch}

      {:ok, %Dispatch{}} ->
        {:error, "is not a failed start dispatch of a subscription"}

      _missing ->
        {:error, "names no dispatch in this organization"}
    end
  end

  # The version on the row, whatever its status now.
  defp subscription(id, tenant) do
    case Ash.get(Subscription, id, authorize?: false, tenant: tenant, not_found_error?: false) do
      {:ok, %Subscription{} = subscription} -> {:ok, subscription}
      _missing -> {:error, "names a subscription that no longer exists"}
    end
  end

  defp started(subscription_id, event_id, tenant) do
    subscription_id
    |> rows(event_id, tenant)
    |> Enum.find(&(&1.status == :started))
    |> case do
      nil -> :none
      dispatch -> {:started, dispatch.id}
    end
  end

  defp failed_ids(subscription_id, event_id, tenant) do
    for row <- rows(subscription_id, event_id, tenant), row.status == :failed, do: row.id
  end

  defp rows(subscription_id, event_id, tenant) do
    Dispatch
    |> Ash.Query.filter(subscription_id == ^subscription_id and event_id == ^event_id)
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.read!(authorize?: false, tenant: tenant)
  end

  defp enabled(%Subscription{enabled: true}), do: :ok
  defp enabled(_subscription), do: {:not_started, "disabled"}

  # Checked now, never as it was when the event happened (ADR 0069).
  defp authority(%Subscription{authority: :standing_grant} = subscription, tenant) do
    case Identity.recipe_requester(
           subscription.accountable_person_id,
           Authority.grant_key(subscription),
           tenant
         ) do
      {:ok, _requester} -> :ok
      {:error, reason} -> {:no_authority, reason}
    end
  end

  defp authority(_subscription, _tenant), do: :ok

  defp event(id, tenant) do
    EventLog
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^id)
    |> Ash.read_one(actor: SystemActor.process(), tenant: tenant)
    |> case do
      {:ok, %EventLog{} = event} -> {:ok, event}
      _missing -> {:not_started, "event_not_found"}
    end
  end

  defp text(reason) when is_atom(reason) or is_binary(reason), do: to_string(reason)
  defp text(reason), do: inspect(reason)
end
