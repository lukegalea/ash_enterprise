# Gleam tooling lessons, new OTP features, and an OTP/Oban audit for ash_enterprise

*Researched 2026-09-20 by librarian (lib-3; full re-research — the prior claude run's digest had no reusable findings). Verified against primary sources.*

## 1. Gleam tooling — what transfers

### 1.1 Compiler-driven LSP
- The LS ships INSIDE the gleam binary, compiler-as-library (v1.10). Analysis is fault-tolerant BY DESIGN for the LS (errors don't stop analysis; incremental fault-tolerance v1.2→v1.17 incl. package-level). Recompile-on-change WITHOUT side effects: no codegen/BEAM compilation for LS passes; unsaved buffers used; "no chance of code execution from opening a file".
- Reactivity economics: no Salsa-style incremental memoization — (a) compilation batching, (b) a BEAM-codegen daemon amortizing compile latency (v1.6), (c) raw perf (Rust arenas v1.18). Roadmap: compile to Erlang abstract forms (debugger support, line numbers, faster).
- Cross-module semantics from compiler-retained reference graph (find-references/global rename v1.10, extended through v1.18).

**Transfer:** Spark already has the Gleam shape — transformers→resolved DSL state; the semantic manifest ≈ Gleam's reference graph. What we lack is loop economics: "compile IS the language server" for DSLs = a **long-lived host**: dev-only `ash_agent.serve` GenServer/escript daemon that boots once and re-emits the manifest on recompile events (hook point exists: mix.exs `listeners: [Phoenix.CodeReloader, Clarity.CodeReloader]`). Don't build incremental expansion prematurely — Gleam got years from fast-enough FULL re-analysis; the daemon kills the dominant term (mix boot).

### 1.2 Build tool as single source of truth
Gleam's `export package-information` (JSON, for other build tools — motivated by Mix interop). Ours: `mix ash_agent.manifest` as first-class versioned file-checkable export every tool reads (validate/describe/search/diff + external consumers); ast.check is the natural consumer.

### 1.3 Error messages as designed artifacts
Gleam operator errors point at the fix + code action; OTP 28 compiler suggests corrections ("did you mean bar/1,3,4?"). Ash errors are structured but rendering isn't DSL-derived: a manifest-driven "did you mean" (unknown action→nearest; unknown input→nearest field) is cheap because the candidate set IS the manifest. Every validation failure should carry machine-usable did_you_mean metadata.

### 1.4 Docs
OTP 27 Erlang docs = Markdown -doc rendered by ExDoc — BEAM's two languages share one pipeline. One manifest → two renderers (HexDocs-style + agent describe JSON).

## 2. Reactive kaizen loop (replaces batch tool-gaps.log)

The log is empty — the write path is too far from the failure moment. Gleam lesson: diagnostics are emitted on every analysis pass, never filed by hand. Design:

```elixir
:telemetry.execute([:ash_agent, :tool_gap], %{duration_ms: ...},
  %{tool: :validate, question: "...", gap_kind: :unknown_input,
    detail: %{unknown: ["approver_id"], candidates: ["approver", "owner_id"]}})
```

AshAgent.Kaizen.Sink (dev-only GenServer, ETS): unknown_input w/ candidates → structured auto-log; ≥3 distinct sessions/7d → propose alias/doc fix. unknown_action → did-you-mean echo (manifest in memory). fallback_grep → track frequency. Weekly digest reads aggregates, not prose. OTP 27 multiple trace sessions enable tracing the tool subprocess without clobbering tracers.

## 3. New OTP features (version corrections verified)

- **OTP 27 (we run it NOW)**: `proc_lib:set_label/1` — labels on non-registered processes, shown in observer + crash dumps (the symbol-ids-in-observer hook); `:json` module (Jason-class perf); -doc attrs + ExDoc; tprof; native JIT coverage (`+JPcover`) — cheap usage telemetry for which tools get called; multiple trace sessions.
- **OTP 28**: priority messages (EEP-76 — control signals skip backed-up queues: job-cancel/inspect-now); compiler did-you-mean; `erlang:hibernate/0` (75% mem at 1M idle procs — projector population); **Nominal types (EEP-69) in Dialyzer** — path to typing Spark-generated boundaries; **PCRE2 migration — audit flag for `validate match(...)` semantics when we bump**.
- **OTP 29** (May 2026): xref analyses reading like agent tooling (unsafe/undocumented/private function_calls via -doc visibility — mark internal action helpers hidden, get misuse detection free); `graph` module (functional digraphs — supervision trees as diffable data); guaranteed uniform map iteration order (kills a class of tool-output flakes); io_ansi.

## 4. OTP/Oban audit

Inventory: oban 2.24.1 (queues default/bpmn/ash_strangler_ledger; Lifeline rescue_after 5m; Pruner 7d; BPMN crontab sweeps), ash_events projections (leader-monitored servers, 30s Probe → [:ash_events_projections, :lag], DLQ, Rebuilder), **`AshEvents.Projections.Lag.snapshot/0` already completely answers projection-lag** (per-projector name/status/leader_node/lag_events/lag_seconds/dlq_depth).

**Only Oban labels processes today** (executor.ex:116-125). Our projector servers, AshStrangler.Listener, AshBpmn.Triggers.Index, Absinthe batcher, Probe are anonymous in observer/crash dumps.

| Question | Existing primitive | Gap |
|---|---|---|
| Queue backup? | Oban.check_all_queues/1 | no agent wrapper |
| Why did job fail? | retained job rows + errors array + 7d window | no cross-ref to BPMN instance/DLQ |
| Supervisor owner? | Process.set_label (OTP 27) | nothing aggregates; only Oban labels |
| Projection lag? | Lag.snapshot/0 COMPLETE | not surfaced to agents |

**Scoped tool surface (anti-over-build):**
1. **`mix ash_agent.snapshot` — build now** (~150 lines, pure composition: check_all_queues ++ Lag.snapshot ++ labeled-process scan ++ filtered supervisor digest, --tree flag folds supervisor_tree in). In-repo dev task; promote only on second consumer.
2. **`mix ash_agent.job_explain` — kaizen-gate** (≥3 recorded gaps; cross-package joins will churn).
3. Complementary now: **label our long-lived processes** ({:projector, name}, :strangler_listener, :bpmn_trigger_index) so snapshot/observer/crash-dumps share vocabulary; Oban already labels executors.

## Sources
gleam.run/news (v1.10/v1.18 announcements), gleam.run/roadmap, language-server-reference; giacomocavalieri.me/writing/gleam-rust-arenas; erlang.org/blog/highlights-otp-{27,28,29}; erlang.org/doc/apps/stdlib/re_incompat.html; oban.hexdocs.pm/Oban.html; local: mix.exs, config/config.exs, application.ex, devenv.nix, deps/ash_events_projections lag/probe, deps/oban executor, .agents/logs/tool-gaps.log.
