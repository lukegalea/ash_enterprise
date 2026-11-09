defmodule AshBrowserTests.SandboxHook do
  @moduledoc """
  Gives a LiveView database access and its test key from telemetry, so a host needs
  no `on_mount` in its router.

  The handlers run inside the LiveView's own process, at `mount` and `handle_event`
  start, and on each HTTP request at `[:phoenix, :endpoint, :start]`. They read the
  sandbox metadata from the browser's user agent, call
  `Phoenix.Ecto.SQL.Sandbox.allow/2` and set the test key.

  The handlers also stamp the key on the span already open when they run, so the
  order of `attach/1` relative to the host's telemetry setup does not matter: attached
  before it, the span processor stamps the span at its start, and attached after it
  (the natural order in `test_helper.exs`) the handler does.

  ## It cannot take the node down

  `:telemetry` permanently detaches a handler that raises, for every test on the
  node. Everything here is therefore guarded: an unknown or absent user agent, a
  socket with no connect info, a malformed header or a stopped owner all do nothing.

  The connect info of a LiveView is not available after `mount`, so the metadata
  decoded there is remembered in the process for later events.
  """

  alias AshBrowserTests.TestKey

  @handler_id {__MODULE__, :attached}

  @events [
    [:phoenix, :live_view, :mount, :start],
    [:phoenix, :live_view, :handle_event, :start],
    [:phoenix, :live_component, :handle_event, :start],
    [:phoenix, :endpoint, :start]
  ]

  @metadata_key {__MODULE__, :metadata}

  @doc """
  Attaches the handlers. Idempotent. Options: `:sandbox`, default
  `Ecto.Adapters.SQL.Sandbox`.
  """
  @spec attach(keyword()) :: :ok
  def attach(opts \\ []) do
    config = %{sandbox: Keyword.get(opts, :sandbox, Ecto.Adapters.SQL.Sandbox)}

    case :telemetry.attach_many(@handler_id, @events, &__MODULE__.handle_event/4, config) do
      :ok -> :ok
      {:error, :already_exists} -> :ok
    end
  end

  @doc "Detaches the handlers."
  @spec detach() :: :ok
  def detach do
    _result = :telemetry.detach(@handler_id)
    :ok
  end

  @doc false
  def handle_event(event, _measurements, metadata, config) do
    handle(event, metadata, config)
    :ok
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp handle([:phoenix, :endpoint, :start], %{conn: conn}, _config) do
    conn
    |> Plug.Conn.get_req_header("user-agent")
    |> List.first()
    |> TestKey.decode()
    |> stamp()
  end

  defp handle(_live_event, %{socket: socket}, config) do
    case metadata(socket) do
      nil ->
        :ok

      metadata ->
        Process.put(@metadata_key, metadata)
        if connected?(socket), do: Phoenix.Ecto.SQL.Sandbox.allow(metadata, config.sandbox)
        stamp(metadata)
    end
  end

  defp handle(_event, _metadata, _config), do: :ok

  defp metadata(socket) do
    case TestKey.decode(user_agent(socket)) do
      nil -> Process.get(@metadata_key)
      metadata -> metadata
    end
  end

  # The socket of a live component has no connect info at all, and that of a
  # LiveView has none after mount, so a raise here is an ordinary outcome.
  defp user_agent(socket) do
    Phoenix.LiveView.get_connect_info(socket, :user_agent)
  rescue
    _error -> nil
  end

  defp connected?(socket) do
    Phoenix.LiveView.connected?(socket)
  rescue
    _error -> false
  end

  defp stamp(nil), do: :ok

  defp stamp(%{owner: owner}) do
    key = TestKey.from_owner(owner)
    TestKey.put(key)
    OpenTelemetry.Span.set_attribute(:otel_tracer.current_span_ctx(), TestKey.attribute(), key)
  end
end
