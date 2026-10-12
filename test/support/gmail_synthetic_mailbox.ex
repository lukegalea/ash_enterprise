defmodule AshEnterprise.Test.GmailSyntheticMailbox do
  @moduledoc """
  A synthetic Gmail mailbox behind the Nango proxy, for tests only.

  Answers the four Gmail API v1 calls the Gmail vertical makes
  (`users.getProfile`, `users.messages.list`, `users.messages.get`,
  `users.history.list`) as a `Req.Test` plug, with response shapes taken from
  Google's public API reference. Every message, address and subject is
  invented; nothing here was ever fetched from a real mailbox.

  State lives in an Agent so a test can add mail, expire the history window
  or inject a rate limit between sync steps:

      {:ok, box} = GmailSyntheticMailbox.start_link()
      GmailSyntheticMailbox.add_message(box, subject: "SYNTHETIC-SUBJECT-1")
      Req.Test.stub(Proxy, GmailSyntheticMailbox.plug(box))
  """

  use Agent

  @proxy_prefix "/proxy/gmail/v1/users/me"
  @owner "operator@mailbox.synthetic.test"

  @doc "The synthetic mailbox owner's address."
  def owner, do: @owner

  def start_link(opts \\ []) do
    Agent.start_link(fn ->
      %{
        messages: %{},
        order: [],
        history: [],
        history_id: Keyword.get(opts, :history_id, 1000),
        min_history_id: 0,
        rate_limit_history: nil,
        requests: []
      }
    end)
  end

  @doc """
  Add one message (a history record of type messageAdded). Options:
  `:id`, `:thread_id`, `:subject`, `:from`, `:to`, `:cc`, `:body`,
  `:labels` (default `["INBOX"]`), `:internal_date` (epoch ms).
  Returns the message id.
  """
  def add_message(box, opts \\ []) do
    Agent.get_and_update(box, fn state ->
      history_id = state.history_id + 1
      n = map_size(state.messages) + 1
      id = Keyword.get(opts, :id, "18f0synth" <> String.pad_leading(Integer.to_string(n), 4, "0"))
      message = build_message(id, history_id, n, opts)

      record = %{
        "id" => Integer.to_string(history_id),
        "messages" => [%{"id" => id, "threadId" => message["threadId"]}],
        "messagesAdded" => [
          %{
            "message" => %{
              "id" => id,
              "threadId" => message["threadId"],
              "labelIds" => message["labelIds"]
            }
          }
        ]
      }

      state = %{
        state
        | messages: Map.put(state.messages, id, message),
          order: [id | state.order],
          history: state.history ++ [record],
          history_id: history_id
      }

      {id, state}
    end)
  end

  @doc "Delete a message (it then 404s on messages.get)."
  def delete_message(box, id) do
    Agent.update(box, fn state -> %{state | messages: Map.delete(state.messages, id)} end)
  end

  @doc """
  Gmail no longer retains history older than the current historyId: any
  `startHistoryId` below it answers 404.
  """
  def expire_history(box) do
    Agent.update(box, fn state -> %{state | min_history_id: state.history_id} end)
  end

  @doc "The next history.list answers 429 with this Retry-After (seconds)."
  def rate_limit_history(box, seconds) do
    Agent.update(box, fn state -> %{state | rate_limit_history: seconds} end)
  end

  @doc "Every request path seen, oldest first, with its decoded query."
  def requests(box), do: box |> Agent.get(& &1.requests) |> Enum.reverse()

  @doc "One message as `users.messages.get` (format full) returns it."
  def message(box, id), do: Agent.get(box, &Map.fetch!(&1.messages, id))

  def history_id(box), do: Agent.get(box, &Integer.to_string(&1.history_id))

  @doc "The `Req.Test` plug answering as this mailbox."
  def plug(box) do
    fn conn ->
      query = conn.query_string |> URI.query_decoder() |> Enum.to_list()

      Agent.update(box, fn state ->
        %{state | requests: [{conn.request_path, query} | state.requests]}
      end)

      route(conn, conn.request_path, query, box)
    end
  end

  defp route(conn, @proxy_prefix <> "/profile", _query, box) do
    state = Agent.get(box, & &1)

    Req.Test.json(conn, %{
      "emailAddress" => @owner,
      "messagesTotal" => map_size(state.messages),
      "threadsTotal" => map_size(state.messages),
      "historyId" => Integer.to_string(state.history_id)
    })
  end

  defp route(conn, @proxy_prefix <> "/messages", query, box) do
    state = Agent.get(box, & &1)
    ids = Enum.filter(state.order, &Map.has_key?(state.messages, &1))
    {page, next} = paginate(ids, query)

    body =
      %{"resultSizeEstimate" => length(ids)}
      |> put_unless_empty(
        "messages",
        Enum.map(page, &%{"id" => &1, "threadId" => state.messages[&1]["threadId"]})
      )
      |> put_if("nextPageToken", next)

    Req.Test.json(conn, body)
  end

  defp route(conn, @proxy_prefix <> "/messages/" <> id, _query, box) do
    case Agent.get(box, &Map.get(&1.messages, URI.decode(id))) do
      nil -> conn |> Plug.Conn.put_status(404) |> Req.Test.json(google_error(404, "notFound"))
      message -> Req.Test.json(conn, message)
    end
  end

  defp route(conn, @proxy_prefix <> "/history", query, box) do
    state = Agent.get(box, & &1)
    start = query |> List.keyfind("startHistoryId", 0) |> elem(1) |> String.to_integer()

    cond do
      state.rate_limit_history ->
        Agent.update(box, &%{&1 | rate_limit_history: nil})

        conn
        |> Plug.Conn.put_resp_header("retry-after", Integer.to_string(state.rate_limit_history))
        |> Plug.Conn.put_status(429)
        |> Req.Test.json(google_error(429, "rateLimitExceeded"))

      start < state.min_history_id ->
        conn |> Plug.Conn.put_status(404) |> Req.Test.json(google_error(404, "notFound"))

      true ->
        records = Enum.filter(state.history, &(String.to_integer(&1["id"]) > start))
        {page, next} = paginate(records, query)

        body =
          %{"historyId" => Integer.to_string(state.history_id)}
          |> put_unless_empty("history", page)
          |> put_if("nextPageToken", next)

        Req.Test.json(conn, body)
    end
  end

  defp paginate(items, query) do
    size =
      query
      |> List.keyfind("maxResults", 0, {"maxResults", "100"})
      |> elem(1)
      |> String.to_integer()

    offset =
      case List.keyfind(query, "pageToken", 0) do
        {"pageToken", "synthetic-page-" <> n} -> String.to_integer(n)
        _ -> 0
      end

    page = items |> Enum.drop(offset) |> Enum.take(size)
    next = if offset + size < length(items), do: "synthetic-page-#{offset + size}"
    {page, next}
  end

  defp build_message(id, history_id, n, opts) do
    subject = Keyword.get(opts, :subject, "SYNTHETIC-SUBJECT-#{n}")

    from =
      Keyword.get(opts, :from, "\"Synthetic Sender #{n}\" <sender#{n}@example.synthetic.test>")

    to = Keyword.get(opts, :to, @owner)
    body = Keyword.get(opts, :body, "SYNTHETIC-BODY-#{n}")

    headers =
      [
        %{"name" => "From", "value" => from},
        %{"name" => "To", "value" => to},
        %{"name" => "Subject", "value" => subject},
        %{"name" => "Date", "value" => "Mon, 12 Oct 2026 09:00:00 +0000"}
      ] ++ cc_header(Keyword.get(opts, :cc))

    %{
      "id" => id,
      "threadId" => Keyword.get(opts, :thread_id, "thread-" <> id),
      "labelIds" => Keyword.get(opts, :labels, ["INBOX"]),
      "snippet" => "SYNTHETIC-SNIPPET-#{n}",
      "historyId" => Integer.to_string(history_id),
      "internalDate" =>
        opts |> Keyword.get(:internal_date, 1_791_795_600_000 + n * 60_000) |> Integer.to_string(),
      "sizeEstimate" => 1024,
      "payload" => %{
        "partId" => "",
        "mimeType" => "multipart/alternative",
        "headers" => headers,
        "body" => %{"size" => 0},
        "parts" => [
          %{
            "partId" => "0",
            "mimeType" => "text/plain",
            "headers" => [%{"name" => "Content-Type", "value" => "text/plain; charset=UTF-8"}],
            "body" => %{
              "size" => byte_size(body),
              "data" => Base.url_encode64(body, padding: false)
            }
          },
          %{
            "partId" => "1",
            "mimeType" => "text/html",
            "headers" => [%{"name" => "Content-Type", "value" => "text/html; charset=UTF-8"}],
            "body" => %{
              "size" => byte_size(body) + 11,
              "data" => Base.url_encode64("<p>" <> body <> "</p>", padding: false)
            }
          }
        ]
      }
    }
  end

  defp cc_header(nil), do: []
  defp cc_header(cc), do: [%{"name" => "Cc", "value" => cc}]

  defp google_error(code, reason) do
    %{
      "error" => %{
        "code" => code,
        "message" => "synthetic error message",
        "errors" => [%{"domain" => "global", "reason" => reason, "message" => "synthetic"}]
      }
    }
  end

  defp put_if(map, _key, nil), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)

  defp put_unless_empty(map, _key, []), do: map
  defp put_unless_empty(map, key, value), do: Map.put(map, key, value)
end
