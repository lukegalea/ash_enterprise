defmodule AshEnterprise.AgentSpike.S1ResumeRecordedResultsTest do
  @moduledoc """
  Spike S1: can a durable run resume its tool loop from tool results that
  were recorded elsewhere, so that no effect ever runs inside the loop?

  **Reading tested.** One job runs the loop until the model asks for a tool
  that needs governing; `approve_tool_call` answers `:ask`, the loop stops
  with `status: :awaiting_approval`, and the job stores each `{:message, m}`
  through `AshAi.Transcript.to_parts/2` as JSON. The effect then runs outside
  the loop, as an invocation, and its result is recorded. A later job
  rebuilds the messages with `Transcript.from_parts/1` and calls
  `AshAi.ToolLoop.resume/3` with *recorded-result tools*: tool callbacks that
  only return the recorded result. The reading is that ash_ai then builds the
  same provider messages it would have built had the tool run in the loop.

  **Result: holds, with one correction.** The model's next request after a
  resume is identical to the request it gets when the tool runs in the loop:
  the same messages, the same tool definitions, and the same OpenAI and
  Anthropic wire bodies (tool-call ids paired with their results, the
  thinking block's signature kept through the JSON round trip). A recorded
  failure and a refused approval reach the model as ordinary tool results.
  The fake model transport records every request; no provider is called.

  Correction: a tool callback receives `(arguments, context)` and nothing in
  either names the tool call it is answering (upstream item U1). A
  recorded-result tool therefore cannot look its invocation up by call id.
  Two ways work today and give identical requests, both asserted below:

    * recorded-result tools that hand out each tool's recorded results in the
      order of `ToolLoop.pending_tool_calls/1`, which is the order the loop
      runs them in; or
    * appending `ReqLLM.Context.tool_result(call_id, content)` for each
      pending call and calling `ToolLoop.run/2`, which then has no pending
      round and goes straight to the model. The loop emits no `{:message, _}`
      for results added this way, so the job records them itself.

  The second is simpler and does not depend on call order, so the runtime
  should take it until U1 lands. It is the fallback the plan names for an S1
  failure ("host-built tool-result messages"), and costs one function.
  """

  use ExUnit.Case, async: true

  alias AshAi.ToolLoop
  alias AshAi.Transcript
  alias ReqLLM.Context
  alias ReqLLM.Providers.Anthropic.Context, as: AnthropicContext

  @user "SYNTHETIC: book a cleaning for patient P-001 tomorrow morning"
  @system "You book appointments for a synthetic dental clinic."
  @signature "sig-synthetic-0001"

  @hours_args %{"day" => "tomorrow"}
  @book_args %{"patient" => "P-001", "slot" => "10:00"}
  @hours_result ~s({"opens":"08:00","closes":"17:00"})
  @book_result ~s({"appointment_id":"apt-synthetic-1","starts_at":"10:00"})

  defmodule FakeModel do
    @moduledoc """
    Stands in for ReqLLM as the loop's `req_llm:` module. Each request takes
    the next scripted reply from the Agent named in `req_llm_opts` and is
    recorded there. Synthetic text only.
    """

    def stream_text(model, messages, opts) do
      script = Keyword.fetch!(opts, :spike_script)

      reply =
        Agent.get_and_update(script, fn %{replies: [reply | rest]} = state ->
          request = %{messages: messages, tools: Keyword.get(opts, :tools, [])}
          {reply, %{state | replies: rest, requests: state.requests ++ [request]}}
        end)

      respond(reply, model, messages)
    end

    defp respond({:tool_round, thinking, text, calls}, model, messages) do
      # Shaped as ReqLLM's Anthropic decoder emits a signed thinking block:
      # the thinking text, then a meta chunk carrying its reasoning details.
      details = %ReqLLM.Message.ReasoningDetails{
        text: thinking,
        signature: "sig-synthetic-0001",
        encrypted?: true,
        provider: :anthropic,
        format: "anthropic-thinking-v1",
        index: 0,
        provider_data: %{"type" => "thinking"}
      }

      chunks =
        [
          ReqLLM.StreamChunk.thinking(thinking, %{signature: "sig-synthetic-0001"}),
          ReqLLM.StreamChunk.meta(%{reasoning_details: [details]}),
          ReqLLM.StreamChunk.text(text)
        ] ++
          (calls
           |> Enum.with_index()
           |> Enum.map(fn {{id, name, args}, i} ->
             ReqLLM.StreamChunk.tool_call(name, args, %{id: id, index: i})
           end))

      response(chunks, :tool_calls, model, messages)
    end

    defp respond({:text, text}, model, messages),
      do: response([ReqLLM.StreamChunk.text(text)], :stop, model, messages)

    defp response(chunks, finish, model, messages) do
      {:ok, handle} =
        ReqLLM.StreamResponse.MetadataHandle.start_link(fn ->
          %{usage: %{input_tokens: 40, output_tokens: 8}, finish_reason: finish}
        end)

      {:ok,
       %ReqLLM.StreamResponse{
         stream: chunks,
         metadata_handle: handle,
         cancel: fn -> :ok end,
         model: model,
         context: Context.new(messages)
       }}
    end
  end

  # The model's replies: one tool round asking for a read and an effect, then
  # an answer once both results are in.
  defp replies(second_round_text \\ "SYNTHETIC: booked for 10:00.") do
    [
      {:tool_round, "SYNTHETIC: check the hours, then book.", "Let me check and book.",
       [
         {"toolu_hours_1", "clinic_hours", @hours_args},
         {"toolu_book_1", "book_appointment", @book_args}
       ]},
      {:text, second_round_text}
    ]
  end

  defp script!(replies) do
    start_supervised!(
      {Agent, fn -> %{replies: replies, requests: []} end},
      id: make_ref()
    )
  end

  defp requests(script), do: Agent.get(script, & &1.requests)

  defp tool(name, description, properties) do
    ReqLLM.Tool.new!(
      name: name,
      description: description,
      parameter_schema: %{
        "type" => "object",
        "properties" => properties,
        "required" => Map.keys(properties),
        "additionalProperties" => false
      },
      # Never used: every test supplies its own callback beside the tool.
      callback: fn _args -> raise "the definition's own callback must never run" end
    )
  end

  defp hours_tool, do: tool("clinic_hours", "Opening hours", %{"day" => %{"type" => "string"}})

  defp book_tool do
    tool("book_appointment", "Books an appointment", %{
      "patient" => %{"type" => "string"},
      "slot" => %{"type" => "string"}
    })
  end

  # An in-loop read: no effect, runs in the loop on every pass.
  defp hours_callback, do: fn @hours_args, _ctx -> {:ok, @hours_result} end

  defp loop_opts(script, extra_tools, approve) do
    [
      model: "openai:gpt-4o-mini",
      req_llm: FakeModel,
      req_llm_opts: [spike_script: script],
      system_prompt: fn _opts -> @system end,
      tools: false,
      extra_tools: extra_tools,
      approve_tool_call: approve,
      max_iterations: 3
    ]
  end

  # The governed approval rule: reads run in the loop, everything else waits.
  defp ask_for_effects do
    fn
      %{name: "clinic_hours"}, _ctx -> :ok
      _call, _ctx -> :ask
    end
  end

  # Runs a stream to the end and returns the `Result` and the messages it
  # emitted, as a job storing turns would see them.
  defp drive(messages, opts) do
    events = messages |> ToolLoop.stream(opts) |> Enum.to_list()
    assert [] == for({:error, reason} <- events, do: reason)
    {:done, result} = List.last(events)
    {result, for({:message, message} <- events, do: message)}
  end

  # What a job stores: Transcript parts, through JSON as a jsonb column would.
  defp store(messages),
    do: messages |> Transcript.to_parts() |> Jason.encode!() |> Jason.decode!()

  # The first job: the loop runs the read, stops for the effect, and the job
  # stores every emitted message.
  defp first_job do
    script = script!(replies())
    effect = fn _args, _ctx -> flunk("an effect ran inside the loop") end

    {result, emitted} =
      drive(
        [Context.user(@user)],
        loop_opts(
          script,
          [{hours_tool(), hours_callback()}, {book_tool(), effect}],
          ask_for_effects()
        )
      )

    assert result.status == :awaiting_approval
    assert [%{id: "toolu_book_1", name: "book_appointment"}] = result.pending_approvals
    assert length(requests(script)) == 1

    {script, store(emitted)}
  end

  # The baseline: the same conversation with the effect run in the loop.
  defp in_loop_baseline do
    script = script!(replies())
    book = fn @book_args, _ctx -> {:ok, @book_result} end

    {result, _emitted} =
      drive(
        [Context.user(@user)],
        loop_opts(script, [{hours_tool(), hours_callback()}, {book_tool(), book}], fn _, _ ->
          :ok
        end)
      )

    assert result.status == :complete
    [_first, second] = requests(script)
    second
  end

  # Recorded-result tools. The callback cannot see the call id (U1), so each
  # tool hands out its recorded results in pending-call order.
  defp recorded_result_tools(messages, recorded) do
    queues =
      messages
      |> ToolLoop.pending_tool_calls()
      |> Enum.group_by(& &1.name, &Map.fetch!(recorded, &1.id))

    queue = start_supervised!({Agent, fn -> queues end}, id: make_ref())

    callback = fn name ->
      fn _args, _ctx ->
        Agent.get_and_update(queue, fn queues ->
          [next | rest] = Map.fetch!(queues, name)
          {next, Map.put(queues, name, rest)}
        end)
      end
    end

    [{hours_tool(), hours_callback()}, {book_tool(), callback.("book_appointment")}]
  end

  defp wire(request) do
    context = Context.new(request.messages)

    %{
      openai: ReqLLM.Provider.Defaults.encode_context_to_openai_format(context, "gpt-4o-mini"),
      anthropic: AnthropicContext.encode_request(context, %{model: "claude-synthetic"})
    }
  end

  defp rebuilt(stored), do: [Context.user(@user) | Transcript.from_parts(stored)]

  test "resume/3 with recorded-result tools sends the request the in-loop run sends" do
    baseline = in_loop_baseline()
    {_first, stored} = first_job()

    # The effect runs outside the loop (an invocation) and its result is recorded.
    recorded = %{"toolu_book_1" => {:ok, @book_result}}

    # The next job: a fresh script whose first reply is the model's answer.
    script = script!(tl(replies()))
    messages = rebuilt(stored)

    assert [%{id: "toolu_book_1"}] = ToolLoop.pending_tool_calls(messages)

    {:ok, result} =
      ToolLoop.resume(
        messages,
        %{"toolu_book_1" => :approve},
        loop_opts(script, recorded_result_tools(messages, recorded), ask_for_effects())
      )

    assert result.status == :complete
    assert result.final_text == "SYNTHETIC: booked for 10:00."
    [resumed] = requests(script)

    assert resumed.messages == baseline.messages

    assert Transcript.fingerprint(@system, resumed.tools) ==
             Transcript.fingerprint(@system, baseline.tools)

    assert wire(resumed) == wire(baseline)
  end

  test "the wire bodies pair every tool call with its result and keep the signature" do
    {_first, stored} = first_job()
    script = script!(tl(replies()))
    messages = rebuilt(stored)
    recorded = %{"toolu_book_1" => {:ok, @book_result}}

    {:ok, _result} =
      ToolLoop.resume(
        messages,
        %{"toolu_book_1" => :approve},
        loop_opts(script, recorded_result_tools(messages, recorded), ask_for_effects())
      )

    %{openai: openai, anthropic: anthropic} = script |> requests() |> hd() |> wire()

    assert [
             %{role: "system"},
             %{role: "user"},
             %{role: "assistant", tool_calls: [%{id: "toolu_hours_1"}, %{id: "toolu_book_1"}]},
             %{role: "tool", tool_call_id: "toolu_hours_1", content: hours},
             %{role: "tool", tool_call_id: "toolu_book_1", content: book}
           ] = openai.messages

    assert inspect(hours) =~ "08:00"
    assert inspect(book) =~ "apt-synthetic-1"

    assert [
             %{role: "user"},
             %{role: "assistant", content: blocks},
             %{role: "user", content: results}
           ] =
             anthropic.messages

    assert [%{type: "thinking", signature: @signature} | _] = blocks

    assert ["toolu_hours_1", "toolu_book_1"] ==
             for(%{type: "tool_use", id: id} <- blocks, do: id)

    assert ["toolu_hours_1", "toolu_book_1"] ==
             for(%{type: "tool_result", tool_use_id: id} <- results, do: id)
  end

  test "host-appended tool results and run/2 send the same request" do
    baseline = in_loop_baseline()
    {_first, stored} = first_job()
    script = script!(tl(replies()))
    messages = rebuilt(stored)

    appended =
      messages ++
        for %{id: id} <- ToolLoop.pending_tool_calls(messages) do
          Context.tool_result(id, Map.fetch!(%{"toolu_book_1" => @book_result}, id))
        end

    assert ToolLoop.pending_tool_calls(appended) == []

    # No callback can run: an empty pending round goes straight to the model.
    never = fn _args, _ctx -> flunk("no tool may run on this path") end

    {result, emitted} =
      drive(
        appended,
        loop_opts(script, [{hours_tool(), never}, {book_tool(), never}], ask_for_effects())
      )

    assert result.status == :complete
    [request] = requests(script)
    assert request.messages == baseline.messages
    assert wire(request) == wire(baseline)

    # Only the model's answer is emitted; the job records the results it added.
    assert [%ReqLLM.Message{role: :assistant}] = emitted
  end

  test "a recorded failure and a refused approval reach the model as tool results" do
    {_first, stored} = first_job()
    messages = rebuilt(stored)

    failed = ~s({"error":"slot no longer free"})
    script = script!(tl(replies("SYNTHETIC: that slot is gone.")))

    {:ok, _} =
      ToolLoop.resume(
        messages,
        %{"toolu_book_1" => :approve},
        loop_opts(
          script,
          recorded_result_tools(messages, %{"toolu_book_1" => {:error, failed}}),
          ask_for_effects()
        )
      )

    [request] = requests(script)

    assert %{role: "tool", tool_call_id: "toolu_book_1", content: content} =
             request |> wire() |> Map.fetch!(:openai) |> Map.fetch!(:messages) |> List.last()

    assert inspect(content) =~ "slot no longer free"

    # A refused approval needs no tool: the decision itself becomes the result.
    script = script!(tl(replies("SYNTHETIC: not booked.")))
    never = fn _args, _ctx -> flunk("a refused call must not run") end

    {:ok, result} =
      ToolLoop.resume(
        messages,
        %{"toolu_book_1" => {:deny, "the reviewer refused"}},
        loop_opts(script, [{hours_tool(), never}, {book_tool(), never}], ask_for_effects())
      )

    assert result.status == :complete
    [request] = requests(script)

    assert %{role: "tool", tool_call_id: "toolu_book_1", content: content} =
             request |> wire() |> Map.fetch!(:openai) |> Map.fetch!(:messages) |> List.last()

    assert inspect(content) =~ "the reviewer refused"
  end

  test "an unresolved call keeps the loop waiting and makes no model request" do
    {_first, stored} = first_job()
    script = script!(tl(replies()))
    messages = rebuilt(stored)

    # No decision and no recorded result yet: the rule asks again.
    {:ok, result} =
      ToolLoop.run(
        messages,
        loop_opts(
          script,
          [{hours_tool(), hours_callback()}, {book_tool(), hours_callback()}],
          ask_for_effects()
        )
      )

    assert result.status == :awaiting_approval
    assert [%{id: "toolu_book_1"}] = result.pending_approvals
    assert requests(script) == []
  end
end
