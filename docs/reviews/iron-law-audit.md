# Iron-Law Audit — Mix Task Boots + Repo Greps (2026-09-20, exp-2)

Read-only audit; nothing modified. Feeds LAWS-1 (judge greps) and the boot-fix queue.

## Law #23 — what app.start costs here
Full tree: Oban (consuming jobs mid-task), AshEvents.Projections.Supervisor (draining), legacy pg_notify listener, PubSub/Absinthe batcher. Endpoint port is NOT bound by plain app.start (that's serve_endpoints/phx.server) — the harms are side effects + boot time.

## Verdicts
**GOOD (exemplars)**: legacy.setup (`@requirements ["app.config"]`), roadmap (`[]`), cdm.gen.resource (none); ash_agent.diff/gaps (none, documented).

**ash_agent_tools describe/search/validate/context — OVERBOOT (highest value fix)**: full app.start + the already-written explicit `load_configured_domains()` (task_output.ex:73-80, Code.ensure_loaded over :ash_domains). The explicit load makes app.start redundant — these are the highest-frequency calls in the repo (mandate runs them before every grep), each paying full boot incl. Oban side effects. Fix: `app.config` + compile + load_configured_domains.

**ash_enterprise OVERBOOT** (all need only Repo+Ash → legacy.setup pattern): demo, audit.export, audit.verify (worst: "verify integrity" consumes Oban jobs), legacy.project, bpmn.publish (runs every deploy), seed, compliance.seed. **bpmn.setup** JUSTIFIED-ish (Oban load-bearing). **ast/check** OVERBOOT (introspection needs compile, not a started app — it's the CI gate). **ash_enterprise.trace** low-priority overboot (env-gated sink only). **ash_agent.runtime** justified (full tree is the point).

## Iron-law greps (violations only)
- **LIKELY** ash_agent_tools describe.ex:263 + validate.ex:367 — unrescued `String.to_existing_atom` on agent-supplied action name → raw ArgumentError breaks the "stdout is pure JSON, always" contract; non-deterministic (succeeds if atom happens to exist). Fix: rescue → structured unknown-action JSON error.
- REVIEW runtime.ex:468 (--sort), forbidden.ex:125 — same class, colder paths.
- REVIEW action_invoker.ex:234, assignment_resolver.ex:158 — defensible (closed sets, rescued/contained); logged.
- REVIEW cdm.gen.resource.ex:307,321 — DOUBLE→:float mapping can generate :float for amount-like columns (none in lib/ today); consider :decimal + note.
- **Clean**: raw/1 (zero), :float money attrs (zero), unpinned filter interpolation (zero; user_drain_worker SQL is $n-params + literal module attrs), unsupervised long-lived processes (zero — trace_sink child_spec properly supervised), String.to_atom (one compile-time constant, safe).

## Fix queue (by value)
1. ash_agent_tools introspection tasks: drop app.start (gated on fix-17 landing — same repo).
2. ash_agent_tools: rescue to_action_name ArgumentError (same gate).
3. ash_enterprise audit.verify + bpmn.publish first, then seed/compliance.seed/legacy.project/demo/audit.export → app.config + explicit Repo start (gated on fix-18 landing — same repo).
4. ast/check → compile-only boot.
5. cdm.gen.resource decimal default.
6. Low: trace task (start only sink child), bpmn.setup (marginal), runtime (leave).

Kaizen note: ash_agent tools inapplicable to this audit's questions (boot config + lint greps, not resource introspection) — expected, not a tool gap.
