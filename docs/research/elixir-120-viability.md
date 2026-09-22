# Raising ash_enterprise's minimum Elixir to 1.20 — viability report

*Researched 2026-09-20 by librarian (lib-2). Elixir 1.20.0 GA 2026-06-03; current stable 1.20.4 (2026-08-28); main is 1.21-dev.*

## 1. Local floors (four, not one)

| Surface | Pin | Source |
|---|---|---|
| Hex-declared floor | `elixir: "~> 1.17"` | mix.exs:8 |
| devenv (main + all 3 worktrees) | Elixir 1.18 / OTP 27 | devenv.nix:10,33 |
| CI | OTP 27.3 + Elixir 1.18.4 (both jobs) | .github/workflows/ci.yml:44-46,182-185 |
| Docker | 1.18.4 / 27.3.4 (must never disagree w/ above) | Dockerfile:10-11 |
| Agent toolchain | 1.19.5 / OTP 27 | (used to build+test the semantic-exporter branch) |

## 2. Load-bearing deps (locked)

ash 3.33.5, spark 2.7.3, phoenix 1.8.14 (=latest), phoenix_live_view 1.2.12 (=latest), ecto 3.14.2, oban 2.24.1 (=latest), ash_authentication 4.15.0, ash_postgres 2.13.1, ash_graphql 1.11.0, ash_oban 0.8.14, ash_events 0.7.0, clarity 0.6.0, tidewave 0.8.2, req 0.7.4, dialyxir/credo/sobelow; first-party git deps: ash_a2ui, ash_strangler, ash_rules, ash_compliance, ash_bpmn, ash_decisions; path dep ash_agent_tools (dev-only).

## 3. Per-dep 1.20 status

- **Phoenix**: CI on main includes {1.20.4/OTP 29, lint + tests + docs --warnings-as-errors} — warning-clean on 1.20. Floor still ~> 1.15.
- **Ash ecosystem**: upstream develops on Elixir 1.20.0/OTP 29.0 (ash .tool-versions); ecosystem rollout tracked in ash-project/ash#2745. Spark compiles itself warnings_as_errors: true → warning-clean by construction. Known: igniter#357 (unused require on 1.20 — verify fix in >0.8.4). No blocking issues found.
- **Expert (Lane C)**: main is 1.20-first (.tool-versions elixir 1.20.0; matrix builds on 1.20/OTP 29). Support table still tops at 1.19. Ride Expert main; elixir_sense-internal compat unverified for 1.20.
- **Ecto family**: actively tracks new-Elixir deprecations.
- **Watch items (non-blocking)**: tidewave CI on 1.18 only; clarity floor 1.18, no 1.20 signal; oban dead-clause warnings may grow under 1.20's redundant-clause warnings (deps compile outside our WAE gate — keep it that way).

**Zero blocking dependencies.**

## 4. What 1.20 gives this program

- **Native type checker**: whole-function inference, guard inference (`is_map_key` ⇒ typed maps with `not_set()`), refinement across clauses, occurrence typing, full Map module typing, redundant-clause/dead-code warnings. Our 68 Ash resources' generated functions get inferred and cross-checked — high verification value, high initial noise. This is the bridge target of Lane D's type algebra.
- **Compile-time levers for our shape**: `module_definition: :interpreted` (targets giant defmodule expansions — Spark; benchmark first), background module purging, batched type-checker cache ops (1.20.3), per-module type-check times via `compile profile: :time` (1.20.2), parallelized dep-lock checks, `Kernel.ParallelCompiler.each_long_verification_threshold/1`.
- **dbg** intermediate pipes; `mix source MODULE`; `mix test --dry-run`; `mix help Mod` types/callbacks.
- **Perf pathology was real but fixed**: #15145 (7x compile slowdown rc-2), #15195, #15285, #15410 — all closed by spring 2026. **Canary on 1.20.4, never 1.20.0.** Instrument long verifications — large generated Ash shapes are the stress class.
- **Deprecations to sweep first**: pin bit-pattern sizes; `require(M).macro()` no longer expands (audit our Spark/igniter extension usage); `File.stream!/3` arg order; `xref: [exclude:]` → `elixirc_options: [no_warn_undefined:]`; Logger `:backends` → handlers (check config/config.exs); struct-update needs prior match; `Code.compile/require` needs `return_diagnostics: true`.

## 5. Lane C impact (module reload / Code.Fragment)

1.19: modules no longer auto-loaded after compilation; lazy loading. 1.20: purging opt-in + background deletion — biggest semantic change for reload tooling; Code.Fragment richer cursor contexts + sigil metadata. ElixirLS author actively filed 1.20-era bugs through Aug 2026 — converging. Implication: ride Expert main; treat elixir_sense-internals as unverified until its support table gains a 1.20 row.

## Verdict

(a) **Safe minimum today: keep ~> 1.17 declared (or bump to ~> 1.18 to match tested reality). Do NOT make 1.20 the minimum yet** — but zero blockers for canarying today.
(b) Blocking deps: none. Watch: ash#2745, igniter#357, clarity/tidewave CI, elixir-sense compat.
(c) Adopt now: 1.20.4 CI canary (allowed-failure), warnings inventory (no WAE, bucket counts), config audits (Logger backends, File.stream!, unpinned bit sizes, require(M) patterns), sweep lib/ + first-party git deps. Wait: raising the floor, `module_definition: :interpreted` (benchmark), Expert toolchain switch, OTP 29 pairing (releases bake ERTS — canary pins OTP 27.3.4, identical ERTS to prod).
(d) **Canary plan**: (1) ci.yml matrix {1.18.4/27.3} + {1.20.4/27.3.4, continue-on-error} + separate canary-warnings job bucketing new warnings (redundant clause / unused require / type violation / deprecation) as burn-down metric; keep per-elixir cache keys. (2) Instrument each_long_verification_threshold (10s) + weekly `mix compile --profile time`; MIX_OS_DEPS_COMPILE_PARTITION_COUNT timing comparison. (3) Fix order: lib/ (only WAE-gated code) → first-party git deps after ash#2745 lands → flip devenv + Dockerfile + CI primary in ONE commit → then raise mix.exs floor to ~> 1.18/~> 1.19.

## Resolution (2026-09-22)

Executed per the plan, accelerated by issue #14 (the dep train — boxic_feel/boxic_dmn declare ~> 1.20.0, clinic-demo's runtime config uses 1.20 regex syntax) making 1.20 a requirement rather than a preference. The canary leg went fully green on 1.20.4/27.3.4 — including `mix compile --warnings-as-errors`, credo, and the suite — so the burn-down reached zero and the flip happened as one commit: devenv.nix (`elixir_1_20`), Dockerfile (1.20.4), ci.yml (single 1.20.4/27.3.4 gate leg; canary matrix, step-level continue-on-error tags, and the canary-warnings inventory job retired; the long-verification instrument kept on the test step), and the mix.exs floor raised to `~> 1.20` directly (skipping the plan's interim ~> 1.18/~> 1.19 floors, since the train requires 1.20 anyway). OTP stays 27 per §5(d): releases bake ERTS; the OTP-29 pairing remains a separate later flip. Dialyzer (advisory) moved to the same pairing with a version-keyed PLT cache.
