defmodule AshEnterprise.Process.Triggers.Dispatch do
  @moduledoc """
  Decides what one audit event means for the triggers watching it, and records the answer.

  The three stages are ordered by cost, because stages one and two run against every audited
  write in a matching resource and stage three is the expensive one:

    1. **Match** — structural, on resource, action and action type. No evaluation.
    2. **Guard** — a FEEL boolean over the event context. In-process, no I/O.
    3. **Route** — a DMN decision naming the process key and its variables.

  Every outcome writes an `AshEnterprise.Process.TriggerDispatch` row, including the ones that
  did nothing. A dispatch that skipped is as much a fact as one that started something, and it
  is the row that answers "why did *nothing* happen" — which is the harder question of the two.
  """

  require Ash.Query
  require Logger

  alias AshEnterprise.Decisions
  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.Process.{Resolver, TriggerDispatch}

  @doc "Runs every published trigger against one event."
  @spec dispatch_event(struct(), [struct()], Ash.UUID.t()) :: :ok
  def dispatch_event(event, triggers, tenant) do
    triggers
    |> Enum.filter(&matches?(&1, event))
    |> Enum.each(&dispatch(&1, event, tenant))

    :ok
  end

  # ── stage 1: match ───────────────────────────────────────────────────────

  defp matches?(trigger, event) do
    trigger.match_resource == event.resource and
      (is_nil(trigger.match_action) or trigger.match_action == to_string(event.action)) and
      (is_nil(trigger.match_action_type) or trigger.match_action_type == event.action_type)
  end

  # ── stages 2 and 3 ───────────────────────────────────────────────────────

  defp dispatch(trigger, event, tenant) do
    context = context_for(event)

    case guard(trigger, context) do
      {:ok, false} ->
        record(trigger, event, tenant, status: :skipped, reason: :guard_false)

      {:error, reason} ->
        record(trigger, event, tenant,
          status: :failed,
          reason: :guard_error,
          error: %{"detail" => inspect(reason, limit: 5)}
        )

      {:ok, true} ->
        route_and_start(trigger, event, context, tenant)
    end
  end

  defp guard(%{guard_feel: nil}, _context), do: {:ok, true}
  defp guard(%{guard_feel: ""}, _context), do: {:ok, true}

  defp guard(%{guard_feel: source}, context) do
    case AshDecisions.Feel.evaluate(source, AshDecisions.Feel.to_feel_value(context)) do
      {:ok, true} -> {:ok, true}
      {:ok, false} -> {:ok, false}
      # A guard that cannot answer is not a guard that says yes. FEEL folds a missing path or
      # a type mismatch to null, and treating null as "fire" would start processes from
      # conditions nobody wrote.
      {:ok, nil} -> {:ok, false}
      {:ok, other} -> {:error, {:guard_not_boolean, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp route_and_start(trigger, event, context, tenant) do
    case route(trigger, context, tenant) do
      {:error, reason, detail} ->
        record(trigger, event, tenant, status: :failed, reason: reason, error: detail)

      {:ok, targets} ->
        start_all(trigger, event, targets, tenant)
    end
  end

  # A trigger names either a decision that chooses, or a process directly. The decision form
  # may return several, which is what `max_starts_per_event` bounds.
  defp route(%{decision_key: nil, process_key: key}, _context, _tenant) when is_binary(key) do
    {:ok, [%{process_key: key, variables: %{}, fired_rule: nil}]}
  end

  defp route(%{decision_key: key} = trigger, context, tenant) when is_binary(key) do
    case Decisions.evaluate(key, context, tenant: tenant) do
      {:ok, %{outputs: outputs}} ->
        outputs
        |> List.wrap()
        |> Enum.map(&target_from_outputs(&1, trigger))
        |> Enum.reject(&is_nil/1)
        |> case do
          [] -> {:error, :no_rule_fired, %{"decision" => key}}
          targets -> {:ok, targets}
        end

      {:error, reason} ->
        {:error, :decision_error, %{"decision" => key, "detail" => inspect(reason, limit: 5)}}
    end
  end

  defp route(_trigger, _context, _tenant),
    do: {:error, :no_rule_fired, %{"detail" => "trigger names neither a process nor a decision"}}

  defp target_from_outputs(outputs, trigger) when is_map(outputs) do
    case Map.get(outputs, "process_key") || trigger.process_key do
      nil -> nil
      key -> %{process_key: key, variables: Map.delete(outputs, "process_key"), fired_rule: nil}
    end
  end

  defp target_from_outputs(_outputs, _trigger), do: nil

  defp start_all(trigger, event, targets, tenant) do
    if length(targets) > trigger.max_starts_per_event do
      # Refusing loudly beats starting fifty thousand processes from one write.
      record(trigger, event, tenant,
        status: :failed,
        reason: :fan_out_exceeded,
        error: %{"wanted" => length(targets), "allowed" => trigger.max_starts_per_event}
      )
    else
      Enum.each(targets, &start_one(trigger, event, &1, tenant))
    end
  end

  defp start_one(trigger, event, target, tenant) do
    with {:ok, definition} <- Resolver.resolve(:process, target.process_key, tenant),
         {:ok, instance} <- start_instance(definition, event, tenant) do
      record(trigger, event, tenant,
        status: :started,
        process_key: target.process_key,
        decision_key: trigger.decision_key,
        fired_rule: target.fired_rule,
        instance_id: instance.id
      )
    else
      {:error, {:no_published_baseline, _kind, key}} ->
        record(trigger, event, tenant,
          status: :failed,
          reason: :no_published_definition,
          process_key: key
        )

      {:error, reason} ->
        record(trigger, event, tenant,
          status: :failed,
          reason: :decision_error,
          process_key: target.process_key,
          error: %{"detail" => inspect(reason, limit: 5)}
        )
    end
  end

  defp start_instance(definition, event, tenant) do
    AshBpmn.start_instance(AshEnterprise.Bpmn,
      definition: definition,
      subject: subject_stub(event),
      # The process runs as a named non-human actor. The originating human is on the instance
      # and in the correlation id -- see `docs/plans/event-triggered-processes.md` §6 for why
      # rebuilding their ActorContext would be a standing privilege-escalation surface.
      actor: SystemActor.process(),
      tenant: tenant,
      correlation_id: get_in(event.metadata, ["correlation_id"])
    )
  end

  # The subject is identified by what the event recorded, not by a live read: a trigger fires
  # on what happened. The process re-reads it through Ash when it needs the current state.
  defp subject_stub(event) do
    %{__struct__: resource_module(event.resource), id: event.record_id}
  end

  defp resource_module(resource) when is_binary(resource) do
    String.to_existing_atom(resource)
  rescue
    ArgumentError -> nil
  end

  # ── the event context, a published contract ──────────────────────────────

  @doc """
  The map a guard and a routing decision both see.

  **This shape is a contract.** Changing it breaks every tenant's triggers, so it is documented
  and tested as one rather than treated as an internal detail.

  `data` is the event's snapshot, *not* a live read. By the time a sweep runs, the record may
  have changed or been archived — which is correct, because a trigger fires on what happened,
  but it means a guard must never be written as though it were a query.
  """
  @spec context_for(struct()) :: map()
  def context_for(event) do
    %{
      "event" => %{
        "id" => event.id,
        "sequence" => event.sequence,
        "occurred_at" => event.occurred_at,
        "resource" => event.resource,
        "action" => to_string(event.action),
        "action_type" => to_string(event.action_type),
        "record_id" => event.record_id,
        "version" => event.version
      },
      "actor" => %{
        "user_id" => event.user_id,
        "system_actor" => get_in(event.metadata, ["system_actor"]),
        "impersonator_id" => get_in(event.metadata, ["impersonator_id"])
      },
      "tenant" => %{"organization_id" => event.organization_id},
      "data" => event.data || %{},
      "changed" => Map.get(event, :changed_attributes) || %{},
      "metadata" => event.metadata || %{}
    }
  end

  # ── the ledger ───────────────────────────────────────────────────────────

  defp record(trigger, event, tenant, opts) do
    attrs =
      opts
      |> Map.new()
      |> Map.merge(%{
        trigger_id: trigger.id,
        event_id: event.id,
        event_sequence: event.sequence,
        correlation_id: get_in(event.metadata, ["correlation_id"]),
        depth: depth_of(event) + 1
      })

    TriggerDispatch.create(attrs, actor: SystemActor.process(), tenant: tenant)
  rescue
    e ->
      # The identity makes a replayed batch idempotent, so a duplicate here is expected rather
      # than exceptional. Anything else is logged and the sweep continues: one trigger must not
      # stop the others.
      Logger.debug("trigger dispatch not recorded: #{Exception.message(e)}")
      :ok
  end

  defp depth_of(event), do: get_in(event.metadata, ["trigger_depth"]) || 0
end
