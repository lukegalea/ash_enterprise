# ADR 0007 — Dialyzer runs, and does not gate

- **Status:** accepted
- **Date:** 2026-08-13

## Context

Dialyzer is conventional in mature Elixir projects, and a reference application
that omitted it would look careless. But this codebase is built on Spark, which
constructs resources through heavy macro expansion, and that interacts badly
with success-typing analysis.

Research found, and this is the substance of the decision:

- **No official guidance exists.** Neither Ash nor Spark documents running
  Dialyzer against generated code. There is no troubleshooting page.
- **No canonical ignore file is published.** Every project solves it privately.
- The only public evidence is anecdotal — an ElixirForum thread reporting a
  `false can never match type true` warning from AshPostgres-generated repo code.
- Spark's own documented limitation is that DSL errors cannot point at source
  locations, which is the same root cause: the code Dialyzer analyses is not the
  code anyone wrote.

Meanwhile the alternatives have improved. Elixir 1.18 ships a set-theoretic type
checker that runs at compile time, understands macro-expanded code, and reports
against real source locations. `ash_credo` adds Ash-aware static checks.

## Decision

**Dialyzer is included, cached, and runs in CI as a separate `continue-on-error`
job. It is advisory. It does not gate.**

The gates are:

1. `mix compile --warnings-as-errors` — including Elixir 1.18's type checker
2. `mix credo --strict` with `ash_credo`
3. `mix ash.codegen --check` — schema drift
4. `mix test`
5. `mix sobelow --config --exit` and `mix hex.audit`

`.dialyzer_ignore.exs` is committed **empty**, with `list_unused_filters: true`
so stale entries are reported. Entries are added only after seeing a warning and
confirming it is spurious, each with a reason and a date.

## Why not simply drop it

Two reasons.

It does find real defects that the compiler does not — impossible pattern
matches, unreachable clauses, contract violations in hand-written code, which is
most of `lib/ash_enterprise/security/`.

And omitting it silently would be the same failure this project criticises
elsewhere: a gap nobody wrote down. Running it advisory-but-visible states the
position.

## Why not make it a gate

Because the only two ways to get there are both worse than not gating.

**A permanently red build.** Spurious warnings from generated code would fail
every run, and a build that is always red is a build nobody reads.

**A broad ignore file.** Silencing whole categories to get green would hide the
real findings among them — worse than not running it, because it looks like
coverage.

## Consequences

**Easier**

- Findings are visible without blocking delivery.
- The ignore file stays honest, because nothing forces entries into it.
- The real gates are ones that behave predictably against macro-generated code.

**Harder**

- An advisory job is a job people stop reading. Mitigated by keeping the ignore
  file empty, so the signal stays small enough to scan.
- Type errors Dialyzer would have caught can reach `main`.
- PLT builds are slow; CI caches them on `mix.lock`.

## Reversal

**To make it a gate:** run `mix dialyzer` locally, triage every finding, and
populate `.dialyzer_ignore.exs` with a documented reason per entry. Then remove
`continue-on-error` from `.github/workflows/ci.yml`. Revisit if Spark ever ships
guidance or an ignore file.

**To remove it:** drop the dep, the `dialyzer` config in `mix.exs`, the ignore
file and the CI job. Update
[thesis 7](../manifesto/07-what-we-do-not-have.md#4-dialyzer-certainty), which
records this as a known weak spot.
