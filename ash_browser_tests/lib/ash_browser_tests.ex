defmodule AshBrowserTests do
  @moduledoc """
  Real-browser tests for Phoenix and Ash applications, with assertions on the
  OpenTelemetry trace each test produced.

  | Module | Purpose |
  |---|---|
  | `AshBrowserTests.Case` | Case template over `PhoenixTest.Playwright.Case`: `:e2e` tag, test key, failure capture |
  | `AshBrowserTests.Browser` | Session-cookie sign-in, shadow-DOM helpers, console and 5xx assertions |
  | `AshBrowserTests.SandboxHook` | Telemetry handlers giving a LiveView database access without a router change |
  | `AshBrowserTests.Trace` | Chain, link, correlation and exception assertions, selected by test key |
  | `AshBrowserTests.Backend` | `spans_for/3` over the in-VM sink, SigNoz or GlitchTip |
  | `AshBrowserTests.Fake`, `Fake.LLM`, `Fake.DSN` | Bandit-served stand-ins for outbound services |
  | `AshBrowserTests.Surfaces`, `Ledger` | A generated test per declared surface; nothing undeclared passes |

  `start!/1` is called once from `test_helper.exs`.

      AshBrowserTests.start!(endpoint: MyAppWeb.Endpoint)

  `README.md` has the whole adoption recipe.
  """

  alias AshBrowserTests.SandboxHook

  @doc """
  Starts the Playwright supervisor, points PhoenixTest at the endpoint and attaches
  the sandbox hook. Call it from `test_helper.exs`, after the application started.

  Options: `:endpoint` (required, a started endpoint), `:sandbox`
  (default `Ecto.Adapters.SQL.Sandbox`).
  """
  @spec start!(keyword()) :: :ok
  def start!(opts) do
    endpoint = Keyword.fetch!(opts, :endpoint)
    url = endpoint.url()

    Application.put_env(:phoenix_test, :base_url, url)
    {:ok, _pid} = PhoenixTest.Playwright.Supervisor.start_link()

    SandboxHook.attach(Keyword.take(opts, [:sandbox]))
  end

  @doc """
  An unused TCP port on the loopback interface. The socket is closed before this
  returns, so hand it to the server straight away.
  """
  @spec free_port() :: :inet.port_number()
  def free_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1}, reuseaddr: false)
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end
end
