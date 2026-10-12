# Runbook: drive a running server from amber_console (ACP)

[amber_console](https://github.com/lukegalea/amber_console) is a terminal ACP
client. Point it at `scripts/acp-attach` to drive a server that is **already
running**, such as the dogfood instance, as its configured operator.

## Run it

On the machine the server runs on, as the same user, in any terminal (an SSH
session is fine; stdio needs no port forward):

```bash
cd ~/amber_console && uv sync    # first time only
uv run amber --command ~/ash_enterprise-dogfood/scripts/acp-attach --cwd ~/ash_enterprise-dogfood
```

It connects on start (status bar `READY`). Then `/new` opens a session, and
`list business units` returns the business units the operator can see, as an
A2UI table. `/help` lists the keys.

## How it works

`mix ash_acp.stdio` boots a whole second copy of the application: a second
endpoint, a second Oban double-running the cron syncs, and a wait on the
`_build` lock held by the server. `scripts/acp-attach` does none of that. It
starts a small hidden Erlang node, connects to the server by its `--sname`
(default `dogfood`, or `scripts/acp-attach NAME`, or `ACP_NODE`), and calls
`AshEnterprise.Acp.Attach.serve/1` there. The ACP wire is the bridge's own
stdin/stdout. Every action runs inside the live server, under its policies.

The bridge needs:

- the server started with `--sname` (the dogfood start command already uses
  `--sname dogfood`);
- the same user, so the same `~/.erlang.cookie`;
- a `devenv shell` in the checkout, so the bridge runs the same Erlang/OTP as
  the server.

`serve/1` leaves the server's log alone. It puts back the default logger
handler that `AshAcp.run_stdio/1` replaces, and it keeps the session's own
output (Ecto debug logs included) out of the wire.

## Who the sessions run as

`AshEnterprise.Acp.system_actor/0` looks up the user by
`config :ash_enterprise, :acp_operator_email`. `config/runtime.exs` sets it
from `ACP_OPERATOR_EMAIL`, and the default is the legacy seed's
`admin@example.com`. The dogfood checkout sets it in its gitignored
`devenv.local.nix`:

```nix
{ ... }:
{
  env.ACP_OPERATOR_EMAIL = "lgalea@vendorpm.com";
}
```

The value is read at boot, so a change needs a server restart. If the user does
not exist, `session/new` fails rather than falling back to an unauthorized
actor.

## Verify

```bash
uv run python tests/live_dogfood.py   # in an amber_console checkout that has it
```

The script is `tests/live_dogfood.py` on amber_console's `dogfood` branch.

This drives amber headless. It checks for `READY`, a session, an A2UI table with
rows, and the detail pane, and prints counts only: dogfood holds real data.

## Limits

- The prompt target maps one phrase, `list business units`
  (`AshEnterprise.Acp.SessionStore.resolve/3`). Any other prompt gets
  `no_matching_action`.
- Sessions live in memory (ETS) in the server and are not closed when the
  client disconnects. They are gone after a server restart. Durable sessions
  arrive with epic E5.
- There is no authentication: anyone who can reach the node's distribution
  port with the cookie is already the server's owner.
