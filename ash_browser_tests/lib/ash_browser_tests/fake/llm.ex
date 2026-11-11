defmodule AshBrowserTests.Fake.LLM do
  @moduledoc """
  A fake model provider. Speaks the OpenAI chat completions and embeddings paths and
  the Anthropic messages path, with scripted replies.

      llm = start_supervised!(AshBrowserTests.Fake.LLM)
      Fake.LLM.enqueue(llm, "Hello from the model")
      Application.put_env(:my_app, :llm_base_url, Fake.url(llm))

  Replies are taken in order; when the queue is empty the default (`:default_reply`,
  `"ok"`) is used. `"stream": true` in a request is answered as server-sent events.
  `Fake.requests/1` shows what was sent, including `traceparent`.
  """

  alias AshBrowserTests.Fake

  @doc "A child spec for `start_supervised!/1`."
  def child_spec(opts) do
    %{id: {__MODULE__, make_ref()}, start: {__MODULE__, :start_link, [opts]}, restart: :temporary}
  end

  @doc "Starts the fake. Options: `:default_reply` and `:name`."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    default = Keyword.get(opts, :default_reply, "ok")

    opts
    |> Keyword.delete(:default_reply)
    |> Keyword.merge(data: [], handler: &answer(&1, &2, default))
    |> Fake.start_link()
  end

  @doc "Queues the text of the next reply."
  @spec enqueue(GenServer.server(), String.t()) :: :ok
  def enqueue(fake, text) when is_binary(text) do
    Fake.update_data(fake, &(&1 ++ [text]))
  end

  defp answer(%{method: "POST", path: "/v1/chat/completions"} = request, replies, default) do
    {text, rest} = next(replies, default)

    if request.json && request.json["stream"] do
      {sse(openai_stream(text, request)), rest}
    else
      {json(%{
         "id" => "chatcmpl-fake",
         "object" => "chat.completion",
         "model" => model(request),
         "choices" => [
           %{
             "index" => 0,
             "finish_reason" => "stop",
             "message" => %{"role" => "assistant", "content" => text}
           }
         ],
         "usage" => usage()
       }), rest}
    end
  end

  defp answer(%{method: "POST", path: "/v1/embeddings"} = request, replies, _default) do
    input = List.wrap((request.json || %{})["input"])

    {json(%{
       "object" => "list",
       "model" => model(request),
       "data" =>
         input
         |> Enum.with_index()
         |> Enum.map(fn {_text, index} ->
           %{"object" => "embedding", "index" => index, "embedding" => [0.0, 0.0, 0.0]}
         end),
       "usage" => usage()
     }), replies}
  end

  defp answer(%{method: "POST", path: "/v1/messages"} = request, replies, default) do
    {text, rest} = next(replies, default)

    {json(%{
       "id" => "msg_fake",
       "type" => "message",
       "role" => "assistant",
       "model" => model(request),
       "stop_reason" => "end_turn",
       "content" => [%{"type" => "text", "text" => text}],
       "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
     }), rest}
  end

  defp answer(_request, replies, _default), do: {:no_answer, replies}

  defp next([text | rest], _default), do: {text, rest}
  defp next([], default), do: {default, []}

  defp model(request), do: (request.json || %{})["model"] || "fake"

  defp usage, do: %{"prompt_tokens" => 1, "completion_tokens" => 1, "total_tokens" => 2}

  defp json(body), do: {200, [{"content-type", "application/json"}], Jason.encode!(body)}

  defp sse(events) do
    body = Enum.map_join(events, "", &"data: #{&1}\n\n")
    {200, [{"content-type", "text/event-stream"}], body}
  end

  defp openai_stream(text, request) do
    chunk =
      Jason.encode!(%{
        "id" => "chatcmpl-fake",
        "object" => "chat.completion.chunk",
        "model" => model(request),
        "choices" => [%{"index" => 0, "delta" => %{"role" => "assistant", "content" => text}}]
      })

    [chunk, "[DONE]"]
  end
end
