# ADR 0070 — Upstream-first placement: 0/1/N and the extension ladder

- **Status:** proposed (2026-11-11)
- **Date:** 2026-11-11
- **Relates to:** tutorial lesson 0 (`tutorial/00_philosophy.livemd`, "Zero, one, many"); ADR 0005 (ash_admin and ash_a2ui); ADR 0006 and 0050 (design system); ADR 0056 (the ash_agent package); ADR 0063 (declared operations are a package); keystone ADR 0062 (thin host); `docs/BLEEDING-EDGE.md`
- **Amends:** nothing. This record states a rule the tutorial and keystone ADR 0062 imply, and extends it to placement of code and to UI.

## Context

Tutorial lesson 0 sets the rule for gaps in the model: 0 (the platform says it, use it), 1 (first gap, inelegant local code is fine, leave a one-line comment naming the missing concept), N (the second use is about to be written: stop, and extend the foundation so the next use is back at 0). Its goal is stated plainly: "Minimize the code a human reviewer has to read to trust the change."

The tutorial lists "a package change upstream (`ash_*`)" as the last step down. It does not say when an agent must take that step, and it says nothing about UI. Three facts show that this is a gap:

- Keystone and AE share 379 same-path `lib` files. 148 are identical except for the namespace (about 10.7k lines). Those are N cases that were copied (programme finding X-02, checked 2026-11-11).
- Keystone reads and writes the application env of its dependencies (`ash_judgments :facts`, `ash_mdm :allowed_targets`, `ash_open_lineage :http_base_url`, `ash_acp :agent_info`, `ash_bpmn :oban_testing`). Each is a "1" that should have become an upstream accessor (X-06).
- Keystone has hand-written LiveViews, colocated hooks and a Lit design system (`assets/js/atlas/**`, 50 elements) that no rule asks anyone to justify. Some of it may already exist as an A2UI surface or catalog capability.

Keystone ADR 0062 gives the brake: extract only on a rule of two, with no domain noun, no speculative options. It does not give the push. An agent that reads only 0062 can reasonably leave everything in keystone. An agent that reads only the tutorial can reasonably extract after one repeat inside one host. Agents need one rule that says which one applies and when to stop.

The word "stop" matters. An agent that is mid-task in keystone has a strong pull to finish in keystone. The rule has to tell it, in plain terms, to stop and move.

## Decision

**Put each piece of code at the highest layer where it is true without a VendorPM noun. Build upward only after a first, cheap, local use. Stop at the second use.**

### 1. The placement ladder (code and declarations)

Ask in order. Take the first step that fits.

| Step | Question | Action |
|---|---|---|
| 1 | Does an existing `ash_*` extension, an AE capability, or a tier-1 library already say it? | Use it. This is 0. Read `usage-rules.md` first. |
| 2 | Is it general (no VendorPM, customer, provider or ticket noun) but missing? | Add it to the right public `ash_*` package, or to AE if it is a cross-package concern. Release or pin. Then consume it. |
| 3 | Is it VendorPM-specific but useful to more than one VendorPM app? | Put it in a private VendorPM extension package (same shape as a public one: DSL, `usage-rules.md`, own test app). Consume it from keystone. |
| 4 | Is it truly keystone-only (a domain decision, a declaration, wiring)? | Keep it in keystone. Write why in the module doc or the PR. |

Domain decisions always stay at step 4, even when the mechanism around them moves (keystone ADR 0062, rule 9): who may see what, what counts as cleared, which zone a call may leave.

### 2. The 0/1/N trigger

- **0:** a step-1 answer exists. Use it. No comment needed.
- **1:** no step-1 answer. Inelegant local code is allowed once. It carries a one-line comment: `# GAP: <missing concept> (<upstream issue or ticket>)`. Open the upstream issue in the same change. This is the tutorial's "keep your '1' with a link to it".
- **N:** the second use is about to be written, in any repo that this record covers. STOP. Do not copy. Move the first use up the ladder, then use it twice at 0.

Any second use triggers the stop. The no-domain-noun test then decides whether to extract.

N counts uses across hosts and inside one host. Two hosts is the strongest case (keystone ADR 0062, rule of two). After the stop, the no-domain-noun test decides. If the code names no VendorPM noun, extract. If it names a VendorPM noun and has one consumer app, keep it at step 4 and record the second use as a ledger row.

**Early-phase bias: err on the side of extracting.** The platform is young. While it is, extract when a second use is *anticipated* inside our known problem domain, not only when it has been written. The known domain is vendor, contract, compliance and procurement management, and the platform capabilities around it. "Anticipated" means a named second use: a ticket, a planned host or a known customer need. It does not mean "someone might want this".

This bias does not lift the brake from keystone ADR 0062. The extracted API is the one the known use needs. No guessed options, no knobs for a use nobody has named (0062, rule 5). The code must still pass the no-domain-noun test.

Review trigger: revisit this bias when the platform's first external host ships, or on 2027-03-31, whichever comes first. If agents extracted too early, drop the bias and count real second uses only.

### 3. The UI ladder

Same shape. Ask in order.

| Step | Question | Action |
|---|---|---|
| U1 | Can an A2UI surface (`AshA2ui.Standalone` module, plus `LiveRenderer`) show it, using the existing catalog? | Write the surface. No hand-written LiveView, table, button, banner or form. |
| U2 | Does the surface need a widget the catalog lacks? | STOP. Add a Lit component to `ash_a2ui` (catalog entry, Lit element, probe test), or to the private VendorPM catalog package if it is Atlas or VendorPM look-and-feel. Pin the new ref. Then declare the surface. |
| U3 | Is it real domain UI that no catalog widget should carry (a designer, a canvas, a wizard with domain writes)? | Host-specific UI is allowed. Write a one-paragraph reason (what was tried, which widget is missing, why upstream is wrong) and add an allowlist row. |

A colocated hook, a hand-written LiveView, a LiveComponent, a raw JS file or a Lit element in a host is a U3 item. It needs the reason and the row. "It was faster" is not a reason.

### 4. STOP conditions for agents

An agent must stop coding in keystone (or in AE host code), and either switch to the upstream repo or raise a tension to Luke, when any of these is true:

1. About to write a second copy of anything that already exists in the other host (grep the other repo first; the S7 ledger lists known pairs).
2. About to read or write `Application.get_env` / `put_env` for another app's name (a dependency). Add an accessor upstream instead.
3. About to add a module whose name or purpose matches a package domain (`*_operations`, `*_judgment*`, `*_mdm*`, `*_lineage*`, `*_bpmn*`, `*_decision*`, `*_evidence*`, `*_strangler*`, `*_a2ui*`, `*_agent*`, `*_compliance*`).
4. About to add a LiveView, LiveComponent, colocated hook, `assets/js` file or Lit element, and no U1 answer was tried.
5. About to wrap or monkey-patch a dependency (a "workaround for a bug upstream"). Fix upstream, pin, and log the interim row in `docs/BLEEDING-EDGE.md` section 3.
6. The fix would let one layer do another layer's job (a gateway that validates, a decision that acts). That is the design saying no. Raise a tension; do not code around it.
7. The same gap blocks the task twice in one session, or an agent keeps getting the same thing wrong. Fix the `usage-rules.md`, or record a gap with `mix ash_agent.gaps`.

When it stops, the agent does one of three things, in this order: (a) the ticket names the upstream repo: it opens a branch and a draft PR there, makes the change with a package-side test, and returns the new ref for a pin bump; (b) the ticket does not name the repo, or the scope is unclear: it writes the upstream issue text, adds the `# GAP:` comment and the ledger row, and continues with the smallest local step; (c) the decision is not clear (is it general? which package? is a private package right?): it raises a tension to Luke and does not guess.

An agent may open a draft pull request in a `lukegalea/ash_*` repo only when the ticket names that repo. An agent never merges, never pushes to upstream `main`, and never publishes a package to Hex.

### 5. Exceptions

An exception is a code or UI item that stays below its ladder step on purpose. It is recorded, never silent.

- **Where:** every host has a file `docs/UPSTREAM-EXCEPTIONS.md`. Each row: path, ladder step it skipped, reason, upstream issue or ticket, owner, exit condition, date. A workaround for a dependency bug goes in `docs/BLEEDING-EDGE.md` section 3 instead, as it does today. A bigger or longer-lived exception gets an ADR.
- **Format:** one row per item. No row, no merge (see enforcement).
- **Expiry:** each row has an exit condition. A row with no exit is allowed only for step-4 items that are truly domain.
- **Existing code:** files that were already copies when this record is accepted are not exceptions. They are the S7 ledger (PLS S7). Classification of those files stays with the ledger, not with this record.

### 6. Enforcement

Enforcement is layered, cheapest first. Detail is in the enforcement plan.

1. Agent instructions: a short checklist near the top of AGENTS.md in AE, keystone and each `ash_*` package (links to this record). The ai-sdlc repo gets no AGENTS.md entry; its dispatcher stage prompts and one skill carry the rule instead.
2. A pull request template line: "Placement ladder step N, and why". The line and the review-prompt rule are blocking. The new-module name check starts as a PR comment.
3. CI ratchets: counts of hand-written LiveViews, hooks, JS files, Lit elements and dependency-env reads may fall, never rise, without an exception row. Same pattern as `scripts/iron-laws.baseline.json` and `exemptions-check.sh`.
4. Review lane: the review stage agent flags duplicates against package modules and the S7 ledger.
5. Dispatcher stage prompts and an `upstream-first` skill in the ai-sdlc repo for dispatched agents.

### 7. What this record does not do

- It does not reclassify the 379 shared files. PLS S7 does that.
- It does not create a shared platform package or sync tooling (programme do-not-do list).
- It does not wrap tier-1 libraries (Ash, Oban, Req, Phoenix). That stays forbidden (0062, rule 7).
- It does not lower the brake. A package API is the smallest that its consumers use. No speculative options.

## Consequences

- Agents get one answer to "where does this go". The default moves from "keystone" to "highest layer where it is true".
- More work lands in public packages. Each lands with a package-side test. A pin bump carries it to hosts. Pin trains get busier (IP-20, 21, 22, 50, 64 already ride in pin steps).
- Review reads less. A reviewer reads one declarative line per use plus the package change once. This is the tutorial's measure.
- Friction on purpose: a hand-written LiveView or hook now needs a written reason.
- Risk: over-extraction with a guessed API. The brake is rule 5 of 0062 and the "no domain noun" test. The early-phase bias raises this risk on purpose. If agents extract too early, drop the bias (see its review trigger).
- Risk: instruction bloat. Mitigation: 30 lines in AGENTS.md, rest in this record.
- A private VendorPM package needs a repo, CI and a pin owner. That cost is real. Step 3 should be rare and each use named. The private VendorPM repo is created only when the first real step-3 item exists. Whether Atlas becomes a private VendorPM package is decided in the S7 ledger work.
- The undefined contract for "how a private package plugs a catalog into `ash_a2ui`" (the README lists custom catalogs as out of scope) is now a named blocker for U2. It needs its own short `ash_a2ui` ADR on how catalogs plug in. That ADR blocks step U2.

## Reversal

Supersede this record. Nothing in code depends on it directly. The CI ratchets are separate scripts with baselines; remove them in the same PR. Packages and private extensions already created stay, since each has its own Reversal. The AGENTS.md checklists are deleted by the same PR.
