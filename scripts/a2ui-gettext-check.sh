#!/usr/bin/env bash
#
# Fail when the A2UI catalogs no longer match what ash_a2ui would write.
#
#   priv/gettext/a2ui_metadata.pot  the labels of this application's surfaces,
#                                   from `mix ash_a2ui.gettext.extract_metadata`
#   priv/gettext/ash_a2ui.pot       the library's own strings, copied from the
#                                   locked dependency by `mix ash_a2ui.gen.gettext`
#
# Both are derived, so a surface change or a dependency bump makes them stale and
# leaves new msgids untranslated. The fix is printed on failure.
#
# Why not `extract_metadata --check-up-to-date` alone: `mix gettext.extract
# --check-up-to-date` (the other gate) rewrites every .pot of the backend into
# Gettext's canonical form, which has no blank line after the header comments;
# ash_a2ui writes one. The committed files are in Gettext's form, so the
# comparison here ignores blank lines. When ash_a2ui drops that blank line, this
# script reduces to `mix ash_a2ui.gettext.extract_metadata --check-up-to-date`.
#
# Usage: scripts/a2ui-gettext-check.sh

set -euo pipefail

root="$(git rev-parse --show-toplevel)"
cd "$root"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail=0

mix ash_a2ui.gettext.extract_metadata --output "$tmp/a2ui_metadata.pot" >/dev/null
if ! diff -B priv/gettext/a2ui_metadata.pot "$tmp/a2ui_metadata.pot" >&2; then
  echo "priv/gettext/a2ui_metadata.pot is out of date. Run: mix ash_a2ui.gettext.extract_metadata && mix gettext.extract && mix gettext.merge priv/gettext" >&2
  fail=1
fi

if ! diff -B deps/ash_a2ui/priv/gettext/ash_a2ui.pot priv/gettext/ash_a2ui.pot >&2; then
  echo "priv/gettext/ash_a2ui.pot no longer matches the locked ash_a2ui. Run: mix ash_a2ui.gen.gettext && mix gettext.extract && mix gettext.merge priv/gettext" >&2
  fail=1
fi

exit "$fail"
