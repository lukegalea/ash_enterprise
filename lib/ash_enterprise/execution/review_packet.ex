defmodule AshEnterprise.Execution.ReviewPacket do
  @moduledoc """
  What a reviewer is shown about an invocation's approval task (R2 HW-02..06, N4): the
  sections the approvals surface lays out beside the task
  (`AshEnterprise.Bpmn.Calculations.ReviewPacket`).

    * **Target**: the action that would run and what its effects declaration says it
      does.
    * **Arguments**: the request's arguments, named and typed by the target's input
      schema (the one a model is shown, `AshAi.Tool.Schema.for_action/3`), with the
      subject's key for an update or a destroy.
    * **Digest**: the `approval_digest` an approval binds (RFC 9396 details, RFC 8785
      canonical JSON).
    * **Currency**: whether the approval would still bind the request now,
      `AshAgent.Invocation.Approval.stale_reason/2`: `{:current, nil}`,
      `{:stale, reason}`, `{:decided, status}` once the row has moved on, or
      `{:unknown, why}`. Anything this module cannot establish is unknown, never current:
      a request the reader cannot read, nothing bound, a check that raised.
    * **Evidence** and **decisions**: what the request's trace holds, read as the
      viewer (`AshEnterprise.Execution.Entry`): the decision entries with their matched
      rules, and references to the observations, the subject's version and the work
      the request belongs to. Contents stay sealed in their records.
    * **Due** and **escalation**: the task's `due_at`, the approval window's end, and
      what the engine recorded about escalating the task.
    * **Questions**: an approver's request for more information and the requester's
      answer (`AshEnterprise.Execution.InfoRequest`), oldest first.

  The invocation is read as the viewer, so a reader who may not read it learns nothing
  about it. The questions and the escalation events are read with the engine's
  authority, for this task's invocation only, once the viewer has been shown the task
  itself: they are part of what is under review.
  """

  require Ash.Query

  alias AshAgent.Invocation.{Approval, Executor, Target}
  alias AshEnterprise.Bpmn.{HumanTask, ProcessEvent}
  alias AshEnterprise.Execution
  alias AshEnterprise.Execution.{InfoRequest, Invocation}

  @invocation to_string(Invocation)
  @approval_key AshEnterprise.Execution.Approval.key()

  @doc "The fields a task needs loaded for `build/2`."
  @spec task_fields() :: [atom()]
  def task_fields,
    do: [:id, :subject_type, :subject_id, :node_id, :instance_id, :due_at, :organization_id]

  @sections [
    :target,
    :arguments,
    :digest,
    :currency,
    :evidence,
    :decisions,
    :due,
    :escalation,
    :questions
  ]

  @doc "The packet's sections, in the order a reviewer reads them."
  @spec sections() :: [atom()]
  def sections, do: @sections

  @doc """
  The packet for `task`, read with `opts` (`actor`, `tenant`): the `sections` asked for
  (all of them by default), each under its name, and the invocation as `:invocation`.
  `nil` for a task that is not an invocation's approval task.
  """
  @spec build(struct(), keyword(), [atom()]) :: map() | nil
  def build(task, opts, sections \\ @sections)

  def build(
        %{subject_type: @invocation, node_id: @approval_key, instance_id: nil} = task,
        opts,
        sections
      ) do
    case read_invocation(task.subject_id, opts) do
      {:ok, invocation} ->
        context = %{task: task, invocation: invocation, opts: opts}

        sections
        |> Map.new(&{&1, section(&1, context)})
        |> Map.put(:invocation, invocation)

      :unreadable ->
        sections
        |> Map.new(&{&1, unreadable(&1, task)})
        |> Map.put(:invocation, nil)
    end
  end

  def build(_task, _opts, _sections), do: nil

  defp section(:target, %{invocation: invocation}),
    do: target(invocation, Target.resolve(invocation.target))

  defp section(:arguments, %{invocation: invocation, opts: opts}),
    do: arguments(invocation, Target.resolve(invocation.target), opts)

  defp section(:digest, %{invocation: invocation}), do: invocation.approval_digest
  defp section(:currency, %{invocation: invocation}), do: currency(invocation)

  defp section(:evidence, %{invocation: invocation, opts: opts}),
    do: evidence(invocation, trace(invocation, opts))

  defp section(:decisions, %{invocation: invocation, opts: opts}),
    do: decisions(trace(invocation, opts))

  defp section(:due, %{task: task, invocation: invocation}), do: due(task, invocation)
  defp section(:escalation, %{task: task}), do: escalation(task)
  defp section(:questions, %{invocation: invocation}), do: questions(invocation)

  # A reader who may see the task but not the request it is about learns nothing about
  # the request: what cannot be read is said to be unreadable, never empty or current.
  defp unreadable(:currency, _task), do: {:unknown, :unreadable}
  defp unreadable(:due, task), do: %{due_at: task.due_at, expires_at: nil}
  defp unreadable(:escalation, task), do: escalation(task)
  defp unreadable(_section, _task), do: :unreadable

  defp read_invocation(id, opts) do
    case Execution.get_invocation(id, Keyword.put(opts, :load, [:recorded?])) do
      {:ok, invocation} -> {:ok, invocation}
      {:error, _not_found_or_forbidden} -> :unreadable
    end
  end

  # --- target and arguments -------------------------------------------------------

  defp target(invocation, {:ok, %{resource: resource, action: action}}),
    do: %{
      name: invocation.target,
      resource: resource,
      action: action.name,
      effect: invocation.effects
    }

  defp target(invocation, {:error, _unresolvable}),
    do: %{name: invocation.target, resource: nil, action: nil, effect: invocation.effects}

  defp arguments(%{recorded?: false}, _target, _opts), do: :erased

  defp arguments(invocation, {:ok, %{resource: resource, action: action}}, opts) do
    args = invocation |> Executor.stored_args(opts) |> stringify()
    {keys_schema, properties} = schema(AshAi.Tool.Schema.for_action(nil, resource, action))
    sensitive = sensitive_inputs(resource, action)

    declared =
      for {name, property} <- properties do
        %{
          name: name,
          type: property_value(property, :type),
          description: property_value(property, :description),
          value: if(name in sensitive, do: :sensitive, else: Map.get(args, name))
        }
      end

    # The subject's key, which is not an input: an update or a destroy names its record.
    keys =
      for {name, value} <- args, not Map.has_key?(properties, name) do
        %{
          name: name,
          type: property_value(Map.get(keys_schema, name), :type),
          description: nil,
          value: value
        }
      end

    {:ok, Enum.sort_by(keys, & &1.name) ++ Enum.sort_by(declared, & &1.name)}
  rescue
    _cannot_open -> :unreadable
  end

  defp arguments(_invocation, {:error, _unresolvable}, _opts), do: :unreadable

  # A tool's schema names the subject's key at the top and the action's inputs under
  # `input`.
  defp schema(schema) do
    {input, keys} = schema |> property_value(:properties) |> stringify() |> Map.pop("input")
    {keys, input |> property_value(:properties) |> stringify()}
  end

  defp stringify(map) when is_map(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)
  defp stringify(_none), do: %{}

  # Inputs the target marks sensitive are named, never shown.
  defp sensitive_inputs(resource, action) do
    accepted =
      (action.accept || [])
      |> Enum.map(&Ash.Resource.Info.attribute(resource, &1))
      |> Enum.reject(&is_nil/1)

    for %{sensitive?: true, name: name} <- action.arguments ++ accepted, do: to_string(name)
  end

  defp property_value(property, key) when is_map(property),
    do: Map.get(property, key) || Map.get(property, to_string(key))

  defp property_value(_property, _key), do: nil

  # --- currency -------------------------------------------------------------------

  @pending [:awaiting_approval, :request_info]

  @doc """
  Whether the approval `invocation` waits for would still bind it now: `{:current, nil}`,
  `{:stale, reason}`, `{:decided, status}` for a row that has moved on, or
  `{:unknown, why}`.
  """
  @spec currency(map() | nil) :: {:current | :stale | :decided | :unknown, term()}
  def currency(%{status: :stale} = invocation), do: {:stale, invocation.error_code || :unknown}

  def currency(%{status: status, approval_digest: digest} = invocation) when status in @pending do
    if is_binary(digest) and digest != "" do
      case Approval.stale_reason(invocation, tenant: invocation.organization_id) do
        nil -> {:current, nil}
        reason -> {:stale, reason}
      end
    else
      {:unknown, :unbound}
    end
  rescue
    _check_failed -> {:unknown, :unchecked}
  end

  def currency(%{status: status}) when is_atom(status) and not is_nil(status),
    do: {:decided, status}

  def currency(_unknown), do: {:unknown, :unreadable}

  # --- evidence and decisions, from the trace as the viewer ------------------------

  defp trace(%{correlation_id: id}, opts) when is_binary(id) and id != "" do
    case Execution.trace(%{correlation_id: id}, opts) do
      {:ok, %{entries: entries}} -> {:ok, entries}
      {:error, _error} -> :unreadable
    end
  end

  defp trace(_invocation, _opts), do: {:ok, []}

  defp evidence(invocation, trace) do
    subject =
      for %{"resource" => resource, "id" => id} = precondition <- invocation.preconditions || [],
          do: "#{short(resource)}:#{id}@#{precondition["version_number"]}"

    parent =
      Enum.reject(
        [
          invocation.run_id && "run:#{invocation.run_id}",
          invocation.process_instance_id && "process_instance:#{invocation.process_instance_id}",
          invocation.parent_invocation_id && "invocation:#{invocation.parent_invocation_id}"
        ],
        &is_nil/1
      )

    observed =
      case trace do
        {:ok, entries} -> for %{kind: :observation, source_ref: ref} <- entries, do: ref
        :unreadable -> []
      end

    subject ++ parent ++ observed
  end

  defp decisions({:ok, entries}) do
    for %{kind: :decision} = entry <- entries do
      %{definition_ref: entry.definition_ref, summary: entry.summary, status: entry.status}
    end
  end

  defp decisions(:unreadable), do: :unreadable

  # --- due and escalation ----------------------------------------------------------

  defp due(task, invocation),
    do: %{due_at: task.due_at, expires_at: invocation.approval_expires_at}

  defp escalation(task) do
    ProcessEvent
    |> Ash.Query.filter(task_id == ^task.id and kind in [:timer_fired, :escalation_failed])
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.read(authorize?: false, tenant: task.organization_id)
    |> case do
      {:ok, events} ->
        for %{data: %{"timer_kind" => "escalate"} = data} = event <- events do
          %{at: event.inserted_at, kind: escalation_kind(event.kind, data)}
        end

      {:error, _error} ->
        :unreadable
    end
  end

  defp escalation_kind(:escalation_failed, _data), do: :failed
  defp escalation_kind(:timer_fired, %{"handler" => "none"}), do: :no_handler
  defp escalation_kind(:timer_fired, _data), do: :escalated

  # --- questions ---------------------------------------------------------------------

  defp questions(invocation) do
    keys = [@approval_key, InfoRequest.key()]

    HumanTask
    |> Ash.Query.filter(
      subject_type == @invocation and subject_id == ^invocation.id and node_id in ^keys
    )
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.read!(authorize?: false, tenant: invocation.organization_id)
    |> pair()
  end

  # Each request for more information, with the answer the requester gave to the task
  # opened for it (the next information task).
  defp pair(tasks) do
    {asked, answers} = Enum.split_with(tasks, &(&1.node_id == @approval_key))
    asked = Enum.filter(asked, &(&1.status == :completed and &1.outcome == "request_info"))

    asked
    |> Enum.with_index()
    |> Enum.map(fn {task, index} ->
      answer = Enum.at(answers, index)

      %{
        question: task.comment,
        asked_at: task.updated_at,
        asked_by_id: task.decided_by_id,
        answer: answer && answer.status == :completed && answer.comment,
        answered_at: answer && answer.status == :completed && answer.updated_at,
        due_at: answer && answer.due_at
      }
    end)
  end

  defp short(resource) when is_binary(resource),
    do: resource |> String.split(".") |> List.last()

  defp short(resource), do: inspect(resource)
end
