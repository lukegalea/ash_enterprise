defmodule AshEnterprise.ExecutionSources.Invocation do
  @moduledoc """
  Invocations (`AshEnterprise.Execution.Invocation`) as execution entries. Each row gives:

    * its **logical operation**, under the run, process instance or invocation that asked
      for it, with the shared status (`AshAgent.Execution.Status.invocation/1`);
    * one **attempt** per claim, read from the audit trail's transitions of the row
      (`AshEnterprise.Audit.EventLog`, as the viewer: a viewer who may not read the
      audit trail sees the operation without its attempts), ending as the transition
      that followed it ended;
    * its **effect**, once it succeeded and was not simulated, or `uncertain` while its
      outcome is unknown.

  Reads the rows recorded under the trace's correlation id, named by it, asked for by
  one of its runs, process instances or invocations, or rerunning one of its invocations
  (under the row they rerun). Arguments and results are sealed and
  never in an entry; a row whose arguments were erased is not recorded.
  """

  @behaviour AshAgent.Execution.Source

  require Ash.Query

  alias AshAgent.Execution.{Source, Status}
  alias AshEnterprise.Audit.EventLog
  alias AshEnterprise.Execution.Invocation
  alias AshEnterprise.ExecutionSources

  @resource Invocation

  # The transitions that end an attempt, and how it ended.
  @ends %{
    succeed: :succeeded,
    fail: :failed,
    defer: :waiting,
    requeue: :waiting,
    dispatch: :running,
    complete_external: nil,
    mark_outcome_unknown: :uncertain,
    mark_stale: :failed,
    apply_resolution: nil
  }

  @impl true
  def read(scope, opts) do
    invocations = ExecutionSources.uuids(scope, :invocation)

    with {:ok, rows, next} <-
           ExecutionSources.read(
             @resource,
             [
               correlation_id: ExecutionSources.correlation(scope),
               id: invocations,
               run_id: ExecutionSources.uuids(scope, :run),
               process_instance_id: ExecutionSources.uuids(scope, :process_instance),
               parent_invocation_id: invocations,
               rerun_of_id: invocations
             ],
             opts,
             load: [:recorded?]
           ),
         {:ok, transitions} <- transitions(rows, opts) do
      {:ok,
       Enum.map(rows, &Ash.Resource.put_metadata(&1, :transitions, transitions[&1.id] || [])),
       next}
    end
  end

  # The audit trail's transitions of `rows`, oldest first, as the viewer may read them.
  defp transitions([], _opts), do: {:ok, %{}}

  defp transitions(rows, opts) do
    ids = Enum.map(rows, & &1.id)
    actions = [:claim | Map.keys(@ends)]

    EventLog
    |> Ash.Query.for_read(:read, %{}, actor: opts[:actor], tenant: opts[:tenant])
    |> Ash.Query.filter(resource == ^@resource and record_id in ^ids and action in ^actions)
    |> Ash.Query.select([:id, :record_id, :action, :occurred_at])
    |> Ash.Query.sort(occurred_at: :asc, id: :asc)
    |> Ash.read()
    |> case do
      {:ok, events} -> {:ok, Enum.group_by(events, & &1.record_id)}
      {:error, error} -> {:error, error}
    end
  end

  @impl true
  def to_entries(rows), do: Enum.flat_map(rows, &entries/1)

  defp entries(row) do
    {status, blocked_on} = Status.invocation(row)
    ref = Source.ref(:invocation, row.id)
    recorded? = row.recorded? == true

    operation =
      Source.entry(
        at: row.created_on,
        kind: :logical_operation,
        status: status,
        blocked_on: blocked_on,
        source_ref: ref,
        parent_ref: parent(row),
        definition_ref: "#{row.target}@#{String.slice(row.target_digest || "", 0, 12)}",
        actor_label: ExecutionSources.principal_label(row.executing_principal),
        recorded?: recorded?,
        summary: summary(row)
      )

    [operation | attempts(row, ref)] ++ effect(row, ref)
  end

  defp parent(%{run_id: id}) when is_binary(id), do: Source.ref(:run, id)
  defp parent(%{parent_invocation_id: id}) when is_binary(id), do: Source.ref(:invocation, id)

  defp parent(%{process_instance_id: id}) when is_binary(id),
    do: Source.ref(:process_instance, id)

  defp parent(%{rerun_of_id: id}) when is_binary(id), do: Source.ref(:invocation, id)

  defp parent(_row), do: nil

  defp summary(%{error_code: code} = row) when is_binary(code), do: "#{row.target}: #{code}"
  defp summary(row), do: row.target

  # Each claim opens an attempt, which ends as the next transition that is not a claim
  # does. The last one, with nothing after it yet, is as the row is now.
  defp attempts(row, ref) do
    events = row.__metadata__[:transitions] || []

    events
    |> Enum.with_index()
    |> Enum.filter(fn {event, _index} -> event.action == :claim end)
    |> Enum.with_index(1)
    |> Enum.map(fn {{claim, index}, n} ->
      ending = events |> Enum.drop(index + 1) |> Enum.find(&(&1.action != :claim))

      Source.entry(
        at: claim.occurred_at,
        kind: :attempt,
        status: ended(ending, row),
        source_ref: Source.ref(:audit_event, claim.id),
        parent_ref: ref,
        summary: "attempt #{n}" <> if(ending, do: ": #{ending.action}", else: "")
      )
    end)
  end

  defp ended(nil, row), do: row |> Status.invocation() |> elem(0)

  defp ended(%{action: action}, row) do
    case Map.fetch(@ends, action) do
      {:ok, nil} -> row |> Status.invocation() |> elem(0)
      {:ok, status} -> status
      :error -> :uncertain
    end
  end

  defp effect(%{simulated: true}, _ref), do: []

  defp effect(%{status: status} = row, ref) when status in [:succeeded, :outcome_unknown] do
    if row.effects["read_only"] == true do
      []
    else
      [
        Source.entry(
          at: row.effect_observed_at || row.modified_on,
          kind: :effect,
          status: if(status == :succeeded, do: :succeeded, else: :uncertain),
          source_ref: Source.ref(:effect, row.id),
          parent_ref: ref,
          definition_ref: row.target,
          summary: effect_summary(row)
        )
      ]
    end
  end

  defp effect(_row, _ref), do: []

  defp effect_summary(%{effect_system: system, effect_ref: effect_ref})
       when is_binary(system) and is_binary(effect_ref),
       do: "#{system} #{effect_ref}"

  defp effect_summary(%{status: :outcome_unknown, target: target}),
    do: "#{target}: outcome unknown"

  defp effect_summary(row), do: row.target
end
