#!/usr/bin/env bash
# Dev container post-start: bring PostgreSQL back. Runs from the repository
# root on every container start, and once at the end of post-create.sh (a Coder
# dev container does not run postStartCommand on its first start).
#
# Infrastructure only. Phoenix is never started here: `mix phx.server` holds
# the _build lock and blocks every other mix command in the checkout.
set -uo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || echo .)"

# shellcheck source=.devcontainer/nix-daemon.sh
. .devcontainer/nix-daemon.sh || exit 1
export PATH="$HOME/.local/bin:$PATH"

pg_up() { devenv shell -- bash -c 'pg_isready -q' >/dev/null 2>&1; }

if pg_up; then
  echo "post-start: PostgreSQL already up"
  exit 0
fi

devenv up -d || { echo "post-start: devenv up -d failed" >&2; exit 1; }

for _ in $(seq 1 60); do
  if pg_up; then
    echo "post-start: PostgreSQL up"
    exit 0
  fi
  sleep 2
done

echo "post-start: PostgreSQL did not become ready; run 'devenv up' in the foreground to see why" >&2
exit 1
