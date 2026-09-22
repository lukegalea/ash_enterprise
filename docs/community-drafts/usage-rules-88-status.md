# STATUS — usage_rules#88 (not a post; internal brief for Luke)

**Checked:** 2026-09-22. No new activity from Zach since your 19:52 comment
(2026-09-21) linking ex_doc#2272 — his latest is the pair of issue comments
at 15:12/15:13 ("lean on ex_doc's own warnings" / "maybe an ex_doc
enhancement") plus **three inline review comments** that are easy to miss
because the review body is empty.

## Zach's open inline review comments (on `validate-references` @ 33079fb)

1. `lib/mix/tasks/usage_rules.validate.ex` — "Don't think we really need a
   `--all`" → drop the flag, managed scope only. (Also simplifies help text
   and tests.)
2. `usage_rules.validate.ex:~102` — "Should we do a simpler
   `String.contains?` here?" — targets the `managed-by: usage-rules` marker
   check. Current HEAD uses `File.read!(&1) =~ "managed-by: usage-rules"`,
   which may already satisfy him — confirm and reply on the thread.
3. `lib/usage_rules/validator.ex` — "We can make this compile conditionally
   on ExDoc being available" → wrap the ExDoc-dependent module (or sections)
   in `if Code.ensure_loaded?(ExDoc)`-style conditional compilation, instead
   of runtime-only `Code.ensure_loaded` checks.

## Suggested next actions on the PR (Luke-gated)

- Address 1–3 in one push, then reply to Zach summarizing (he asked for
  less hand-rolled machinery; the conditional-compile change is the
  substantive one).
- Consider whether the ex_doc#2272 outcome should reshape the PR further:
  José's `EXTRA_DOCS` pattern (verified working today, see
  `ex-doc-2272-extradocs-reply.md`) validates managed markdown via a plain
  docs build with zero new code. If Zach likes it, `mix usage_rules.validate`
  could shrink to roughly "EXTRA_DOCS plumbing + the bare-span special case"
  — or the README could just document the mix.exs snippet for library
  authors and the task could focus on scope discovery. Worth floating to
  Zach only after ex_doc#2272 settles, to avoid churning the PR twice.
- Housekeeping before merge: running `mix docs` on the branch warns about
  `validator.ex:12` moduledoc refs to hidden ExDoc functions
  (`ExDoc.Extras.build/2`, `ExDoc.Formatter.autolink/5`) — reword to plain
  text or they'll trip any `warnings_as_errors` docs CI.
