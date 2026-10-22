#!/usr/bin/env bash
#
# Fail when AGENTS.md or .claude/skills no longer match what
# `mix usage_rules.sync` would generate from the locked dependencies.
#
# Both are generated from the usage-rules.md files that dependencies ship, so a
# mix.lock bump changes what they should say. Nothing else notices when the
# sync is skipped: the 2026-10-13 ash_a2ui bump left the ash-framework skill a
# hundred lines behind the library for days. This gate makes the skipped sync
# a red build instead.
#
# It uses the sync's own `--check` flag (an Igniter global flag): the task runs
# in full, writes nothing, and exits non-zero if any file would change, be
# created or be removed. The fix is always the same two commands, printed on
# failure. Never hand-edit the generated sections to make this pass.
#
# Usage: scripts/usage-rules-check.sh
#
# The sync runs under MIX_ENV=dev, the environment AGENTS.md is generated in.
# ash_agent_tools contributes a section; it is a dev and test dependency, so an
# environment without it would drop that section and report drift that is not
# there.

set -euo pipefail

root="$(git rev-parse --show-toplevel)"
cd "$root"

if ! MIX_ENV=dev mix usage_rules.sync --check; then
  cat >&2 <<'EOF'

usage-rules: AGENTS.md or .claude/skills is out of date with the locked deps.
Regenerate and commit the result:

    devenv shell -- mix usage_rules.sync --yes
    git add AGENTS.md .claude/skills
EOF
  exit 1
fi

echo "usage-rules: AGENTS.md and .claude/skills match the locked dependencies"
