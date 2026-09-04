# ash-enterprise-demo — a Coder template

Brings up the ash_enterprise Phoenix/Ash demo app in a Coder workspace on the
home-lab deployment. The workspace container is just a host: it clones the
repo at a ref you pick, installs [devenv](https://devenv.sh) (Nix), and runs
the exact commands the repo's own `run-the-app` skill prescribes
(`mix setup` → seed → BPMN/DMN baselines → `mix phx.server`). All
environment definition lives in the repo's committed `devenv.nix`; this
template owns none.

Two parameters, both mutable (update a running workspace and restart):

| Parameter    | Default | What |
|---|---|---|
| `repo_ref`   | `main`  | Branch/tag of lukegalea/ash_enterprise to run — the demo-environment field. |
| `auto_setup` | `true`  | Setup + seed on first start (idempotent via a marker). Off = faster restarts of an already-seeded workspace. |

## Push

From this repo (needs Coder credentials on this machine):

```sh
coder templates push ash-enterprise-demo -d coder/template \
  --variable docker_gid=988 \
  --variable homes_root=/mnt/sdlc/coder-homes
```

`docker_gid` is the daemon host's docker GID — read it with
`stat -c %g /var/run/docker.sock` and pass the real value. The other defaults
(`repo_url`, `private_repo_url`) rarely need overriding.

## Create a workspace

```sh
# The main branch
coder create ash-demo --template ash-enterprise-demo --parameter repo_ref=main

# A feature branch (the normal demo use)
coder create ash-demo-designer --template ash-enterprise-demo \
  --parameter repo_ref=feat/designer-catalogues

# A branch that only exists on the private POC remote
# (ash_enterprise_vpm_poc) — the start scripts fetch both remotes and
# resolve the ref from whichever has it.
coder create ash-demo-poc --template ash-enterprise-demo \
  --parameter repo_ref=<poc-only-branch>
```

To repoint a running workspace: `coder create --parameter repo_ref=...` on the
existing workspace (parameters are mutable), then restart — the clone script
checks out the new ref on start.

## First start

Slow — by design, once. The first start installs Nix, builds the devenv
environment (OTP 27 + Elixir 1.18 + Postgres 17), fetches deps, compiles and
seeds: expect tens of minutes. Later starts only sync deps and bounce the
server: minutes, not tens of them. Watch the start-script logs (Clone →
Install Nix + devenv → Setup + seed → Start Phoenix) and the dashboard
metadata (`App`, `Ref`, `Server log tail`) for progress. Nix state lives under
the workspace's persistent home; **deleting the workspace discards it**, so a
rebuild-from-nothing happens only on a fresh workspace.

## Sign in and demo

Seeder credentials: **admin@example.com / password1234** (the seed task prints
them; that admin carries the tenant + roles the demo drives).

| URL | What |
|---|---|
| `/` | Home, with navigation |
| `/app/demo` | Demo walkthrough page (on branches that ship it; not on `main`) |
| `/app/processes` | Process catalog — including the seed-driven drift badge |
| `/app/decisions` | Decision catalog |
| `/app/processes/access_request.grant/designer` | The bpmn-js designer over the published process |
| `/app/decisions/access_request.risk/editor` | The dmn-js editor over the published decision |
| `/app/tasks` | Task inbox from the sample request the setup drives through the process |
| `/dev/dashboard` | LiveDashboard + telemetry |

## GitHub auth (needed for the first-party deps)

mix.exs pins four first-party git deps by SHA; **ash_bpmn is a private repo**.
The deployment's `github` external-auth provider is brokered into the
workspace's git automatically (GIT_ASKPASS) — link your GitHub account when
creating the workspace and `mix deps.get` just works.

If a fetch ever fails (expired grant, helper glitch), grab a fresh token from
inside the workspace and hand it to git one-shot:

```sh
coder external-auth access-token github
git -c credential.helper='!f() { echo username=x; echo password=<TOKEN>; }; f' fetch origin
```

(The devenv install also writes that token into the workspace's
`~/.config/nix/nix.conf` as an `access-tokens` line when it first runs, to
keep Nix's GitHub fetches out of anonymous rate limits.)

## Caveats

- **One live stack per host.** Every workspace runs on the shared Docker
  daemon host: full BEAM VM, Postgres, nix builds and asset compilation all
  land there. devenv's dynamic Postgres port means two stacks won't collide on
  ports, but the deployment is sized for one live stack — don't run several
  seeded demo workspaces (or a demo alongside heavy nix builds) on the small
  host.
- **Per-workspace nix store.** `/nix` lives in the workspace container layer,
  so each workspace builds its own toolchain once (first-start cost) and a
  stopped-then-started workspace keeps it. Deleting the workspace deletes the
  store.
- **auto_setup=false on a never-seeded workspace** boots nothing useful — the
  start log warns and tells you to flip it back on.
