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
`password1234` by default.

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
| `/admin` | Zero-config admin over every resource |
| `/clarity` | ER, class, policy and state-machine diagrams (dev only) |
| `/dev/dashboard` | LiveDashboard and telemetry |
| `/api/json/swaggerui` | JSON:API with OpenAPI |
| `/gql/playground` | GraphQL |

## Checks

```bash
devenv shell -- check              # the full local gate, same as CI
devenv shell -- mix test
devenv shell -- mix ash.codegen --check   # schema drift gate
devenv shell -- reset-db
```

## The agent console needs a key

`/agent` interprets natural language with an LLM. Without `ANTHROPIC_API_KEY` (or
`OPENAI_API_KEY`) in `.env` it says so plainly rather than falling back to
pattern matching — a fallback that half-works produces a demo that appears to
prove something it does not.

Everything safety-relevant in that flow — authorization, confirmation, execution,
audit — is ordinary Ash code and is exercised by the test suite **without** a key.
