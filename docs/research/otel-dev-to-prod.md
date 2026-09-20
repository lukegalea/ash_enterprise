# Distributed tracing, from development assistant to production ops

| | |
|---|---|
| **Status** | Research — design for review |
| **Date** | 2026-09-20 |
| **Verified against** | working tree at `main` (`55e3670`), `mix.lock` as committed, `deps/` as vendored |
| **Touches** | `config/config.exs`, `config/runtime.exs`, `lib/ash_enterprise/application.ex`, `lib/ash_enterprise_web/telemetry.ex`, `AshEnterprise.Platform.Correlation`, `ash_agent_tools`, `opentelemetry_ash` |
| **Companions** | [ADR 0018 — Grafana LGTM](../adr/0018-grafana-lgtm-observability-backend.md), [the provenance envelope](../verification/provenance-envelope.md), [semantic manifest v0](../rfc/semantic-manifest-v0.md), [`.claude/skills/audit-and-telemetry`](../../.claude/skills/audit-and-telemetry/SKILL.md) |

---

## 0. The claim

This repository already has the expensive half of distributed tracing: a tracer wired into
the framework's own execution model, so every action is a span with no per-resource wiring.
What it does not have is anything that makes those spans *useful to the person or agent
writing the code* — and that, not production dashboards, is where the near-term return is.

The argument in one line: **a trace is the only artifact in this system that records what
actually ran, in order, with timings and failures, across the process boundaries the audit
log cannot cross.** An agent that can read the trace of the action it just invoked is an
agent that can answer "why was that forbidden", "why was that slow", and "did the notifier
fire" without guessing from source. Today it has to guess.

The same pipeline, same exporter, same span shapes then serve production ops. That is the
point of building it dev-first rather than prod-first: the dev loop exercises the
instrumentation constantly, by people who will notice when it lies.

---

## 1. Inventory: what is actually instrumented

Everything in this section was read from the tree today. Where an existing document
disagrees, that is noted — two of them are stale.

### 1.1 Wired and working

| Thing | Where | State |
|---|---|---|
| Ash tracer | `config/config.exs:240` — `config :ash, :tracer, [OpentelemetryAsh]` | Active. Spans for Ash **actions** only (see §1.2). |
| LiveView | `lib/ash_enterprise/application.ex:163` — `OpentelemetryPhoenix.setup(adapter: :bandit, liveview: true)` | **Working.** `mount`, `handle_params`, `handle_event` each start a real `kind: :server` root span. |
| Phoenix HTTP | same call | **Produces no root span at all** — see G0, the largest single finding here. |
| Ecto | `lib/ash_enterprise/application.ex:164` — `OpentelemetryEcto.setup([:ash_enterprise, :repo], db_statement: :disabled)` | Active, **without SQL text**. |
| Exporter default | `config/config.exs:245-247` — `span_processor: :batch, traces_exporter: :none` | Off by default, deliberately. |
| Exporter switch | `config/runtime.exs:166-180` | `OTEL_EXPORTER_OTLP_ENDPOINT` flips `traces_exporter` to `:otlp`, protocol `:http_protobuf`, sets `service.name` / `service.namespace`. |
| Cross-process context | `opentelemetry_process_propagator` 0.3.0 | Arrives transitively (required by `opentelemetry_ash` and `opentelemetry_phoenix`); used by `OpentelemetryAsh.get_span_context/0`. |
| Metrics declaration | `lib/ash_enterprise_web/telemetry.ex` | Declared; consumed only by LiveDashboard. |
| LiveDashboard | `lib/ash_enterprise_web/router.ex:354` — `live_dashboard "/dashboard", metrics: AshEnterpriseWeb.Telemetry` | Dev only (`dev_routes`). |

Locked versions (`mix.lock`, today):

```
opentelemetry                     1.7.0
opentelemetry_api                 1.5.0
opentelemetry_exporter           1.10.0
opentelemetry_phoenix             2.0.1
opentelemetry_ecto                1.2.0
opentelemetry_ash                 0.1.3     <- the weak link
opentelemetry_process_propagator  0.3.0
opentelemetry_semantic_conventions 1.27.0
opentelemetry_telemetry           1.1.2
```

### 1.2 The gaps, specifically

**G0 — HTTP requests have no root span, and the route is silently discarded.**
`opentelemetry_phoenix` 2.x does not create the server span itself when the adapter is
Bandit. Its own handler is an explicit no-op:

```elixir
# deps/opentelemetry_phoenix/lib/opentelemetry_phoenix.ex:140
def handle_endpoint_start(_event, _measurements, _meta, %{adapter: :bandit}), do: :ok
```

and its `@moduledoc` says so: *"`bandit` — when using `Bandit.PhoenixAdapter` as your adapter
you must add `:opentelemetry_bandit` to your project and pass `adapter: :bandit`."* The
second half was done; the first was not. `opentelemetry_bandit` appears **zero times** in
`mix.exs` and `mix.lock`.

The consequence is worse than a missing span. `handle_router_dispatch_start/4`
(`opentelemetry_phoenix.ex:154-160`) does not *start* a span — it calls
`Tracer.update_name/1` and `Tracer.set_attributes/1` on the **current** span, expecting
`opentelemetry_bandit` to have opened one. With no current span those calls land on an
undefined context and vanish. So for every HTTP request the route, the method, the
`phoenix.plug`/`phoenix.action` attributes and the response status are all computed and
thrown away, and the Ash and Ecto spans underneath are **orphans** — roots of their own
single-span traces, with no request to group them.

The irony is worth stating: LiveView is fine. Its handlers
(`opentelemetry_phoenix.ex:163-210`) call
`OpentelemetryTelemetry.start_telemetry_span/4` with `kind: :server`, so a `mount` or a
`handle_event` is a genuine root that Ash spans nest under. This application's primary
surface therefore traces correctly, and its REST, GraphQL, JSON:API and MCP surfaces do
not — which is exactly the sort of partial success that reads as "tracing works" until
somebody debugs an API call.

Worth one more sentence, because it bears on thesis 5 (*agents are users*): the three
`AshAi.Mcp.Router` mounts at `router.ex:297`, `:316` and `:325` are the production
agent-facing surface, and they are on the untraced side of that line. The one caller who
cannot read a stack trace is the one whose requests currently leave no trace.

Fix: add `{:opentelemetry_bandit, "~> 0.3"}` (0.3.0, published 2025-08-21, Apache-2.0,
under the OpenTelemetry org) and call `OpentelemetryBandit.setup/1` **before**
`OpentelemetryPhoenix.setup/1`. ADR 0018's follow-up list already named this package; it is
the item that was not done, and it is two lines.

Worth noting for anyone reading the option schema and getting confused: `adapter` is
declared both `required: true` and with a `default: :cowboy2` — contradictory, and the
subject of upstream issue #482 (open since 2025-04-22). `required: true` wins, so the
repository's explicit `adapter: :bandit` is correct and is not what is broken here.

**G1 — `OpentelemetryAsh.set_metadata/2` is a literal no-op.** From the vendored source,
`deps/opentelemetry_ash/lib/opentelemetry_ash.ex`:

```elixir
@impl Ash.Tracer
def set_metadata(_type, _metadata) do
  :ok
end
```

Ash calls this at **36 sites** across `deps/ash/lib/` (`actions/read/read.ex:86`,
`query/query.ex:941`, `changeset/changeset.ex:2322`, `notifier/notifier.ex:423`, …) with a
map that Ash's own `@type metadata()` defines as:

```elixir
%{domain: module(), resource: module(), actor: term(),
  tenant: term(), action: atom(), authorize?: boolean()}
```

plus `resource_short_name`. **All of it is discarded.** The only attribute any Ash span
carries is `%{type: type}` — the span type atom — set in `start_span/2`.

The single thing that survives is the span *name*, built by
`Ash.Domain.Info.span_name/3` (`deps/ash/lib/ash/domain/info.ex:236`) as
`"#{domain}:#{resource}.#{action}"`. So identity exists, but only as an unstructured string
that a consumer must parse. This is the root cause of every other design problem in this
document, and it is the one fix worth making upstream.

For scale: the whole package is **97 lines in one module**, with a single parent-span
assertion for a test suite. Every commit between the 0.1.3 release (2025-07-11) and the
most recent push (2026-09-01) is a dependabot dependency bump except one test update; the
source file itself has not changed. Fifteen stars, zero open issues. It is feature-frozen
rather than abandoned — Ash bumps keep it *compatible*, they just do not make it grow.

`Ash.Tracer.Simple` (`deps/ash/lib/ash/tracer/simple.ex`) is a working reference
implementation in Ash's own tree that **does** store metadata, which makes the gap harder
to defend and the fix easier to write.

**G2 — most Ash span types are switched off by default.** `trace_type?/1` falls back to
`[:custom, :action, :flow]` when `config :opentelemetry_ash, :trace_types` is unset, and
this repository never sets it (grep: only two *comment* hits for `opentelemetry_ash`, in
`config/config.exs:238` and `application.ex:129`). So `:query`, `:changeset`, `:validation`,
`:change`, `:preparation`, `:calculation`, `:notifier`, `:before_action`, `:after_action`,
`:before_transaction`, `:after_transaction`, `:bulk_create`/`:bulk_update`/`:bulk_destroy`,
`:bulk_batch` and `:request_step` produce **no spans at all**.

The default list is wrong at both ends. `:flow` is in it and **does not exist in Ash 3** —
`Ash.Tracer.span :flow` appears nowhere in 3.33.5, Flow having been extracted from core.
`:request_step` is likewise dead: it survives in the typespec
(`deps/ash/lib/ash/tracer/tracer.ex:11-29`) and is never emitted. Meanwhile the list
*excludes* `:query` and `:changeset`, which are the two most useful types for the purpose
in §2. The package's own getting-started guide recommends this list — *"We suggest using
this list. It trims down some noisy traces"* — so following the documentation gets you one
stale entry out of three and none of the spans you want.

One more naming defect to carry into any fix: the notifier span is emitted as
`:notification` (`deps/ash/lib/ash/notifier/notifier.ex:406`) while the typespec calls it
`:notifier`. A `trace_types` list written from the typespec silently omits it.

This is why the skill's claim that "every action, query, changeset, validation and
calculation becomes a span" overstates the current state. Every *action* does.

**G3 — every Ash span is `kind: :client`.** `start_span/2` hardcodes it. Ash actions are
in-process work; they are `:internal`. Backends that derive service-dependency graphs from
client spans will draw edges that do not exist, and span-kind-based sampling policies will
mis-file them.

**G4 — `set_handled_error/2` is not implemented.** It is an optional callback
(`tracer.ex:61`), so Ash's `function_exported?` fallback makes this silent. Errors that Ash
catches and turns into a result — the ordinary `{:error, %Ash.Error.Invalid{}}` path — leave
no mark on the span. Only *raised* errors reach `set_error/2`.

**G5 — Oban is untraced, and AshOban cannot be made to propagate context by
configuration.** `opentelemetry_oban` is not declared in `mix.exs` and does not appear in
`mix.lock`. Three queues run real work (`config/config.exs` — `default: 10, bpmn: 10,
ash_strangler_ledger: 10`), and the two named ones are the system's most interesting
asynchronous paths: every BPMN token advance, every process timer, the reconciliation
sweep, and the legacy change-ledger drain. None of it appears in a trace. Given that
`Correlation`'s id does not cross a process boundary either, an Oban-dispatched BPMN node is
currently invisible to *both* correlation mechanisms.

Adding the dependency is necessary and **not sufficient**, which is the part worth knowing
before anyone budgets this as a one-liner. `opentelemetry_oban` writes the W3C
`traceparent` into `job.meta` only from its own `OpentelemetryOban.insert/2` wrapper; its
README says so explicitly. **AshOban always inserts through bare `Oban.insert!/1`** — at
`lib/ash_oban.ex:877`, `:883`, `:947`, `:965`, `:968`, and inside the generated modules at
`lib/transformers/define_action_workers.ex:97` and
`lib/transformers/define_schedulers.ex:176`, `:192`. A grep of `ash_oban` for
`opentelemetry|otel|traceparent` returns nothing; the single `:tracer` hit is a key in a
`Keyword.split/2` separating Ash options from Oban options, resolved in the *enqueueing*
process and never serialized.

So with the dependency added, an AshOban job gets a `process <queue>` span that is a **fresh
root trace** with no parent and no link, and the Ash spans inside it nest under that orphan.
There is no configuration that fixes this, because the insert calls are compiled into
transformer-generated modules. Three options: accept orphan roots (defensible for cron,
where there is no meaningful parent); enqueue manually via `AshOban.build_trigger/3` into
`OpentelemetryOban.insert/1` for the paths that matter; or upstream a PR to AshOban. The
cost lands on `run_trigger` and `change run_oban_trigger(...)`, which is exactly the BPMN
dispatch path.

Two more traps if this is picked up: **`opentelemetry_oban` must be `>= 1.2.0`** (2026-02-27)
or dependency resolution fails — 1.1.x pins `opentelemetry_semantic_conventions ~> 0.2`,
which conflicts with the `~> 1.27` that everything Bandit-era requires. And its
`span_relationship` option defaults to **`:link`, not `:child`**, so nesting requires
`OpentelemetryOban.setup(job: [span_relationship: :child])`.

**G6 — no SQL text on Ecto spans.** `db_statement: :disabled` is correct for production and
wrong for the dev-assist use case in §2: the query an action actually issued is precisely
what a developer or agent wants to see, and it is the thing `execute_sql_query` over
Tidewave cannot reconstruct after the fact.

The option is not a boolean. `opentelemetry_ecto` 1.2.0 accepts `:disabled`, `:enabled`, **or
a 1-arity sanitizer function** — `maybe_add_db_statement(attributes, sanitizer, query) when
is_function(sanitizer, 1)`. That third form is the one this repository should want in both
environments, and §4.2 uses it. (`:disabled` became the default in 1.2.0 precisely because
of the unsanitized-statement risk.)

**G6b — LiveView spans carry no attributes at all.** The handlers at
`opentelemetry_phoenix.ex:163-210` start correctly-shaped `kind: :server` spans named
`"MyAppWeb.SomeLive.mount"` / `".handle_params"` / `".handle_event#save"`, and set
**nothing** on them — not `http.route`, not the LiveView module as an attribute, nothing but
the name. So the surface that *does* trace correctly (G0) produces spans you cannot filter
or group by in a backend, only string-match on.

This is fixed upstream but unreleased: `opentelemetry_phoenix` `main` adds `http.route` to
`handle_event` spans (carried forward from the route resolved at `mount`/`handle_params`), a
`liveview_span_names: :route` option producing `live_view.mount /resources/:resource_id`,
and handlers for `[:phoenix, :live_view, :render, *]`. The last hex release is **2.0.1,
2025-02-21 — nineteen months ago** — while `main` merged PRs as recently as 2026-09-15 and
now pins its test matrix at `phoenix 1.8.13` / `phoenix_live_view 1.2.11`. Phoenix 1.8 and
LiveView 1.2 are actively tested upstream and simply not released. That is a third
fork-or-wait decision alongside §5.2, and unlike `opentelemetry_ash` the code already exists.

**G7 — metrics are declared for 3 domains out of 13.** `ash_metrics/0` iterates
`[:accounts, :security, :audit]`. `config/config.exs` lists thirteen domains in
`:ash_domains`, including `Bpmn`, `Decisions`, `Process`, `Contracts`, `Compliance`,
`Legacy` and the two agent domains. The skill correctly warns that adding a domain requires
a change here; ten domains have been added without it.

**G8 — nothing consumes `metrics/0` except LiveDashboard.** The `Telemetry.Metrics`
reporter line in `telemetry.ex:16` is commented out, and the supervisor starts
`:telemetry_poller` only. This is ADR 0018's third follow-up, still open.

**G9 — no sampler is configured.** Neither `config/config.exs` nor `config/runtime.exs`
names `:sampler`, so the SDK default applies everywhere, dev and prod alike. §4 argues that
is the right answer in dev and the wrong one in prod.

**G10 — no collector, anywhere in the repo.** `grep -i 'otel\|signoz\|collector\|jaeger\|grafana\|tempo' devenv.nix` returns nothing. There is no docker-compose. `.env.example`
suggests `OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318` and nothing in this repository
listens there. Turning tracing on locally today means pointing at something you brought
yourself.

**G11 — `.env.example` is wrong about the default.** It says *"Unset means traces are
logged, not exported."* They are not logged. `traces_exporter: :none` drops them on the
floor. A one-line fix, but it is the kind of comment that makes someone stop looking.

**G12 — no trace id reaches the audit trail.** `AshEnterprise.Platform.Correlation.audit_metadata/1`
emits exactly `correlation_id`, `depth`, `system_actor`, `impersonator_id`. The
[provenance envelope](../verification/provenance-envelope.md) design proposes `trace_id` and
`span_id` fields; `AshEnterprise.Provenance.Envelope` does not exist in `lib/`. (The module
that *does* exist, `AshEnterprise.Platform.Changes.StampProvenance`, fills Dataverse's four
`*_by_id` columns and is unrelated.)

**G13 — spans are never asserted on.** No test captures spans. `config/test.exs` sets
`disable_async?: true`, which conveniently removes the cross-process propagation problem
from the suite — and also removes any chance of the suite catching a propagation
regression.

### 1.3 Two documents that are now stale

Both `docs/manifesto/07-what-we-do-not-have.md` §9 and
`docs/adr/0018-grafana-lgtm-observability-backend.md` state, as of 2026-08-18, that
`OpentelemetryPhoenix.setup/1` and `OpentelemetryEcto.setup/1` are "never called anywhere in
`lib/` or `config/`" and that `config/runtime.exs` "contains no OpenTelemetry configuration
at all." Both were true then and are false now: `application.ex:162-166` and
`runtime.exs:166-180` landed since. ADR 0018's follow-up list had four items: the two `setup/1` calls are done; `opentelemetry_bandit` and `opentelemetry_oban` are not (G0, G5), and neither is the metrics reporter (G8). The ADR's *conclusion* — that the Ash-side work is "approximately zero" — is the part that has not aged well, and G0 through G5 are why.

Correcting them is outside this document's write scope and is listed as a task in §5.

---

## 2. The dev-assist model

This is the part that is not standard practice, so it gets the most argument.

### 2.1 What an agent cannot currently find out

An agent working in this repository can already ask, without running anything, what an
action accepts and what would forbid it: `AshAgentTools.describe_action/2`,
`validate_input/3`, `explain_forbidden/2` — a `only: :dev` path dependency whose stated
contract is *"Nothing is executed against your data."* Static introspection, deliberately.

What it cannot find out is what happened when the action *ran*:

- which policy actually produced the denial, for this actor, on this row;
- which queries the action issued, in what order, and which one was slow;
- whether a notifier fired, and what it did;
- whether the failure came from a validation, a change, the data layer, or a hook;
- whether the Oban job the action enqueued ever ran, and what it did.

Every one of those is a span, or would be with G2 fixed. Today the agent's fallback is to
read source and guess, or to re-run with `IO.inspect`, which is the loop this repository's
whole agent-facing surface exists to avoid.

### 2.2 The proposal: `mix ash_agent.trace`

A fourth `mix ash_agent.*` task, and a matching `AshAgentTools.Trace` module, following the
conventions the existing three already enforce (`~/ast-forks/ash_agent_tools`):
**stdout is pure JSON always**, Logger suppressed around `app.start` unless `--verbose`,
`--out FILE`, `--pretty`, SPDX headers, MIT.

```
mix ash_agent.trace                      # summarize the most recent root trace
mix ash_agent.trace --last 5             # the last five
mix ash_agent.trace --trace-id <hex32>   # a specific one
mix ash_agent.trace --correlation <uuid> # join from an audit row
mix ash_agent.trace --explain            # add the narrative rendering (below)
```

Two callables behind it:

```elixir
AshAgentTools.Trace.last(opts \\ [])       # -> [trace_summary]
AshAgentTools.Trace.explain(trace_id)      # -> narrative + structured findings
```

**What `explain/1` returns, and why those fields.** Not a span dump — a span dump is a
worse version of what a trace UI already does, and it is expensive in agent context. The
return is a *reduction*, shaped by what actually goes wrong in an Ash application:

| Field | Source | Why |
|---|---|---|
| `root` | the `:action` span | `domain:resource.action`, duration, ok/error |
| `errors` | spans with `status == :error`, innermost first | The innermost errored span is almost always the cause; the outermost is almost always `Ash.Error.Invalid`, which tells you nothing |
| `policy` | `Ash.Error.Forbidden.Policy.report/2` output, captured as a span event | The one artifact that answers *which grant was missing* |
| `queries` | `:query` spans + child Ecto spans | Count, total time, the slowest, and **N+1 detection**: identical `db.statement` issued more than once under one root |
| `notifications` | `:notifier` spans | "Did the pub_sub fire" is a recurring LiveView debugging question with no cheap answer today |
| `async` | Oban spans linked from the root | The BPMN/strangler blind spot (G5), once closed |
| `symbols` | resolved symbol ids per span (§3) | Lets the agent jump from a span straight to the declaration |

The N+1 finding is worth singling out. It is mechanical, it is the single most common
performance defect in an Ash application with `load:` in the wrong place, and it is
invisible to every static tool in this repository. A trace makes it a three-line reduction.

**Why a reduction and not a dump — the evidence.** This is the one design point where other
people have already been wrong in public and written it up. Jaeger's
[ADR 002](https://github.com/jaegertracing/jaeger/blob/main/docs/adr/002-mcp-server.md)
(decided 2026-01-23, implemented in v2.20.0, 2026-07-19) states the premise directly:
*"a single trace can carry thousands of spans — far more than is useful to put in a context
window, and dumping one wholesale produces worse answers, not better ones."* Their answer is
a narrowing ladder — search, then topology without attributes, then critical path, then
inspect only the suspicious spans — and they ported the critical-path algorithm out of the
web UI into Go specifically so the narrowing could happen server-side.

`otel-desktop-viewer`'s own agent-integration notes put a number on it: an unbounded trace
search returned **~45,000 summaries and 9.4 MB**, and a single detailed trace **~171 KB**.
Honeycomb's Austin Parker described the same failure a year earlier — *"the sheer amount of
tokens that our query data API returns"* driving agents into *"doom loop[s] of queries and
hallucinations."* And Stripe reported at O11yCon 2026 that *"the size of the logs broke the
LLM's context window,"* solved by sub-agents returning structured summaries.

So `explain/1` returning a reduction is not a convenience. It is the design constraint, and
it should carry a hard output bound plus an explicit truncation flag rather than trusting
traces to stay small.

### 2.3 Where the trace data comes from — the one real design decision

Three options, and they are not equally good.

**(a) Query the backend.** The agent asks SigNoz (or Tempo) over HTTP for the trace. Honest
about the architecture — this is the same path a human takes — and it means the dev tool and
the prod tool are literally the same tool with a different base URL, which is the thesis of
this document. Cost: the dev loop now depends on a running collector *and* backend, and on
the export delay (batch processor, then ingestion). "Run the action, immediately ask for its
trace" races with ingestion.

**(b) A local in-VM span sink.** A `:dev`-only span processor that keeps the last N root
traces in an ETS table inside the application, alongside the OTLP exporter. Zero
dependencies, zero latency, works with `traces_exporter: :none`, and is readable from
`project_eval` over Tidewave — which is already the highest-leverage agent path into this
app (`.mcp.json`). Cost: it is a second implementation of "store a trace", bounded and
lossy, and it does not exist in prod.

This is less speculative than it sounds: the Erlang SDK already ships two in-VM exporters
for exactly this shape of need. `otel_exporter_pid` sends `{span, Span}` to a pid per span,
and `otel_exporter_tab` writes into ETS. They are the mechanism behind the official
[testing guide](https://opentelemetry.io/docs/languages/erlang/testing/), and
**`opentelemetry_ash`'s own test suite is a working Ash example of it** —
`:otel_batch_processor.set_exporter(:otel_exporter_pid, self())`, then
`assert_receive {:span, ...}` against `"domain:resource.create"`. So the sink is a thin
consumer over a supported SDK facility rather than a bespoke processor, and the same
facility is what Phase 4's propagation test needs. (Caveat: `set_exporter/1,2,3` is marked
deprecated in favour of `otel_tracer_provider`, which does not export a replacement and
whose hexdocs page 404s. It remains what the official guide documents; expect a warning.)

**(c) Both.** The sink is the dev default and the backend query is the `--trace-id` path.

**Recommendation: (c), built as (b) first.** The in-VM sink is perhaps 150 lines, has no
infrastructure prerequisite, and is what makes the tool usable on a laptop with nothing
running — which is the condition under which an agent will actually reach for it. The
backend query is the production story and can follow once §4 is live. Building (a) first
means the tool is unusable until the collector is, and a dev tool with a prerequisite is a
dev tool nobody adopts.

The sink must be `:dev` (and `:test`) only, and must be bounded — a ring of N root traces,
default 50, dropping oldest. An unbounded span buffer in a long-running `iex-server` is a
memory leak with a nice name.

### 2.4 Dev UX: what a human looks at

Three surfaces, and they are complementary rather than competing:

- **LiveDashboard** (`/dev/dashboard`, already mounted) shows *metrics and process state*.
  It has no trace view and is not going to grow one. It stays what it is.
- **SigNoz, local** is the trace UI, *if it is already running*. That qualifier now carries
  weight. SigNoz is a credible scripted backend — it publishes a machine-readable OpenAPI
  3.0.3 spec (`https://signoz.io/api/api-reference-openapi/latest`, 157 paths), a v5
  `query_range` that takes `filter.expression = "trace_id = '<id>'"`, root-user bootstrap
  environment variables that make first login scriptable, and since 2026-05 an official MCP
  server with `signoz_get_trace_details` / `signoz_search_traces`. It is also five to seven
  containers with a documented **4 GB memory floor**, and its install story changed twice in
  2026 (single-binary merge moved the UI from :3301 to **:8080**; `install.sh` and the
  bundled compose files were deprecated in v0.130.0 in favour of the Foundry tool). Most
  tutorials you will find are stale.

  So: use it when the homelab endpoint is reachable, because then the marginal cost really is
  one environment variable. Do not make it the prerequisite for the dev loop. ADR 0018 names
  LGTM as the *production* destination and routes through a collector precisely so the
  backend is swappable, so pointing dev traffic at SigNoz contradicts nothing — but if a
  laptop-local backend is wanted, **Jaeger all-in-one is one container**
  (`cr.jaegertracing.io/jaegertracing/jaeger:2.21.0`, native OTLP on 4317/4318) and, with
  `extensions.jaeger_query.ai.mcp: {}`, is the only option whose agent surface was explicitly
  designed around a context budget (§2.2). Tempo 2.9+ has the same shape via TraceQL and an
  `/api/mcp` endpoint, and is the smaller reconciliation with ADR 0018 — at the cost of an
  "experimental, not for production" label on that endpoint.

  ⚠️ One non-obvious trap either way: Jaeger **v2.21.0 removed the v1 HTTP search endpoint**
  (`GET /api/traces?service=…`) as a breaking change on 2026-09-14. Script against
  `/api/v3/traces`, which is classified stable; `/api/*` is explicitly "internal and subject
  to change."

- **The collector's `file` exporter** deserves a mention as the zero-infrastructure floor:
  `format: json`, `flush_interval: 1s`, one OTLP-JSON object per line, and the agent reads it
  with `jq`. No server, no auth, no time window, no query language. Stability is alpha and
  it is not a UI, but for "run the thing, read what it just emitted" there is nothing
  simpler. (The `debug` exporter is *not* a substitute — pretty-printed text, not parseable.)
- **A terminal trace viewer** for the case where neither is running. This is the same need
  the in-VM sink serves; `mix ash_agent.trace --pretty` piped through `jq` covers it for an
  agent, and a human gets the SigNoz link.

### 2.5 Always-on or sampled in dev

**Recommendation: always-on in dev, and set it explicitly rather than inheriting a default.**

The arguments for sampling do not apply here. Dev traffic is one developer and one agent;
there is no cardinality pressure and no ingest bill. And the failure mode of sampling in dev
is specifically hostile to the use case: an agent runs an action, asks for its trace, and
gets nothing — not because the instrumentation is broken but because the die came up wrong.
That is indistinguishable from a bug, and an agent will spend several turns chasing it.

Two caveats to state plainly:

- **Turning on the full span set (G2) is not free, and there is a number.** Ash issue
  #2921 ("Allow compiling out Ash's telemetry instrumentation", opened 2026-09-09, closed
  2026-09-16) reports a production-scale Ash test suite emitting **3,853,289 Ash telemetry
  spans per run**; removing them saved ~14s, about 3%. The fix that landed was an O(1)
  handler lookup in `Ash.Tracer.telemetry_handlers?/1` — which is in the 3.33.5 this
  repository is on, and is visible in `deps/ash/lib/ash/tracer/tracer.ex:88-110`. Two
  readings: the per-span overhead is small, and the span *count* is very large. In dev that
  is the point. It should still be measured before it is recommended for prod (§4).
- **Boot cost.** The SDK starts regardless today; enabling an exporter adds a connection and
  a batch processor. This is small, but `iex-server` restart latency is a thing developers
  notice, and the honest answer is "measure it," not "it's fine."

### 2.6 Prior art: this is no longer a novel idea, and that is the good news

When this document was commissioned the dev-assist angle looked speculative. It is not, as
of about four months ago — but the people who built it are platform vendors, not
observability vendors, and nobody has built it for Elixir.

**Microsoft shipped exactly this design for .NET.** The Aspire Dashboard is a standalone
OTLP receiver for local development (`mcr.microsoft.com/dotnet/aspire-dashboard`, in-memory,
UI on 18888). Since Aspire 13.2 (2026-03-31) it exposes an HTTP telemetry API returning OTLP
JSON — `GET /api/telemetry/traces`, `GET /api/telemetry/spans` (with `?follow=true` for
NDJSON streaming), and `GET /api/telemetry/traces/{traceId}` — and `aspire agent mcp` serves
`list_traces` and `list_trace_structured_logs` to a coding agent, with `aspire agent init`
writing the config for VS Code, Claude Code, Copilot CLI and OpenCode. Their own documented
example prompt is the loop this document is proposing, almost word for word: *"inspect the
failed weather request with trace ID `<trace-id>` and the `app` console logs. Explain why the
health check passes, propose the smallest fix, and verify the same request after the fix."*

**Cloudflare shipped it six weeks ago and deliberately chose REST over MCP.**
[*"Your agent can now debug Workers with local tracing"*](https://blog.cloudflare.com/local-tracing/)
(2026-08-04): `wrangler dev` captures OTel traces for local invocations with no SDK and no
config, and when it detects a coding-agent session it prints a hint pointing at a read-only
local query API — queried with **SQL**, with *"an OpenAPI schema, so agents can discover
available endpoints at runtime without hardcoded instructions."* Their worked example is a
diagnosis: *"the KV read succeeded, the D1 insert failed with `no such column:
delivery_window`, and the Queue was never called."* That is the `explain/1` output of §2.2,
for a different runtime.

**Jaeger's ADR 002 is the design document for the hard part** (§2.2) and should be read
before writing `explain/1` rather than after.

**And the argument is older than the tooling.** Jessica Kerr, for Honeycomb, wrote the
clearest version of it in 2023: *"Do add attributes to spans, and new spans as appropriate,
and **look at traces while you're developing locally**."* What changed is that the consumer
is now a program with a context budget, which is what makes the reduction in §2.2 the
load-bearing part rather than the UI.

**For Elixir there is nothing.** Tidewave 0.9.0 exposes `project_eval`, `get_docs`,
`get_source_location`, `get_logs` and `execute_sql_query` and **no telemetry, trace or span
tool**. `phoenix_profiler` is from January 2023 and unrelated to OTel. No Hex package
exposes OTel spans over MCP. The generic OTLP-in/MCP-out projects that exist are tiny — the
most adopted, `traceloop/opentelemetry-mcp-server`, has ~200 stars and supports Jaeger,
Tempo and Traceloop but not SigNoz — and the OpenTelemetry project itself ships no
telemetry-reading MCP surface at all (`extension/mcp` in collector-contrib helps an LLM
*author collector config*).

The handle this repository would need is already one line:

```elixir
OpenTelemetry.Tracer.current_span_ctx() |> OpenTelemetry.Span.hex_trace_id()
```

so a Mix task — or `project_eval` over Tidewave — can run an Ash action, print the trace id,
and hand it straight to whichever backend tool is configured.

**The honest read on originality:** the *mechanism* is well-trodden and there is a design
document from Jaeger and two shipped products to copy from. What is unbuilt is the Elixir
and Ash half — and specifically the symbol-id bridge in §3, which neither Aspire nor
Cloudflare has an equivalent of, because neither has a declarative semantic layer to point
spans back at. That is the part worth claiming.

### 2.7 What this is not

It is not a profiler. Span timings under a batch processor in a dev VM are indicative, not
measurements; `:fprof`/`:eprof` and `tokio-console`-style tools answer a different question.
The trace answers *what ran and in what order*, and that is the question an agent debugging
an Ash action actually has.

---

## 3. The symbol-id bridge

This is the section that makes tracing part of the semantic platform rather than a separate
concern bolted to it.

### 3.1 The idea

A span today says `"security:access_request.record_risk"`. A symbol id from the semantic
manifest says `ash:v0:AshEnterprise.Security.AccessRequest#actions/record_risk`
([RFC §4.3](../rfc/semantic-manifest-v0.md)). The second is a join key into the manifest,
which carries source spans, content digests and the provenance chain that says which `use`
macro injected what.

Attribute spans with the symbol id, and a trace stops being a list of names and becomes a
list of *declarations* — resolvable to a file and line, diffable across commits, and
addressable in an agent transcript that survives a recompile. That is the property RFC §4.3
was designed for, applied to runtime rather than to editor state.

### 3.2 The attributes

```
ash.symbol_id       ash:v0:AshEnterprise.Security.AccessRequest#actions/record_risk
ash.domain          AshEnterprise.Security
ash.resource        AshEnterprise.Security.AccessRequest
ash.action          record_risk
ash.action_type     update
ash.authorize?      true
ash.tenant_id       <uuid>          -- id only, never the tenant struct
ash.actor_id        <uuid>          -- id only; see §3.5
ash.correlation_id  <uuid>          -- the existing join key
```

All but the first come straight from the metadata map Ash already passes and
`opentelemetry_ash` already throws away (G1). The first is derived from
`{resource, dsl_path, name}` — a pure function over data the tracer is handed, no
introspection needed at span time.

`ash.definition_version` — the manifest's `hashes.content` for that action symbol — is
deliberately **not** in the list. It answers "which shape of this action ran", which is
exactly the question the [provenance envelope §2.3](../verification/provenance-envelope.md)
exists to answer, and putting it on every span means a digest lookup per span and a high-
cardinality attribute that changes on every deploy. It belongs on the envelope, which is
written once per action, and the trace joins to the envelope by `correlation_id`.

### 3.3 Where the id comes from

The id grammar is implemented: `AshAgentTools.diff_manifest/2` parses and diffs by symbol id
today, and `Ash.Info.Manifest.Semantic` on the `feature/manifest-semantic-export` branch of
the vendored Ash fork emits them — reviewed on 2026-09-20 in
[`docs/reviews/semantic-exporter-review.md`](../reviews/semantic-exporter-review.md) with a
verdict of *fix first* over four localized defects.

That matters for sequencing but not for feasibility. A span does not need the manifest
*document*; it needs the id, and the id is a string built from three values the tracer
already receives. A ~20-line `AshEnterprise.Telemetry.SymbolId` module produces it with no
dependency on the exporter landing. When the exporter does land, the ids already flowing
through traces join to it with no migration — which is the whole argument for a structural,
non-content-hashed id grammar.

### 3.4 The correlation story, end to end

Right now there are four provenance mechanisms and no single path through them. The
[envelope design §1](../verification/provenance-envelope.md) lays this out; tracing is the
piece that makes the joins actually reachable at runtime.

The coherent version:

```
HTTP request
  └─ Phoenix span              trace_id = T                    (opentelemetry_phoenix)
     └─ LoadActorContext plug  correlation_id = C   <-- stamp T:root_span onto the
        │                                               correlation scope here
        └─ Ash action span     trace_id = T, ash.correlation_id = C, ash.symbol_id = S
           ├─ audit EventLog row    metadata.correlation_id = C, metadata.trace_id = T
           ├─ Ecto query spans      parent = the action span
           └─ Oban job enqueued     job.meta carries {C, T}     <-- G5's other half
              └─ job span           links to T, new correlation preserved as C
```

That diagram assumes G0 is fixed. Until `opentelemetry_bandit` is added there is no `T`
for an HTTP request to inherit, and every leg below the plug is its own trace — so G0 is a
prerequisite for this section, not a parallel concern.

Three concrete changes make the rest real, in increasing order of cost:

1. **`Correlation.audit_metadata/1` gains `trace_id`** (and `span_id`), read from the
   ambient OTel context. Trace ids exist in-process whether or not an exporter is
   configured, so this works today with `traces_exporter: :none` — and an operator who turns
   exporting on later gets historical audit rows that join to live traces. One caveat, from
   reading `lib/ash_enterprise/audit/event_log.ex`: the chain trigger hashes
   `NEW.metadata::text`, so adding a key changes the hash input. New rows are fine; the
   change is additive and does not invalidate existing chain segments, but it must land as
   one commit with the trigger's expectations unchanged.
2. **Span attributes** per §3.2 — requires fixing G1.
3. **Oban propagation** — carry both `C` and `T` in job meta, restore both in `perform/1`.
   This closes G5 and the `Correlation` process-boundary gap in the same middleware, which
   is the right shape: they are two mechanisms with one boundary problem, and ADR 0018
   already notes that "nothing currently reconciles them."

### 3.5 What must not go into a span

ADR 0018 is emphatic and correct: spans must **not** carry `ActorContext`. The precomputed
grant map — business-unit ids, team ids, the privilege set — is the authorization model, and
exporting it into a system with a different access model duplicates the thing this platform
refuses to duplicate.

So: `ash.actor_id` yes, `ash.tenant_id` yes, resolved grants never. §4.2 extends the rule to
field values.

---

## 4. The production transition

The thesis is that there is no transition — same exporter, same span shapes, same collector
protocol, different sampler and different redaction posture. Four things actually change.

### 4.1 Sampling

Dev is always-on (§2.5). Production cannot be, once G2 is fixed: a request that produces one
span today would produce dozens, and the interesting ones are rare.

Head sampling — a ratio decided at the root — is the wrong tool, because the spans worth
keeping are exactly the ones a ratio discards: the errors, the slow tails, the policy
denials. What is wanted is **tail sampling**, which is a *collector* concern and not an SDK
one: the SDK keeps producing every span, the collector buffers each trace until it is
complete and then decides. That is the shape of the policy set worth running here:

- keep **every** trace containing an error status;
- keep **every** trace containing a policy denial (a span attribute the collector can match
  on, which is another reason §3.2's attributes matter);
- keep every trace over a latency threshold;
- keep a low probabilistic sample of everything else, so the healthy baseline is visible.

Concretely, and with the version pinned because this processor moves: collector-contrib
`tailsamplingprocessor` at **v0.161.0 (2026-09-15)**, stability **beta** for traces, 17
policy types. The shape that expresses the list above:

```yaml
processors:
  tail_sampling:
    decision_wait: 10s
    num_traces: 100000
    decision_cache:
      sampled_cache_size: 1000000        # docs: >= 10x num_traces
      non_sampled_cache_size: 1000000
    policies:
      - name: errors
        type: status_code
        status_code: {status_codes: [ERROR]}

      - name: policy-denials
        type: string_attribute
        string_attribute: {key: ash.policy.decision, values: [forbidden]}

      - name: slow
        type: latency
        latency: {threshold_ms: 2000}

      - name: baseline
        type: probabilistic
        probabilistic: {hash_salt: ash-enterprise, sampling_percentage: 5}
```

**Two semantics that are routinely got wrong.** Top-level policies are **OR**'ed — any
"sample" decision keeps the trace — so a `composite` budget placed alongside these does not
cap them; budgeting requires putting everything inside the `composite`. And the deprecated
`invert_match` inverted-decision mechanism was **permanently removed in v0.155.0**; use the
`not` or `drop` policy types instead. Anything written against `invert_match` is already
broken.

Scaling this past one collector requires the `load_balancing` exporter with
`routing_key: "traceID"` — the processor's own README is emphatic that *"all spans for a
given trace MUST be received by the same collector instance."* Note the component was
renamed from `loadbalancing`; the old name is a deprecated alias.

This is the one place the application and the collector are coupled by convention rather
than by protocol: the `policy-denials` policy above only works because something sets
`ash.policy.decision`, which is a span attribute this repository would have to add (§3.2).
That coupling belongs in a comment next to the collector config, not in someone's memory.

### 4.2 Redaction

The rule the [envelope §2.4](../verification/provenance-envelope.md) states for digests
applies verbatim to spans, and more strictly: **a span carries no field values.** Not "no
sensitive values with an allowlist" — an allowlist drifts, and a span is exported to a
system with a different access model and an indefinite retention policy.

Concretely:

- `db_statement` is the one setting that should differ by environment, and the right dev
  value is **not** `:enabled`. `opentelemetry_ecto` accepts a 1-arity sanitizer function
  (G6), so dev gets `db_statement: &AshEnterprise.Telemetry.SqlRedactor.sanitize/1` and prod
  keeps `:disabled`. Ecto parameterizes queries for every adapter this application uses, so
  the leak surface is small — but "small" is not the standard for a document that leaves the
  security boundary, and a sanitizer is the thing that can be reviewed.
- Ash span attributes are ids, names and booleans (§3.2). No changeset attributes, no query
  filters, no action arguments.
- `sensitive?: true` is the manifest's own marker for this, and the manifest already has to
  honour it — RFC §8 makes it the one security prohibition, and the exporter review's
  finding **S-sensitive** is that the current branch emits such values verbatim. Whatever
  fixes that for the manifest is the same predicate a span redactor needs, and it should be
  one implementation. Today the repository has nine `sensitive? true` declarations, all in
  `accounts/token.ex` and `accounts/user.ex`; `ash_cloak` is declared in `mix.exs` and used
  nowhere in `lib/`, so field-level encryption is not currently a second source of truth.
- The dev posture differs on exactly one axis: `db_statement` is enabled in dev, because the
  query text is the point (§2.2, G6). That asymmetry must be configured by environment, not
  by a runtime flag someone can flip in prod.

### 4.3 Retention

Traces are not evidence. The audit log is evidence; the envelope is evidence; a trace is
operational telemetry with a short useful life. 7–14 days of full-fidelity retention plus
whatever the sampled baseline costs is the normal answer, and there is no compliance
argument for more — which is worth saying out loud, because in this repository nearly
everything else is retained forever and the instinct to match is strong.

The one thing that *is* long-lived is the trace **id**, carried on the audit row (§3.4). A
trace id whose trace has expired still tells you that two audit rows belonged to one
request, which is most of the value.

### 4.4 Cardinality

`ash.symbol_id` is bounded by the number of declarations in the application — hundreds, not
millions — so it is a safe span attribute and a safe metric dimension. `ash.tenant_id` and
`ash.actor_id` are unbounded and are safe as *span attributes* (spans are not aggregated by
them) and unsafe as *metric* dimensions. The existing metric tags in `telemetry.ex`
(`:resource_short_name`, `:action`) are already on the right side of that line; the fix for
G7 must not cross it.

---

## 5. Verdict and plan

### 5.1 Feasibility

**Feasible, and cheaper than it looks, with one genuine external dependency.**

The pipeline exists and is correctly shaped. The exporter is configured. The collector is
already available on the author's infrastructure. Nothing in §2, §3 or §4 requires a new
architecture; the work is (i) making `opentelemetry_ash` carry the metadata Ash already
hands it, (ii) a bounded dev-time span sink and one Mix task, (iii) three small propagation
changes. Items (ii) and (iii) are unblocked today. Item (i) is the dependency question.

### 5.2 The `opentelemetry_ash` question: fork, vendor, or contribute

The facts, verified today: 0.1.3, published 2025-07-11, last release fourteen months ago,
recent commits are dependency bumps only. The package is 100 lines. Four of the five
defects in §1.2 (G1, G2, G3, G4) live in those 100 lines.

- **Vendoring** (copy the module into `lib/ash_enterprise/telemetry/` and drop the dep) is
  tempting because the module is tiny, and wrong for this repository specifically. It makes
  a first-class Ash integration into local code that nobody upstream benefits from, which is
  the opposite of the posture the semantic-manifest RFC and the
  [community PR dossier](../rfc/upstream-dossier.md) establish.
- **Forking** is the pragmatic middle and is the pattern already in use — `~/ast-forks/`
  holds forks of ash, clarity, expert and usage_rules, and `ash_agent_tools` is a path
  dependency. A fork unblocks §2 and §3 immediately.
- **Contributing** is the right destination. The changes are small, individually
  defensible, and each has a one-line justification an unfamiliar maintainer can check:
  *"Ash passes this metadata and we drop it"*, *"the default trace_types list contains
  `:flow`, which is not an Ash 3 span type"*, *"Ash actions are `:internal`, not
  `:client`"*.

**Recommendation: fork now, PR the four fixes as separate commits, keep the fork pinned
until they land.** The dossier's playbook applies: ash-project repos are MIT with REUSE/SPDX
headers on new files, Conventional Commits, `mix check` as the CI gate, and features are
discussed before they are coded. G1–G4 are bug fixes rather than features, which is the
easier conversation; G1 in particular is a correctness gap against the documented behaviour
of `Ash.Tracer.set_metadata/2` ("This may be called multiple times per span, and should
ideally merge with previous metadata"), which the current implementation does not do at all.

Open the issue before the PR, and check whether the maintainer wants `set_metadata` to map
onto OTel attributes with an `ash.` prefix or under semantic-convention names — that is the
one decision worth not making unilaterally.

### 5.3 Phases

**Phase 0 — truth (hours, no risk).** Correct `.env.example`'s claim about the default
(G11); correct `manifesto/07` §9 and ADR 0018's three "never called" assertions (§1.3);
correct the `audit-and-telemetry` skill's "every action, query, changeset, validation and
calculation becomes a span" to say what G2 makes true. Nothing here is code. It is first
because every subsequent decision gets made by someone reading one of those four documents.

**Phase 1 — see anything at all (a day).** `opentelemetry_bandit` plus its `setup/1` call,
which is what turns an HTTP request from a handful of orphans into one trace (G0) — this is
the highest value-per-line change in the whole document. Then a `devenv` process or
documented compose file for a local OTLP endpoint, `OTEL_EXPORTER_OTLP_ENDPOINT` in
`.env.example` pointing at it, and a `mix ash_enterprise.demo` run that produces a trace
someone can open. The point of
doing this before the interesting work is that it converts every later change from an
argument into a screenshot. *Risk: none. Prerequisite for judging everything else.*

**Phase 2 — the fork (2–3 days).** G1 (metadata → attributes), G2 (`trace_types` default,
and set it explicitly in this repo), G3 (`:internal`), G4 (`set_handled_error`). Measure the
span volume with the full type set enabled before recommending it for prod. Open the
upstream issue in parallel. *Risk: the measurement comes back bad and G2 has to be
environment-split. That is a fine outcome and worth knowing early.*

**Phase 3 — the dev sink and the agent tool (3–4 days).** The bounded ETS ring, the `:dev`
span processor, `AshAgentTools.Trace.last/1` and `explain/1`, `mix ash_agent.trace`. This is
where the return is, and it is only reachable after Phase 2 because `explain/1` without span
attributes is a list of strings. Add the policy-denial span event
(`Ash.Error.Forbidden.Policy.report/2` output) here; `config :ash, policies:
[show_policy_breakdowns?: true]` is already set in both `config/dev.exs:2` and
`config/test.exs:5`, so the breakdown is already being computed and is simply thrown
away. *Risk: scope creep into a trace viewer. The deliverable is JSON for an agent; the
human's viewer is SigNoz.*

**Phase 4 — the joins (2–3 days).** `trace_id` into `audit_metadata/1`; symbol ids onto
spans; Oban middleware carrying correlation and trace context. Add the first span assertions
to the suite — a propagation test that would fail if the Oban middleware regressed is the
one test that pays for itself. *Risk: the audit chain. The change is additive to a hashed
column, and it must land as one reviewed commit rather than as a drive-by.*

**Phase 5 — production posture (2–3 days).** `opentelemetry_oban`; the collector's
tail-sampling policy set (§4.1); the environment split on `db_statement`; the redaction
predicate shared with the manifest emitter; a reporter attached to `metrics/0` (G8) and
`ash_metrics/0` widened to all thirteen domains (G7). *Risk: cardinality. §4.4 is the rule;
the metric change is the place it gets broken.*

### 5.4 The risks worth naming once more

- **Boot and runtime cost in dev.** Measured in Phase 2, not assumed.
- **Cardinality.** Bounded on spans, dangerous on metrics. One rule, §4.4.
- **The thin dependency.** Addressed by the fork, but a fork is a maintenance liability
  until the PRs land, and "until the PRs land" is not a date the maintainer has agreed to.
- **Scope.** The failure mode here is building an observability product instead of a
  debugging aid. The test for whether a piece of this belongs: *would an agent debugging a
  failing action read it?* The trace viewer fails that test. `explain/1` passes it.

---

## 6. Open questions

1. **Does the dev sink belong in `ash_agent_tools` at all?** That package's contract is
   "nothing is executed against your data" — static introspection. A runtime trace reader
   violates the letter of it. Either the contract gets a stated exception for read-only
   runtime observation, or the trace tool is a sibling package. The Mix-task surface and the
   pure-JSON-stdout convention should be shared either way.
2. **Should `explain/1` be a Tidewave tool or a Mix task?** José's stated position on
   `tidewave` (dossier, PR #215 context) is that MCP tools are expensive context-wise and
   the accepted pattern is a Mix task plus usage rules, invoked through `project_eval`. That
   argues for a Mix task, which is also what §2.2 proposes. Worth confirming rather than
   assuming.
3. **`ash.` prefix or OTel semantic conventions?** §3.2 uses `ash.*`. There is no
   semantic-convention namespace for an ORM-like action layer, and inventing one unilaterally
   is worse than a clearly-vendored prefix — but this is the question to put upstream with
   the G1 PR.
4. **Does the symbol id belong on the span or only on the envelope?** §3.2 puts the id on
   the span and the digest on the envelope. The counter-argument is that a span should carry
   no derived identity at all and the join should always go through `correlation_id`. That
   is cleaner and strictly worse for the dev-assist case, which is the case this document is
   arguing for.
5. **Local backend: SigNoz or the LGTM stack that ADR 0018 names?** §2.4 recommends SigNoz
   locally on availability grounds and notes it contradicts nothing, because the collector is
   the seam. If that seam is not actually going to exist locally, the recommendation weakens
   and the two should match.
</content>
