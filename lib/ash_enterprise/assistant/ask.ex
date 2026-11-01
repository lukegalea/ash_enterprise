defmodule AshEnterprise.Assistant.Ask do
  @moduledoc """
  One assistant answer as a durable agent run (ADR 0056): the question is recorded, a
  run of the assistant agent (`AshEnterprise.Assistant.Agent`) is started for it, and
  the answer is recorded from the run's journal once the run ends.

  ## A run, not a process

  The answer is an `AshEnterprise.Execution.Run`, stepped by its `:step` jobs. Nothing
  lives in the page: a worker that dies mid-answer leaves the run `running` until its
  lease expires, and the recover sweep queues it again from its last recorded step. The
  page follows the run (`progress/2`, on each `AshEnterprise.Execution.Run` update it is
  told of, `topic/1`) and records the answer when the run ends (`settle/2`); a page that
  was closed records it when the thread is next opened (`pending/2`).

    * **Tools** — every assistant tool is a `:read`, so a run takes each in its loop and
      journals its result as a step. Composed surfaces and proposals are read off those
      results.
    * **Input** — the time, the conversation so far and the question
      (`AshEnterprise.Assistant.Prompt.input/3`): one user message, the run's sealed
      `input`.
    * **Sealing** — the run starts with the thread as its subject, so its input, output
      and journal are sealed under the thread's erasure scope (ADR 0024): shredding the
      thread shreds the run too.
    * **Its key** — `assistant:<thread>:<question>:<attempt>`, which is how a thread finds
      its runs again.
    * **The answer** — a `Turn` whose id is the run's, so recording it twice writes it
      once.

  ## The zone

  Before a run starts, the model every run step calls
  (`AshEnterprise.Execution.AgentRuntime.target/0`) must be in-zone and in the canonical
  store's zone (`AshEnterprise.Assistant.ZoneGate`); otherwise the answer fails at once
  with the reason, and a refused model call is recorded. The tools check it again on
  every read. There is no hosted fallback.

  ## Stopping

  Stop is the person cancelling their own answer: the run is read as them, then
  cancelled by the system actor, since cancelling a run is otherwise a role grant's
  (`AshEnterprise.Execution.Run`), and an answer is not work anyone else depends on. A
  run that reaches its step, tool-call or token limit is not lifted: it is cancelled the
  same way and the answer fails with that reason.

  Never logs content: reasons and counts only.
  """

  import Ash.Expr, only: [expr: 1]

  require Ash.Query
  require Logger

  alias AshAi.Transcript
  alias AshEnterprise.AI.Models
  alias AshEnterprise.Assistant.{Agent, History, Prompt, Turn, ZoneGate}
  alias AshEnterprise.Canonical.{CalendarEvent, Conversation}
  alias AshEnterprise.Execution
  alias AshEnterprise.Execution.AgentRuntime
  alias AshEnterprise.Platform.SystemActor

  @caller "assistant"
  @history 12
  @final [:completed, :failed, :cancelled]

  @typedoc "Why an answer failed: what the page explains."
  @type reason ::
          :not_configured
          | :outside_zone
          | :zone_mismatch
          | :not_published
          | :not_permitted
          | :step_cap
          | :budget
          | :timeout
          | :denied
          | :empty_answer
          | :internal

  @typedoc """
  A run as the page follows it: its tool calls so far (`"name"`, `"arguments"`,
  `"count"`, `"ok"`, and `"surface"` or `"proposal"` when the call put one on the page),
  the text of its latest model turn, and how many model calls it has made.
  """
  @type progress :: %{
          run: Ash.Resource.record(),
          calls: [map()],
          text: String.t(),
          model_calls: non_neg_integer(),
          refs: [String.t()]
        }

  @doc "The caller a refused model call is recorded under."
  @spec caller() :: String.t()
  def caller, do: @caller

  @doc "The model calls an answer may make: the agent's `max_steps`."
  @spec max_steps() :: pos_integer()
  def max_steps, do: Agent.__agent__().limits[:max_steps]

  @doc "The PubSub topic an answer's run publishes its updates on."
  @spec topic(Ash.UUID.t()) :: String.t()
  def topic(run_id), do: "agent_runs:#{run_id}"

  @doc """
  Records `question` in `thread` and starts the run that answers it, as the actor in
  `opts`. `{:ok, %{question: turn, run: run}}`, or `{:error, reason, %{question: turn,
  answer: turn}}` when it could not start, with the failed answer recorded (`question`
  is nil only when the question itself could not be recorded).
  """
  @spec ask(Ash.Resource.record(), String.t(), keyword()) ::
          {:ok, %{question: Turn.t(), run: Ash.Resource.record()}}
          | {:error, reason(), %{question: Turn.t() | nil, answer: Turn.t() | nil}}
  def ask(thread, question, opts) do
    case Turn.append(%{thread_id: thread.id, role: :user, content: question}, opts) do
      {:ok, turn} -> start(thread, turn, opts)
      {:error, _error} -> {:error, :internal, %{question: nil, answer: nil}}
    end
  end

  @doc "Answers `question`, a recorded question `Turn` of `thread`, again: see `ask/3`."
  @spec retry(Ash.Resource.record(), Turn.t(), keyword()) ::
          {:ok, %{question: Turn.t(), run: Ash.Resource.record()}}
          | {:error, reason(), %{question: Turn.t(), answer: Turn.t() | nil}}
  def retry(thread, %Turn{role: :user} = question, opts), do: start(thread, question, opts)

  defp start(thread, question, opts) do
    with :ok <- zone(),
         {:ok, run} <- start_run(thread, question, opts) do
      {:ok, %{question: question, run: run}}
    else
      {:error, reason} ->
        Logger.warning("assistant answer failed before its run started: #{reason}")

        answer =
          record(thread.id, %{id: Ash.UUID.generate(), status: :failed, reason: reason}, opts)

        {:error, reason, %{question: question, answer: answer}}
    end
  end

  # The run's model, in the canonical store's zone, or no run at all. A refusal is
  # recorded like the guard's, though the guard itself would let a hosted model through
  # with REQUIRE_IN_ZONE_MODELS off.
  defp zone do
    target = AgentRuntime.target()

    reason =
      case {target.residency, ZoneGate.check(target)} do
        {:in_zone, :ok} -> nil
        {:in_zone, {:error, :zone_mismatch}} -> :zone_mismatch
        {_outside, _} -> if(configured?(), do: :outside_zone, else: :not_configured)
      end

    if reason do
      Models.record(target, @caller, :stream_text, :refused, nil, 0, Atom.to_string(reason))
      {:error, reason}
    else
      :ok
    end
  end

  defp configured?, do: Models.resolve(Models.default_spec()).residency == :in_zone

  defp start_run(thread, question, opts) do
    input = Prompt.input(question.content, prior(thread, question, opts))
    key = "#{prefix(thread.id)}#{question.id}:#{Ash.UUID.generate()}"

    case Execution.start_agent_run(
           Agent.key(),
           input,
           %{
             run_key: key,
             origin: :assistant,
             subject_type: inspect(thread.__struct__),
             subject_id: thread.id
           },
           opts
         ) do
      {:ok, run} -> {:ok, run}
      {:error, error} -> {:error, start_refusal(error)}
    end
  end

  # No published version in the tenant is the agent argument's error; no start grant
  # (or no person to run as) is forbidden.
  defp start_refusal(%Ash.Error.Forbidden{}), do: :not_permitted

  defp start_refusal(%Ash.Error.Invalid{errors: errors}) do
    if Enum.any?(errors, &match?(%{field: :agent}, &1)), do: :not_published, else: :internal
  end

  defp start_refusal(_error), do: :internal

  # The thread before this question, as text turns.
  defp prior(thread, question, opts) do
    case History.load(thread.id, opts) do
      {:ok, %{turns: entries}} ->
        entries
        |> Enum.take_while(&(&1.turn.id != question.id))
        |> History.prior(@history)

      _ ->
        []
    end
  end

  defp prefix(thread_id), do: "assistant:#{thread_id}:"

  @doc """
  The runs of `thread` that have no recorded answer yet, oldest first, each with the id
  of the question it answers: `[{question_id, run}]`. Read as the actor in `opts`.
  """
  @spec pending(Ash.Resource.record(), [Turn.t()], keyword()) ::
          [{Ash.UUID.t(), Ash.Resource.record()}]
  def pending(thread, turns, opts) do
    answered = MapSet.new(turns, & &1.id)
    prefix = prefix(thread.id)

    Execution.list_agent_runs(
      Keyword.merge(opts,
        query: [filter: expr(contains(run_key, ^prefix)), sort: [created_on: :asc]]
      )
    )
    |> case do
      {:ok, runs} ->
        for run <- runs,
            not MapSet.member?(answered, run.id),
            [question_id, _attempt] <- [run_key_parts(run.run_key, prefix)],
            do: {question_id, run}

      {:error, _error} ->
        []
    end
  end

  defp run_key_parts(key, prefix) do
    key |> String.replace_prefix(prefix, "") |> String.split(":", parts: 2)
  end

  @doc "The run `run_id` and its journal so far, as the actor in `opts` reads them."
  @spec progress(Ash.UUID.t(), keyword()) :: {:ok, progress()} | {:error, term()}
  def progress(run_id, opts) do
    with {:ok, run} <- Execution.get_agent_run(run_id, opts),
         {:ok, steps} <-
           Execution.list_agent_steps(
             Keyword.merge(opts,
               query: [filter: [run_id: run.id], sort: [seq: :asc]],
               load: [:parts]
             )
           ) do
      {:ok, journal(run, steps)}
    end
  end

  @doc """
  Records the answer of the run `run_id` once it has ended, as the actor in `opts`:
  `{:ok, turn}` for a completed run, `{:error, reason, turn}` for one that failed, was
  stopped or reached a limit, and `{:pending, progress}` while it is still working. A
  run waiting on a limit is cancelled first: an answer's limits are not lifted.
  Recording twice records once.
  """
  @spec settle(Ash.Resource.record(), Ash.UUID.t(), keyword()) ::
          {:ok, Turn.t()} | {:error, reason() | :stopped, Turn.t() | nil} | {:pending, progress()}
  def settle(thread, run_id, opts) do
    case progress(run_id, opts) do
      {:ok, progress} -> settled(thread, progress, verdict(progress.run), opts)
      {:error, _error} -> {:error, :internal, nil}
    end
  end

  defp settled(_thread, progress, :pending, _opts), do: {:pending, progress}

  defp settled(thread, progress, {:limit, reason}, opts) do
    _ = cancel(progress.run)
    answer(thread, progress, :failed, reason, opts)
  end

  defp settled(thread, progress, {status, reason}, opts),
    do: answer(thread, progress, status, reason, opts)

  @doc "Stops the run `run_id`: read as the actor in `opts`, then cancelled. See the moduledoc."
  @spec stop(Ash.UUID.t(), keyword()) :: :ok | {:error, term()}
  def stop(run_id, opts) do
    with {:ok, run} <- Execution.get_agent_run(run_id, opts) do
      if run.status in @final, do: :ok, else: cancel(run)
    end
  end

  defp cancel(run) do
    case Execution.request_agent_run_cancel(run,
           actor: SystemActor.system(),
           tenant: run.organization_id
         ) do
      {:ok, _run} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp verdict(%{status: :completed}), do: {:complete, nil}
  defp verdict(%{status: :cancelled}), do: {:stopped, nil}
  defp verdict(%{status: :failed} = run), do: {:failed, failure(run)}
  defp verdict(%{status: :waiting, blocked_on: :limit}), do: {:limit, :step_cap}
  defp verdict(%{status: :waiting, blocked_on: :budget}), do: {:limit, :budget}
  defp verdict(_run), do: :pending

  defp failure(%{failure_class: :timeout}), do: :timeout
  defp failure(%{failure_class: :denied}), do: :denied
  defp failure(%{error_code: "output_uncastable"}), do: :empty_answer
  defp failure(_run), do: :internal

  defp answer(thread, progress, status, reason, opts) do
    run = progress.run

    if reason do
      Logger.warning(
        "assistant answer #{status}: #{reason} after #{progress.model_calls} model call(s), " <>
          "#{length(progress.calls)} tool call(s)"
      )
    end

    turn =
      record(
        thread.id,
        %{
          id: run.id,
          status: status,
          reason: reason,
          content: if(status == :complete, do: answer_text(run, progress), else: progress.text),
          calls: progress.calls,
          refs: progress.refs,
          source_scope_ids: source_scopes(progress.refs, opts),
          iterations: progress.model_calls,
          duration_ms: max(DateTime.diff(run.modified_on, run.created_on, :millisecond), 0)
        },
        opts
      )

    cond do
      status == :complete -> {:ok, turn}
      status == :stopped -> {:error, :stopped, turn}
      true -> {:error, reason, turn}
    end
  end

  defp answer_text(run, progress) do
    case run.output do
      text when is_binary(text) and text != "" -> String.trim(text)
      _none -> String.trim(progress.text)
    end
  end

  # The answer, written once: a second write of the same id is refused, and the turn
  # already recorded is the answer.
  defp record(thread_id, answer, opts) do
    attrs = %{
      id: answer.id,
      thread_id: thread_id,
      role: :assistant,
      content: Map.get(answer, :content, ""),
      status: answer.status,
      error_class: answer.reason && Atom.to_string(answer.reason),
      tool_calls: %{"calls" => Map.get(answer, :calls, [])},
      refs: Map.get(answer, :refs, []),
      source_scope_ids: Map.get(answer, :source_scope_ids, []),
      iterations: Map.get(answer, :iterations),
      duration_ms: Map.get(answer, :duration_ms)
    }

    case Turn.append(attrs, opts) do
      {:ok, turn} -> turn
      {:error, _error} -> recorded(answer.id, opts)
    end
  end

  defp recorded(id, opts) do
    Turn
    |> Ash.Query.filter(id == ^id)
    |> Ash.read_one(opts)
    |> case do
      {:ok, %Turn{} = turn} -> turn
      _ -> nil
    end
  end

  # -- the journal --------------------------------------------------------------------

  defp journal(run, steps) do
    parts = Enum.flat_map(steps, &(&1.parts || []))

    results =
      for %{"type" => "tool_result", "id" => id} = part <- parts,
          into: %{},
          do: {id, decode(part["content"])}

    calls =
      for %{"type" => "tool_call", "id" => id} = part <- parts do
        call(run, part, Map.fetch(results, id))
      end

    %{
      run: run,
      calls: calls,
      text: latest_text(steps),
      model_calls: run.step_count,
      refs: results |> Map.values() |> Enum.flat_map(&refs_in/1) |> Enum.uniq()
    }
  end

  defp call(run, part, result) do
    base = %{
      "name" => part["name"],
      "arguments" => decode(part["arguments"]),
      "ok" => nil,
      "count" => nil
    }

    case result do
      :error ->
        base

      {:ok, rows} when is_list(rows) ->
        shown(%{base | "ok" => true, "count" => length(rows)}, run, part["id"], rows)

      {:ok, _refusal} ->
        %{base | "ok" => false}
    end
  end

  # What a compose or propose tool put on the page: a surface to render or a proposal
  # to confirm, under an id of the page's own, derived from the run and the call so the
  # page and the recorded answer name it alike.
  defp shown(call, run, call_id, [%{"surface" => %{} = request} = row]) do
    Map.put(call, "surface", %{
      "id" => page_id("s", run, call_id),
      "request" => request,
      "title" => row["shown"]
    })
  end

  defp shown(call, run, call_id, [%{"proposal" => %{} = wire} = row]) do
    Map.put(call, "proposal", %{
      "id" => page_id("p", run, call_id),
      "wire" => wire,
      "summary" => row["proposed"],
      # What the person does with it is recorded as a settlement, so the page may offer
      # it again until then.
      "settled" => "recorded"
    })
  end

  defp shown(call, _run, _call_id, _rows), do: call

  defp page_id(prefix, run, call_id) do
    digest = :crypto.hash(:sha256, run.id <> ":" <> to_string(call_id))
    prefix <> Base.encode16(binary_part(digest, 0, 6), case: :lower)
  end

  # The text of the latest model turn: the answer once the run has completed, or what it
  # said before its last lookups while it works.
  defp latest_text(steps) do
    steps
    |> Enum.filter(&(&1.role == :assistant))
    |> List.last()
    |> case do
      nil -> ""
      step -> step.parts |> Transcript.text() |> to_string()
    end
  end

  defp decode(text) when is_binary(text) do
    case Jason.decode(text) do
      {:ok, value} -> value
      {:error, _} -> text
    end
  end

  defp decode(value), do: value

  defp refs_in(%{} = map) do
    Enum.flat_map(map, fn
      {"ref", ref} when is_binary(ref) -> [ref]
      {_key, value} -> refs_in(value)
    end)
  end

  defp refs_in(list) when is_list(list), do: Enum.flat_map(list, &refs_in/1)
  defp refs_in(_value), do: []

  # The erasure scopes the cited records were sealed under, read as the person (they
  # could see them a moment ago). People, tasks, briefs and approvals are not sealed
  # under a connection scope.
  defp source_scopes([], _opts), do: []

  defp source_scopes(refs, opts) do
    ids =
      for ref <- refs,
          [_surface, id] <- [String.split(ref, ":", parts: 2)],
          {:ok, uuid} <- [Ecto.UUID.cast(id)],
          do: uuid

    [Conversation, CalendarEvent]
    |> Enum.flat_map(&scopes_of(&1, ids, opts))
    |> Enum.uniq()
  end

  defp scopes_of(_resource, [], _opts), do: []

  defp scopes_of(resource, ids, opts) do
    resource
    |> Ash.Query.filter(id in ^ids)
    |> Ash.Query.select([:id, :erasure_scope_id])
    |> Ash.read(opts)
    |> case do
      {:ok, rows} -> Enum.map(rows, & &1.erasure_scope_id)
      _ -> []
    end
  end
end
