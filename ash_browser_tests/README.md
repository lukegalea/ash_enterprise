# ash_browser_tests

Real-browser tests for Phoenix and Ash applications, with assertions on the
OpenTelemetry trace each test produced. Test-only: never a runtime dependency, and
never compiled into a release.

A sparse package of this repository, like `telemetry/` and `battery/`. It has no
dependency on the ash_enterprise application.

What it gives a host, as `AshBrowserTests.*`:

| Module | Purpose |
|---|---|
| `Case` | Case template over `Playwright.Test` and Fluffy's PhoenixTest facade: the `:e2e` tag, a per-test key, session-cookie sign-in, failure capture |
| `Browser` | `sign_in/3`, `assert_deep/3` and friends across shadow roots, console and 5xx assertions |
| `SandboxHook` | Telemetry handlers that give a LiveView its database access and test key, with no router change |
| `Trace` | Chain, link, correlation and exception assertions, always selected by test key |
| `Backend` | One `spans_for/3` over the in-VM sink, SigNoz and GlitchTip |
| `Fake`, `Fake.LLM`, `Fake.DSN` | Bandit-served stand-ins for outbound HTTP, which record requests and propagated headers |
| `Surfaces`, `Ledger`, `A2uiManifest` | A generated test per declared surface and action; anything neither exercised nor waived fails |
| `Tables`, `Rows`, `RowActions` | A generated test per A2UI table and preset, with its own ledger; and the row-level helpers (locate by `data-a2ui-row-id`, switch presets, fill prompt widgets) |
| `Reporter`, `Report` | An ExUnit formatter recording each outcome, and the renderer behind `mix ash_browser_tests.report` |

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

### 2. Chromium

Install Playwright's driver and Chromium with `mix playwright.install chromium` (in CI,
`mix playwright.install chromium --with-deps`). In devenv, Chromium comes from the
environment instead (`pkgs.chromium`, an `executable_path` below).

### 3. `config/test.exs`

```elixir
# The endpoint runs only for the browser tier, gated so the rest of the suite stays server: false.
config :my_app, MyAppWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: String.to_integer(System.get_env("E2E_PORT", "4002"))],
  server: System.get_env("E2E") == "1"

config :my_app, :sql_sandbox, true

config :fluffy, endpoint: MyAppWeb.Endpoint, ecto_repos: [MyApp.Repo]

# `AshBrowserTests.SandboxHook` reads the sandbox metadata from the user agent.
config :fluffy, Fluffy.Sandbox, header: "user-agent"

chromium = System.get_env("E2E_CHROMIUM") || System.find_executable("chromium")

config :playwright, :test,
  browser_name: :chromium,
  launch_options: [timeout: 90_000] ++ if(chromium, do: [executable_path: chromium], else: []),
  action_timeout: 30_000,
  navigation_timeout: 30_000,
  expect: [timeout: 30_000],
  # Under test-results/: traces and screenshots of failed tests.
  trace: :retain_on_failure,
  screenshot: :only_on_failure

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
ExUnit.start(formatters: [ExUnit.CLIFormatter, AshBrowserTests.Reporter])

if System.get_env("E2E") == "1" do
  AshEnterprise.Telemetry.setup(otp_app: :my_app, browser_context: true, db_statement: :enabled)
  AshBrowserTests.start!(endpoint: MyAppWeb.Endpoint)
end
```

`AshBrowserTests.Reporter` records each test's outcome so
`mix ash_browser_tests.report` can join it to the screenshot and trace. Without
it the report still builds, but every row reads "no result" — the media
filenames carry no outcome of their own. It is harmless in a suite with no
browser tests.

Skip the `setup/1` call if the application already makes it at start. It needs
`browser_context: true` in the test environment, or the server never adopts the browser's
span as a parent and every chain from `browser_event/1` or `browser_connect/1` fails.

`AshBrowserTests.start!/1` points Fluffy at the endpoint and attaches the sandbox hook.

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

> #### The default chain assumes browser tracing {: .warning}
>
> A generated surface asserts `[browser_connect(), live_mount()]` and a generated
> action `[browser_event(), handle_event()]` — both rooted at a span the *browser*
> emits. A host without browser tracing (no `otel-browser` meta tag, no tracer in
> `app.js`, no span ingest route) has no such span, so every generated test fails
> on an absent span rather than on anything being wrong.
>
> Such a host supplies its own `chain:` per surface — `[live_mount(), query()]`
> asserts the server half, which is most of the value — and adopts browser tracing
> later. `ash_enterprise`'s own host is the worked example.
>
> `assert_chain/3` takes **two matchers at minimum**: it asserts links, and one span
> is not a chain. A single-element chain raises a `FunctionClauseError` rather than
> a readable error.

The ledger governs **what the host declares**, not the application's whole registry.
It cannot fail for a surface `surfaces/0` never returns, so a host adopting a subset
should make the subset explicit and check that each name still resolves — a renamed
or deleted surface otherwise shrinks coverage silently, with every test still green.

### A2UI row actions

`AshBrowserTests.A2uiManifest` is the interface the generator consumes: a `manifest/1`
returning, per surface, `row_actions` (a stable `id`, the button's accessible `label`,
the Ash action and resource, `visible_when`, `prompt_fields`, and a confirm label if
there is one) and `tables` with their presets.

`ash_a2ui` now builds that — `AshA2ui.Manifest.for_surface/2` — so a host's module is
usually one line per surface over its own registry. `A2uiManifest.Stub` answers `nil`
for every surface, for a host with no A2UI; `Static` serves a hand-written map.

### The derived table suite

```elixir
defmodule MyAppWeb.E2E.TablesTest do
  use AshBrowserTests.Tables, host: MyAppWeb.E2E.Surfaces, async: true
end
```

A test per A2UI table and per preset: the rows the page shows must equal the rows the
table's read returns for the same actor, compared by `data-a2ui-row-id` and never by
text. Tables that read nothing until a `require_context` is chosen open through the
surface's own deep link (`?ctx[<name>]=<id>`). It has its own ledger
(`table_waivers/0`), on the same terms as the surface ledger.

`AshBrowserTests.Tables.Host` adds the callbacks: `manifests/0`, `row_opts/2`,
`table_waivers/0`, `context_record/3` and the optional `seed_table/3`. `Rows` and
`RowActions` are the row-level helpers underneath — locating a row by
`data-a2ui-row-id`, switching presets through the picker, filling choice-picker,
checkbox and date prompt widgets — and a host can use them directly when it wants to
declare a row action's `run` itself rather than take the generated one.

> #### Two row-action paths {: .warning}
>
> `Surfaces` generates row actions with its own `run_row_action/3`, which clicks by row
> text and fills prompts with `PhoenixTest.fill_in/3`. `RowActions.perform/3` waits for
> the row, locates it by `data-a2ui-row-id` and handles the widget types. They overlap,
> and a host currently picks one by either taking the generated action or declaring its
> own `run:`. Reconciling them is a follow-up, not a thing to discover mid-debugging.

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

## The report

```bash
MIX_ENV=test mix ash_browser_tests.report
```

Reads the screenshots, the traces and `Reporter`'s results, and writes one
`index.html` beside them: a row per test with its status, duration, screenshot
and a link to its trace, failures first. Inline CSS, no JavaScript, no external
request and only relative links, so it opens from an unzipped CI artifact on a
machine with no network.

When `GITHUB_STEP_SUMMARY` is set it also appends a markdown table there, with
the failure messages in a `<details>` block. A step summary **cannot render a
local image** — only absolute URLs — so the table says which tests have media
and leaves the looking to the page.

In CI, upload on success as well as failure. A screenshot of a page that passed
but looks wrong is the one worth having, and it is the case a failure-only
upload never captures:

```yaml
- name: Report
  if: always()
  run: MIX_ENV=test mix ash_browser_tests.report
- uses: actions/upload-artifact@v4
  if: always()
  with:
    name: browser-tier
    path: tmp/playwright/
```

## This package's own suite

```bash
cd ash_browser_tests
mix deps.get
MIX_ENV=test mix playwright.install chromium   # or E2E_CHROMIUM=<path>, as in devenv
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
