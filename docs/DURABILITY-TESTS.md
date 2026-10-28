# The durability test tier

Most of this suite runs inside the Ecto SQL sandbox: one connection per test, one transaction,
rolled back at the end. That is fast and isolated, and it cannot test anything whose truth
depends on a commit. Nothing commits, no second connection ever sees a write, two "concurrent"
writers share one connection, and a job never runs in a process of its own.

The durability tier is for those claims: a compare-and-set that two writers race for, a job
killed between two commits, a retry that must find the first commit and not repeat it.

## Running it

```bash
devenv shell -- mix test.durability                     # the whole tier
devenv shell -- mix test.durability test/ash_enterprise/durability/harness_test.exs
```

`MIX_TEST_PARTITION` is honoured as everywhere else, so two checkouts on one cluster do not
share a database.

The ordinary `mix test` excludes the tier. `mix test --only durability` does not run it either:
the tests fail at once and say to use `mix test.durability`, because running them on the
sandbox would test nothing they were written for.

## What changes in a durability run

`mix test.durability` sets `ASH_ENTERPRISE_DURABILITY=1` and reloads the config, and
`config/test.exs` then:

- points both repos at `ash_enterprise_test<partition>_durability`, with an ordinary connection
  pool instead of the sandbox;
- runs a real Oban: `testing: :disabled`, every configured queue plus `durability`, this node
  as the leader (only the leader stages retries and scheduled jobs), and the application's
  crontab emptied, so no sweep acts on the tests' rows on its own schedule. A test that needs a
  sweep runs it.

The alias drops that database (a killed earlier run leaves one behind), the `test` alias creates
and migrates it, and the suite drops it when it ends. `test/test_helper.exs` runs only
`:durability` tests in this mode, one module at a time.

`ASH_ENTERPRISE_DURABILITY=1 mix test` does the same without the first drop.

## Writing a durability test

```elixir
defmodule AshEnterprise.Durability.ExampleTest do
  use AshEnterprise.DurabilityCase, async: false
end
```

`AshEnterprise.DurabilityCase` tags the module `:durability`, imports the harness
(`AshEnterprise.Durability`), brings in `ExUnitProperties`, and disarms every fault point after
each test. Nothing is rolled back, so key every row by something unique to the test (a tenant
created in `setup` is the usual way).

The harness:

- `subscribe_jobs/0` and `await_job/3` wait for a job to finish in a given state, from Oban's
  own telemetry, sent after Oban has recorded the outcome. A job killed outright finishes as
  `:failure` with `kind: :exit`.
- `job!/1` reads a job's committed row.
- `race/3` runs a function in many processes released at once, each on its own connection.
- `AshEnterprise.Durability.Interleavings` generates the orders concurrent actors' steps can
  happen in, and runs a step sequence checking invariants after every step.

## Fault points

`AshEnterprise.Faults.point/1` marks a place in application code where a test may make the
process fail, typically between two commits:

```elixir
record_claim!(visit)
AshEnterprise.Faults.point(:after_claim)
notify_clinic!(visit)
```

```elixir
Faults.arm(:after_claim, :kill)       # or :raise, or :exit; once unless times: n
```

It is a function, not a macro. Fault points are compiled in only under `config/test.exs`
(`config :ash_enterprise, AshEnterprise.Faults, enabled?: true`); everywhere else `point/1` is
`:ok` and `arm/3` refuses. Armed points are global to the node, so a test that arms one is
`async: false`.

`test/ash_enterprise/durability/harness_test.exs` is the worked example: a job killed between
its two commits leaves the first committed and visible, is recorded as failed, and its retry
completes the second without repeating the first.
