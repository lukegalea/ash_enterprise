# ADR 0070 — Upstream-first placement: code goes at the highest layer where it is true

- **Status:** proposed (2026-11-11)
- **Date:** 2026-11-12
- **Related:** [ADR 0005](0005-admin-and-a2ui-division-of-labour.md) (ash_admin and ash_a2ui), [ADR 0050](0050-neobrutalism-design-system.md) (design
  system), [ADR 0056](0056-the-ash-agent-package.md) (the ash_agent package), [ADR 0063](0063-declared-operations-are-a-package.md)
  (declared operations are a package), ash_a2ui [ADR 0001](https://github.com/lukegalea/ash_a2ui/blob/main/docs/adr/0001-custom-component-catalogs.md) (custom component catalogs), [BLEEDING-EDGE.md](../BLEEDING-EDGE.md)

## Context

AE is built on public `ash_*` packages, and host applications are built on AE. Code that every host needs belongs in a
package or in AE. Code that only one host needs belongs in that host. Nothing tells an agent, mid-task, which one
applies, so code lands where the agent happens to be working. A host application in a deployment we operate shows
the cost (checked 2026-11-11):

- The host and AE share 379 same-path `lib` files. 148 are identical except for the namespace (about 10.7k lines).
  Each pair is a second use that was copied instead of moved down.
- The host reads and writes the application env of five dependencies (`ash_judgments :facts`,
  `ash_mdm :allowed_targets`, `ash_open_lineage :http_base_url`, `ash_acp :agent_info`, `ash_bpmn :oban_testing`).
  Each should have been an accessor in the package.
- The host has hand-written LiveViews, colocated hooks and 50 Lit elements of its own. No rule asked anyone to
  justify them, and some duplicate what an A2UI surface already does.

Moving code down has failed in three further ways, all seen in the last two weeks of host UI work:

- **Gaps are found late.** An upstream ash_a2ui change was planned from the DSL documentation. A heading over two
  cards, a "calculated" note and a shadow-DOM styling problem showed up only against the real screen, and the
  upstream PR grew twice. Each time, the host work stopped again.
- **The gaps were not widgets.** None of them was a new component. They were options, fields and DSL shapes on
  components that already existed (`badge_help`, `caption`, `sort_reset`, `label`, `section`, `row_layout`). A rule
  that says "add a widget the catalog lacks" lets an agent say the widget exists and carry on in the host.
- **The round trip is long.** The loop ran: upstream PR, merge, pin bump (once through a fork commit with
  `override: true`), usage-rules sync, then a second host push. Maintainer review was not the bottleneck: the two
  ash_a2ui PRs went from opened to merged in 15 and 16 minutes. What worked was proving the change against a local
  `path:` dependency before opening the upstream PR.

Two pressures act on every placement. The **push**: the second use is the signal to move code down. The **brake**:
move only what two consumers use, with no domain noun and no guessed options. An agent that knows only the push
extracts too early. An agent that knows only the brake leaves everything in the host. This record gives one rule
that holds both, tells an agent when to stop, and says what to do when it does.

## Decision

**Put each piece of code at the highest layer where it is true without a product noun. Find the gaps before you
write code. Allow one local use. Stop at the second.**

### 1. Terms

- **Layers**, highest first: (1) tier-1 libraries (Ash, Phoenix, Oban, Req), the public `ash_*` packages and AE;
  (2) a private extension package owned by one product; (3) the host application.
- **Product noun:** a word from one product's business: its customers, providers, tickets, documents, brand, or
  the name of its design system. Generic platform words (tenant, actor, task, surface, catalog) are not product nouns.
- **0, 1, N:** how many times a capability is used.
  - **0:** a higher layer already expresses it. Use that. Write no local code for it.
  - **1:** the first use, and no higher layer has it. One local version is allowed (section 4).
  - **N:** a second use. Stop and move the first use up a layer, so both uses are back at 0.
- **Second use:** a second use that is written, or a second use that is **anticipated**. Anticipated means named in
  writing: a ticket, a planned host or a customer commitment, inside the problem domain the platform already serves.
  "Someone might want this" is not a second use. This is looser than "a second consumer is committed" on purpose.
  See section 10.

### 2. The brake

These hold for every extraction, including an early one:

1. **Rule of two.** A package owns machinery only when a second use exists (section 1). A package API starts with
   the uses that exist.
2. **No product noun.** Code that needs a product noun to make sense stays in that product's layers (2 or 3). If a
   noun can be stripped, strip it, then extract.
3. **No speculative options.** Each option, field and callback names a caller that uses it today.
4. **Never wrap a tier-1 library**, and never hide a declaration behind a second DSL.
5. **Domain decisions stay in the host:** who may see what, what counts as cleared, which zone a call may leave.
   The mechanism around a decision can move down. The decision itself cannot.

### 3. Find gaps before writing code: the gap map

Before any host code for a feature that uses a package, write a **gap map**. It lists each part of the feature
against what the package can do:

| Part | Expressible | Needs a host swap | Missing upstream | Evidence |
|---|---|---|---|---|

- For UI, a part is each visible element of the target screen: each heading, card, column, badge, note, empty
  state, action and layout rule. For other code, a part is each capability the feature calls.
- **Expressible:** the DSL or API does it today. **Needs a host swap:** a documented extension point covers it
  (a renderer override, a callback, a catalog registered by the host). **Missing upstream:** neither.
- **Evidence is the real code, not the docs.** Render a probe surface against the actual page, or call the API in a
  test, for every row marked expressible. A row checked only against documentation is unverified, and an
  unverified row counts as missing upstream.
- The map goes in the host PR description or its ticket, before the first host commit. Its "missing upstream"
  rows are the scope of the upstream change (section 6). A gap found later is added to the map with the reason
  it was missed.

The gap map is not the tool-gap digest from `mix ash_agent.gaps`. That digest records what agents failed to
find at run time. A recurring entry there is fixed in the package's `usage-rules.md`, not in a gap map.

### 4. The placement ladder for code

Ask in order. Take the first step that fits.

| Step | Question | Action |
|---|---|---|
| 1 | Does a tier-1 library, an `ash_*` package or AE already express it? | Use it. This is 0. Read the package's `usage-rules.md` first. |
| 2 | Is it general (no product noun) but missing? | Add it to the right `ash_*` package, or to AE when it spans packages. Follow the round trip (section 6). |
| 3 | Does it need a product noun, and is it useful to more than one of that product's apps? | Put it in a private extension package owned by that product, with the same shape as a public one: DSL, `usage-rules.md`, its own test app. |
| 4 | Is it host-only: a domain decision, a declaration, wiring? | Keep it in the host. Say why in the module doc or the PR. |

At the first use with no step-1 answer, one local version is allowed. It carries a one-line comment,
`# GAP: <missing concept> (<upstream issue>)`, and the upstream issue is opened in the same change.

At the second use, stop. Do not copy. Move the first use up the ladder, then use it twice at 0. The brake
(section 2) decides how far up it can go.

### 5. The UI ladder

Ask in order, after the gap map exists.

| Step | Question | Action |
|---|---|---|
| U1 | Does the gap map have no "missing upstream" rows? | Write an A2UI surface (`AshA2ui.Standalone` plus `LiveRenderer`) with the existing catalogs. No hand-written LiveView, table, button, banner or form. |
| U2 | Does the map have a "missing upstream" row? | STOP. Add the missing capability upstream (below), then write the surface. |
| U3 | Is it domain UI that no catalog should carry: a designer, a canvas, a wizard with domain writes? | Host UI is allowed, with a written reason (what was tried, what is missing, why upstream is wrong) and an exception row (section 8). |

**U2 covers any missing capability, not only a widget:** a component, an option on a component, a field shape, a row
layout, a DSL entity or option, or an encoder or renderer behaviour. Where it goes follows ash_a2ui ADR 0001,
section 8:

- No product noun, and an ash_a2ui DSL feature needs it: add it to ash_a2ui. A new component goes into the `admin`
  catalog as an additive minor version. An option, field or entity goes into the DSL and its struct.
- A product noun, or only one host uses it: add it to that product's own catalog package. The host registers the
  catalog in the browser (ash_a2ui ADR 0001, section 5). The encoder does not emit third-party catalogs (section 6
  there), so the host surface writes those nodes with the catalog's own `@catalogId`.
- A product's design system is judged element by element. An element with no product noun in its name or props
  (a date picker, a status pill) goes to ash_a2ui like any other U2 capability. An element that carries the
  product's look and feel stays in the product's catalog package. The name of the design system is not a reason
  to keep a generic element in the host.

**Frozen contracts.** Some ash_a2ui modules say "FROZEN CONTRACT … do not change outside an integration commit"
(`Component`, `Field`, `ResolvedView`, `ActionHandler`, the `Info` signatures, the encoder callbacks and the
`LiveRenderer` use-options). A U2 pull request **is** an integration commit for those modules when it is additive:
new optional fields, options or callbacks, defaults that keep current behaviour, a package-side test, and a catalog
version bump when the wire format changes. Removing or renaming a frozen field is not U2. It needs its own ADR in
the package.

### 6. The round trip

Moving code down is one loop, done in this order:

1. **Prove it locally first.** Point the host at the package checkout with a `path:` dependency. Make the package
   change and the host change together, and get both test suites green. Do not commit the `path:` dependency (the
   `cold-clone` CI job fails on it).
2. **Open the upstream PR** with a package-side test for each new capability. Its description lists the gap-map rows
   it closes.
3. **While it waits, the host may pin the PR's commit.** A fork branch, or a first-party package pinned off `main`,
   gets a row in [BLEEDING-EDGE.md](../BLEEDING-EDGE.md) (section 1 for a fork, section 2 for a first-party package)
   in the same commit. `override: true` is allowed only with that row. `bleeding_edge_doc_test.exs` enforces it.
4. **When it merges, one host PR closes the loop.** It bumps the pin to the merged commit, runs
   `mix usage_rules.sync` and its check, bumps the catalog version if the wire changed, and deletes the fork row, the
   `# GAP:` comments and the exception rows the change resolved.

### 7. When to stop, and what to do

An agent stops writing code in a host, AE's own app code included, when any of these is true:

1. It is about to write a second copy of something that exists in another host or package. Search the other repos
   first. The host's list of known copies names the pairs found so far.
2. It is about to read or write `Application.get_env` or `put_env` under a dependency's app name. Add an accessor
   to the package instead.
3. It is about to add a module whose name or purpose matches a package's domain (`*_operations`, `*_judgment*`,
   `*_mdm*`, `*_lineage*`, `*_bpmn*`, `*_decision*`, `*_evidence*`, `*_strangler*`, `*_a2ui*`, `*_agent*`,
   `*_compliance*`).
4. It is about to add a LiveView, LiveComponent, colocated hook, `assets/js` file or Lit element, and no gap map
   exists for the feature.
5. It is about to wrap or patch a dependency to work around a bug. Fix the bug upstream. Record the interim
   workaround in [BLEEDING-EDGE.md](../BLEEDING-EDGE.md) section 3.
6. The fix would let one layer do another layer's job (a gateway that validates, a decision that acts). That is
   the design saying no. Raise a tension. Do not code around it.
7. The same gap blocks the task twice in one session, or agents keep getting the same thing wrong. Fix the
   package's `usage-rules.md`.

When it stops, the agent takes the first of these that applies:

- **(a)** The ticket names the upstream repo: branch there, follow the round trip (section 6), open a draft PR,
  and return the commit for the host pin.
- **(b)** The ticket does not name the repo, or the scope is unclear: write the upstream issue, add the `# GAP:`
  comment and the exception row, and continue with the smallest local step.
- **(c)** It cannot tell whether the code is general, which package owns it, or whether a private package is right:
  raise a tension to the maintainer. Do not guess.
- **(d)** The feature is due, and the upstream change is open as a draft PR: ship the smallest host workaround,
  with an exception row that names the PR and a removal date no later than the package's next pin bump in that
  host.

Stopping decides where code goes. It does not hold a feature hostage to an upstream merge: (b) and (d) let the host
ship, and the exception row makes sure the debt comes back.

An agent opens a pull request in an `ash_*` repo only when the ticket names that repo, and only as a draft. It never
merges, never pushes to a package's `main`, and never publishes to Hex.

### 8. Exceptions

An exception is code or UI that stays below its ladder step on purpose. It is recorded, never silent.

- Each host keeps `docs/UPSTREAM-EXCEPTIONS.md`, one row per item: path, step skipped, reason, upstream issue or PR,
  owner, exit condition, remove-by date, date added. AE's is added with this record. A host creates its own with
  its first row, or when it adopts this record.
- A workaround for a dependency bug is not an exception. It goes in [BLEEDING-EDGE.md](../BLEEDING-EDGE.md) section 3.
- Every row has an exit condition and a remove-by date. Only a step-4 or U3 item that is truly domain may have
  neither.
- Files that were already copies when this record is accepted are not exceptions. They are the host's list of known
  copies, worked down separately.
- **Ownership:** the owner of a row is the person who merged the change that added it. A host's adoption record
  names who answers for its rows as a whole.
- **When a package maintainer is away:** nothing in this record waits on an upstream merge. The host pins the PR's
  commit (section 6, step 3) or ships under (d). Each package's README names who besides its maintainer may merge.
  Until it does, the pin is the path.

### 9. Enforcement

Built with this record:

- The placement checklist near the top of AE's `AGENTS.md`.
- AE's `docs/UPSTREAM-EXCEPTIONS.md`.
- `bleeding_edge_doc_test.exs` (already in CI) covers every fork pin and `override: true` the round trip adds.

Not built yet:

1. A pull request template line: "Gap map: link. Placement: step N, because …". Blocking in review.
2. CI ratchets: the counts of hand-written LiveViews, hooks, JS files, Lit elements and dependency-env reads in a
   host may fall, never rise, without an exception row. Same pattern as `scripts/iron-laws.baseline.json`.
3. A doc test: every `# GAP:` comment links an issue, and every exception row has an owner, an exit condition and a
   remove-by date that has not passed.
4. A review check that flags a new module duplicating a package module or a known copy.

So this record is `accepted, not built` when it is accepted, and becomes `accepted` when items 1 to 3 run in CI.
A rule without a ratchet did not stop host workarounds before, and will not now.

### 10. The early-phase bias, and when it ends

Counting an anticipated second use (section 1) extracts earlier than counting written ones. That is deliberate
while the platform is young and its problem domain is known. It raises the risk of a guessed API, so the brake
(section 2) applies unchanged: the extracted API is the one the named uses need.

Revisit this when the platform's first external host ships, or on 2027-03-31, whichever comes first. If agents
extracted too early, drop "anticipated" and count written second uses only.

### 11. What this record does not do

- It does not reclassify the existing copies. Each host's list of known copies does that.
- It does not create a shared platform package or sync tooling between hosts.
- It does not add a server-side extension point for third-party catalogs. ash_a2ui ADR 0001 keeps that closed until
  a second known user needs one.

## Does it consume ActorContext?

No. This record decides where code is placed and how it moves between repositories. It adds no runtime behaviour,
so there is nothing for `ActorContext` to flow through. The domain decisions it keeps in the host (section 2,
rule 5) are where `ActorContext` is consumed, and this record does not move them.

## Consequences

- Agents have one answer to "where does this go", and the default moves from "where I am working" to "the highest
  layer where it is true".
- Gaps surface before host code is written, from the real screen rather than the documentation, so an upstream
  change is scoped once.
- More work lands in public packages, each with a package-side test. Pin bumps are more frequent, and each one is a
  single host PR.
- Review reads less: one declarative line per use, plus each package change once.
- A hand-written LiveView or hook now needs a written reason. That friction is the point.
- Risk: extraction with a guessed API. The brake and the bias's review date bound it.
- Risk: a host waits on upstream. The fork pin and (d) bound it, at the cost of an exception row with a date.
- A private extension package needs a repo, CI and an owner. Step 3 should be rare, and a private package repo is
  created only when its first real step-3 item exists.

## Reversal

Supersede this record. No code depends on it. The CI ratchets and the doc test are separate scripts with baselines,
removed in the same PR. Packages and private extensions created under it stay, each with its own Reversal. The
`AGENTS.md` checklists go in the same PR.
