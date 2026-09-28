---
name: iron-laws
description: "Use when writing or reviewing LiveViews, Oban workers, mix tasks, Ecto queries or anything else in this application's Elixir code, and whenever scripts/iron-laws.sh or the laws judge reports a hit. Covers which of the 26 Iron Laws bite in this repo, how the judge gates precommit and CI, and when a hit may be baselined."
---

# The Iron Laws in this repository

The 26 laws and their reasons are in the `ash_agent_tools:iron-laws` section of
`AGENTS.md` (from `usage-rules/iron-laws.md` in ash_agent_tools, adapted from
phxagents under MIT). This skill covers how they apply *here*. The gate itself
is documented in `docs/IRON-LAWS.md`.

## The gate

```bash
devenv shell -- scripts/iron-laws.sh        # what precommit and CI run
devenv shell -- scripts/iron-laws.sh diff   # only lines you added
devenv shell -- scripts/iron-laws.sh tree   # whole tree against the baseline
```

- **diff** judges every line added since the merge base with `origin/main`,
  including uncommitted and untracked files. A `likely` or `definite` hit fails.
- **tree** judges every tracked `.ex`/`.exs`/`.heex` file and fails on any hit
  that is not in `scripts/iron-laws.baseline.json`, and on any baseline entry
  that no longer fires.
- To check a snippet before writing it:
  `devenv shell -- env MIX_ENV=dev mix ash_agent.laws --code '...'`.

The judge matches text patterns; it does not parse code. Read a hit's `hint`,
then decide. It runs under `MIX_ENV=dev` because ash_agent_tools is a dev-only
dependency.

## The laws that bite here

Ranked by how often this codebase has come near them.

1. **#23: mix tasks start only what they need.** Every `ash_enterprise.*` task
   that needs the database currently calls `app.start`, which also starts Oban
   queues and the projectors. That is baselined debt. A **new** task must not
   add to it: require `app.config`, then start only the Repo and whatever else
   it actually uses. A read-only or introspection task must never drain Oban.
2. **#11: authorize every `handle_event`.** Here that means passing
   `socket.assigns.current_user` as the actor to an Ash action or code
   interface, so the policies decide. The judge only looks for `Ash.can?` in
   the file, so an actor-bearing handler shows up as a hit, and it is
   baselined only once someone has checked that every path it takes carries
   the actor. A handler that calls Ash with `authorize?: false` for a
   person's request is a real violation, whatever the judge says.
3. **#01 and #03: mount runs twice.** Subscribe to PubSub only inside
   `if connected?(socket)`. The dashboard was fixed for exactly this.
4. **#10: no `String.to_atom` on input.** The two existing uses turn a
   compile-time module attribute into a module name for a dev-only dependency,
   the exception the law allows. Anything that comes from a request, an agent
   or a file uses `String.to_existing_atom/1` or an allow-list.
5. **#07, #08, #09: Oban.** Workers declare `unique:`, match string keys in
   `perform/1`, and carry ids, not structs. AshOban triggers already follow
   this; hand-written workers need to follow it too.
6. **#21: `assign_new`.** Fine in function components, where it defaults an
   attribute (the generated `core_components.ex` does this, and it is
   baselined). Not in a LiveView's `mount`.

The platform rules in `CLAUDE.md` come first where they overlap. For example,
"policy checks never query" is stricter than anything in the laws.

## When a hit is wrong

1. Check the hit really is a false positive, and why. Write that reason down.
2. If it is new code, reshape it when you can do so honestly. Don't disguise a
   real violation just to get past the pattern.
3. Otherwise add an entry to `scripts/iron-laws.baseline.json` with `law`,
   `file`, the trimmed line `text`, and a `reason` a reviewer can check. The
   diff check has no baseline: a false positive on a new line gets a reason
   in the commit message, and the entry goes into the baseline in the same
   commit.
4. If the detector itself is wrong (for example, #07 ignores a `unique:` on the
   same line as `use Oban.Worker`), note it for ash_agent_tools and say in the
   baseline reason that the entry can go once the detector is fixed.
