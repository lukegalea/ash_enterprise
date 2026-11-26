---
name: run-the-app
description: "Use when starting, seeding, or exercising this application locally — devenv, the dynamic Postgres port, the build lock, and the URLs worth visiting."
---

# Running the app

Everything runs inside `devenv`. Do not invoke `mix` directly: it will not find
the right Elixir and it will write to `~/.mix` instead of the project-local
`MIX_HOME`.

```bash
devenv up -d                    # infrastructure only (Postgres)
devenv shell -- mix setup       # deps, database, migrations
devenv shell -- mix ash_enterprise.seed
devenv shell -- iex-server      # the app, in IEx
```

Sign in with the credentials the seeder prints — `admin@example.com` /
`password1234` by default. That fixed password is allowed in dev and test only; anywhere else
`mix ash_enterprise.seed` and `mix ash_enterprise.demo` refuse without `--password-file PATH`.

## Three things that will confuse you

**The Postgres port is dynamic.** devenv shifts it when 5432 is taken by Docker
or another project. Never hardcode it — read `$PGPORT`, which `enterShell`
resolves from the running cluster's `postgresql.conf`. `config/dev.exs` and
`config/test.exs` already do.

**Do not run `mix phx.server` as a devenv process.** It holds the `_build` lock
and blocks every other mix command, and process-compose restarts it so it takes
the lock straight back. That is why `processes.phoenix` is deliberately absent
from `devenv.nix`.

**`MIX_ENV` is deliberately unset.** Exporting it pins the environment for every
mix invocation, so `mix test` would run in `:dev`, `config/test.exs` would never
load, and the Ecto Sandbox pool would be missing.

## Where to look

| URL | What |
|---|---|
| `/` | Home, with navigation |
| `/agent` | The helper console — propose, confirm, execute |
| `/app/users`, `/app/teams`, `/app/roles`, `/app/business-units` | A2UI surfaces |
| `/admin` | Zero-config admin over every resource (dev only) |
| `/clarity` | ER, class, policy and state-machine diagrams (dev only) |
| `/dev/dashboard` | LiveDashboard and telemetry (dev only) |
| `/api/json/swaggerui` | JSON:API explorer over the OpenAPI document (dev only) |
| `/gql/playground` | GraphQL explorer (dev only) |

"Dev only" is the `dev_routes` switch, on in `config/dev.exs` unless the build has
`DEV_ROUTES=false`. The router reads it when it compiles, so set it for every mix command
that builds or runs the instance; Mix recompiles the router when it changes. A deployment that runs the dev config for other people should build with it off: it then
loses `/admin`, `/dev/dashboard`, `/dev/mailbox`, `/clarity`, `/canvas`, the two API explorers
and `/ash_agent/mcp`. Pair it with `FIXED_SEED_PASSWORD=false` at runtime.

## Checks

```bash
scripts/pre-ci                     # CI's static checks, in CI's order (no test run)
devenv shell -- check              # the static checks plus the whole suite (about two hours)
devenv shell -- mix test
devenv shell -- mix ash.codegen --check   # schema drift gate
devenv shell -- reset-db
```

## The baseline tour

```bash
CLINIC_DEMO_DIR=/path/to/clinic-demo devenv shell -- scripts/baseline-tour.sh
```

Walks the demo surfaces that exist today on a loopback instance with its own database and
port, and stops at the first broken step: the explorer opened from the import batch's
correlation id, the canvas's record capabilities and their consequence classes, a stale
planning candidate refused, and the clinic's labelled simulation run and four-eyes apply.
It also checks that MiniZinc and `prlimit` are on `PATH`; `TOUR_MINIZINC=report` prints
their absence and carries on for a host that has none yet. The header of the script lists
its environment (`TOUR_PORT`, `TOUR_DB`, `TOUR_KEEP`).

## The provenance demo

```bash
CLINIC_DEMO_DIR=/path/to/clinic-demo devenv shell -- scripts/provenance-demo.sh
```

Seeds the demo tenant (`mix ash_enterprise.demo`, which includes `AshEnterprise.Provenance.DemoData`)
on a loopback instance of its own, fills it a second time to show the seed changes nothing, and
asks "where did this value come from" through `AshEnterprise.Provenance.explain/2` as the person
each step names: a task's title and its derived lane, a judged fact and one whose document was
erased, a viewer who may not read the source, and a task a recipe's steps wrote. The assistant
step waits for the Why surface and prints PENDING until then. The clinic's scenario-apply guard
and per-run rows close the run. Its environment is `PROV_PORT`, `PROV_DB` and `PROV_KEEP`.

## The agent console needs a key

`/agent` interprets natural language with an LLM. Without `ANTHROPIC_API_KEY` (or
`OPENAI_API_KEY`) in `.env` it says so plainly rather than falling back to
pattern matching — a fallback that half-works produces a demo that appears to
prove something it does not.

Everything safety-relevant in that flow — authorization, confirmation, execution,
audit — is ordinary Ash code and is exercised by the test suite **without** a key.
