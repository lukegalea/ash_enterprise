# ADR 0033 — The A2UI experience layer is adopted app-wide: experience v2 with the admin catalog

- **Status:** accepted
- **Date:** 2026-09-09

## Context

The A2UI surfaces in this application render from a payload the `ash_a2ui`
library encodes, and a client-side catalog renders that payload. Through the
vpm-14 base the wire payload described *widgets*, not *intent*: rows offered a
single "Select" button (whose only effect was populating a permanently visible
form), pagination chrome rendered whether or not there was anything to page,
a successful action produced an untyped status string, and an empty table
rendered nothing at all. Each of those is defensible as a minimal protocol
tier, and each is the wrong admin experience: a screen whose every affordance
is "Select" does not tell a person what tasks exist.

Upstream (`ash_a2ui`), that gap is now closed by two changes shipped on the
`feat/catalog-admin-v1` branch, each driven by a written acceptance oracle
(`.sdlc/acceptance/A2UI-101.yaml`, `A2UI-101B.yaml` in the library
repository):

* **Experience v2** (`experience_version: 2`) — explicit task modes
  (browse / create / view / edit) with semantic row controls (`view_record`,
  `start_edit`) and a `start_create` affordance, a task panel gated behind
  `/ui/panel/*` state with mode-aware headings and a primary label,
  conditional pagination driven by the query state, a data-driven empty
  state, and typed feedback (`/ui/feedback` kind + message). Under the
  default version 1 the output is byte-identical to the previous release;
  the library's full suite pins that.
* **The admin catalog** (`catalog: :admin_v1`) — a semantic component
  vocabulary (`entityPage`, `dataGrid`, `recordPanel`, `statusBanner`, …)
  emitted only when v2 is also on. Surfaces using advanced features
  (sections, reports, export, editable fields, nested forms) keep those
  subtrees byte-equal to the basic-v2 composition, so the upgrade is
  core-only by construction. The handler gains nothing: zero new action
  names or dispatch clauses, proven by test.

The renderer for the admin catalog ships as a plain ES module in the library
(`priv/js/ash_admin_catalog.js`), registering under its own catalog id
(`https://ash-a2ui.dev/catalogs/admin/v1`); the message processor resolves a
surface's catalog by exact id, so basic and admin surfaces coexist without
negotiation.

The question for this repository was not *whether the layer works* — its
oracle suites and the byte-compat gate answer that — but *whether an
application turns it on app-wide by configuration*, and what that commits
us to.

## Decision

Turn the whole layer on, app-wide, by configuration:

```elixir
config :ash_a2ui, experience_version: 2, catalog: :admin_v1
```

No per-surface opt-in exists or is needed: every A2UI surface in this
application — the original screens, the canonical and legacy surfaces from
vpm-14, and anything the agent composes — is `AshA2ui.Standalone`-based, so
one config tuple moves all of them together. The assets side registers the
admin catalog as a *sibling* catalog alongside the merged basic one, passing
the merged catalog as the admin catalog's base so admin surfaces inherit the
basic-catalog corrections (combobox pickers, search composites) too. The
host also themes the admin catalog through its designed seam (`--ash-admin-*`
/ `--a2ui-*` custom properties in `app.css`) and repairs the small set of
host-markup accessibility issues the new Playwright axe tier surfaced
(theme-toggle button names, logo alt text, and the light-theme A2UI accent,
which failed AA contrast in both of its roles and now uses the 700 step of
the same hue inside A2UI surfaces).

The dependency pin moves from a SHA ref to the `feat/catalog-admin-v1`
branch, because both PRs are stacked there and neither has merged. `mix.lock`
records the exact commit, so builds stay reproducible while the pin lasts.

## Consequences

**Made easy.** Every A2UI screen gains task modes, conditional pagination,
empty states, and typed feedback in one commit, and every future surface
inherits them for free. The acceptance evidence carries over: the layer's
behaviour is pinned by 31 oracle-tagged library tests, and this repository
adds a Playwright tier (`assets/e2e/a2ui_admin_experience.spec.ts`) that
exercises the real rendered components — create / view / edit round-trips
through the actual sign-in flow, empty-state and pagination behaviour on
real data, and axe-core scans with zero serious or critical violations in
browse and task states.

**Made hard.** The experience layer is wire-visible: snapshots or downstream
consumers that scrape A2UI payloads will see the new component vocabulary and
state paths. Inside this repository nothing consumes the payloads except the
renderer, so the blast radius is the screens themselves. The host test suite
needed exactly one change (`row_count/3` in the surface policy test now reads
the records list instead of "the longest list in the data model", because v2
stores non-row state — empty-state and pagination sentinels — in the data
model too); the suite's other 277 tests pass unmodified, which is the
byte-compat gate doing its job from the consumer side.

**Carried.** The branch pin is an unfinished sentence: it exists so this
adoption can land before the upstream PRs do, and it must not outlive them.
When `feat/experience-v1` and `feat/catalog-admin-v1` merge upstream, the pin
moves to a tag (or main) in a one-line change plus `mix deps.get`.

## Reversal

Tier 3 in [docs/manifesto/06-reversibility.md](../manifesto/06-reversibility.md),
and the exit stays what it always was, with two small additions.

**To switch the experience off:** delete the `config :ash_a2ui` tuple. Under
version 1 the library emits byte-identical v1 payloads (the library's
compat suite pins this), every surface returns to the pre-adoption screens,
and the renderer's admin catalog simply never resolves — no surface carries
its catalog id. This is a one-line revert that requires no other edit.

**To leave v2 on but drop the admin catalog:** set `catalog: :basic`. v2
semantics stay; the wire returns to the basic component vocabulary.

**To remove the integration entirely:** the tier-3 boundary still holds —
delete the `ash_a2ui` dependency line, `lib/ash_enterprise_web/a2ui/`, the
routes and live_session, the two catalog blocks and the admin wiring in
`assets/js/app.js`, the `--a2ui-*`/`--ash-admin-*` theme blocks in
`assets/css/app.css`, and the `assets/e2e/` tier. The database is untouched:
the experience layer stores no state.

**The signal to watch:** the branch pin. If the upstream PRs stall long
enough that this branch starts drifting from the library's mainline, the
right move is to merge upstream first and re-pin — carrying a long-lived
fork of a tier-3 dependency is the failure mode the SHA-pinning in the base
was chosen to avoid.

## Correction — 2026-09-20: the pin landed, and the sentence is finished

The branch pin described above no longer exists, so three statements in this
record are now false and are left in place rather than edited, because what the
decision looked like while it was still open is the part worth keeping.

`feat/experience-v1` and `feat/catalog-admin-v1` both merged upstream
(`ash_a2ui` 769a0ad, then 53c1a0c). The dependency tracks `main` and `mix.lock`
holds the merged commit, which is the move the **Carried** section said to make
and the resolution of **the signal to watch**. Nothing drifted: the pin was open
for two days.

Two consequences for the sections above.

**The reversal ladder is shorter than it was.** "Delete the `config :ash_a2ui`
tuple" and "set `catalog: :basic`" are unchanged and remain one-line reverts.
What has gone is the third rung — there is no branch to unpin, so reverting the
experience no longer implies anything about the dependency at all.

**The one test that had to change has company now.** `row_count/3` was the only
consumer-side edit at adoption. Two further defects surfaced afterwards, both
from looking at the rendered screens rather than the payload, and both fixed
upstream: surface headings were the resource's module short name, so
`/app/legacy-users` was titled "User"; and enum values reached grid cells as raw
atoms while the form picker for the same field showed labels. Neither was a
regression from this adoption — v1 had both — but v2 is where they became
visible, which is the argument for the acceptance tier this ADR introduced.
