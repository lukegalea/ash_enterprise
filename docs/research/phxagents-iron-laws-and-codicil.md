# phxagents "26 Iron Laws" + Codicil Status — Research & Integration

*Researched 2026-09-20 (lib-6). ✅ verified primary source · ⚠️ inferred.*

## Thread 1: phxagents (phxagents.dev = oliver-kriska/claude-elixir-phoenix, 555★, MIT, v3.1.0 Aug 2026)

Docs-site brand; repo is a Claude Code plugin (`/phx:*`) with generated skills-only targets for Amp/Codex/Pi/OpenCode/DeepSeek. Solo maintainer (Oliver Kriska). Origin: every file model-generated, audited against 3 production Phoenix codebases + 1,351 session transcripts; "every Iron Law is a scar." Ships an `ash-framework` skill + ash-policy-reviewer/query-optimizer/resource-designer agents (took 4 months; precedent for Ash-aware tooling demand).

### The 26 Iron Laws (canonical at phxagents.dev/iron-laws) — summary
- **LiveView (6)**: #1 no unconditional DB queries in mount (mount runs twice; assign_async default; dead-render IS crawler HTML) · #02 streams for lists >100 · #03 connected? before PubSub · #18 check changeset errors before UI debugging · #21 never assign_new for per-mount values · #24 match {:error, %Ecto.Changeset{}} explicitly.
- **Ecto (6)**: #04 never :float for money · #05 pin ^ in queries · #06 separate queries has_many / JOIN belongs_to · #15 no implicit cross joins · #17 dedup before cast_assoc · #19 hidden inputs for required embedded fields.
- **Oban (3)**: #07 idempotent jobs · #08 string-key args · #09 store IDs not structs.
- **Security (3)**: #10 no String.to_atom on user input · #11 authorize in EVERY handle_event · #12 never raw/1 untrusted.
- **OTP (2)**: #13 no process without runtime reason · #14 supervise all long-lived processes.
- **Elixir (4)**: #16 @external_resource for compile-time files · #20 wrap third-party APIs · #23 mix tasks start ONLY what they need (app.config + ensure_all_started, never app.start) · #25 capture locale before spawning.
- **Verification (1)**: #22 verify before claiming done — run mix compile && mix test and show the result.
- **Style (1)**: #26 comments aren't commit messages (keep only durable facts).
Plus an iron-law-judge agent (per-law grep patterns, DEFINITE/LIKELY/REVIEW tiers, violations-only output).

### Meta-findings that matter MORE than the laws (measured, Origin page)
- **Prose doesn't fire; hooks do**: CLAUDE.md routing prose fired 0/160 sessions; hook-injected hints followed 27.4%; autonomous model routing 0 ever.
- **Eval harness for tool/skill descriptions**: 51 fixtures, 269 should + 233 should-not, 75% per-skill gate; failure taxonomy = missing term / too-broad scope / neighbor collision.
- **Eval sets leak** (38/42 files embedded hints).
- **Tidewave-style runtime MCP context hints convert at 9%** — "still bad and in it today."
- **19/51 skills ever invoked**; hook-injected content is what arrives.
- Hooks deliberately fail open.

### Our stack vs the laws
**Satisfied**: #22 (our program IS this law mechanized — validate-by-casting), #10 (one compile-time-constant String.to_atom, compliant; String.to_existing_atom would be pure), #26 (mostly). **Adopt**: #23 (audit all mix tasks for app.start — DISPATCHED), #14 (DX-2 daemon = supervised Bandit child, NOT standalone-alias Agent.start), context-economy lessons (hook-inject the mandate where harness allows; formalize tool-gaps.log into fire-rate metrics), description trigger-evals before DX-2 launch (use our skill_eval machinery + their taxonomy). **N/A**: the Phoenix-app laws govern apps we build (relevant for the CAPSTONE demo code!), not our tooling — run the judge's greps over demo code as a CI check there. **Ahead of their curve**: deterministic trace.explain vs their 9%-conversion Tidewave hints.

## Thread 2: Codicil — ✅ ARCHIVED Mar 25 2026, read-only. Do NOT contribute.
Archive notice verbatim: *"I did not notice any significant difference in coding assistant performance when using this (and it was almost never called). YMMV. Please feel free to fork."* (ityonemo/E-xyza; 45★; 2 unanswered issues; 1 external PR merged on archive day.) Issue #3 (OPENAI_BASE_URL ignored) is real but moot upstream. **Validation of our bet**: two independent measured confirmations that LLM-dependent agent tooling doesn't get invoked, and deterministic metadata-native tools survive. Patterns still worth stealing for DX-2 (from a fork, not a PR): Plug-mounted MCP behind Code.ensure_loaded?, tool-description overrides via config, subtract-tools-to-avoid-MCP-overlap rule (their 0.5.0), tracer→GenServer→batch indexing with checksum change detection. Check the 4 forks + wende/cicada for active successors before any fork.

## AshAI decision (Luke's question, grounded via deepwiki)
ash_ai already has `AshAi.DevTools` (list_ash_resources/get_usage_rules/list_generators) behind `tools: :ash_dev_tools`, and third parties add MCP tools by defining Ash actions + the `tools` DSL block — the extension point exists. **Verdict: keep ash_agent_tools separate; integrate, don't fold.** Rationale: (1) determinism/no-LLM/no-provider-keys is our identity — ash_ai couples to LangChain/providers and runtime AI scope; (2) release cadence + review gate control; (3) separate hex package is the distribution unit the awesome-list/serena world consumes. **But dogfood the seam**: expose ash_agent_tools' describe/validate/context/search AS custom MCP tools through ash_ai's DevTools extension pattern in ash_enterprise (an `AshAgentTools.DevTools` bridge) — and if that proves clean, offer the bridge upstream as a draft PR. This gets AshAI-distribution without coupling. Fold law #14/#23 + hook-mandate + trigger-evals into DX-2's spec.
