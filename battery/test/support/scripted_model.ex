defmodule Battery.ScriptedModel do
  @moduledoc """
  Stands in for ReqLLM as a step's `req_llm:` module (`Battery.Execution.Runtime`),
  ported from ash_agent's own test host. Each `stream_text/3` call takes the
  next reply of the script and records the request:

    * `{:tools, [{id, name, arguments}]}`: the model calls those tools;
    * `{:text, text}`: the model answers;
    * `{:error, reason}`: the call fails to open;
    * `{:die, reason}`: the calling process exits with `reason`, as a worker killed
      during its model call.

  The script and the requests live in a named Agent, so a step in another process reads
  the same one. Synthetic text only; nothing reaches a network.
  """

  use Agent

  @doc "Starts the script `replies`, replacing any earlier one."
  def script!(replies) do
    case Process.whereis(__MODULE__) do
      nil -> {:ok, _} = Agent.start(fn -> %{replies: replies, requests: []} end, name: __MODULE__)
      _pid -> Agent.update(__MODULE__, fn _ -> %{replies: replies, requests: []} end)
    end

    ExUnit.Callbacks.on_exit(fn ->
      if pid = Process.whereis(__MODULE__), do: Agent.stop(pid)
    end)

    :ok
  end

  @doc "The requests made so far, oldest first: `%{messages, tools, caller}`."
  def requests, do: Agent.get(__MODULE__, & &1.requests)

  def stream_text(model, messages, opts) do
    request = %{
      messages: messages,
      tools: opts |> Keyword.get(:tools, []) |> Enum.map(& &1.name),
      caller: opts[:caller]
    }

    reply =
      Agent.get_and_update(__MODULE__, fn
        %{replies: [reply | rest]} = state ->
          {reply, %{state | replies: rest, requests: state.requests ++ [request]}}

        %{replies: []} = state ->
          {{:text, "SYNTHETIC: the script ran out"},
           %{state | requests: state.requests ++ [request]}}
      end)

    respond(reply, model, messages)
  end

  defp respond({:error, reason}, _model, _messages), do: {:error, reason}
  defp respond({:die, reason}, _model, _messages), do: exit(reason)

  defp respond({:tools, calls}, model, messages) do
    calls
    |> Enum.with_index()
    |> Enum.map(fn {{id, name, arguments}, i} ->
      ReqLLM.StreamChunk.tool_call(name, arguments, %{id: id, index: i})
    end)
    |> response(:tool_calls, model, messages)
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
       context: ReqLLM.Context.new(messages)
     }}
  end
end
