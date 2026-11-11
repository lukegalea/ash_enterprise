defmodule AshBrowserTests.Backend.SigNoz do
  @moduledoc """
  Reads spans back out of a real SigNoz through `POST /api/v5/query_range`.

      config :ash_browser_tests, AshBrowserTests.Backend.SigNoz,
        url: "http://127.0.0.1:8080",
        api_key: System.get_env("SIGNOZ_API_KEY")

  A key is a test key (`ash.test_key = '…'`) or `{:trace_id, hex}`
  (`trace_id = '…'`).

  ## Exceptions

  SigNoz does not accept `exception.type` or `events.name` as a filter on the traces
  signal. An exception is found with `hasError = true` and read from the row's
  `events`, which is what `only_errors: true` selects.

  ## Options

  `:url`, `:api_key` and `:lookback_ms` (default one hour) override the configured
  values; `:only_errors` adds the `hasError` filter; `:req_options` is merged into
  the `Req` request.
  """

  @behaviour AshBrowserTests.Backend

  alias AshBrowserTests.Span

  @default_lookback_ms :timer.hours(1)

  @kinds %{
    "Client" => :client,
    "Server" => :server,
    "Producer" => :producer,
    "Consumer" => :consumer,
    "Internal" => :internal
  }

  @impl true
  def spans_for(key, opts) do
    config = Application.get_env(:ash_browser_tests, __MODULE__, []) |> Keyword.merge(opts)
    now = System.system_time(:millisecond)
    url = Keyword.fetch!(config, :url)

    body = %{
      "schemaVersion" => "v1",
      "start" => now - Keyword.get(config, :lookback_ms, @default_lookback_ms),
      "end" => now,
      "requestType" => "raw",
      "compositeQuery" => %{
        "queries" => [
          %{
            "type" => "builder_query",
            "spec" => %{
              "name" => "A",
              "signal" => "traces",
              "disabled" => false,
              "limit" => 1000,
              "order" => [%{"key" => %{"name" => "timestamp"}, "direction" => "asc"}],
              "filter" => %{"expression" => expression(key, config)}
            }
          }
        ]
      }
    }

    request =
      Req.new(
        method: :post,
        url: url <> "/api/v5/query_range",
        json: body,
        headers: [{"SIGNOZ-API-KEY", Keyword.get(config, :api_key, "")}],
        retry: false
      )
      |> Req.merge(Keyword.get(config, :req_options, []))

    case Req.request(request) do
      {:ok, %{status: 200, body: body}} -> {:ok, spans(body)}
      {:ok, %{status: status, body: body}} -> {:error, {:http_status, status, body}}
      {:error, exception} -> {:error, exception}
    end
  end

  @doc "The filter expression for `key`."
  @spec expression(AshBrowserTests.Backend.key(), keyword()) :: String.t()
  def expression(key, opts \\ []) do
    selector =
      case key do
        {:trace_id, hex} -> "trace_id = '#{quoted(hex)}'"
        {:correlation_id, id} -> "ash.correlation_id = '#{quoted(id)}'"
        key when is_binary(key) -> "ash.test_key = '#{quoted(key)}'"
      end

    if Keyword.get(opts, :only_errors, false) do
      selector <> " AND hasError = true"
    else
      selector
    end
  end

  defp quoted(value), do: String.replace(value, "'", "\\'")

  defp spans(%{"data" => %{"data" => %{"results" => results}}}) when is_list(results) do
    results
    |> Enum.flat_map(fn result -> result["rows"] || [] end)
    |> Enum.map(&normalize_row/1)
    |> Enum.uniq_by(& &1.span_id)
  end

  defp spans(_unexpected), do: []

  @doc "One `query_range` row as a span."
  @spec normalize_row(map()) :: Span.t()
  def normalize_row(%{"data" => row}) do
    %Span{
      trace_id: row["trace_id"],
      span_id: row["span_id"],
      parent_span_id: blank_to_nil(row["parent_span_id"]),
      name: row["name"],
      kind: Map.get(@kinds, row["kind_string"], :internal),
      status: status(row),
      status_message: blank_to_nil(row["status_message"]),
      attributes: row["attributes"] || %{},
      events: Enum.map(decoded(row["events"]), &event/1),
      links: Enum.map(decoded(row["links"]), &link/1),
      source: :signoz
    }
  end

  defp status(%{"has_error" => true}), do: :error

  defp status(%{"status_code_string" => code}) when is_binary(code) do
    case String.downcase(code) do
      "error" -> :error
      "ok" -> :ok
      _other -> :unset
    end
  end

  defp status(_row), do: :unset

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  # `events` and `links` come back either as lists or as lists of JSON strings.
  defp decoded(nil), do: []

  defp decoded(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, list} when is_list(list) -> list
      _other -> []
    end
  end

  defp decoded(value) when is_list(value), do: Enum.flat_map(value, &decoded_item/1)
  defp decoded(_value), do: []

  defp decoded_item(item) when is_map(item), do: [item]

  defp decoded_item(item) when is_binary(item) do
    case Jason.decode(item) do
      {:ok, map} when is_map(map) -> [map]
      _other -> []
    end
  end

  defp decoded_item(_item), do: []

  defp event(event) do
    %{name: event["name"] || "", attributes: event["attributes"] || %{}}
  end

  defp link(link) do
    %{trace_id: link["traceId"] || link["trace_id"], span_id: link["spanId"] || link["span_id"]}
  end
end
