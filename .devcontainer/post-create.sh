#!/usr/bin/env bash
# Dev container post-create: install Nix, devenv and omp, start PostgreSQL and
# run `mix setup`. Non-interactive and idempotent: a rerun skips what is done.
#
# Output also goes to ~/.cache/post-create.log, with the time each step took.
set -euo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || echo .)"

mkdir -p "$HOME/.cache"
exec > >(tee -a "$HOME/.cache/post-create.log") 2>&1

t0=$SECONDS
step() { echo "post-create: [$(date -u +%H:%M:%S) +$((SECONDS - t0))s] $*"; }

# 1. The platform CA. A workspace platform with its own CA (a TLS-inspecting
# proxy, private hostnames) stages it into the checkout as .sdlc-ca-bundle.crt
# (git-excluded), racing this script, so wait for it briefly. It is absent on a
# plain `devcontainer up`, and then nothing changes. The Coder agent inside this
# container needs it before it can connect, which is why it goes first.
step "platform CA"
for _ in $(seq 1 15); do
  [ -f .sdlc-ca-bundle.crt ] && break
  sleep 2
done
if [ -f .sdlc-ca-bundle.crt ]; then
  sudo cp .sdlc-ca-bundle.crt /usr/local/share/ca-certificates/platform-ca-bundle.crt
  sudo update-ca-certificates
else
  echo "post-create: no .sdlc-ca-bundle.crt staged; keeping the image's trust store"
fi

# 2. git. Fetching from github.com over HTTP/2 can stall behind some container
# networks (ls-remote works, clone hangs). mix fetches the git dependencies
# that way, so pin HTTP/1.1 for GitHub only.
git config --global http.https://github.com/.version HTTP/1.1

# 3. Nix, from the Determinate Systems installer pinned by version and sha256.
# `--init none` because the container has no systemd; nix-daemon.sh starts the
# daemon by hand.
step "nix"
if [ ! -x /nix/var/nix/profiles/default/bin/nix ]; then
  NIX_INSTALLER_SHA256=5df3f9032a386617f96c966581f1a73db3349e60d60e861e948e5a91363f4d26
  installer="$(mktemp)"
  curl -fsSL "https://install.determinate.systems/nix/tag/v3.24.0/nix-installer-x86_64-linux" -o "$installer"
  echo "$NIX_INSTALLER_SHA256  $installer" | sha256sum -c -
  chmod +x "$installer"
  "$installer" install linux --init none --no-confirm
  rm -f "$installer"
fi
# shellcheck source=.devcontainer/nix-daemon.sh
. .devcontainer/nix-daemon.sh
nix --version

# Login shells (Coder ssh sessions, `bash -lc`) find nix, devenv and omp.
if ! grep -qs 'ash_enterprise dev container' "$HOME/.profile"; then
  cat >> "$HOME/.profile" <<'PROFILE'
# ash_enterprise dev container: Nix, devenv and omp
export NIX_REMOTE=daemon
export PATH="$HOME/.local/bin:$HOME/.nix-profile/bin:/nix/var/nix/profiles/default/bin:$PATH"
PROFILE
fi

# 4. devenv. devenv.nix and devenv.lock pin everything the project uses; this
# is only the CLI that reads them, pinned to the release the project is
# developed with. devenv 2.4.0 runs the git hooks over every file on each
# `devenv shell -- CMD`, which here means a dozen concurrent `mix format` runs
# before every command.
step "devenv"
DEVENV_VERSION=2.2.1
if ! devenv --version 2>/dev/null | grep -q "^devenv $DEVENV_VERSION"; then
  nix profile remove devenv >/dev/null 2>&1 || true
  nix profile install --accept-flake-config "github:cachix/devenv/v$DEVENV_VERSION"
fi
devenv --version

# 5. omp, the coding agent CLI that headless agent runs use, under bun. The
# entry point is a wrapper in ~/.local/bin that runs omp's cli.js with bun. It
# must never be written to ~/.bun/bin/omp: that path is bun's own link to
# cli.js, and writing through it overwrites the agent's code.
step "omp"
BUN_VERSION=1.4.4
OMP_VERSION=18.16.0
if ! "$HOME/.bun/bin/bun" --version 2>/dev/null | grep -qx "$BUN_VERSION"; then
  curl -fsSL https://bun.sh/install | bash -s -- "bun-v$BUN_VERSION"
fi
omp_cli="$HOME/.bun/install/global/node_modules/@oh-my-pi/pi-coding-agent/dist/cli.js"
omp_pkg="${omp_cli%/dist/cli.js}/package.json"
if ! grep -qs "\"version\": \"$OMP_VERSION\"" "$omp_pkg"; then
  "$HOME/.bun/bin/bun" install -g "@oh-my-pi/pi-coding-agent@$OMP_VERSION"
fi
mkdir -p "$HOME/.local/bin"
rm -f "$HOME/.local/bin/omp"
cat > "$HOME/.local/bin/omp" <<WRAPPER
#!/usr/bin/env bash
exec "\$HOME/.bun/bin/bun" "$omp_cli" "\$@"
WRAPPER
chmod 0755 "$HOME/.local/bin/omp"
export PATH="$HOME/.local/bin:$PATH"
omp --version

# 6. PostgreSQL (the only devenv process), then the project. The first
# `devenv shell` builds the environment from devenv.lock, which takes a while.
step "postgres"
bash .devcontainer/post-start.sh

step "mix setup"
# `mix setup` builds the assets but does not install their npm packages, as
# CI's asset build does first.
devenv shell -- bash -c 'mix local.hex --force --if-missing && mix local.rebar --force --if-missing \
  && npm ci --prefix assets && mix setup'

# Warm the test build too: an agent's first `mix test` otherwise compiles the
# whole project again under MIX_ENV=test.
step "test compile"
devenv shell -- env MIX_ENV=test mix compile

step "done"
