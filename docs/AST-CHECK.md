# `mix ast.check`

One task, one gate, for the surface this repository shows to coding agents.
Everything an outside agent is *told* about this program — which actions exist,
what inputs they take, where the rules documents live — is a contract that can
silently rot. This task checks the rot, not the weather: it runs the program's
own tooling against itself and exits nonzero on any failure, which is what
makes it a gate rather than a report.

    mix ast.check                        # all steps, human output
    mix ast.check --format json          # machine-readable report
    mix ast.check --skip-contracts       # skip the ash_agent_tools smoke test
    mix ast.check --skip-links           # skip the AGENTS.md link check
    mix ast.check --semantic             # also validate priv/semantic manifests

Every step reports `ok`, `FAIL` or `skipped`, with a reason on every skip. A
skipped step never fails the gate; an unexplained silence would.

## The steps

### Contracts — `contracts`

For each `{resource, action, inputs}` triple in
`config :ash_enterprise, :ast_check_contracts` (defaults are defined in
`lib/mix/tasks/ast/check.ex`), the task calls `AshAgentTools.describe_action/2`
and asserts:

1. the action still exists, and
2. every listed input still appears in the action's documented input contract
   (required arguments, optional inputs, or action arguments).

A rename — `for_export` becoming `export_window`, an argument changing name —
is exactly the kind of change that compiles clean, passes a suite that never
mentions the old name, and breaks every agent transcript holding the old
surface. This step is where it dies instead.

The default triples are chosen to exercise the three read-action shapes an
agent meets most: a read with required arguments
(`Audit.EventLog.for_export`), a filtered read behind a domain code interface
(`Process.Binding.for_kind`), and a `get_by` lookup
(`Accounts.User.get_by_email`).

**This step needs `ash_agent_tools`, which is a `only: :dev` path dependency**
(`~/ast-forks/ash_agent_tools`, not on hex). Under `MIX_ENV=test` — therefore
in CI and in `mix precommit` — the step reports itself skipped with that
reason. The full run is the dev-env default:

    mix ast.check    # dev env: contracts + links

### Rules links — `rules-links`

Every relative markdown link in the composed `AGENTS.md` must resolve to a
file on disk. `mix usage_rules.sync` links topics into `deps/`
(`[ash_bpmn usage rules](deps/ash_bpmn/usage-rules.md)`), so a dependency
restructuring its `usage-rules.md` breaks those links on the next sync. This
catches that before an agent follows one into a 404. Fragments
(`...md#4-dialyzer-certainty`) are checked as files; anchors and absolute URLs
are ignored.

### Semantic manifests — `semantic`, opt-in

With `--semantic`, every file under `priv/semantic/**/*.json` must:

1. parse as JSON,
2. declare `"manifest_version": "0"`, and
3. carry symbol ids matching the v0 grammar from
   [docs/rfc/semantic-manifest-v0.md §4.3](rfc/semantic-manifest-v0.md):
   `ash:v0:<module>#<dsl_path>/<name>[:<discriminator>]`.

The exporter does not exist yet, so the directory is normally absent and the
step reports skipped when asked for an empty directory. The flag stays off by
default until it does; the point of wiring it now is that the moment the first
manifest appears, it is checked — not the moment after the first bad one
ships.

## Where it runs

- **CI** (`.github/workflows/ci.yml`): a `mix ast.check` step after `mix test`
  — after, because booting the app for the task wants the database the test
  job has already prepared. Under `MIX_ENV=test` this gates the links step;
  the contract step reports skipped.
- **`mix precommit`**: appended after `test`, same reasoning.
- **Locally, full gate**: `mix ast.check` in `:dev` (the default), contracts
  included.

## Extending the contract list

Add a triple to config, keeping the map shape:

```elixir
config :ash_enterprise, :ast_check_contracts, [
  %{resource: AshEnterprise.Ledger.Entry, action: :by_account, inputs: [:account_id]}
]
```

Add an action to the list when outside agents are told about it — a README
example, a skill, a documented integration. The list is a statement of what we
promise the agent surface, and this task is what keeps the promise checkable.
