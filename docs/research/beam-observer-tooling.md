# BEAM Observer Ecosystem for Agents & Developers — Research Report

*Researched 2026-09-20 by librarian (lib-4), building on the recovered digest of the killed claude run (9/16 subagent reports recovered + verified; 7 topics re-researched). Local BEAM claims re-probed on this machine (OTP 27.3.4.16 / Elixir 1.18.4). Full source list at the end; legend: [V-L] ran code here · [V] verified against fetched sources · [I] inferred.*

## 0. Headline that changes the premise

**The "is a JSON node_snapshot tool novel?" question is dead** — two projects shipped exactly that in July 2026, both agent-marketed:
1. **observer_cli 2.0.0** (2026-07-14): CLI with `--format text|term|json`, versioned `observer_cli.cli/v1` envelope, normative JSON Schema 2020-12 in the hex package, stable exit codes, identifier redaction. "Production-ready BEAM diagnostics for operators, automation, and AI agents."
2. **observer_web 0.2.8** (2026-07-21): read-only JSON API in-router (`observer_api "/observer/api"`): /system, /processes (etop ranking, cap 1000), /ets, /apps, Resolver-guarded. PR-67 titled "Add read-only JSON API for automation and AI agents."
3. **Voyager** (Software Mansion, Aug-Sep 2026): desktop BEAM inspector with real MCP server (6 read-only tools) — source-available, NOT OSI, free ≤10 employees.

**Consequence: don't build raw JSON snapshots. Remaining gaps = integration**: in-process library access, Ash-aware labeling, trace correlation.

## 1. Inventory (key facts)

- **:observer (Wx)**: display-only, headless-unusable, no programmatic output. **crashdump_viewer** (cdv) is the irreplaceable post-mortem piece; crash dumps are parseable text.
- **Process labels**: `proc_lib:set_label/1` — **OTP 26** (not 27); no `erlang:process_label/0` exists [V-L]. Shown in i/0, observer, crash reports, LiveDashboard 0.9.
- **observer_cli 2.0**: needs recon pinned 2.5.6 on target; CLI = ephemeral hidden-node escript (never injects code — cookie via env/file only); OTP 26-29, JSON needs OTP 27+ controller. **Under-advertised library seam: `observer_cli_snapshot:dispatch/4` is PUBLIC in release builds** — heap-capped monitored worker, JSON-safe map by construction, byte-capped. Also public: observer_cli_diagnostic:capture/2, observer_cli_trace:call/2. Maintainer playbook: issue-first, merges outside PRs in days.
- **:etop**: data path is undocumented async `:observer_backend.etop_collect/1` — timed out as one-shot here [V-L]. Ignore as API; use recon proc_count/proc_window.
- **recon 2.5.6**: alive but release-stalled (2 yrs unreleased master); overwhelmingly programmatic; no JSON (Jason fails on raw output [V-L]). **recon_ex: dead** (2016).
- **:observer_backend / :appmon_info**: in runtime_tools (every release!) but `-moduledoc false` private; sys_info/0 = 40-key proplist [V-L].
- **LiveDashboard 0.9.1** (Aug 2026): process-label display, compact sup trees, :erpc; **zero JSON API, structurally**; `SystemInfo` engine private but probed working (processes/ets/usage/app_tree callbacks — none JSON-encodable raw [V-L]); hot-loads its own BEAM onto remote nodes (code injection — change-control caveat).
- **Tracing**: :sys (get_state/trace — programmatic), :dbg (sessions since OTP 26), redbug 2.1.0 (bounded), extrace, recon_trace (bounded, capture programmatic); Kino.Process renders Mermaid seq diagrams but trapped in Kino.JS (no structured out); msacc available [V-L].
- **os_mon/telemetry_poller**: push-side gauges; telemetry_poller 1.3.0 already in lock ([vm, memory], run queues, system_counts w/ limits).
- **Tidewave ⚠️**: 0.9.0 (2026-08-18) **removed the get_*_schema family incl. get_ash_resources** — our .mcp.json praise describes a tool that dies on the next deps.update; pinned 0.8.2 works. No extension API; project_eval = unsandboxed eval, inspect limit 50 truncation.
- **ash_ai dev MCP**: 3 static tools, zero BEAM runtime introspection. **Nothing on hex ships typed BEAM runtime introspection over MCP** except commercial-ish Voyager; IntelliJ ships debugger MCP tools; Alibaba Arthas MCP is the JVM peer. In-process language-runtime introspection is thin EVERYWHERE — leading-edge, not catch-up.

## 2. Agent exposure gap

- **Today via project_eval (no new deps)**: Process.list+info walks, :sys.get_state (raw terms), :ets.all/info, ~20-line supervisor traversal, sys_info proplist — all Erlang terms, truncated at inspect limit 50 by tidewave. Agent can ask anything, gets elided strings.
- **Two dev deps (hours)**: recon + observer_cli 2.0 → in-process `observer_cli_snapshot:dispatch/4` gives JSON-safe capped maps without escripts; CLI escript works from this machine against any bundling release today.
- **Still novel + cheap**: (a) ~100-200-line **AshAgentTools.Runtime** wrapping dispatch/4 + SystemInfo callbacks + term→JSON normalizer (mix ash_agent.runtime snapshot|top|tree --trace-id); (b) **Ash-aware annotations** (which children are projectors, which ETS tables are Hammer/BPMN); (c) trace_id correlation; (d) MCP exposure (no hex competitor).

## 3. Ash-specific views for THIS app

Projection servers (leader/failover invisible to generic tools), BPMN :bpmn queue + Triggers.Index ETS, strangler listener + ledger queue (poison-row = repeat executing/retry), Hammer ETS tables (noise unless labeled), LiveView processes, Absinthe batcher (classic hidden-queue suspect), AshAuthentication.Supervisor (skip).

**Cheapest high-leverage move: `proc_lib:set_label/1`** on projector servers, trigger index, strangler listener, Hammer clean process — ~10 lines; labels surface in every generic tool incl. LiveDashboard 0.9 + Voyager, turning them Ash-aware.

## 4. Integration with OTel lane (one runtime plane)

Observer = STATE plane; OTel = TIME plane; join on **trace_id** (one-liner: current_span_ctx → hex_trace_id). Runtime JSON objects carry trace_id/correlation_id; with G1 fixed (ash.* span attrs) + labels set, a span ash.domain/resource/action resolves to the labeled executing process — same join-key discipline as symbol-ids. Oban async half: until opentelemetry_oban propagation, queue depth via observer tools + execute_sql_query on oban_jobs. **Do NOT fold observer data into OTLP** — point-in-time introspection ≠ time series.

## 5. Contribution targets (value ÷ effort)

1. **In-repo ash_agent_tools**: AshAgentTools.Runtime wrap + normalizer (S) — gated on fix-14.
2. **In-repo deps**: add recon+observer_cli (dev); LiveDashboard 0.8.7→0.9.1 (compatible); **audit .mcp.json tidewave comment** (0.9.0 removes get_ash_resources — pin vs update is a decision) (S).
3. **observer_web** (MIT, active, already agent-mode): PRs /supervision-tree, /ports, /oban-queues (S-M) — most receptive venue.
4. **observer_cli**: CLI plugin/extension seam for JSON data payloads (real gap — plugins are TUI-only); sup-tree depth cap for deep Oban trees; Mix task wrapper (M). Issue-first (maintainer's own playbook).
5. **Oban**: set_label on worker processes (S, issue-first).
6. **LiveDashboard**: do NOT PR a JSON API (structurally out; #411 sat 3.5yrs).
7. **opentelemetry_ash G1-G4**: done — draft PR #75 open.
8. **Voyager**: tool requests upstream; license caveat.
9. **OTP long game**: one EEP/discussion on stabilizing observer_backend snapshot API.

## 6. Corrections to priors

observer_cli is agent-first since 2.0 (don't plan "gain --format json upstream" — shipped); recon_ex dead; proc_lib:set_label is OTP 26 not 27 and there's no erlang:process_label; tidewave 0.9 kills get_ash_resources; LiveDashboard injects code remotely (vs observer_cli's no-injection rule); mix app.tree is build-time only.

## Open questions
observer_web response payload shapes (endpoint list verified, bodies unread); recon on OTP 29 (absent from its CI despite observer_cli claiming 26-29); live_debugger (Software Mansion) unverified — merits its own pass if LiveView debugging becomes a lane.

## Sources
github.com/zhongwencool/observer_cli (+ v2.0.0 schema) · observer_web PR-67 · software-mansion/voyager · phoenixframework/phoenix_live_dashboard (system_info.ex) · erlang.org OTP observer notes + proc_lib docs · ferd/recon · tidewave CHANGELOG · ash-project/ash_ai · local probes /tmp/obs2.exs,/tmp/obs3.exs; recovered subagent reports at /tmp/opencode/observer_reports/.
