# DRAFT — for Luke's review before posting to expert-lsp/expert#903

**Post as:** comment on closed PR #903 (no reopen request, no new issue
unless the 0.1.10 verification below turns something up)
**Tone rules:** gracious, zero re-litigation; absorb all four review points;
the version-pin context explains without excusing; end with one precise
question, not a pitch.
**Facts to verify before posting:** (a) Serena's current expert pin is still
`v0.1.0-rc.6` (check serena repo/config at post time); (b) optionally run
the 0.1.10 editor session and attach expert.log/project.log if anything
still reaches a nil document — the draft works without it, but it upgrades
"will verify" to "verified".

---

Thanks for taking the time to review and for the context — all fair points,
and the version history explains the confusion on our side: the repro came
from Serena's Elixir support, which pins expert `v0.1.0-rc.6`, so that's
where the `FunctionClauseError` (and their xfail for it) lives — we forked
from a matching commit rather than deliberately testing an old release.
The drive-by installation.md edit and the test placement were wrong calls
on our part; noted for future PRs.

Reading current main, `Expert.Document.Lookup.request_document/1` now
fetch-or-opens (`Store.fetch` → `open_temporary`) and returns
`{:error, :document_not_found}` instead of nil, so the nil-into-`EngineApi`
path shouldn't be reachable from the built-in handler anymore. Agreed that
an API-boundary clause would mask exactly the signal you'd want visible —
point taken on where that kind of handling belongs, too.

Plan on our side:

1. Verify against 0.1.10 in a real editor and attach `expert.log` /
   `project.log` stacktraces here if any `textDocument/*` request still
   reaches a nil document.
2. Take the pin bump upstream with Serena so the xfail can be dropped.

One question so we point clients at the right expectation: for consumers
that walk unopened files (building symbol indexes), is the intended
contract on current versions an LSP error response (e.g. `invalid_request`)
rather than an empty symbol list? Reading main suggests error, which is
fine — we'd just like Serena to assert against the real contract.
