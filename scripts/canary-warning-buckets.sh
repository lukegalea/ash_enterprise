#!/usr/bin/env bash
#
# Bucket the compiler warnings captured by the `canary-warnings` CI job into
# the categories tracked by the Elixir 1.20 burn-down
# (docs/research/elixir-120-viability.md section 5(d)) and print them as a
# markdown table for $GITHUB_STEP_SUMMARY.
#
# Usage: canary-warning-buckets.sh [LOGFILE]
#        Reads the captured `mix compile` log, or stdin when no path is given.
#        Stdout is the summary table; CI appends it to the job summary, but
#        the script itself never touches CI state, so it runs locally against
#        any captured log.
#
# The regexes are anchored on the warning phrases the 1.20 compiler emits.
# They are deliberately plain, because the inventory is the product here: when
# a run shows a large "unbucketed" count, tighten these patterns against the
# actual log rather than trusting the buckets to stay honest on their own.
# Buckets are independent greps -- one warning line can match more than one
# bucket -- so the bucket rows sum to at most, not exactly, the total.

set -euo pipefail

log="${1:--}"

# Slurp stdin up front: the buckets each grep the log once, and a pipe cannot
# be read more than once.
if [ "$log" = "-" ]; then
  log="$(mktemp)"
  cat > "$log"
  trap 'rm -f "$log"' EXIT
fi

count() {
  grep -Eic -- "$1" "$log" || true
}

# Redundant clauses / dead code the refinement across clauses finds.
bucket_redundant='redundant|will never match|cannot match because a previous clause'
# require(M) that 1.20 no longer expands (the igniter#357 class).
bucket_unused_require='unused require'
# Native type checker violations.
bucket_type_violation='violation|will always fail|will never fail|will not succeed'
# Whole-function inference notes.
bucket_inferred='inferred'
# Deprecated syntax/std-lib usage (bit sizes, File.stream!/3, Logger backends...).
bucket_deprecation='deprecat'
# Our own instrumentation lines from the CANARY_INSTRUMENT preamble, not
# compiler warnings -- counted separately so the totals stay comparable. The
# "took" anchor keeps the preamble's "instrumentation skipped" notice from
# counting as a measurement.
bucket_long_verification='long verification.*took'

n_redundant=$(count "$bucket_redundant")
n_unused_require=$(count "$bucket_unused_require")
n_type_violation=$(count "$bucket_type_violation")
n_inferred=$(count "$bucket_inferred")
n_deprecation=$(count "$bucket_deprecation")
n_long=$(count "$bucket_long_verification")
n_total=$(count '^warning:')

n_unbucketed=$(( n_total - n_redundant - n_unused_require - n_type_violation - n_inferred - n_deprecation ))
if [ "$n_unbucketed" -lt 0 ]; then n_unbucketed=0; fi

cat <<EOF
## Elixir 1.20 canary -- compiler warning inventory

From \`mix compile --force\` (no --warnings-as-errors) on Elixir 1.20.4 / OTP 27.3.4.
Buckets are independent greps over the captured log; one line can match more
than one bucket. Unbucketed is the total minus the warning buckets, floored
at zero. Patterns live in \`scripts/canary-warning-buckets.sh\` -- tighten them
there when the unbucketed count grows.

| Bucket | Lines |
| --- | ---: |
| Redundant clause | $n_redundant |
| Unused require | $n_unused_require |
| Type violation | $n_type_violation |
| Inferred type | $n_inferred |
| Deprecation | $n_deprecation |
| **Total \`warning:\` lines** | **$n_total** |
| Unbucketed | $n_unbucketed |
| Long verifications (>10s) | $n_long |
EOF
