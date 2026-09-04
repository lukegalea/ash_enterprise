// The ash-enterprise-demo Coder template. Owned here, pushed from here:
//
//   coder templates push ash-enterprise-demo -d coder/template
//
// It provisions a Coder workspace that runs the ash_enterprise Phoenix/Ash
// demo app on the home-lab deployment, for a ref you pick at creation time:
// main, a feature branch, or a branch that only exists on the private POC
// remote. Everything about the environment itself comes from the repo's
// committed devenv.nix — this template owns no toolchain of its own. It
// provisions the Linux container, clones the repo, installs Nix + devenv,
// and hands off: `devenv shell -- mix setup` etc. do the rest, exactly as
// the run-the-app skill prescribes for local dev.
//
// App facts this template encodes (verified against devenv.nix / config/dev.exs):
//   - NEVER invoke mix directly — wrong Elixir, wrong MIX_HOME. Always
//     `devenv shell -- mix ...`.
//   - The devenv Postgres port is DYNAMIC ($PGPORT, resolved by enterShell
//     from the running cluster's postgresql.conf). It is never hardcoded here;
//     the probe below runs INSIDE the devenv shell so $PGHOST/$PGPORT are the
//     module's own values.
//   - MIX_ENV stays unset.
//   - `mix phx.server` must NOT run as a devenv process (it holds the _build
//     lock and process-compose would restart it straight back). The app script
//     starts it as a plain background process via `devenv shell --`.
//   - The dev server binds 127.0.0.1:4000. The agent shares that network
//     namespace, so the coder_app's http://localhost:4000 just works.
//
// The app has four FIRST-PARTY git deps pinned by SHA, one of which
// (ash_bpmn) is a PRIVATE github repo, and the private POC remote carries
// refs that exist nowhere else — so the workspace uses the deployment's
// `github` external auth provider (data.coder_external_auth, optional = true)
// and adds that private remote on every start. See coder/README.md.
//
// Host section mirrors the vendorpm-workspace template's working patterns
// (docker provider, enterprise-node image, docker socket + group_add, host-path
// homes under var.homes_root with the VPM-19 isolated-checkout mount, CA
// bundle, chown entrypoint, host-gateway) minus everything this template
// doesn't need: there is no devcontainer leg, no submodules/refs machinery,
// no shared checkout mode, and no agent-mode token plumbing. This template is
// isolated-only: every workspace gets its own home and its own checkout.

terraform {
  required_providers {
    // >= 2.4.0 for Dynamic Parameters (mutable, order, validation blocks).
    coder  = { source = "coder/coder", version = ">= 2.4.0" }
    docker = { source = "kreuzwerker/docker" }
  }
}

provider "coder" {}
provider "docker" {}

data "coder_provisioner" "me" {}
data "coder_workspace" "me" {}
data "coder_workspace_owner" "me" {}

// ── Host variables ───────────────────────────────────────────────────────────
//
// The deployment's two host constants. Both are passed at push time the way
// the vendorpm-workspace template's are; the defaults match this lab.

variable "docker_gid" {
  type        = number
  default     = 988
  description = <<-EOT
    GID of the `docker` group on the daemon host, added to the workspace
    container as a supplementary group. The mounted /var/run/docker.sock is
    root:docker 0660, so without membership every docker call in the workspace
    fails with "permission denied". Read it on the host with
    `stat -c %g /var/run/docker.sock` and pass it at push time.
  EOT
}

variable "homes_root" {
  type        = string
  default     = "/mnt/sdlc/coder-homes"
  description = <<-EOT
    Host directory (on the Docker daemon host) under which each workspace's
    /home/coder lives as <owner>-<workspace>/. The workspace home exists as a
    REAL host path, so it outlives stops/restarts; the daemon auto-creates the
    dir root-owned and the container entrypoint chowns it before anything
    writes. The isolated checkout lives at <homes_root>/<owner>-<workspace>/
    ash_enterprise, mounted back at its identical absolute path (VPM-19
    pattern), so every workspace is workspace-unique by construction.
    Cleanup of stale homes after workspace deletion is an operator sweep.
  EOT
}

variable "repo_url" {
  type        = string
  default     = "https://github.com/lukegalea/ash_enterprise.git"
  description = "The demo repo to clone. var.repo_ref picks the ref to run."
}

variable "private_repo_url" {
  type        = string
  default     = "https://github.com/lukegalea/ash_enterprise_vpm_poc.git"
  description = <<-EOT
    The private POC remote. Added to the checkout on every start and fetched
    alongside origin, so a repo_ref that exists only there still resolves.
  EOT
}

// ── What this workspace should run ───────────────────────────────────────────
//
// Two parameters, both mutable: update a running workspace's repo_ref (or
// auto_setup) and restart, and the start scripts re-resolve. That is what
// makes "point the demo at a branch" a 30-second edit rather than a new
// workspace.

data "coder_parameter" "repo_ref" {
  name         = "repo_ref"
  display_name = "Repo ref"
  description  = <<-EOT
    Branch or tag of lukegalea/ash_enterprise to run — the demo-environment
    field. Point it at a feature branch to demo that branch. A ref that only
    exists on the private POC remote works too: the checkout fetches both
    remotes before resolving the ref.
  EOT
  type         = "string"
  form_type    = "input"
  default      = "main"
  mutable      = true
  order        = 1

  validation {
    // Git's own rules, loosely: no spaces, no `..`, no leading dash. The point
    // is to catch a pasted URL or a sentence, not to reimplement
    // check-ref-format — the clone script fails visibly on a ref that does
    // not exist on either remote.
    regex = "^[A-Za-z0-9][A-Za-z0-9._/-]*$"
    error = "Use a branch or tag name, e.g. main or feat/designer-catalogues"
  }
}

data "coder_parameter" "auto_setup" {
  name         = "auto_setup"
  display_name = "Auto setup + seed"
  description  = <<-EOT
    Run deps + database setup and seed the demo data (tenant, admin user,
    BPMN/DMN baselines) on start when the workspace has not been seeded yet.
    Idempotent: first start is slow, later starts only sync deps. Turn OFF for
    faster restarts of an already-seeded workspace.
  EOT
  type         = "bool"
  default      = true
  mutable      = true
  order        = 2
}

# Brokered per-user GitHub credential.
//
// ash_bpmn is a PRIVATE github repo pinned by SHA in mix.exs, so `mix deps.get`
// needs auth even though the demo repo itself is public. Coder wires this
// grant into git over HTTPS through GIT_ASKPASS, which the devenv-spawned git
// processes inherit — no further configuration. optional = true is load-
// bearing: a workspace owner who never completes the OAuth flow must still be
// able to build (they just can't fetch ash_bpmn until they link GitHub, or
// hand a token to git manually — `coder external-auth access-token github`
// yields one; see README).
data "coder_external_auth" "github" {
  id       = "github"
  optional = true
}

locals {
  // Workspace-unique key, mirroring the homes_root layout and the container
  // name below: <owner>-<workspace> (ws name lowercased). Every path hangs
  // off this, so two workspaces can never share one.
  ws_key = "${data.coder_workspace_owner.me.name}-${lower(data.coder_workspace.me.name)}"

  // This workspace's own directory under homes_root — the same host dir the
  // /home/coder bind mounts, at its identical absolute path on the daemon host.
  isolated_root = "${var.homes_root}/${local.ws_key}"

  // The checkout path the whole template operates on. One local, so the agent
  // dir, clone script, setup script, app script and metadata can never
  // disagree about where the checkout is.
  effective_clone_dir = "${local.isolated_root}/ash_enterprise"

  // Where the app script redirects the server's output; the dashboard tails it.
  server_log = "/tmp/ash-enterprise-server.log"
}

resource "coder_agent" "main" {
  arch = data.coder_provisioner.me.arch
  os   = "linux"
  dir  = local.effective_clone_dir

  # Git identity from the workspace owner, so commits made in the demo are
  # attributable. No VPM-style identity plumbing, no agent tokens: this
  # template is human-owned demo environments only.
  env = {
    GIT_AUTHOR_NAME     = coalesce(data.coder_workspace_owner.me.full_name, data.coder_workspace_owner.me.name)
    GIT_AUTHOR_EMAIL    = data.coder_workspace_owner.me.email
    GIT_COMMITTER_NAME  = coalesce(data.coder_workspace_owner.me.full_name, data.coder_workspace_owner.me.name)
    GIT_COMMITTER_EMAIL = data.coder_workspace_owner.me.email
  }

  # Is the app up? Displays the HTTP status code.
  metadata {
    display_name = "App"
    key          = "app"
    script       = "curl -sf -o /dev/null -w '%%{http_code}' http://localhost:4000/ || echo down"
    interval     = 30
    timeout      = 10
  }

  # Which ref the demo is actually running — a demo workspace's whole value is
  # being the right code, so that belongs on the dashboard.
  metadata {
    display_name = "Ref"
    key          = "ref"
    script       = "git -C ${local.effective_clone_dir} rev-parse --abbrev-ref HEAD 2>/dev/null && git -C ${local.effective_clone_dir} rev-parse --short HEAD 2>/dev/null || echo \"no checkout yet\""
    interval     = 60
    timeout      = 15
  }

  # Server output, so a failed boot is visible without opening a terminal.
  metadata {
    display_name = "Server log tail"
    key          = "server_log"
    script       = "tail -5 ${local.server_log} 2>/dev/null || echo \"no server log yet\""
    interval     = 60
    timeout      = 10
  }
}

// ── Start scripts ────────────────────────────────────────────────────────────
//
// All run_on_start, all idempotent, sequenced clone → devenv → setup → app.
// Belt-and-braces wait guards live inside each script so a concurrent
// execution environment degrades to "slow" rather than "wrong".

# Clone (or refresh) the checkout at the requested ref.
#
# run_on_start + start_blocks_login, like the reference template: the checkout
# must exist before anything else runs, and nothing owner-specific happens
# before this (Coder wires GIT_ASKPASS from the github external-auth grant).
resource "coder_script" "clone" {
  agent_id           = coder_agent.main.id
  display_name       = "Clone ash_enterprise"
  icon               = "/icon/code.svg"
  run_on_start       = true
  start_blocks_login = true
  script             = <<-EOT
    set -euo pipefail

    DIR="${local.effective_clone_dir}"
    REPO_REF="${data.coder_parameter.repo_ref.value}"

    # Existence before content, as in the reference template.
    mkdir -p "$DIR"

    if [ ! -d "$DIR/.git" ]; then
      echo "cloning ${var.repo_url} at ref $REPO_REF"
      if ! git clone --quiet --branch "$REPO_REF" "${var.repo_url}" "$DIR"; then
        # The ref may exist only on the private POC remote. Fall back to a
        # default-branch clone; the fetches below then resolve the ref.
        echo "ref '$REPO_REF' is not on origin — cloning the default branch, then fetching the private POC remote"
        rm -rf "$DIR"
        git clone --quiet "${var.repo_url}" "$DIR"
      fi
    fi

    cd "$DIR"

    # Private POC remote: some ash_enterprise demo refs live only there.
    # `remote add` errors when it already exists — that is the success case.
    git remote add private "${var.private_repo_url}" 2>/dev/null || true

    # Fetch both remotes BEFORE checkout, so a repo_ref from either resolves.
    git fetch --quiet --prune origin || echo "warn: origin fetch failed"
    git fetch --quiet --prune private || echo "warn: private fetch failed (private-only refs will not resolve)"

    # Checkout the requested ref by name (fetch-then-checkout rather than
    # `pull --ff-only`: the ref can be a tag, and it can differ from the one
    # the previous start used, since the parameter is mutable).
    if git rev-parse --verify -q "$REPO_REF" >/dev/null 2>&1; then
      git checkout --quiet "$REPO_REF"
    else
      if ! git checkout --quiet -B "$REPO_REF" "origin/$REPO_REF" 2>/dev/null; then
        if ! git checkout --quiet -B "$REPO_REF" "private/$REPO_REF" 2>/dev/null; then
          echo "ERROR: ref '$REPO_REF' not found on origin or private — check the ref name"
          exit 1
        fi
      fi
    fi

    # Fast-forward to the remote tip when the ref is a branch of either
    # remote; tags and detached SHAs fall through silently.
    git merge --ff-only --quiet "origin/$REPO_REF" 2>/dev/null ||
      git merge --ff-only --quiet "private/$REPO_REF" 2>/dev/null || true

    echo "checked out: $(git rev-parse --abbrev-ref HEAD) @ $(git rev-parse --short HEAD)"
  EOT
}

# Install Nix + devenv when missing.
#
# devenv.sh's root URL serves HTML (verified 2026-09), not an install script —
# piping it into sh fails — so this uses the documented path: the official
# Nix installer (daemonless, container-safe: no systemd in this image) followed
# by `nix profile install nixpkgs#devenv`, with a non-flake `nix-env` fallback.
# The enterprise-node image gives the coder user passwordless sudo; the
# installer drives it itself when present and works as plain root otherwise.
resource "coder_script" "devenv" {
  agent_id     = coder_agent.main.id
  display_name = "Install Nix + devenv"
  icon         = "/icon/terminal.svg"
  run_on_start = true
  script       = <<-EOT
    set -euo pipefail

    DIR="${local.effective_clone_dir}"

    # Wait for the clone (startup scripts run in order; this is insurance).
    for i in $(seq 1 120); do
      if [ -d "$DIR/.git" ]; then break; fi
      sleep 2
    done
    if [ ! -d "$DIR/.git" ]; then
      echo "ERROR: no checkout at $DIR — the clone script failed; fix that first"
      exit 1
    fi

    # Find Nix wherever the installer left it: the user profile (single-user,
    # the container case) or the daemon profile (multi-user), then make both
    # profile bins visible on PATH for the steps below.
    if ! command -v nix >/dev/null 2>&1; then
      for f in "$HOME/.nix-profile/etc/profile.d/nix.sh" \
               /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh \
               /nix/var/nix/profiles/default/etc/profile.d/nix.sh \
               /etc/profile.d/nix.sh; do
        if [ -f "$f" ]; then . "$f"; fi
      done
      export PATH="$HOME/.nix-profile/bin:/nix/var/nix/profiles/default/bin:$PATH"
    fi

    if ! command -v nix >/dev/null 2>&1; then
      echo "installing Nix (one-time; several minutes)..."
      # NB: in nix-installer 2.35.x `--init` belongs to the planner subcommand
      # (`install linux --init none`), not to `install` itself. `--init none`
      # is the daemonless/container-safe path — no systemd in this image, and
      # the default (systemd) plan leaves a root-owned store with a daemon
      # socket that never exists. Verified against the binary the bootstrap
      # actually fetches (releases/download/2.35.1).
      if ! curl -sSfL https://artifacts.nixos.org/nix-installer | sh -s -- install linux --init none --no-confirm; then
        echo "ERROR: Nix installer failed"
        if ! command -v sudo >/dev/null 2>&1; then
          echo "       (no sudo on PATH and not root — Nix needs one of the two to create /nix)"
        fi
        exit 1
      fi
      for f in "$HOME/.nix-profile/etc/profile.d/nix.sh" \
               /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh \
               /nix/var/nix/profiles/default/etc/profile.d/nix.sh \
               /etc/profile.d/nix.sh; do
        if [ -f "$f" ]; then . "$f"; fi
      done
      export PATH="$HOME/.nix-profile/bin:/nix/var/nix/profiles/default/bin:$PATH"
    fi

    if ! command -v nix >/dev/null 2>&1; then
      echo "ERROR: Nix is still not on PATH after install — see /nix and the devenv script log"
      exit 1
    fi

    # devenv is flake-based. The Determinate installer enables flakes by
    # default; write the setting defensively for installs that did not.
    mkdir -p "$HOME/.config/nix"
    touch "$HOME/.config/nix/nix.conf"
    if ! grep -q 'experimental-features' "$HOME/.config/nix/nix.conf"; then
      echo 'experimental-features = nix-command flakes' >> "$HOME/.config/nix/nix.conf"
    fi

    # Opportunistic GitHub token for Nix's fetches (rate limits), using the
    # same brokered grant the git side uses. Skipped silently when the
    # provider is not linked; written only once, into the workspace's own
    # ~/.config/nix/nix.conf. devenv documents this exact setting.
    if command -v coder >/dev/null 2>&1; then
      if ! grep -q 'access-tokens' "$HOME/.config/nix/nix.conf"; then
        NIX_GH_TOKEN="$(coder external-auth access-token github 2>/dev/null || true)"
        if [ -n "$NIX_GH_TOKEN" ]; then
          echo "access-tokens = github.com=$NIX_GH_TOKEN" >> "$HOME/.config/nix/nix.conf"
        fi
      fi
    fi

    if ! command -v devenv >/dev/null 2>&1; then
      echo "installing devenv (one-time)..."
      nix --extra-experimental-features 'nix-command flakes' profile install nixpkgs#devenv ||
        nix-env --install --attr devenv -f https://github.com/NixOS/nixpkgs/tarball/nixpkgs-unstable
    fi

    if ! command -v devenv >/dev/null 2>&1; then
      echo "ERROR: devenv still not on PATH after install — check the log above"
      exit 1
    fi

    echo "devenv ready: $(command -v devenv)"
  EOT
}

# Bring up infrastructure and (first run) seed the demo.
#
# `devenv up -d` runs infrastructure only — Postgres, with the repo's dynamic
# port. The heavy first-time path (mix setup = deps + ecto + assets + seeds,
# then the tenant/admin seeder, then the BPMN/DMN baseline task) is guarded by
# the auto_setup parameter and a marker file, so it runs exactly once; later
# starts only sync deps. The Postgres readiness probe runs INSIDE the devenv
# shell so $PGHOST/$PGPORT are the module's own (dynamic) values — never
# hardcoded here.
resource "coder_script" "setup" {
  agent_id     = coder_agent.main.id
  display_name = "Setup + seed"
  icon         = "/icon/database.svg"
  run_on_start = true
  script       = <<-EOT
    set -euo pipefail

    DIR="${local.effective_clone_dir}"
    AUTO_SETUP="${data.coder_parameter.auto_setup.value}"

    for f in "$HOME/.nix-profile/etc/profile.d/nix.sh" \
             /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh \
             /nix/var/nix/profiles/default/etc/profile.d/nix.sh \
             /etc/profile.d/nix.sh; do
      if [ -f "$f" ]; then . "$f"; fi
    done
    export PATH="$HOME/.nix-profile/bin:/nix/var/nix/profiles/default/bin:$PATH"

    if ! command -v devenv >/dev/null 2>&1; then
      echo "ERROR: devenv not found — check the 'Install Nix + devenv' script log"
      exit 1
    fi

    cd "$DIR"

    # Readiness probe: pg_isready when available, else a raw TCP connect to
    # the port Postgres is ACTUALLY listening on ($PGPORT, resolved by the
    # devenv postgres module — dynamic, never hardcoded).
    PG_OK() {
      devenv shell -- bash -c 'pg_isready -q 2>/dev/null || exec 3<>"/dev/tcp/$PGHOST/$PGPORT"' >/dev/null 2>&1
    }

    echo "checking devenv infrastructure (Postgres)..."
    if PG_OK; then
      echo "Postgres already up (PGHOST=$PGHOST via devenv shell)"
    else
      echo "starting Postgres via devenv up -d — first evaluation builds the nix environment and can take a long time"
      devenv up -d
      i=0
      while [ "$i" -lt 60 ]; do
        if PG_OK; then echo "Postgres is up"; break; fi
        echo "waiting for Postgres..."
        i=$((i+1))
        sleep 2
      done
      if ! PG_OK; then
        echo "ERROR: Postgres did not become ready — check the devenv environment evaluation output above"
        exit 1
      fi
    fi

    MARKER="$DIR/.coder-seeded"

    if [ "$AUTO_SETUP" = "true" ] && [ ! -f "$MARKER" ]; then
      echo "first run: mix setup (deps + database + assets) — the long step"
      devenv shell -- mix setup
      echo "seeding tenant + admin (credentials printed below)"
      devenv shell -- mix ash_enterprise.seed
      echo "publishing the demo BPMN/DMN baselines and driving a sample request"
      devenv shell -- mix ash_enterprise.bpmn.setup
      touch "$MARKER"
      # Keep the marker out of git status, like the reference template does
      # for its staged CA bundle.
      echo ".coder-seeded" >> "$DIR/.git/info/exclude" 2>/dev/null || true
      echo "seeded — sign in with the credentials printed above"
    elif [ ! -f "$MARKER" ]; then
      echo "WARNING: auto_setup=false and this workspace has never been seeded;"
      echo "         the app will boot with no demo data (or not at all)."
      echo "         Set auto_setup=true and restart the workspace to seed."
      devenv shell -- mix deps.get
    else
      echo "already seeded — syncing deps only"
      devenv shell -- mix deps.get
    fi
  EOT
}

# Start (or restart) the Phoenix server as a plain background process.
#
# NOT a devenv process: `mix phx.server` holds the _build lock, and a
# supervised copy would take the lock straight back after process-compose
# restarts it (the exact reason processes.phoenix is absent from devenv.nix).
# nohup + setsid + a pidfile of the session leader make the restart kill
# reliable (kill the whole process group, since devenv shell spawns children).
resource "coder_script" "app" {
  agent_id     = coder_agent.main.id
  display_name = "Start Phoenix"
  icon         = "/icon/rocket.svg"
  run_on_start = true
  script       = <<-EOT
    set -euo pipefail

    DIR="${local.effective_clone_dir}"
    PIDFILE="/tmp/ash-enterprise-server.pid"
    SERVER_LOG="${local.server_log}"
    AUTO_SETUP="${data.coder_parameter.auto_setup.value}"

    for f in "$HOME/.nix-profile/etc/profile.d/nix.sh" \
             /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh \
             /nix/var/nix/profiles/default/etc/profile.d/nix.sh \
             /etc/profile.d/nix.sh; do
      if [ -f "$f" ]; then . "$f"; fi
    done
    export PATH="$HOME/.nix-profile/bin:/nix/var/nix/profiles/default/bin:$PATH"

    if ! command -v devenv >/dev/null 2>&1; then
      echo "ERROR: devenv not found — check the 'Install Nix + devenv' script log"
      exit 1
    fi

    # If a first-run seed is expected, wait for it to finish (insurance in
    # case scripts run concurrently; sequential execution arrives here with
    # the marker already present).
    if [ "$AUTO_SETUP" = "true" ]; then
      i=0
      while [ "$i" -lt 720 ]; do
        if [ -f "$DIR/.coder-seeded" ]; then break; fi
        sleep 10
        i=$((i+1))
      done
      if [ ! -f "$DIR/.coder-seeded" ]; then
        echo "WARNING: seeding has not finished — starting the server anyway; it will fail without a database"
      fi
    fi

    # Kill any stale server: pidfile first (the whole process group), then a
    # pattern sweep defensively.
    if [ -f "$PIDFILE" ]; then
      OLD="$(cat "$PIDFILE" 2>/dev/null || true)"
      if [ -n "$OLD" ]; then
        if kill -0 -- "-$OLD" 2>/dev/null; then
          echo "stopping stale server (process group -$OLD)"
          kill -- "-$OLD" 2>/dev/null || true
          sleep 2
        elif kill -0 "$OLD" 2>/dev/null; then
          echo "stopping stale server (pid $OLD)"
          kill "$OLD" 2>/dev/null || true
          sleep 2
        fi
      fi
      rm -f "$PIDFILE"
    fi
    pkill -f 'beam.smp.*phx' 2>/dev/null || true

    cd "$DIR"
    echo "starting Phoenix (log: $SERVER_LOG)..."
    setsid nohup devenv shell -- mix phx.server >"$SERVER_LOG" 2>&1 </dev/null &
    echo $! > "$PIDFILE"
    echo "server launching (process group $(cat "$PIDFILE")) — the App link goes green once the healthcheck passes"
  EOT
}

// ── The app link ─────────────────────────────────────────────────────────────
//
// The agent shares the container's network namespace and the dev server binds
// 127.0.0.1:4000 (config/dev.exs), so `localhost` reaches it — no tunnel, no
// host.docker.internal (that is for the container's view of the HOST, one
// namespace further out).

resource "coder_app" "app" {
  agent_id     = coder_agent.main.id
  slug         = "app"
  display_name = "ash_enterprise"
  url          = "http://localhost:4000"
  order        = 1
  open_in      = "tab"
  share        = "owner"

  healthcheck {
    url       = "http://localhost:4000/"
    interval  = 15
    threshold = 10
  }
}

// ── Workspace host ───────────────────────────────────────────────────────────
//
// Mirrors the vendorpm-workspace template's host section faithfully (it is
// the pattern this deployment runs on), simplified to isolated-only.

resource "docker_image" "host" {
  name = "codercom/enterprise-node:ubuntu"

  # Workspaces share one daemon, so siblings reference the same image tag.
  # Without keep_locally, destroying ANY workspace tries to remove the tag
  # while a live sibling's container still uses it and fails the whole
  # terraform destroy (observed in the reference template's history).
  keep_locally = true
}

resource "docker_container" "workspace" {
  count = data.coder_workspace.me.start_count
  image = docker_image.host.name
  name  = "coder-${data.coder_workspace_owner.me.name}-${lower(data.coder_workspace.me.name)}"

  # The workspace does not run nested docker itself in this template, but the
  # socket + supplementary group are kept identical to the reference so
  # operators debug it the same way and future legs (compose, devcontainer)
  # work without a template change.
  volumes {
    host_path      = "/var/run/docker.sock"
    container_path = "/var/run/docker.sock"
  }
  group_add = [var.docker_gid]

  # /home/coder = the host-path home (VPM-18 pattern). Bind, not volume: the
  # path must exist identically on the daemon host. The daemon auto-creates
  # it root-owned; the entrypoint chown below fixes ownership before the
  # agent or any script writes.
  volumes {
    host_path      = "${var.homes_root}/${data.coder_workspace_owner.me.name}-${lower(data.coder_workspace.me.name)}"
    container_path = "/home/coder"
    read_only      = false
  }

  # Isolated checkout mount (VPM-19): mount the home's own host dir at its
  # identical real path, NEXT to /home/coder rather than inside it. The
  # checkout (<isolated_root>/ash_enterprise) is then a REAL directory at the
  # SAME absolute path on the daemon host and inside this node — workspace-
  # unique by construction, and nix/devenv state under it persists with the
  # home.
  volumes {
    host_path      = local.isolated_root
    container_path = local.isolated_root
    read_only      = false
  }

  # ai-sdlc platform CA trust (homelab mkcert bundle, present on the Docker
  # host this template builds on). Without it the workspace agent itself
  # cannot reach the Coder deployment (TLS signed by the homelab CA).
  volumes {
    host_path      = "/mnt/sdlc/sdlc-ca-bundle.crt"
    container_path = "/etc/ssl/certs/ca-certificates.crt"
    read_only      = true
  }

  # Entrypoint: fix ownership of the daemon-created bind sources (root-owned
  # on first start), then exec the agent bootstrap via env — the startup
  # scripts contain quoting no wrapper survives. The ! -user coder guard
  # makes restarts cheap. Never rm anything under the checkout here: the
  # mount IS the persistent checkout.
  entrypoint = [
    "sh", "-c",
    "sudo chown coder:coder /home/coder ${local.effective_clone_dir} 2>/dev/null || true; sudo find /home/coder -mindepth 1 -maxdepth 1 ! -user coder -exec sudo chown -R coder:coder {} + 2>/dev/null || true; exec sh -c \"$CODER_INIT\""
  ]
  env = [
    "CODER_AGENT_TOKEN=${coder_agent.main.token}",
    "CODER_INIT=${replace(coder_agent.main.init_script, "/localhost|127\\.0\\.0\\.1/", "host.docker.internal")}",
  ]
  host {
    host = "host.docker.internal"
    ip   = "host-gateway"
  }
}
