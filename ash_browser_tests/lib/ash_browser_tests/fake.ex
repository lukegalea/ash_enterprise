defmodule AshBrowserTests.Fake do
  @moduledoc """
  A real HTTP server on the loopback interface that records what it receives.

  `Req.Test` stubs are keyed to the calling process, so they cannot see the processes
  a browser spawns: a LiveView, a request process, a Task. A fake is reached by URL,
  like the real service, and it records the propagated headers, so the test also
  proves the trace context left the process.

      fake = start_supervised!(AshBrowserTests.Fake)
      Fake.stub(fake, "POST", "/quotes", status: 201, json: %{"id" => 1})

      # the application calls Fake.url(fake) <> "/quotes" ...

      assert [request] = Fake.requests(fake)
      assert request.trace_id == span.trace_id

  Each fake listens on its own port, so one per test is safe under `async: true`.

  ## Responses

  `stub/4` adds a response for a method and path (`status:`, `json:` or `body:`, and
  `headers:`). The first matching stub answers; with no stub, a fake answers 200 with
  `{}`. A two-argument function given as `:handler` to `start_link/1` sees each
  `AshBrowserTests.Fake.Request` and the fake's data first, and answers
  `{{status, headers, body}, data}` or `{:no_answer, data}`.
  """

  use GenServer

  defmodule Request do
    @moduledoc "One received request."
    defstruct [:method, :path, :query, :headers, :body, :json, :traceparent, :trace_id, :at]

    @type t :: %__MODULE__{}
  end

  @doc false
  def child_spec(opts) do
    %{id: {__MODULE__, make_ref()}, start: {__MODULE__, :start_link, [opts]}, restart: :temporary}
  end

  @doc "Starts a fake. Options: `:name`, `:handler`, `:data` (initial handler data)."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @doc "The base URL, such as `http://127.0.0.1:45678`."
  @spec url(GenServer.server()) :: String.t()
  def url(fake), do: GenServer.call(fake, :url)

  @doc "The port the fake listens on."
  @spec port(GenServer.server()) :: :inet.port_number()
  def port(fake), do: GenServer.call(fake, :port)

  @doc "Every request received, oldest first."
  @spec requests(GenServer.server()) :: [Request.t()]
  def requests(fake), do: GenServer.call(fake, :requests)

  @doc "The requests whose path matches `path` exactly."
  @spec requests(GenServer.server(), String.t()) :: [Request.t()]
  def requests(fake, path), do: fake |> requests() |> Enum.filter(&(&1.path == path))

  @doc "Adds a stub for a method and path. Later stubs take precedence."
  @spec stub(GenServer.server(), String.t(), String.t(), keyword()) :: :ok
  def stub(fake, method, path, response) do
    GenServer.call(fake, {:stub, String.upcase(method), path, response})
  end

  @doc "Updates the data a `:handler` sees."
  @spec update_data(GenServer.server(), (term() -> term())) :: :ok
  def update_data(fake, fun), do: GenServer.call(fake, {:update_data, fun})

  @doc false
  def record(fake, %Request{} = request), do: GenServer.call(fake, {:record, request})

  # --- GenServer ----------------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)

    {:ok, server} =
      Bandit.start_link(
        plug: {__MODULE__.Router, self()},
        scheme: :http,
        ip: {127, 0, 0, 1},
        port: 0,
        startup_log: false
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(server)

    {:ok,
     %{
       port: port,
       server: server,
       requests: [],
       stubs: [],
       handler: opts[:handler],
       data: opts[:data]
     }}
  end

  @impl GenServer
  def handle_call(:url, _from, state), do: {:reply, "http://127.0.0.1:#{state.port}", state}
  def handle_call(:port, _from, state), do: {:reply, state.port, state}

  def handle_call(:requests, _from, state) do
    {:reply, Enum.reverse(state.requests), state}
  end

  def handle_call({:stub, method, path, response}, _from, state) do
    {:reply, :ok, %{state | stubs: [{method, path, response} | state.stubs]}}
  end

  def handle_call({:update_data, fun}, _from, state) do
    {:reply, :ok, %{state | data: fun.(state.data)}}
  end

  def handle_call({:record, request}, _from, state) do
    {reply, data} = respond(state, request)
    {:reply, reply, %{state | requests: [request | state.requests], data: data}}
  end

  @impl GenServer
  def handle_info({:EXIT, server, reason}, %{server: server} = state) do
    {:stop, reason, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp respond(%{handler: handler} = state, request) when is_function(handler, 2) do
    case handler.(request, state.data) do
      {{status, headers, body}, data} when is_integer(status) -> {{status, headers, body}, data}
      {:no_answer, data} -> {stubbed(state, request), data}
    end
  end

  defp respond(state, request), do: {stubbed(state, request), state.data}

  defp stubbed(state, request) do
    case Enum.find(state.stubs, fn {method, path, _} ->
           method == request.method and path == request.path
         end) do
      {_method, _path, response} -> response_tuple(response)
      nil -> {200, [{"content-type", "application/json"}], "{}"}
    end
  end

  defp response_tuple(response) do
    status = Keyword.get(response, :status, 200)
    headers = Keyword.get(response, :headers, [])

    case Keyword.fetch(response, :json) do
      {:ok, json} ->
        {status, [{"content-type", "application/json"} | headers], Jason.encode!(json)}

      :error ->
        {status, headers, Keyword.get(response, :body, "")}
    end
  end

  # --- The plug ------------------------------------------------------------------------

  defmodule Router do
    @moduledoc false
    @behaviour Plug

    alias AshBrowserTests.Fake
    alias AshBrowserTests.Fake.Request

    @impl Plug
    def init(fake), do: fake

    @impl Plug
    def call(conn, fake) do
      {:ok, body, conn} = read_all(conn, "")
      request = build(conn, body)
      {status, headers, response} = Fake.record(fake, request)

      conn = Enum.reduce(headers, conn, fn {k, v}, c -> Plug.Conn.put_resp_header(c, k, v) end)
      Plug.Conn.send_resp(conn, status, response)
    end

    defp read_all(conn, acc) do
      case Plug.Conn.read_body(conn, length: 10_000_000) do
        {:ok, chunk, conn} -> {:ok, acc <> chunk, conn}
        {:more, chunk, conn} -> read_all(conn, acc <> chunk)
      end
    end

    defp build(conn, raw) do
      body = decompress(raw, Plug.Conn.get_req_header(conn, "content-encoding"))
      headers = Map.new(conn.req_headers)
      traceparent = headers["traceparent"]

      %Request{
        method: conn.method,
        path: conn.request_path,
        query: conn.query_string,
        headers: headers,
        body: body,
        json: decode_json(body, headers["content-type"]),
        traceparent: traceparent,
        trace_id: trace_id(traceparent),
        at: DateTime.utc_now()
      }
    end

    defp decompress(raw, ["gzip" | _]), do: :zlib.gunzip(raw)
    defp decompress(raw, _encoding), do: raw

    defp decode_json(body, content_type) when is_binary(content_type) do
      if String.contains?(content_type, "json") do
        case Jason.decode(body) do
          {:ok, decoded} -> decoded
          {:error, _reason} -> nil
        end
      end
    end

    defp decode_json(_body, _content_type), do: nil

    defp trace_id("00-" <> <<trace_id::binary-size(32), "-", _rest::binary>>), do: trace_id
    defp trace_id(_traceparent), do: nil
  end
end
