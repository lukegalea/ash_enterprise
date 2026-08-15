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
#   2  drift detected, OR the check could not run (asyncRewake surfaces the
#      message to the agent — the two cases print very different messages)
#
# Deliberately advisory. This compiles the project, so it runs async and never
# blocks an edit — a hook that adds 20 seconds to every file write gets disabled
# within a day, and a disabled hook catches nothing.
#
# ---------------------------------------------------------------------------
# Why this classifies instead of treating "exit != 0" as drift
# ---------------------------------------------------------------------------
# `mix ash.codegen --check` exits non-zero for two very different reasons:
#
#   (a) it ran, and found pending codegen — real drift;
#   (b) it never got far enough to decide — the project would not compile, a
#       `mix phx.server` was holding the `_build` lock (see CLAUDE.md), deps
#       were missing, devenv or mix was not on PATH, and so on.
#
# Conflating them is dangerous in one direction only. Telling someone to run
# `mix ash.codegen <name>` when the check merely failed to run invites a
# spurious/empty migration plus real resource-snapshot churn — a destructive
# fix for a problem that did not exist. Staying quiet about real drift costs
# almost nothing: the next edit re-runs this hook, and `mix ash.codegen
# --check` is a hard gate in CI.
#
# So the classification is deliberately asymmetric: DRIFT is asserted only on
# a positively recognised drift signature emitted by ash/ash_postgres itself.
# Everything else — every unrecognised failure, including ones not listed
# below — falls through to "the check could not run", which reports the
# captured reason and never suggests generating a migration.
#
# Signatures below were captured from real runs of this project (Elixir 1.18.4,
# ash_postgres). Sources:
#   deps/ash/lib/ash/error/framework/pending_codegen.ex
#   deps/ash_postgres/lib/migration_generator/migration_generator.ex
#   elixir/lib/mix/lib/mix/project.ex (with_build_lock)

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

# Say nothing about projects that are not this one. A session can edit a sibling
# checkout — a library this app depends on, another repo entirely — and those
# have their own tooling, their own migrations, and frequently no devenv at all.
# Reporting on them produced a stream of "the check could not run: devenv.nix
# does not exist" that was accurate about a question nobody asked.
#
# Silence rather than a message: not-this-project is not a condition anyone needs
# to fix, so it should not reach the agent at all.
[ -f "$root/devenv.nix" ] && [ -f "$root/mix.exs" ] || exit 0

cd "$root" || exit 0

# Reports "the check could not run" and exits. $1 is a one-line reason, the
# captured output is appended verbatim so the reason is auditable. This message
# must never tell anyone to generate a migration — see the note above.
report_could_not_run() {
  reason="$1"
  detail="${2-}"

  {
    echo "The Ash codegen drift check could NOT RUN — this is not a drift report."
    echo
    echo "Reason: ${reason}"
    echo
    echo "\`mix ash.codegen --check\` did not get far enough to compare resources"
    echo "against their snapshots, so whether anything has drifted is UNKNOWN."
    echo
    echo "Do NOT run \`mix ash.codegen <name>\` on the strength of this message."
    echo "Generating against a project that could not be checked produces an empty"
    echo "or wrong migration plus resource-snapshot churn. Fix the condition below,"
    echo "then re-run the check by hand:"
    echo
    echo "    devenv shell -- mix ash.codegen --check"

    if [ -n "$detail" ]; then
      echo
      echo "Captured output (last 40 lines):"
      echo "---"
      printf '%s\n' "$detail" | tail -40
      echo "---"
    fi
  }

  exit 2
}

# Everything runs inside devenv; a bare `mix` would use the wrong Elixir and
# write to the wrong MIX_HOME.
command -v devenv >/dev/null 2>&1 ||
  report_could_not_run "devenv is not on PATH, so the check could not be invoked at all."

# Cap the run. When another mix process (classically a stray \`mix phx.server\`)
# holds the \`_build\` lock, mix does not fail — it BLOCKS, printing "Waiting for
# lock on the build directory". Without a cap the hook would sit there until the
# harness timeout killed it, producing no message at all. The cap is below the
# hook's own 300s timeout in .claude/settings.json so we get to report.
timeout_cmd=""
if command -v timeout >/dev/null 2>&1; then
  timeout_cmd="timeout 240"
fi

stderr_file="$(mktemp)"
# shellcheck disable=SC2086
stdout="$($timeout_cmd devenv shell -- mix ash.codegen --check 2>"$stderr_file")"
status=$?
stderr="$(cat "$stderr_file")"
rm -f "$stderr_file"

# In sync. Nothing to say.
[ "$status" -eq 0 ] && exit 0

# Match against both streams with ANSI escapes stripped — mix writes the drift
# messages and the lock notice to stderr, and colours some of them (the lock
# notice is literally prefixed with a reset sequence).
combined="$(printf '%s\n%s\n' "$stdout" "$stderr" | sed $'s/\033\\[[0-9;]*[a-zA-Z]//g')"

if [ "$status" -eq 124 ]; then
  report_could_not_run \
    "The check timed out after 240s. Most often this means another mix process is holding the _build lock — CLAUDE.md warns against running \`mix phx.server\` as a devenv process for exactly this reason. Check for a running server or a stuck mix." \
    "$combined"
fi

# --- Positively identified DRIFT ------------------------------------------
#
# Captured verbatim from real runs:
#
#   ** (Mix) Pending Code Generation Detected for 2 files
#
#     Run with --dry-run to view pending changes
#
# (Ash.Error.Framework.PendingCodegen, re-raised by Mix.Tasks.Ash.Codegen.)
#
# and, when --dev migrations are still lying around:
#
#   Codegen check failed.
#
#   You have migrations remaining that were generated with the --dev flag.
#
#   Run `mix ash.codegen <name>` to remove the dev migrations and replace them
#   with production-ready migrations.
#
# Both mean the check RAN and reached a verdict, so both get the drift message.
# Note this is tested before any infrastructure signature: a run that waited on
# the build lock and then completed still produced a real verdict.
if printf '%s' "$combined" | grep -qF "Pending Code Generation Detected"; then
  cat <<'MESSAGE'
Ash resources have drifted from the generated migrations.

`mix ash.codegen --check` ran and reported pending code generation, which means
a resource was changed without regenerating. This is a hard gate in CI.

Fix it with:

    devenv shell -- mix ash.codegen <descriptive_name>
    devenv shell -- mix ash.migrate
MESSAGE

  exit 2
fi

if printf '%s' "$combined" | grep -qF "migrations remaining that were generated with the --dev flag"; then
  cat <<'MESSAGE'
Ash codegen is not finished: `--dev` migrations are still in the tree.

`mix ash.codegen --check` ran and reported leftover migrations generated with
`--dev`. They are temporary and must be replaced with named, production-ready
migrations before this passes CI.

Fix it with:

    devenv shell -- mix ash.codegen <descriptive_name>
    devenv shell -- mix ash.migrate
MESSAGE

  exit 2
fi

# --- Everything else: the check could not run ------------------------------
#
# Below is only about phrasing a useful reason. Classification has already been
# decided by falling through the drift test above, so an unrecognised failure
# lands here too, which is the intended fail-safe direction.
if printf '%s' "$combined" | grep -qiE "waiting for lock on the build directory|lock on the (build|deps) directory|held by process"; then
  reason="Another mix process holds the _build lock (CLAUDE.md: do not run \`mix phx.server\` as a devenv process). The check could not complete."
elif printf '%s' "$combined" | grep -qiE "compilation error|could not compile|compilation failed|CompileError|DslError"; then
  reason="The project does not compile, so no resource could be inspected. The compiler already reports this; it is not drift."
elif printf '%s' "$combined" | grep -qiE "unchecked dependencies|errors on dependencies|dependency is not available|deps\.get"; then
  reason="Dependencies are missing or out of date (\`mix deps.get\`). The check never reached the resources."
elif printf '%s' "$combined" | grep -qiE "econnrefused|connection refused|tcp connect|could not connect|DBConnection.ConnectionError"; then
  reason="The database was unreachable. Note PGPORT is dynamic in this project — devenv shifts it when 5432 is taken; never hardcode it (CLAUDE.md)."
elif printf '%s' "$combined" | grep -qiE "command not found|no such file or directory|could not find a Mix.Project|mix: not found"; then
  reason="The mix task could not be invoked in this environment (missing mix, missing project, or a broken devenv shell)."
elif printf '%s' "$combined" | grep -qiE "error: |devenv|nix"; then
  reason="The devenv/nix shell failed to start, so mix never ran."
else
  reason="\`mix ash.codegen --check\` exited ${status} without emitting a recognised drift signature. Treated as an infrastructure failure rather than drift, on purpose."
fi

report_could_not_run "$reason" "$combined"
