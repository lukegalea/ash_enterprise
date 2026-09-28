# The iron-laws judge and agent-docs validation

Two gates, in `mix precommit`, `devenv shell -- check` and CI. They share one
policy: a check that is already failing when it lands gets ignored. So every
existing hit was reviewed when the gates were switched on, and each one was
either fixed or written into a baseline together with the reason it stays.

    devenv shell -- scripts/iron-laws.sh         # the laws judge: diff + tree
    devenv shell -- scripts/extra-docs.sh        # EXTRA_DOCS=1 mix docs, filtered

## The iron-laws judge

`mix ash_agent.laws`, from ash_agent_tools, checks Elixir source against the 26
Iron Laws (adapted from phxagents, MIT; the full text is the
`ash_agent_tools:iron-laws` section of `AGENTS.md`). It is deterministic pattern
matching. It does not boot or compile the application. It sorts each hit into
one of three certainty tiers. For how the laws apply in this codebase, see the
`iron-laws` skill in `.claude/skills/iron-laws/SKILL.md`.

`scripts/iron-laws.sh` runs it two ways:

- **diff**: every line added since the merge base with `origin/main`, including
  uncommitted and untracked files. In CI, the base is the PR's target branch,
  or for a push, the commit the push started from. An empty diff passes.
  This is the check the ticket asked for:
  `git diff origin/main | mix ash_agent.laws - --diff`. The script also maps
  each hit back to its file, so a baseline entry covers the hit in this mode
  too.
- **tree**: every tracked `.ex`, `.exs` and `.heex` file, checked against
  `scripts/iron-laws.baseline.json`. This mode catches what the diff mode can't
  see: the judge skips its whole-file detectors on a diff, because a diff lacks
  the context they need.

Both modes fail on any hit at the judge's default floor, `likely` or above,
that isn't in the baseline. Review-tier hits are counted but never fail the
run. The tree mode also fails when a baseline entry stops firing, so an excuse
can't outlive the code it excused.

The judge exits 0 whether or not it finds anything. Its verdict is the
`clean?` field in its JSON, and the script reads that field with `jq`, which
both devenv and GitHub's runners provide. ash_agent_tools is an `only: :dev`
dependency, so the script always runs the judge under `MIX_ENV=dev`, even
from `mix precommit`, which itself runs under `test`.

### Blocking, not advisory

The ticket suggested running the judge in advisory mode for its first week, to
see what false positives it raised against real ash_enterprise code. That
review happened up front instead: the full tree was judged at the `review`
floor, and every `likely` or `definite` hit is accounted for below. Since the
diff mode only ever judges lines a change adds, a blocking gate can only
fail a change on code that change wrote.

### The baseline, as landed (2026-09-28, ash_agent_tools 304c1c5)

The judge found 22 hits at `likely` or above.

**Fixed (1):**

- **#03** `DashboardLive.mount/3` subscribed to PubSub on the dead render as
  well as the connected one. It now subscribes only when connected.

**Baselined (21):** each entry in `scripts/iron-laws.baseline.json` carries its
reason.

| Law | Hits | Why it stays |
|---|---|---|
| #23 mix tasks start only what they need | 10 | Real debt. Every task that writes through Ash calls `app.start`. Converting them to `app.config` plus starting only the Repo is follow-up work from `docs/reviews/iron-law-audit.md`, fix item 3. `audit.verify` and `bpmn.publish` go first, because a verify or deploy task must not drain Oban. |
| #21 no `assign_new` for per-mount values | 5 | False positive. These are function components in the generated `core_components.ex`, where `assign_new` defaults an attribute the caller left out. The law is about LiveView `mount`. |
| #11 authorize every `handle_event` | 3 | Authorized through policies. Each handler passes the signed-in user as actor to Ash-backed calls, which is one of the two forms the law accepts. The detector only looks for `Ash.can?` in the file. |
| #10 no `String.to_atom` on user input | 2 | A compile-time constant naming a dev-only module, which is the exception the law itself makes. |
| #07 Oban jobs are idempotent | 1 | A detector bug. `unique:` is on the same line as `use Oban.Worker`, and the window detector starts looking one line after the match (`Enum.slice(lines, no, window)` with a 1-based `no`). When ash_agent_tools fixes it, the tree mode will report the entry as stale. |

Review-tier notes (14, never failing): #16 `File.read!` without
`@external_resource`, mostly in tests, which read at runtime, not compile time;
#24, one catch-all near a Repo call in the compliance seeds; #02, one
comprehension over an assign in `core_components.ex`.

### Adding to the baseline

Fix the code if you honestly can. If a hit really is a false positive, add
`{law, file, text, reason}` to the baseline in the same commit. `text` is the
flagged line with its leading and trailing whitespace trimmed, and `reason`
must be something a reviewer can check. Keys never include line numbers, so an
edit elsewhere in the file doesn't invalidate an entry.

## Agent-docs validation (EXTRA_DOCS)

The agent-facing markdown (`AGENTS.md`, `CLAUDE.md` and every
`.claude/skills/*/SKILL.md`) makes a lot of references to modules and
functions, and nothing compiles them. `mix docs` with `EXTRA_DOCS=1` passes
those files through ex_doc's extras pipeline, the pattern endorsed in
elixir-lang/ex_doc#2272. A reference that no longer resolves then warns the
same way it would in a moduledoc. The same build also checks every moduledoc
in the application. `mix docs` is configured here only as a validator:
nothing publishes these docs. See `docs/0` in `mix.exs`.

`scripts/extra-docs.sh` builds the docs and fails on every ex_doc warning,
with two exceptions:

1. **Links to repository files.** ex_doc can only resolve a link to a page it
   renders, so a link from `AGENTS.md` to `deps/ash_oban/usage-rules.md`, or
   from the README to an ADR, always warns. If the target exists relative to
   the linking file or to the repository root, the script drops the warning. A
   link to a file that exists nowhere still fails. (`mix ast.check` separately
   checks the links in `AGENTS.md`.)
2. **`scripts/extra-docs.baseline`**, which holds only warnings in *generated*
   files, the ones `mix usage_rules.sync` rewrites and nobody may hand-edit:
   - two references in `AGENTS.md` that come from upstream usage rules;
   - eighteen hidden mix-task modules in the usage_rules-built `ash-framework`
     and `phoenix-web` skills.

   Their fixes belong upstream. A baseline line that stops matching fails the
   check.

Hand-written docs are always fixed, never baselined. When this landed, it
fixed three moduledoc callback references in `AshEnterprise.Audit.EventSource`
(they now name `AshBpmn.EventSource`) and one broken relative link in
`AshEnterprise.Bpmn.TaskCandidate`. Four references that deliberately name
hidden or private functions are listed in `skip_code_autolink_to`, which is
ex_doc's documented escape hatch for exactly that case.

To validate other markdown, pass globs separated by spaces:

    EXTRA_DOCS='docs/adr/*.md docs/manifesto/*.md' devenv shell -- env MIX_ENV=dev mix docs
