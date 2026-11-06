defmodule AshEnterprise.Execution.Explorer do
  @moduledoc """
  What the execution explorer (`AshEnterpriseWeb.ExplorerLive`) reads beyond the trace
  itself (`AshEnterprise.Execution.Entry`'s `trace`), every read made as the viewer:

    * `merge/2`: a later page of a trace folded into the entries already shown;
    * `detail/2`: the record behind one entry, as the viewer may read it, for the
      detail panel (a run's mode, an invocation's arguments, a decision's matched rules,
      a judgment's cited lines);
    * `drawing/2` and `nodes/2`: the BPMN of the process run in the trace, and the
      element of it each entry happened on, so one selection is shared by the timeline,
      the diagram and the detail;
    * `recent/1`: the latest work the viewer may read, to start from.

  A record the viewer may not read answers `:unreadable`, and an erased one says it is
  erased: neither reads as empty.
  """

  require Ash.Query

  alias AshEnterprise.AI.ModelCall
  alias AshEnterprise.Bpmn.{Definition, HumanTask, Instance, ProcessEvent}
  alias AshEnterprise.Decisions.Evaluation
  alias AshEnterprise.Erasure.Shredded
  alias AshEnterprise.Execution
  alias AshEnterprise.Execution.{Intervention, Invocation, Recovery, Run, Step}
  alias AshEnterprise.Process.DefinitionLoader
  alias AshEnterprise.Quality.CaseResult
  alias AshEnterprise.SystemOne.Judgment

  @recent 8

  @doc """
  `existing` with `page`'s entries that are not already in it, oldest first. Every
  trace re-reads the sources it was not given a cursor for, so their entries come again;
  an entry is the same entry when it has the same record and kind.
  """
  @spec merge([map()], [map()]) :: [map()]
  def merge(existing, page) do
    (existing ++ page)
    |> Enum.uniq_by(&{&1.source_ref, &1.kind})
    |> Enum.sort_by(& &1.at, DateTime)
  end

  @doc """
  The cursors to read the next page with: those of every source that has more.
  """
  @spec cursors([map()]) :: %{optional(String.t()) => String.t()}
  def cursors(reports) do
    for %{status: :more, cursor: cursor, source: source} <- reports,
        is_binary(cursor),
        into: %{},
        do: {to_string(source), cursor}
  end

  # --- detail -------------------------------------------------------------------------

  @doc """
  The record behind `source_ref`, read as `opts[:actor]` in `opts[:tenant]`, as a map
  with its `type` and the facts the detail panel shows. `:unreadable` when the viewer
  may not read it (or it is gone); `:none` for a reference with no record to read (a
  source the trace could not read, an audit transition).
  """
  @spec detail(String.t(), keyword()) :: {:ok, map()} | :unreadable | :none
  def detail(source_ref, opts) do
    case String.split(source_ref, ":", parts: 2) do
      [type, id] -> detail(type, id, opts)
      _other -> :none
    end
  end

  defp detail("run", id, opts) do
    with {:ok, run} <- get(Run, id, opts) do
      {:ok,
       %{
         type: :run,
         id: run.id,
         agent_key: run.agent_key,
         mode: run.mode,
         status: run.status,
         failure_class: run.failure_class,
         error_code: run.error_code,
         correlation_id: run.correlation_id
       }}
    end
  end

  defp detail("invocation", id, opts) do
    with {:ok, row} <- get(Invocation, id, opts, load: [:args, :recorded?]) do
      {:ok,
       %{
         type: :invocation,
         id: row.id,
         target: row.target,
         mode: row.mode,
         status: row.status,
         simulated?: row.simulated == true,
         failure_class: row.failure_class,
         error_code: row.error_code,
         args: sealed(row.args, row.recorded?),
         run_id: row.run_id,
         step_seq: row.step_seq,
         rerun_of_id: row.rerun_of_id,
         recoverable?: recoverable?(row),
         correlation_id: row.correlation_id
       }}
    end
  end

  # A person's act on an invocation (the recovery surface's): what, why, and by whom.
  defp detail("intervention", id, opts) do
    with {:ok, row} <- get(Intervention, id, opts) do
      {:ok,
       %{
         type: :intervention,
         id: row.id,
         act: row.act,
         reason: row.reason,
         resolution: row.resolution,
         owner_id: row.owner_id,
         invocation_id: row.invocation_id,
         rerun_id: row.rerun_id
       }}
    end
  end

  defp detail("effect", id, opts) do
    with {:ok, invocation} <- detail("invocation", id, opts),
         do: {:ok, %{invocation | type: :effect}}
  end

  defp detail("step", id, opts) do
    with {:ok, step} <- get(Step, id, opts, load: [:recorded?]) do
      {:ok,
       %{
         type: :step,
         id: step.id,
         seq: step.seq,
         role: step.role,
         tools: Enum.map(step.tool_calls || [], &(&1["name"] || "?")),
         recorded?: step.recorded? == true,
         run_id: step.run_id,
         calls: calls(step, opts)
       }}
    end
  end

  defp detail("human_task", id, opts) do
    with {:ok, task} <- get(HumanTask, id, opts) do
      {:ok,
       %{
         type: :human_task,
         id: task.id,
         name: task.name || task.node_id,
         node_id: task.node_id,
         status: task.status,
         outcome: task.outcome,
         decided_by_id: task.decided_by_id
       }}
    end
  end

  defp detail("process_event", id, opts) do
    with {:ok, event} <- get(ProcessEvent, id, opts) do
      {:ok, %{type: :process_event, id: event.id, kind: event.kind, node_id: event.node_id}}
    end
  end

  defp detail("process_instance", id, opts) do
    with {:ok, instance} <- get(Instance, id, opts) do
      {:ok,
       %{
         type: :process_instance,
         id: instance.id,
         status: instance.status,
         outcome: instance.outcome,
         correlation_id: instance.correlation_id
       }}
    end
  end

  defp detail("evaluation", id, opts) do
    with {:ok, evaluation} <- get(Evaluation, id, opts) do
      {:ok,
       %{
         type: :evaluation,
         id: evaluation.id,
         definition: "#{evaluation.definition_key}@#{evaluation.definition_version}",
         decision_id: evaluation.decision_id,
         hit_policy: evaluation.hit_policy,
         matched_rule_ids: evaluation.matched_rule_ids || [],
         failed?: evaluation.error not in [nil, %{}],
         correlation_id: evaluation.correlation_id
       }}
    end
  end

  defp detail("judgment", id, opts) do
    with {:ok, judgment} <- get(Judgment, id, opts) do
      {:ok,
       %{
         type: :judgment,
         id: judgment.id,
         question: "#{judgment.question_id}@#{judgment.question_version}",
         answer_kind: judgment.answer_kind,
         subject: judgment.subject_type && "#{judgment.subject_type}:#{judgment.subject_id}",
         cited: judgment.atom_ids || [],
         document_hash: judgment.document_hash,
         recorded?: not is_nil(judgment.state_ciphertext)
       }}
    end
  end

  defp detail("case_result", id, opts) do
    with {:ok, result} <- get(CaseResult, id, opts) do
      {:ok,
       %{
         type: :case_result,
         id: result.id,
         case_id: result.case_id,
         status: result.status,
         run_id: result.run_id
       }}
    end
  end

  defp detail("model_call", id, opts) do
    with {:ok, call} <- get(ModelCall, id, opts) do
      {:ok,
       %{
         type: :model_call,
         id: call.id,
         profile: call.profile,
         model: call.model,
         outcome: call.outcome,
         error_class: call.error_class,
         tokens:
           if(is_integer(call.input_tokens) and is_integer(call.output_tokens),
             do: call.input_tokens + call.output_tokens
           ),
         duration_ms: call.duration_ms
       }}
    end
  end

  defp detail(_type, _id, _opts), do: :none

  # Whether the recovery surface offers a person anything on this row now, or will once
  # its unknown outcome has been asked about (`AshEnterprise.Execution.Recovery`).
  defp recoverable?(%{status: :outcome_unknown}), do: true

  defp recoverable?(row),
    do: Enum.any?([Recovery.rerun(row), Recovery.cancel(row)], &(&1 == :ok))

  defp get(resource, id, opts, extra \\ []) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         {:ok, %{} = record} <-
           Ash.get(
             resource,
             id,
             [actor: opts[:actor], tenant: opts[:tenant], not_found_error?: false] ++ extra
           ) do
      {:ok, record}
    else
      _unreadable -> :unreadable
    end
  end

  # Sealed content as the viewer reads it: erased once its scope is shredded, never an
  # empty value.
  defp sealed(_value, false), do: :erased
  defp sealed(%Shredded{}, _recorded?), do: :erased
  defp sealed(value, _recorded?), do: value

  # A model turn's tool calls: the invocation each ran as, with the arguments the model
  # asked for, as the viewer may read them.
  defp calls(%{role: :assistant, run_id: run_id, tool_calls: [_ | _] = calls}, opts) do
    call_ids = for %{"id" => id} <- calls, is_binary(id), do: id

    Invocation
    |> Ash.Query.for_read(:read, %{}, actor: opts[:actor], tenant: opts[:tenant])
    |> Ash.Query.filter(run_id == ^run_id and tool_call_id in ^call_ids)
    |> Ash.Query.load([:args, :recorded?])
    |> Ash.Query.sort(created_on: :asc)
    |> Ash.read()
    |> case do
      {:ok, rows} ->
        Enum.map(rows, fn row ->
          %{
            id: row.id,
            target: row.target,
            status: row.status,
            args: sealed(row.args, row.recorded?)
          }
        end)

      {:error, _error} ->
        :unreadable
    end
  end

  defp calls(_step, _opts), do: []

  # --- the diagram ----------------------------------------------------------------------

  @doc """
  The process run the trace's entries are about (the first one named), as the viewer
  may read it, with the BPMN of the definition version it pinned: `{:ok, %{instance_id,
  definition, xml, names}}`, `names` being each element's name by its id. `:none` when
  the trace names no run the viewer may read, or its definition has no diagram.
  """
  @spec drawing([map()], keyword()) :: {:ok, map()} | :none
  def drawing(entries, opts) do
    with id when is_binary(id) <- instance_id(entries),
         {:ok, instance} <- get(Instance, id, opts),
         {:ok, definition} <-
           DefinitionLoader.load(Definition, instance.definition_id, instance, %{
             tenant: instance.organization_id
           }),
         xml when is_binary(xml) and xml != "" <- definition.xml do
      names =
        for {node_id, node} <- (definition.graph || %{})["nodes"] || %{},
            into: %{},
            do: {node_id, node["name"] || node_id}

      {:ok,
       %{
         instance_id: instance.id,
         definition: "#{definition.key}@#{definition.version}",
         xml: xml,
         names: names
       }}
    else
      _nothing_to_draw -> :none
    end
  end

  defp instance_id(entries) do
    entries
    |> Enum.flat_map(&[&1.source_ref, &1.parent_ref])
    |> Enum.find_value(fn
      "process_instance:" <> id -> id
      _other -> nil
    end)
  end

  @doc """
  The element of the process each of `entries` happened on, as `%{source_ref =>
  node_id}`: process events and tasks name theirs. Read as the viewer; an entry whose
  record cannot be read has none.
  """
  @spec nodes([map()], keyword()) :: %{String.t() => String.t()}
  def nodes(entries, opts) do
    Map.merge(
      node_ids(ProcessEvent, ids(entries, "process_event"), "process_event", opts),
      node_ids(HumanTask, ids(entries, "human_task"), "human_task", opts)
    )
  end

  defp ids(entries, type) do
    for %{source_ref: ref} <- entries,
        [^type, id] <- [String.split(ref, ":", parts: 2)],
        {:ok, uuid} <- [Ecto.UUID.cast(id)],
        uniq: true,
        do: uuid
  end

  defp node_ids(_resource, [], _type, _opts), do: %{}

  defp node_ids(resource, ids, type, opts) do
    resource
    |> Ash.Query.for_read(:read, %{}, actor: opts[:actor], tenant: opts[:tenant])
    |> Ash.Query.filter(id in ^ids)
    |> Ash.Query.select([:id, :node_id])
    |> Ash.read()
    |> case do
      {:ok, rows} ->
        for %{node_id: node} = row <- rows,
            is_binary(node),
            into: %{},
            do: {"#{type}:#{row.id}", node}

      {:error, _error} ->
        %{}
    end
  end

  # --- where to start -------------------------------------------------------------------

  @doc """
  The latest invocations, agent runs and process runs the viewer may read, newest first,
  each as `%{ref, label, status, at}` to open in the explorer.
  """
  @spec recent(keyword()) :: [map()]
  def recent(opts) do
    query = [sort: [created_on: :desc], limit: @recent]
    read = [actor: opts[:actor], tenant: opts[:tenant], query: query]

    invocations =
      for row <- ok(Execution.list_invocations(read)),
          do: item("invocation", row, row.target, row.status)

    runs =
      for run <- ok(Execution.list_agent_runs(read)),
          do: item("run", run, run.agent_key, run.status)

    instances =
      Instance
      |> Ash.Query.for_read(:read, %{}, actor: opts[:actor], tenant: opts[:tenant])
      |> Ash.Query.sort(created_on: :desc)
      |> Ash.Query.limit(@recent)
      |> Ash.read()
      |> ok()
      |> Enum.map(&item("process_instance", &1, &1.subject_type, &1.status))

    Enum.sort_by(invocations ++ runs ++ instances, & &1.at, {:desc, DateTime})
  end

  defp ok({:ok, rows}), do: rows
  defp ok({:error, _error}), do: []

  defp item(type, row, label, status),
    do: %{ref: "#{type}:#{row.id}", type: type, label: label, status: status, at: row.created_on}
end
