defmodule AshEnterprise.Assistant.Runner do
  @moduledoc """
  One assistant answer: the question is recorded, the in-zone model is asked
  with the read tools, and the answer is recorded however the run ends.

  ## The loop

  `AshAi.ToolLoop.stream/2` over `AshEnterprise.Assistant`'s tools, with:

    * **model** — the in-zone generative profile, and only that
      (`AshEnterprise.AI.Models.default_spec/0` resolved by `Models.resolve/1`).
      A target outside the zone, or in-zone but not in the canonical store's
      zone, is refused before anything is sent — whatever
      `REQUIRE_IN_ZONE_MODELS` says — and the refusal is recorded. There is
      no hosted fallback, ever.
    * **transport** — `AshEnterprise.AI.Models.GuardedReqLLM`, so every model
      call passes the ADR 0042 guard and appends an `AshEnterprise.AI.ModelCall`
      (`caller: "#{"assistant.chat"}"`).
    * **tools** — native OpenAI-style `tools`/`tool_calls`: the in-zone
      runtime emits them reliably (`docs/research/splash-tool-calling.md`),
      so there is no text protocol to parse. Each tool runs as the person,
      and the run's target rides in the action context so the zone gate can
      check it (`AshEnterprise.Assistant.ZoneGate`).
    * **step cap** — at most `#{6}` model calls. A run that reaches the cap
      gets one more call with no tools, asking it to answer from what it
      found; if that yields nothing, the answer fails as `step_cap`.

  ## Events

  The caller's process (`notify:`) receives `{:assistant, ref, event}`:

    * `{:user_turn, turn}` — the question, recorded;
    * `:waiting` — a model call is open;
    * `{:text, chunk}` — answer text as it streams;
    * `{:tool_call, %{id:, name:, arguments:}}` and
      `{:tool_result, %{id:, ok?:, count:}}`;
    * `{:surface, %{id:, request:, title:}}` — `compose_surface` verified a
      surface; the page composes `request` again as the person to show it;
    * `{:proposal, %{id:, wire:, summary:}}` — a proposal tool built one; the
      page rebuilds it from `wire` as the person and waits for a confirm;
    * `{:step, n}` — model call `n` is starting;
    * `{:done, turn}` / `{:failed, reason, turn}` — terminal, after the answer
      is recorded (`turn` is nil only if recording failed).

  Send `{:assistant_stop, ref}` to the run's process to stop it: it closes
  the open stream at the next chunk and records the answer as `:stopped`.

  Never logs content: failures are logged by reason atom and counts only.
  """

  require Ash.Query
  require Logger

  alias AshEnterprise.AI.Models
  alias AshEnterprise.AI.Models.GuardedReqLLM
  alias AshEnterprise.Assistant
  alias AshEnterprise.Assistant.{History, Prompt, Turn, ZoneGate}
  alias AshEnterprise.Canonical.{CalendarEvent, Conversation}

  @caller "assistant.chat"
  @max_steps 6
  @history 12

  @typedoc "Why an answer failed: what the page explains."
  @type reason ::
          :not_configured
          | :outside_zone
          | :zone_mismatch
          | :model_unreachable
          | :model_recovering
          | :model_error
          | :step_cap
          | :empty_answer
          | :internal

  @doc "The caller name model calls are recorded under."
  @spec caller() :: String.t()
  def caller, do: @caller

  @doc "The step cap: model calls per answer."
  @spec max_steps() :: pos_integer()
  def max_steps, do: @max_steps

  @doc """
  Starts a run under `AshEnterprise.TaskSupervisor` and returns its pid.
  See `run/1` for the options.
  """
  @spec start(keyword()) :: {:ok, pid()} | {:error, term()}
  def start(opts) do
    Task.Supervisor.start_child(AshEnterprise.TaskSupervisor, fn -> run(opts) end,
      restart: :temporary
    )
  end

  @doc """
  Runs one answer in the calling process.

    * `:thread` — the `AshEnterprise.Assistant.Thread` (required);
    * `:question` — the new question, recorded first; or
    * `:retry` — an existing question `Turn` to answer again;
    * `:actor`, `:tenant` — the person (required);
    * `:notify`, `:ref` — where events go (default: the caller, `make_ref()`);
    * `:answer_id` — the answer turn's id, so a page that gives up on a run
      can record the same answer without writing it twice;
    * `:model` — a model spec (default: the in-zone profile);
    * `:req_llm_opts` — extra transport options (tests pass `downstream:`);
    * `:max_steps` — the step cap (default #{@max_steps}).

  Returns `{:ok, turn}` or `{:error, reason, turn}`.
  """
  @spec run(keyword()) :: {:ok, Turn.t()} | {:error, reason(), Turn.t() | nil}
  def run(opts) do
    state = init(opts)

    # The question is recorded even when the model cannot be asked, so the
    # person can retry it once the in-zone runtime is back.
    with {:ok, state} <- record_question(state),
         {:ok, target} <- target(state) do
      %{state | target: target} |> converse() |> finish()
    else
      {:error, reason, state} -> fail_early(state, reason)
    end
  rescue
    error ->
      Logger.error("assistant run crashed: #{inspect(error.__struct__)}")
      fail_early(init(opts), :internal)
  end

  # -- setup ---------------------------------------------------------------------

  defp init(opts) do
    %{
      thread: Keyword.fetch!(opts, :thread),
      question: opts[:question],
      user_turn: opts[:retry],
      actor: Keyword.fetch!(opts, :actor),
      tenant: Keyword.fetch!(opts, :tenant),
      notify: Keyword.get(opts, :notify, self()),
      ref: Keyword.get_lazy(opts, :ref, &make_ref/0),
      answer_id: Keyword.get_lazy(opts, :answer_id, &Ash.UUID.generate/0),
      model: Keyword.get_lazy(opts, :model, &Models.default_spec/0),
      req_llm_opts: Keyword.get_lazy(opts, :req_llm_opts, &configured_transport/0),
      max_steps: Keyword.get(opts, :max_steps, @max_steps),
      started: System.monotonic_time(),
      target: nil,
      # what the run accumulates
      text: "",
      calls: [],
      refs: MapSet.new(),
      steps: 0,
      result: nil,
      error: nil,
      stopped?: false
    }
  end

  # Extra transport options from configuration. Only the test suite sets any
  # (`downstream:`, the scripted model, so the LiveView's runs never reach a
  # network); a deployment has no reason to.
  defp configured_transport do
    :ash_enterprise
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:req_llm_opts, [])
  end

  # The in-zone profile, in the canonical store's zone — or nothing at all.
  # A refusal here is recorded like the guard's, though the guard itself
  # would have let a hosted model through with REQUIRE_IN_ZONE_MODELS off.
  defp target(state) do
    target = Models.resolve(state.model)

    reason =
      case {target.residency, ZoneGate.check(target)} do
        {:in_zone, :ok} -> nil
        {:in_zone, {:error, :zone_mismatch}} -> :zone_mismatch
        {:outside_zone, _} -> if(configured?(), do: :outside_zone, else: :not_configured)
      end

    if reason do
      Models.record(target, @caller, :stream_text, :refused, nil, 0, Atom.to_string(reason))
      {:error, reason, state}
    else
      {:ok, target}
    end
  end

  defp configured?, do: Models.resolve(Models.default_spec()).residency == :in_zone

  defp record_question(%{user_turn: %Turn{}} = state), do: {:ok, state}

  defp record_question(%{question: question} = state) when is_binary(question) do
    case append(state, %{role: :user, content: question}) do
      {:ok, turn} ->
        emit(state, {:user_turn, turn})
        {:ok, %{state | user_turn: turn}}

      {:error, _error} ->
        {:error, :internal, state}
    end
  end

  # -- the conversation ------------------------------------------------------------

  defp converse(state) do
    messages = [ReqLLM.Context.system(Prompt.system()) | prior(state)]
    messages = messages ++ [ReqLLM.Context.user(state.user_turn.content)]

    state = consume(AshAi.ToolLoop.stream(messages, loop_opts(state, true)), state)

    cond do
      state.error == :max_iterations_reached and not state.stopped? -> final_answer(state)
      unbacked_proposal?(state) -> back_the_claim(state)
      true -> state
    end
  end

  # An answer that says it proposed something when no propose_ tool ran in
  # this run: the person would look for a Confirm that is not there. The live
  # eval caught the in-zone model doing it after an answer that offered a
  # proposal. One corrective turn, with the tools: make the proposal, or say
  # that nothing was proposed.
  # A claim in the past tense ("I've proposed", "Proposed: …"), not an
  # offer ("I can propose"), which is an honest answer.
  @claims_a_proposal ~r/\b(?:I'?ve|I have|I) (?:just )?proposed\b|^\W*proposed\b/imu

  defp unbacked_proposal?(
         %{error: nil, stopped?: false, result: %AshAi.ToolLoop.Result{}} = state
       ) do
    Regex.match?(@claims_a_proposal, answer_text(state)) and
      not Enum.any?(state.calls, &Map.has_key?(&1, "proposal")) and
      state.steps < state.max_steps
  end

  defp unbacked_proposal?(_state), do: false

  defp back_the_claim(%{result: %AshAi.ToolLoop.Result{messages: messages}} = state) do
    nudge =
      ReqLLM.Context.user(
        "No propose_ tool ran in this answer, so nothing is on the person's screen to " <>
          "confirm. If they asked for a change, call the propose_ tool now. Otherwise " <>
          "answer again without saying anything was proposed."
      )

    done = state.steps
    state = %{state | result: nil, text: "", max_steps: max(state.max_steps - done, 1)}
    state = consume(AshAi.ToolLoop.stream(messages ++ [nudge], loop_opts(state, true)), state)
    %{state | steps: done + state.steps}
  end

  # The thread before this question, as text turns.
  defp prior(state) do
    case History.load(state.thread.id, actor_opts(state)) do
      {:ok, %{turns: entries}} ->
        entries
        |> Enum.take_while(&(&1.turn.id != state.user_turn.id))
        |> History.messages(@history)

      _ ->
        []
    end
  end

  defp loop_opts(state, tools?) do
    base = [
      model: state.target.spec,
      req_llm: GuardedReqLLM,
      req_llm_opts: Keyword.merge([caller: @caller, temperature: 0.2], state.req_llm_opts),
      actor: state.actor,
      tenant: state.tenant,
      context: %{ZoneGate.key() => state.target},
      max_iterations: if(tools?, do: state.max_steps, else: 1)
    ]

    if tools?,
      do:
        base ++
          [
            actions: Enum.map(Assistant.tool_resources(), &{&1, :*}),
            tools: Assistant.tool_names()
          ],
      else: base ++ [tools: false]
  end

  # At the cap: one call with no tools, over everything the loop gathered.
  defp final_answer(%{result: %AshAi.ToolLoop.Result{messages: messages}} = state) do
    nudge =
      ReqLLM.Context.user(
        "You have used all your lookups. Answer now from the results above, " <>
          "citing refs as before. Do not call tools."
      )

    state = %{state | error: nil, result: nil, text: ""}
    state = consume(AshAi.ToolLoop.stream(messages ++ [nudge], loop_opts(state, false)), state)

    %{
      state
      | error: state.error || if(String.trim(state.text) == "", do: :max_iterations_reached)
    }
  end

  defp final_answer(state), do: state

  defp consume(stream, state) do
    emit(state, :waiting)

    Enum.reduce_while(stream, state, fn event, state ->
      receive do
        {:assistant_stop, ref} when ref == state.ref -> {:halt, %{state | stopped?: true}}
      after
        0 -> {:cont, handle(event, state)}
      end
    end)
  rescue
    error -> %{state | error: error}
  catch
    :exit, reason -> %{state | error: {:exit, reason}}
  end

  defp handle({:content, chunk}, state) do
    emit(state, {:text, chunk})
    %{state | text: state.text <> chunk}
  end

  defp handle({:tool_call, %{id: id, name: name, arguments: arguments}}, state) do
    emit(state, {:tool_call, %{id: id, name: name, arguments: arguments}})
    call = %{"id" => id, "name" => name, "arguments" => arguments, "ok" => nil, "count" => nil}
    # The text so far was narration before a lookup, not the answer.
    %{state | calls: state.calls ++ [call], text: ""}
  end

  defp handle({:tool_result, %{id: id, result: result}}, state) do
    {ok?, count, refs} = outcome(result)
    emit(state, {:tool_result, %{id: id, ok?: ok?, count: count}})
    shown = shown(result)
    Enum.each(shown, &emit(state, &1))

    calls =
      Enum.map(state.calls, fn
        %{"id" => ^id} = call ->
          Enum.reduce(shown, %{call | "ok" => ok?, "count" => count}, &record_shown/2)

        call ->
          call
      end)

    %{state | calls: calls, refs: Enum.into(refs, state.refs)}
  end

  defp handle({:iteration, %{iteration: n}}, state) do
    emit(state, {:step, n})
    emit(state, :waiting)
    %{state | steps: n}
  end

  defp handle({:error, reason}, state), do: %{state | error: reason}

  defp handle({:done, %AshAi.ToolLoop.Result{} = result}, state),
    do: %{state | result: result, steps: max(state.steps, result.iterations)}

  defp handle(_other, state), do: state

  # A tool's raw result is the action's map: `count`, and refs anywhere in it.
  # A refusal (`error`) is a tool that answered, but not with rows.
  defp outcome({:ok, _content, %{} = raw}) do
    ok? = not Map.has_key?(raw, "error")
    {ok?, raw["count"] || raw["total"], refs_in(raw)}
  end

  defp outcome({:ok, _content, _raw}), do: {true, nil, []}
  defp outcome(_error), do: {false, nil, []}

  # What a compose or propose tool put on the page: a surface to render or a
  # proposal to confirm, each under an id of the page's own (never the
  # model's call id). Events for the page; recorded on the call.
  defp shown({:ok, _content, %{"surface" => %{} = request} = raw})
       when not is_map_key(raw, "error") do
    [{:surface, %{id: page_id("s"), request: request, title: raw["shown"]}}]
  end

  defp shown({:ok, _content, %{"proposal" => %{} = wire} = raw})
       when not is_map_key(raw, "error") do
    [{:proposal, %{id: page_id("p"), wire: wire, summary: raw["proposed"]}}]
  end

  defp shown(_result), do: []

  defp record_shown({:surface, surface}, call),
    do:
      Map.put(call, "surface", %{
        "id" => surface.id,
        "request" => surface.request,
        "title" => surface.title
      })

  defp record_shown({:proposal, proposal}, call),
    do:
      Map.put(call, "proposal", %{
        "id" => proposal.id,
        "wire" => proposal.wire,
        "summary" => proposal.summary,
        # What the person does with it is recorded as a settlement, so the
        # page may offer it again until then (an older proposal, recorded
        # before settlements existed, is never offered again).
        "settled" => "recorded"
      })

  defp page_id(prefix),
    do: prefix <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)

  defp refs_in(%{} = map) do
    Enum.flat_map(map, fn
      {"ref", ref} when is_binary(ref) -> [ref]
      {_key, value} -> refs_in(value)
    end)
  end

  defp refs_in(list) when is_list(list), do: Enum.flat_map(list, &refs_in/1)
  defp refs_in(_value), do: []

  # -- the answer ------------------------------------------------------------------

  defp finish(state) do
    {status, reason} = verdict(state)
    content = answer_text(state)

    attrs = %{
      role: :assistant,
      content: content,
      status: status,
      error_class: reason && Atom.to_string(reason),
      tool_calls: %{"calls" => Enum.map(state.calls, &Map.delete(&1, "id"))},
      refs: MapSet.to_list(state.refs),
      source_scope_ids: source_scopes(state),
      iterations: state.steps,
      duration_ms: Models.elapsed_ms(state.started)
    }

    turn =
      case append(state, Map.put(attrs, :id, state.answer_id)) do
        {:ok, turn} -> turn
        {:error, _} -> nil
      end

    if reason do
      Logger.warning(
        "assistant answer #{status}: #{reason} after #{state.steps} step(s), " <>
          "#{length(state.calls)} tool call(s)"
      )

      emit(state, {:failed, reason, turn})
      {:error, reason, turn}
    else
      emit(state, {:done, turn})
      {:ok, turn}
    end
  end

  defp verdict(%{stopped?: true}), do: {:stopped, nil}

  defp verdict(%{error: nil} = state),
    do: if(answer_text(state) == "", do: {:failed, :empty_answer}, else: {:complete, nil})

  defp verdict(%{error: error}), do: {:failed, classify(error)}

  defp answer_text(%{result: %AshAi.ToolLoop.Result{final_text: text}} = state)
       when is_binary(text) and text != "",
       do: text |> String.trim() |> fallback(state.text)

  defp answer_text(state), do: String.trim(state.text)

  defp fallback("", text), do: String.trim(text)
  defp fallback(text, _), do: text

  @doc "The reason a run's error is shown as."
  @spec classify(term()) :: reason()
  def classify(:max_iterations_reached), do: :step_cap
  def classify(%Models.OutsideZone{}), do: :outside_zone
  def classify(%ReqLLM.Error.API.Request{status: 503}), do: :model_recovering
  def classify(%ReqLLM.Error.API.Response{status: 503}), do: :model_recovering
  def classify(%ReqLLM.Error.API.Request{status: nil}), do: :model_unreachable
  def classify({:exit, _reason}), do: :model_unreachable

  def classify(%{__struct__: struct} = error) do
    name = inspect(struct)

    cond do
      String.contains?(name, "TransportError") ->
        :model_unreachable

      String.contains?(name, "Timeout") ->
        :model_unreachable

      match?(%{status: status} when is_integer(status) and status >= 500, error) ->
        :model_recovering

      true ->
        :model_error
    end
  end

  def classify(reason) when reason in [:timeout, :econnrefused, :ehostunreach, :closed],
    do: :model_unreachable

  def classify(_other), do: :model_error

  # The erasure scopes the cited records were sealed under, read as the
  # person (they could see them a moment ago). People, tasks, briefs and
  # approvals are not sealed under a connection scope.
  defp source_scopes(state) do
    ids =
      state.refs
      |> Enum.map(&String.split(&1, ":", parts: 2))
      |> Enum.flat_map(fn
        [_surface, id] -> [id]
        _ -> []
      end)
      |> Enum.flat_map(fn id ->
        case Ecto.UUID.cast(id) do
          {:ok, uuid} -> [uuid]
          :error -> []
        end
      end)

    if ids == [] do
      []
    else
      opts = actor_opts(state)

      [Conversation, CalendarEvent]
      |> Enum.flat_map(&scopes_of(&1, ids, opts))
      |> Enum.uniq()
    end
  end

  # No answer is recorded without a recorded question to hang it on.
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

  defp fail_early(state, reason) do
    turn =
      with %Turn{} <- state.user_turn,
           {:ok, turn} <-
             append(state, %{
               id: state.answer_id,
               role: :assistant,
               content: "",
               status: :failed,
               error_class: Atom.to_string(reason),
               duration_ms: Models.elapsed_ms(state.started)
             }) do
        turn
      else
        _ -> nil
      end

    Logger.warning("assistant answer failed before the model was asked: #{reason}")
    emit(state, {:failed, reason, turn})
    {:error, reason, turn}
  end

  defp append(state, attrs) do
    Turn.append(Map.put(attrs, :thread_id, state.thread.id), actor_opts(state))
  end

  defp actor_opts(state), do: [actor: state.actor, tenant: state.tenant, authorize?: true]

  defp emit(%{notify: pid, ref: ref}, event) when is_pid(pid),
    do: send(pid, {:assistant, ref, event})

  defp emit(_state, _event), do: :ok
end
