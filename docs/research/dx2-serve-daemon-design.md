# DX-2 Design Brief: `ash_agent.serve` — supervised MCP daemon for `ash_agent_tools`

*Author: oracle lane ora-1, 2026-09-21. Status: design approved-for-implementation, gated on LAWS-1 lane finishing in ash_agent_tools (write-scope conflict).*

## 1. Transport decision: **Plain Plug-based MCP-over-HTTP on supervised Bandit. Reject Anubis.**

### Comparison

| Dimension | Anubis MCP (`anubis_mcp` 2.0.0) | DIY Plug + Bandit |
|---|---|---|
| **Dependency risk** | Sole maintainer (zoedsoupe); **28 releases 0.13.0→2.0.0 in ~1 year** — a documented breaking-change treadmill. **LGPL-3.0** — a real problem for `ash_agent_tools`' MIT distribution story (awesome-list consumers, future hex publish). Required deps: `finch` (an HTTP *client*, useless to a server; drags mint/castore) and `peri` **exact-pinned `0.9.0`** — exact pins cause resolver conflicts in graphs; this repo has 100+ deps. | **Zero new deps.** Bandit `~> 1.5` is already the endpoint adapter (`mix.exs:353`); Plug/Jason present; `file_system` already transitive via `phoenix_live_reload` (dev). |
| **MCP spec compliance** | Tracks spec revisions for you — the one genuine argument for it. | Bounded: our surface is 7 request/response tools. initialize handshake + `tools/list` + `tools/call` + `ping` + JSON-RPC error codes. Precedent sizing: tidewave's MCP-over-HTTP core is **32-line `http.ex` + 352-line `handler.ex`**; ash_ai's `server.ex` is **1,360 lines only because it supports three protocol revisions in tandem**. We need one revision family (initialize-based; degrade to `2024-11-05` — the repo *already* does this pinning for `AshAi.Mcp.Dev`, `endpoint.ex:57–59`, with the comment "many tools need the older version"). Estimate: **~350 lines**. |
| **Streaming (SSE)** | Provides SSE/WebSocket channels. | **Not needed.** Deterministic request/response tools; no server-initiated notifications. Spec permits POST-only servers (GET → 405, compliant clients tolerate). SSE can be added later via chunked Plug responses if a progress-notification need ever appears. |
| **Auth for localhost** | Its own auth abstractions (`jose` optional dep for JWT — overkill). | Bandit bound to `127.0.0.1`; optional bearer token from config for defense-in-depth. Surface is read-only introspection, so worst case is schema disclosure to local processes — acceptable, token optional. |
| **Maintenance burden** | Upgrade treadmill driven by someone else's 2.0 breaks; LGPL review; dep-solver risk. | ~350 lines we own, mirroring two patterns already running in this repo's endpoint. Tool-surface churn stays under our gate (see §2.4) — which is the *actual* lesson of the tidewave 0.8.2 pin: server-side tool removal forced client pain. |
| **Client-upgrade pressure** | SDKs chase newest spec revision; the 2025-06-18→2026-07-28 transitions are exactly what strands older clients. | Same shape as the two existing `.mcp.json` entries (`"type": "http"`, localhost URL). No client upgrade required; works with tidewave-0.8.2-era client stacks. |

### Recommendation and rationale

**Build the Plug.** The decisive facts: (1) Anubis's LGPL-3.0 license conflicts with the MIT package's distribution goals (`codicil-assessment.md` already earmarks this package for hex + awesome-list); (2) its exact-pinned `peri` + required `finch` add solver/weight risk for capability we don't use; (3) the DIY cost is small and *known* — tidewave demonstrates that a compliant MCP server is ~400 lines when you don't chase every revision, and DX-2 needs no sessions, no SSE, no resources/prompts/sampling; (4) the repo's own `AshAi.Mcp.Dev` pin to `2024-11-05` proves client lag is real and that first-party control of protocol-version behavior is the mitigation. The one thing Anubis would buy — someone else tracking spec churn — is precisely the dependency the tidewave pin teaches us not to acquire.

## 2. Architecture sketch

### 2.1 Placement

The daemon is a **separate BEAM OS process with its own minimal supervision tree** — not a child of `AshEnterprise.Supervisor`. The main tree boots Repo, Oban, projectors, the legacy listener, the endpoint (`application.ex:15–41`); mounting there would violate iron law #23 and destroy the verified compile-only property (72 resources, zero apps started). Entry point: a new `mix ash_agent.serve` task in the ash_agent_tools package (`@requirements ["app.config"]`), which starts the tree and blocks — **law #14 compliance**: every long-lived process is supervised, explicitly rejecting tidewave's own README pattern (`Agent.start(fn -> Bandit.start_link(...) end)` — the exact anti-pattern the iron-laws doc flags).

### 2.2 Supervision tree

```
AshAgentTools.Daemon.Supervisor            (one_for_one; started by `mix ash_agent.serve`)
├── AshAgentTools.Runtime                  (GenServer — the compiled-context owner)
│     • init: ensure_compiled() + load_configured_domains()   [reuse TaskOutput helpers;
│       fine inside this VM because it boots under Mix]
│     • state: compiled_at, discovery summary, per-module describe cache keyed by
│       module + beam checksum, reload mutex, kaizen digest
│     • serializes recompiles so concurrent tool calls can't race module purge/load
│     • emits [:ash_agent, :daemon, :reloaded] telemetry; invalidates caches
├── AshAgentTools.Watcher                  (GenServer wrapping :file_system backend —
│     watches lib/, config/; 300ms debounce → Runtime.request_reload/0)
└── {Bandit, plug: AshAgentTools.Mcp.Plug, ip: {127,0,0,1}, port: 4100}
```

### 2.3 MCP surface (Plug pipeline → JSON-RPC dispatch)

`AshAgentTools.Mcp.Plug` mirrors tidewave's shape: reads the body itself (no Plug.Parsers dependency), dispatches on method:

- `initialize` → serverInfo + `capabilities: %{tools: %{}}`, protocol version negotiated down to the client's request (initialize-based revisions; `2024-11-05` accepted)
- `notifications/initialized` → 202
- `tools/list` → tool cards; `tools/call` → `content: [%{type: "text", text: json}]`, `isError` for structured failures
- `ping` → `{}`; GET → 405 (POST-only server, spec-permitted)
- Stateless — no `Mcp-Session-Id`; spec allows omitting it

Tool mapping (facade is pure, maps 1:1 — the moduledoc already promises this):

| MCP tool | Facade call | Notes |
|---|---|---|
| `ash_describe` `{resource, action?}` | `describe_resource/1` / `describe_action/2` | no-arg → discovery summary (domains + resources) — folded, not a separate list tool, to avoid colliding with tidewave's `get_ash_resources` |
| `ash_validate` `{resource, action, params}` | `validate_input/3` | flagship — validate-by-casting without execution |
| `ash_search` `{term, kinds?}` | `semantic_search/2` | |
| `ash_context` `{file, line}` | `context/3` | collapses grep→read→re-grep |
| `ash_forbidden` `{resource, action}` | `explain_forbidden/2` | policy listing (guidance, not verdicts) |
| `ash_diff` `{old, new}` | `diff_manifest/2` | optional in v1; pure file read |
| `ash_daemon_status` / `ash_reload` | Runtime | compiled_at, resource count, cache stats; manual reload backstop |

`ArgumentError` from bad input maps to the structured-error pattern the mix tasks already implement (`emit_describe_error` with `did_you_mean` — `ash_agent.describe.ex:133–145`).

**Deliberately excluded:** the `edit` tool stays a mix task (write-path; the daemon's identity is read-only, which also keeps the loopback-auth question trivial), per the Codicil 0.5.0 subtract-to-avoid-overlap rule (`project_eval`, SQL, file-edit neighbors all belong to tidewave or the shell).

### 2.4 Boot + hot-reload + pre-launch gate

- **Boot:** compile-only, exactly as the tasks do — `app.config` + `Mix.Task.run("compile")` under quiet shell + `load_configured_domains/0` (`task_output.ex:30–42, 120–135`). No `app.start`. The ~15s mix-boot is paid **once** at daemon start; every tool call thereafter is in-memory.
- **Hot reload:** Watcher fires on `lib/`/`config/` change → Runtime re-runs compile + `load_configured_domains`, invalidates checksum-keyed caches, logs the resource-count delta. Tool calls stay eventually-consistent reads over `:code.all_loaded()`; recompiles are serialized behind the Runtime GenServer. `ash_reload` covers watcher misses (git stash edge cases).
- **Pre-launch trigger-eval gate** (iron-laws adoption item): build `eval_set.json` with should-trigger queries ("what does Post create accept", "validate these params", "why was this forbidden") and should-not neighbors ("run this SQL" → tidewave, "edit the file" → edit tools, "which routes exist" → grep/phx.routes). Run the skill_eval machinery against the daemon's tool descriptions; **75% per-tool gate**; label failures by the phxagents taxonomy (missing term / too-broad scope / neighbor collision — the folded discovery summary directly serves the collision case). Sequence: daemon on scratch port → eval harness drives a real client at it → gate green → merge → add to `.mcp.json`. Post-launch, Kaizen telemetry (`[:ash_agent, :tool_gap]`, attach/digest already in the package) becomes the fire-rate metric — the meta-finding that only 19/51 skills are ever invoked is the KPI this guards.

## 3. Risks and open questions for Luke

**Risks**
1. **Recompile races:** a module purge mid-tool-call can raise. Mitigate: catch-and-retry-once with `Code.ensure_loaded/1`; serialization bounds the window. Residual risk acceptable for dev introspection.
2. **Worktree port collision:** `.mcp.json` is committed and points at one port; `.slim/worktrees/*` are separate checkouts with separate `_build`s — two daemons would fight over 4100. *Needs your call* (see Q2).
3. **Memory drift across many reloads** (retained old module versions, cache misses): cheap to restart; expose `compiled_at` + BEAM size in `ash_daemon_status` so staleness is visible.
4. **Client SSE probing:** some clients open GET before POSTing. POST-only is spec-tolerated and both repo-configured servers already live with it — but verify against OpenCode *and* Claude Code in the gate, not just the spec.
5. **Anubis remains the wrong kind of tempting:** if we ever want its ideas (schema-driven tool defs via `peri`), read, don't import — LGPL + exact-pin make it a non-starter for this package.

**Open questions**
1. **Package placement of the Plug:** implement `Mcp.Plug` + `Daemon` + `serve` task *inside ash_agent_tools* (Plug optional dep, Bandit stays the host's — the Codicil `Code.ensure_loaded?`-gated mount pattern, preserving the MIT hex story), or keep it in-repo as an `AshAgentTools.DevTools` bridge until the ash_ai DevTools seam experiment (Lane E) informs the shape? Lean: in-package, since the daemon must work without any host app running.
2. **Worktree story:** one daemon for the main checkout only, or port derived from cwd hash so each worktree gets its own? (Lean: main checkout only for v1; worktree agents keep the mix-task surface.)
3. **Port + token defaults:** 4100 okay? Token config-gated default-off, or always-on with the token printed at boot?
4. **`ash_diff` in v1 or deferred?** It reads manifest files the RFC exporter doesn't emit yet (`mix ash.manifest.dump --semantic` is future work) — arguably dead weight until that lands. Lean: defer.
5. **Gate mechanics:** run the trigger-eval as a CI job (needs a bootable daemon + client harness in CI) or as a pre-launch local script with results posted to the PR? CI is the kaizen-loop-consistent answer but costs setup.

---

**Bottom line:** DIY Plug, ~350 lines, zero new deps, one protocol revision family, separate supervised compile-only VM, hot-reload via the already-present `file_system`, launch gated by the 75% trigger-eval harness. Anubis loses on LGPL, churn (28 releases/yr, 0.x→2.0), exact-pinned deps, and forced client-upgrade pressure — the exact failure mode the tidewave 0.8.2 pin documents.

## 4. Reconciliation with librarian research (lib-1, 2026-09-21)

lib-1 recommended **Anubis MCP 2.x (`~> 2.0`)** as ecosystem default (~172K dl/30d; spec hard parts fixed via real interop failures: Last-Event-ID resumability, session races, atom-exhaustion DoS). Reconciled decision: **DIY Plug stands; Anubis is the designated fallback.** Rationale:

1. **Anubis's proven value is in the parts we don't implement.** Our server is stateless, POST-only, tools-only — no `Mcp-Session-Id`, no SSE, no resumability, no distribution. The interop bugs Anubis fixed in July 2026 live almost entirely in those features.
2. **lib-1 confirmed client viability of the minimal server**: both Claude Code (TS SDK 1.x, max 2025-06-18) and opencode accept a POST+JSON-only tools server with Origin check + bearer header. No client upgrade pressure either way.
3. **Design amendments adopted from lib-1 (spec MUSTs, add to build spec):**
   - Validate `Origin` header on every request (DNS-rebinding protection) — reject non-local origins.
   - Handle `MCP-Protocol-Version` request header post-init: absent → assume `2025-03-26`; invalid → 400.
   - `202` (no body) for notifications/responses; `DELETE` → 405 alongside GET.
   - `Accept: application/json, text/event-stream` tolerated; always reply `application/json`.
4. **Escalation trigger**: if the pre-launch trigger-eval gate (§2.4) or manual Claude Code + opencode + MCP Inspector smoke tests surface interop failures we can't fix cheaply, switch to Anubis 2.x pinned `~> 2.0` (per its documented deprecation policy this behaves like our tidewave 0.8.2 deliberate pin). LGPL is acceptable for an app-level dep; it only blocks the in-package (ash_agent_tools hex) placement variant — which remains Luke's open question #1 regardless.
