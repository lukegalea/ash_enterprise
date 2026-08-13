#!/usr/bin/env bash
#
# Warns when Ash resources have drifted from their generated migrations.
#
# Ash derives migrations as a DIFF against resource snapshots, so editing a
# resource without running `mix ash.codegen` leaves the schema silently behind
# the code. Nothing fails at the point of the edit; it surfaces later as a
# migration that does not exist, or — worse — as a deploy against a schema that
# does not match.
#
# Reads the PostToolUse hook payload on stdin and exits:
#   0  not a resource edit, or codegen is in sync
#   2  drift detected (asyncRewake surfaces the message to the agent)
#
# Deliberately advisory. This compiles the project, so it runs async and never
# blocks an edit — a hook that adds 20 seconds to every file write gets disabled
# within a day, and a disabled hook catches nothing.

set -uo pipefail

payload="$(cat)"

file="$(printf '%s' "$payload" | jq -r '.tool_input.file_path // .tool_response.filePath // empty')"

# Only Elixir source under lib/ can change a resource definition. Tests,
# migrations, config and docs cannot.
case "$file" in
  */lib/*.ex) ;;
  *) exit 0 ;;
esac

# Resolve the project root from the edited file rather than trusting the working
# directory, which is not guaranteed for hook execution.
root="${file%%/lib/*}"
[ -d "$root" ] || exit 0
cd "$root" || exit 0

# Everything runs inside devenv; a bare `mix` would use the wrong Elixir and
# write to the wrong MIX_HOME. If devenv is unavailable, stay silent rather than
# reporting a failure that is about the environment, not the code.
command -v devenv >/dev/null 2>&1 || exit 0

if output="$(devenv shell -- mix ash.codegen --check 2>&1)"; then
  exit 0
fi

# `--check` also fails when the project does not compile. That is already
# reported by the compiler, and repeating it here as "drift" would be actively
# misleading.
if printf '%s' "$output" | grep -qiE "compilation (error|failed)|CompileError"; then
  exit 0
fi

cat <<'MESSAGE'
Ash resources have drifted from the generated migrations.

`mix ash.codegen --check` failed, which means a resource was changed without
regenerating. This is a hard gate in CI.

Fix it with:

    devenv shell -- mix ash.codegen <descriptive_name>
    devenv shell -- mix ash.migrate
MESSAGE

exit 2
