defmodule AshEnterprise.Showcase.RecordedModel do
  @moduledoc """
  The showcase's recorded model mode: an agent's model turns replayed from a recorded
  transcript, so a tour is the same every time and needs no model and no key
  (`AshEnterprise.Showcase`, `model_mode: :recorded`).

  It stands where ReqLLM stands, behind the guarded ReqLLM module
  (`AshEnterprise.AI.Models.GuardedReqLLM`, `downstream:`), and
  `AshEnterprise.Execution.AgentRuntime` routes an agent's runs to it. So a recorded turn
  goes through everything a live one does: the run's claim and budget hold, the flow
  guard, the `AshEnterprise.AI.ModelCall` record (profile `"recorded"`, model
  `recorded:<agent key>`), the tool loop, the journal, and every tool call's invocation.
  Only the model's words come from a file.

  ## The transcripts

  One JSON file per agent, `priv/showcase/recorded/<agent key>.json`, read when this
  module compiles:

      {"agent": "credentialing.licence_reader",
       "cases": {"DEMO-PT-0001": [turn, turn, ...]}}

  A case is chosen by the run's input, which names it (the first case whose key the
  input contains). A turn is `{"usage": {"input_tokens": n, "output_tokens": n},
  "parts": [...]}`, its parts in `AshAi.Transcript`'s shape (`"text"`, and
  `"tool_call"` with `"id"`, `"name"` and `"arguments"`).

  Which turn answers is decided by the conversation, never by a counter: the n-th call
  of a run, counting the model's turns already in its journal, gets the n-th turn. A
  call made again after its first attempt failed (the model timed out) is answered with
  the same turn, as a model would be asked the same question again. A conversation with
  no recorded turn left, or no case, is an error: the call fails and nothing is invented.

  The recorded turns are synthetic.
  """

  alias ReqLLM.StreamChunk
  alias ReqLLM.StreamResponse
  alias ReqLLM.StreamResponse.MetadataHandle

  defmodule NoRecordedTurn do
    @moduledoc "Raised into the call's error when a conversation has no recorded turn left."
    defexception [:agent, :turn]

    @impl true
    def message(%{agent: agent, turn: turn}),
      do: "no recorded turn #{turn} for #{agent} in this conversation"
  end

  # The transcripts are read when this module compiles: they are fixtures shipped with
  # the code, and a recorded agent is a code-declared one.
  @dir Path.expand("../../../priv/showcase/recorded", __DIR__)
  @files @dir |> Path.join("*.json") |> Path.wildcard() |> Enum.sort()

  for file <- @files, do: @external_resource(file)

  @transcripts Map.new(
                 @files,
                 &{Path.basename(&1, ".json"), &1 |> File.read!() |> Jason.decode!()}
               )

  @doc false
  # A transcript added or removed recompiles this module.
  def __mix_recompile__?,
    do: @dir |> Path.join("*.json") |> Path.wildcard() |> Enum.sort() != @files

  @doc "Whether the agent keyed `key` has recorded transcripts."
  @spec recorded?(String.t()) :: boolean()
  def recorded?(key) when is_binary(key), do: Map.has_key?(@transcripts, key)

  @doc "The case names the agent keyed `key` has recorded, in order."
  @spec cases(String.t()) :: [String.t()]
  def cases(key) do
    case transcript(key) do
      {:ok, %{"cases" => cases}} -> cases |> Map.keys() |> Enum.sort()
      _none -> []
    end
  end

  @doc "The spec a recorded agent's runs call: `AshEnterprise.AI.Models.recorded_spec/1`."
  @spec spec(String.t()) :: LLMDB.Model.t()
  def spec(key), do: AshEnterprise.AI.Models.recorded_spec(key)

  @doc """
  As `ReqLLM.stream_text/3`: the recorded turn this conversation is at, as a stream of
  the chunks a model would send.
  """
  def stream_text(model, context, _opts) do
    key = agent(model)
    messages = messages(context)
    turn = Enum.count(messages, &(&1.role == :assistant))

    with {:ok, %{"cases" => cases}} <- transcript(key),
         {:ok, turns} <- case_for(cases, messages),
         %{} = recorded <- Enum.at(turns, turn) do
      response(recorded, model, context)
    else
      _none -> {:error, %NoRecordedTurn{agent: key, turn: turn + 1}}
    end
  end

  defp response(%{"parts" => parts} = recorded, model, context) do
    chunks = chunks(parts)
    finish = if Enum.any?(parts, &(&1["type"] == "tool_call")), do: :tool_calls, else: :stop
    usage = usage(recorded["usage"])

    {:ok, handle} =
      MetadataHandle.start_link(fn -> %{usage: usage, finish_reason: finish} end)

    {:ok,
     %StreamResponse{
       stream: chunks,
       metadata_handle: handle,
       cancel: fn -> :ok end,
       model: model,
       context: context
     }}
  end

  defp chunks(parts) do
    parts
    |> Enum.filter(&(&1["type"] in ["text", "tool_call"]))
    |> Enum.with_index()
    |> Enum.map(fn
      {%{"type" => "text", "text" => text}, _index} ->
        StreamChunk.text(text)

      {%{"type" => "tool_call", "id" => id, "name" => name} = call, index} ->
        StreamChunk.tool_call(name, arguments(call["arguments"]), %{id: id, index: index})
    end)
  end

  defp arguments(arguments) when is_map(arguments), do: arguments
  defp arguments(arguments) when is_binary(arguments), do: Jason.decode!(arguments)
  defp arguments(nil), do: %{}

  defp usage(%{"input_tokens" => input, "output_tokens" => output}),
    do: %{input_tokens: input, output_tokens: output}

  defp usage(_none), do: %{input_tokens: 0, output_tokens: 0}

  # The first case the run's input names.
  defp case_for(cases, messages) do
    input = messages |> Enum.find(&(&1.role == :user)) |> text()

    case Enum.find(Enum.sort(cases), fn {name, _turns} -> String.contains?(input, name) end) do
      {_name, turns} -> {:ok, turns}
      nil -> :error
    end
  end

  defp text(nil), do: ""

  defp text(%{content: content}) when is_binary(content), do: content

  defp text(%{content: parts}) when is_list(parts),
    do: Enum.map_join(parts, " ", &(Map.get(&1, :text) || ""))

  defp text(_message), do: ""

  defp agent(%{id: "recorded:" <> key}), do: key
  defp agent(_model), do: ""

  defp messages(%ReqLLM.Context{messages: messages}), do: messages
  defp messages(messages) when is_list(messages), do: messages
  defp messages(_context), do: []

  defp transcript(key), do: Map.fetch(@transcripts, key)
end
