defmodule AshBrowserTests.Fake.DSN do
  @moduledoc """
  A fake Sentry-compatible ingest endpoint: receives envelopes and parses out the
  events they hold, so a test can assert what reached error tracking.

      dsn_fake = start_supervised!(AshBrowserTests.Fake.DSN)
      Application.put_env(:sentry, :dsn, Fake.DSN.dsn(dsn_fake))

      assert [event] = Fake.DSN.events(dsn_fake)
      assert event.trace_id == span.trace_id
      assert event.exception_type == "RuntimeError"
  """

  alias AshBrowserTests.Fake

  @doc "A child spec for `start_supervised!/1`."
  def child_spec(opts) do
    %{id: {__MODULE__, make_ref()}, start: {__MODULE__, :start_link, [opts]}, restart: :temporary}
  end

  @doc "Starts the fake."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    Fake.start_link(Keyword.put(opts, :handler, &answer/2))
  end

  @doc "A DSN pointing at the fake."
  @spec dsn(GenServer.server(), pos_integer()) :: String.t()
  def dsn(fake, project \\ 1) do
    "http://public@127.0.0.1:#{Fake.port(fake)}/#{project}"
  end

  @doc "Every event in every envelope received, oldest first."
  @spec events(GenServer.server()) :: [map()]
  def events(fake) do
    fake
    |> Fake.requests()
    |> Enum.filter(&String.ends_with?(&1.path, "/envelope/"))
    |> Enum.flat_map(&parse_envelope(&1.body))
  end

  @doc """
  Parses a raw envelope into its `event` items, each normalized to a map with
  `:event_id`, `:trace_id`, `:tags`, `:exception_type`, `:exception_value`, `:level`
  and `:raw`.
  """
  @spec parse_envelope(binary()) :: [map()]
  def parse_envelope(body) do
    body
    |> String.split("\n", trim: true)
    |> Enum.map(&decode_line/1)
    |> items()
    |> Enum.filter(fn {header, _payload} -> header["type"] == "event" end)
    |> Enum.map(fn {_header, payload} -> normalize(payload) end)
  end

  defp decode_line(line) do
    case Jason.decode(line) do
      {:ok, value} -> value
      {:error, _reason} -> %{}
    end
  end

  # The first line is the envelope header, then alternating item header and payload.
  defp items([_envelope_header | rest]), do: pairs(rest)
  defp items([]), do: []

  defp pairs([%{"type" => _} = header, payload | rest]), do: [{header, payload} | pairs(rest)]
  defp pairs([_unknown | rest]), do: pairs(rest)
  defp pairs([]), do: []

  defp normalize(event) do
    exception = event |> get_in(["exception", "values"]) |> List.wrap() |> List.first() || %{}
    tags = tags(event["tags"])

    %{
      event_id: event["event_id"],
      trace_id: tags["trace_id"] || get_in(event, ["contexts", "trace", "trace_id"]),
      tags: tags,
      exception_type: exception["type"],
      exception_value: exception["value"],
      level: event["level"],
      raw: event
    }
  end

  defp tags(tags) when is_map(tags), do: tags
  defp tags(tags) when is_list(tags), do: Map.new(tags, fn [key, value] -> {key, value} end)
  defp tags(_tags), do: %{}

  defp answer(%{path: path}, data) do
    if String.ends_with?(path, "/envelope/") do
      {{200, [{"content-type", "application/json"}], ~s({"id":"fake"})}, data}
    else
      {{404, [], ""}, data}
    end
  end
end
