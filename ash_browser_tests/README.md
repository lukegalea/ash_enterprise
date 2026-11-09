# ash_browser_tests

Real-browser tests for Phoenix and Ash applications, with assertions on the
OpenTelemetry trace each test produced. Test-only: never a runtime dependency, and
never compiled into a release.

A sparse package of this repository, like `telemetry/` and `battery/`. It has no
dependency on the ash_enterprise application.

What it gives a host, as `AshBrowserTests.*`:

| Module | Purpose |
|---|---|
| `Case` | Case template over `PhoenixTest.Playwright.Case`: the `:e2e` tag, a per-test key, session-cookie sign-in, failure capture |
| `Browser` | `sign_in/3`, `assert_deep/3` and friends across shadow roots, console and 5xx assertions |
| `SandboxHook` | Telemetry handlers that give a LiveView its database access and test key, with no router change |
| `Trace` | Chain, link, correlation and exception assertions, always selected by test key |
| `Backend` | One `spans_for/3` over the in-VM sink, SigNoz and GlitchTip |
| `Fake`, `Fake.LLM`, `Fake.DSN` | Bandit-served stand-ins for outbound HTTP, which record requests and propagated headers |
| `Surfaces`, `Ledger`, `A2uiManifest` | A generated test per declared surface and action; anything neither exercised nor waived fails |

## Adopting it

### 1. Dependency

```elixir
# mix.exs
{:ash_browser_tests,
 github: "lukegalea/ash_enterprise", sparse: "ash_browser_tests", ref: "<sha>", only: :test},
# ...plus, if you do not already take it, the telemetry package the trace helpers read:
{:ash_enterprise_telemetry,
 github: "lukegalea/ash_enterprise", sparse: "telemetry", ref: "<sha>"},
```

Trace assertions need `ash_enterprise_telemetry` for spans. The rest of the package
works without it.

### 2. Playwright, from the host's `assets`

```jsonc
// assets/package.json, exact version
"devDependencies": {"playwright": "1.65.0"}
```

Run `npm ci` with `PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1`. Browsers are never
downloaded: Chromium comes from the environment (`pkgs.chromium` in devenv, and an
`executable_path` below).

### 3. `config/test.exs`

```elixir
# The endpoint runs only for the browser tier, gated so the rest of the suite stays server: false.
config :my_app, MyAppWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: String.to_integer(System.get_env("E2E_PORT", "4002"))],
  server: System.get_env("E2E") == "1"

config :my_app, :sql_sandbox, true

config :phoenix_test,
  otp_app: :my_app,
  endpoint: MyAppWeb.Endpoint,
  playwright: [
    browser_pool: :chromium_pool,
    browser_pools: [
      [
        id: :chromium_pool,
        browser: :chromium,
        size: 2,
        executable_path: System.get_env("E2E_CHROMIUM") || System.find_executable("chromium")
      ]
    ],
    assets_dir: "./assets",
    timeout: 15_000,
    browser_launch_timeout: 30_000
  ]

# The in-VM trace ring must hold a whole run.
config :ash_enterprise_telemetry, :trace_sink, ring_size: 5_000, max_spans: 200_000
config :ash_enterprise_telemetry, :trace_sink?, true
```

Trace assertions also need the telemetry package set up in the `test` environment:

```elixir
config :opentelemetry,
  processors: [
    {AshEnterprise.Telemetry.SpanProcessor, %{}},
    {AshEnterprise.Telemetry.TraceSink.Processor, %{}}
  ]

config :ash, :tracer, [AshEnterprise.Telemetry.AshTracer]
config :ash_enterprise_telemetry, :browser_ingest, enabled: true, rate_limit: 100_000
```

Order matters if the host adds an OTLP exporter: a processor that does not return `true`
from `on_end` starves the ones after it, so a batch exporter goes before the sink.

`config/runtime.exs` often reads `PORT` in every environment and silently overrides
the port above, so either skip it for `:test` or run through
`mix ash_browser_tests.test`, which sets both `E2E_PORT` and `PORT`.

### 4. `test/test_helper.exs`

```elixir
ExUnit.configure(exclude: [:e2e])   # keep browser tests out of plain `mix test`
ExUnit.start()

if System.get_env("E2E") == "1" do
  AshEnterprise.Telemetry.setup(otp_app: :my_app, browser_context: true, db_statement: :enabled)
  AshBrowserTests.start!(endpoint: MyAppWeb.Endpoint)
end
```

Skip the `setup/1` call if the application already makes it at start. It needs
`browser_context: true` in the test environment, or the server never adopts the browser's
span as a parent and every chain from `browser_event/1` or `browser_connect/1` fails.

`AshBrowserTests.start!/1` starts the Playwright supervisor, points PhoenixTest at the
endpoint, and attaches the sandbox hook.

### 5. The endpoint

```elixir
socket "/live", Phoenix.LiveView.Socket,
  websocket: [connect_info: [:user_agent, session: @session_options]],
  longpoll: [connect_info: [:user_agent, session: @session_options]]

if Application.compile_env(:my_app, :sql_sandbox, false) do
  plug Phoenix.Ecto.SQL.Sandbox
end
```

There is no `on_mount` and no router change: `AshBrowserTests.SandboxHook` covers every
`live_session` through telemetry. Add `:user_agent` to any other socket a browser test
reaches too.

Browser spans need two more things, and a suite with neither can still assert server
chains:

```elixir
# Endpoint, before Plug.Parsers: where the browser posts its spans.
plug AshEnterprise.Telemetry.OtlpIngest
```

- The telemetry package's browser tracer loaded by the page, and
  `<meta name="otel-browser" content="on">` in the root layout. See "Browser" in
  `telemetry/README.md`.
- `window.__otelFlush` and `window.__otelEndConnect` defined by the page.
  `flush_browser_spans/1` calls them when present, and without them spans arrive only on
  the tracer's own schedule.

## Writing a test

```elixir
defmodule MyAppWeb.E2E.OrdersTest do
  use AshBrowserTests.Case, async: true

  test "creating an order reaches the database", %{conn: conn, test_key: key} do
    conn
    |> sign_in(%{"user_token" => token}, MyAppWeb.Endpoint.session_options())
    |> visit("/orders")
    |> assert_connected()
    |> click_button("Create order")

    assert_chain(key, [browser_event(), handle_event(), ash_action(action: :create), query()])
    assert_one_correlation(key, handle_event())
  end
end
```

The key is the sandbox owner the browser carries in its user agent. Server processes
learn it from that header; `Trace` selects by it and nothing else.

Assertions wait: spans arrive after the browser flushes. Every assertion also takes a
list of `Span`s and checks it once, which is how to test the negative cases.

`allow_browser_failures: true` as a test tag turns off the at-exit check for a test that
provokes a failure on purpose; `take_browser_failures/2` consumes the expected ones
instead.

## The generator

```elixir
defmodule MyAppWeb.E2E.Surfaces do
  @behaviour AshBrowserTests.Surfaces.Host
  alias AshBrowserTests.{Action, Surface}

  @impl true
  def surfaces do
    [
      %Surface{id: "orders", path: "/orders", actor: :admin},
      %Surface{id: "reports", path: "/reports", actor: :manager,
       actions: [%Action{id: "export", run: &MyAppWeb.E2E.Actions.export/2}]},
      %Surface{id: "webhooks", path: nil}
    ]
  end

  @impl true
  def waivers, do: [{:surface, "webhooks", "no page; covered by a hand-written journey"}]

  @impl true
  def sign_in(conn, actor, _context), do: MyAppWeb.E2E.Login.as(conn, actor)
end

defmodule MyAppWeb.E2E.SurfacesTest do
  use AshBrowserTests.Surfaces, host: MyAppWeb.E2E.Surfaces, async: true
end
```

Each surface gets a test: sign in, visit, the LiveView connects, the surface mounts, no
console errors or 5xx, span chain intact. Each action with a `run` gets one too. A
`ledger:` test fails if anything is neither exercised nor waived, if a waiver has no
reason, or if a waiver names something no longer declared.

### A2UI row actions

`AshBrowserTests.A2uiManifest` is the interface; `A2uiManifest.Stub` is the placeholder
until `ash_a2ui` ships a manifest. What this package needs from `ash_a2ui`, built on
`AshA2ui.Info`, per surface:

- `row_actions`: for each, a stable `id`, the button's accessible `label`, the Ash
  `action` and resource, the `visible_when` condition, `prompt_fields` (name, label,
  type, required, options) and, if there is one, the confirm control's label.
- `tables` and presets, so rows can be matched against the Ash read.
- A row selector stable across renders, if `tr`/`[role=row]` turns out not to be enough
  once it is exercised on a real page.

## Running

Inside the environment (devenv provides Postgres, Node and Chromium):

```bash
MIX_ENV=test mix ash_browser_tests.test --assets assets.build test/e2e
```

`--assets` builds Tailwind and esbuild first; without the compiled CSS, hidden forms are
visible and locators become ambiguous. It allocates a free port, sets `E2E=1`,
`E2E_PORT` and `PORT`, then runs `mix test`.

Or in a host's mix project: `def cli, do: [preferred_envs: ["ash_browser_tests.test": :test]]`
and `mix ash_browser_tests.test ...`.

## This package's own suite

```bash
cd ash_browser_tests
mix deps.get
npm ci --prefix test/playwright       # PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
mix test
```

It runs Chromium against a tiny Phoenix application in `test/support/fixture`. The real
Postgres repo's database is `ash_browser_tests_test`, using the standard `PG*` variables.

### Live backends

`Backend.SigNoz` and `Backend.GlitchTip` have tests against recorded responses. To run
them against a real stack:

```bash
SIGNOZ_URL=... SIGNOZ_API_KEY=... SIGNOZ_OTLP_URL=... \
GLITCHTIP_URL=... GLITCHTIP_TOKEN=... GLITCHTIP_ORG=... GLITCHTIP_DSN=... \
  mix test --only live_backends
```
