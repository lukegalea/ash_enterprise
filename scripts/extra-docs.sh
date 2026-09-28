#!/usr/bin/env bash
#
# Validate the agent-facing markdown (AGENTS.md, CLAUDE.md, every
# .claude/skills/*/SKILL.md) and the moduledocs by building the docs with
# EXTRA_DOCS=1, the ex_doc#2272 pattern (see docs/0 in mix.exs). Every
# warning ex_doc prints fails the run, with two exceptions:
#
#   1. "references file X but it does not exist" when X does exist in the
#      repository. ex_doc can only resolve links to pages it renders, so a
#      link from AGENTS.md to deps/ash_oban/usage-rules.md, or from the README
#      to docs/adr/0001-*.md, always warns even though the file is there. If X
#      exists relative to the referencing file or to the repository root, the
#      link is fine and the warning is dropped. A link to a file that exists
#      nowhere is a real broken link and still fails.
#   2. Entries in scripts/extra-docs.baseline: warnings in generated files we
#      must not edit (AGENTS.md sections, the usage_rules-built skills), each
#      with its reason. A baseline line that no longer matches also fails.
#
# Usage: scripts/extra-docs.sh [LOGFILE]
#        With LOGFILE, check a captured `mix docs` log instead of building.
#
# ex_doc is `only: :dev`, so the build runs under MIX_ENV=dev.

set -euo pipefail

root="$(git rev-parse --show-toplevel)"
cd "$root"

baseline="scripts/extra-docs.baseline"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

if [ $# -ge 1 ]; then
  cp "$1" "$tmp/docs.log"
else
  MIX_ENV=dev EXTRA_DOCS=1 mix docs > "$tmp/docs.log" 2>&1 || {
    cat "$tmp/docs.log" >&2
    echo "extra-docs: mix docs failed to build" >&2
    exit 1
  }
fi

# ex_doc prints each warning, a source excerpt, then a "└─ LOCATION" line.
# The formatters (html, epub, markdown) repeat every warning, hence sort -u.
# LOCATION is one of
#   AGENTS.md:1571: (file)
#   lib/x.ex:78: Some.Module (module)
#   (ash_enterprise 0.1.0) lib/x.ex:86: Some.Module.fun/1
# and is reduced to its path.
awk '
  /warning: / { sub(/^.*warning: /, ""); msg = $0; next }
  msg != "" && /└─/ {
    loc = $0
    sub(/^.*└─ */, "", loc)
    sub(/^\([^)]*\) */, "", loc)
    sub(/:.*$/, "", loc)
    print msg "\t" loc
    msg = ""
  }
' "$tmp/docs.log" | sort -u > "$tmp/warnings"

: > "$tmp/remaining"
while IFS=$'\t' read -r msg loc; do
  if [[ "$msg" =~ ^documentation\ references\ file\ \"([^\"]*)\"\ but\ it\ does\ not\ exist$ ]]; then
    target="${BASH_REMATCH[1]%%#*}"
    if [ -e "$(dirname "$loc")/$target" ] || [ -e "$target" ]; then
      continue
    fi
  fi
  printf '%s\t%s\n' "$msg" "$loc" >> "$tmp/remaining"
done < "$tmp/warnings"

# Baseline lines are "MESSAGE<TAB>PATH"; blank lines and # comments are ignored.
grep -v -e '^#' -e '^[[:space:]]*$' "$baseline" | sort -u > "$tmp/allowed" || true
sort -u -o "$tmp/remaining" "$tmp/remaining"

new="$(comm -23 "$tmp/remaining" "$tmp/allowed")"
stale="$(comm -13 "$tmp/remaining" "$tmp/allowed")"
status=0

if [ -n "$new" ]; then
  echo "extra-docs: documentation references that do not resolve:" >&2
  echo "$new" | awk -F'\t' '{ print "  " $2 ": " $1 }' >&2
  status=1
fi

if [ -n "$stale" ]; then
  echo "extra-docs: baseline entries that no longer fire -- delete them from $baseline:" >&2
  echo "$stale" | awk -F'\t' '{ print "  " $2 ": " $1 }' >&2
  status=1
fi

if [ "$status" -eq 0 ]; then
  echo "extra-docs: $(wc -l < "$tmp/warnings") distinct ex_doc warnings, all resolvable repository links or baselined"
fi

exit "$status"
