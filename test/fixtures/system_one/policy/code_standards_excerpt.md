# Demo engineering standards — excerpt (synthetic)

A fixture policy for the System One proposal mechanism (S1-61 /
CAP2-POLICY). The clauses are an original, synthetic excerpt written for
this repository's test suite in the style of its own house standards; no
real standard text is quoted and no VendorPM wording appears (DEC-MOAT:
the mechanism is domain-free — a domain contributes only policy text like
this, and a subject resource at declaration time).

<!-- SPDX-License-Identifier: CC0-1.0 -->

## std-1 Commit messages

Every commit message is written in the imperative mood: "add validator",
never "added validator". A commit whose only change is formatting says
"format" in its message.

## std-2 Tests must not sleep

A test must not sleep. Any timing dependence is expressed as an explicit
wait on a condition, never as a fixed delay such as `Process.sleep/1`. A
new test that sleeps is rejected in review.

## std-3 Documentation states the thing first

Documentation states the thing it documents in its first sentence.
History, rationale and alternatives come after the statement, in their own
section.
