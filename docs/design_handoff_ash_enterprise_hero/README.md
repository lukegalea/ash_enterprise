# Handoff: Ash Enterprise homepage hero (variation 2B)

## Overview

A replacement above-the-fold hero and first below-fold section for the Ash Enterprise
marketing homepage (`site/src/pages/index.astro` in the `ash_enterprise` repo).

It implements the "Enterprise Atelier" art direction from the positioning brief:

- **Fold:** a 50/50 split — warm paper panel (eyebrow, H1, supporting line, two CTAs, trust
  line) on the left; code specimen and derived-outputs list on a slightly deeper paper panel
  on the right.
- **Below fold:** the "leverage" section intro, followed by **Fig. 1**, a cutaway-elevation
  diagram of the stack: BEAM → Elixir/OTP + Phoenix → Ash → the Ash ecosystem → Ash Enterprise.

Primary CTA throughout is **Explore the live demo**. Secondary is **Read the doctrine**.

## About the design files

The files in this bundle are **design references written as HTML** — prototypes showing the
intended look and structure, not production code to paste in. The task is to **rebuild this
design inside the existing Astro site** (`site/`), using its established patterns: Tailwind 4
utility classes, the token variables in `src/styles/global.css`, the `Section.astro` /
`CodePanel.astro` components, `withBase()` for every internal href, and the
`data-theme` dark-mode scheme documented in `site/README.md`.

Two files are included:

| File | What it is |
|---|---|
| `AshEnterpriseHero.dc.html` | **The approved design (2B).** Open in a browser. |
| `AshEnterpriseHero-all-variations.dc.html` | Full exploration canvas — turn 1 (1A/1B/1C) and turn 2 (2A/2B). Context only. |
| `support.js` | Runtime needed to open either HTML file locally. Not part of the implementation. |

## Fidelity

**High fidelity.** Colours, type sizes, spacing and copy are final and should be matched
exactly. The one caveat is noted under *Open questions* below.

Design width is **1440px**. The prototype is a fixed-width artboard; responsive behaviour is
specified in *Responsive behaviour* and must be built, not inferred from the artboard.

## Screens / views

### 1. Hero (above the fold)

**Purpose:** in under ten seconds, a CTO learns the category, the audience, the mechanism, and
the next action.

**Layout**

- Page background `#F3EFE4`. Outer hairline `1px solid #CDC6B7`.
- Top bar: `flex`, `justify-content: space-between`, padding `20px 56px`, bottom border
  `1px solid #CDC6B7`. Wordmark left, six nav links right in a `flex` row with `gap: 32px`.
- Fold: CSS grid, `grid-template-columns: minmax(0,1fr) minmax(0,1fr)`, `min-height: 740px`.
  - **Left cell:** padding `96px 64px 96px 56px`, `flex-direction: column`,
    `justify-content: center`.
  - **Right cell:** background `#EDE9DC`, `border-left: 1px solid #CDC6B7`, padding `72px 56px`,
    vertically centred.

**Components — left cell**

| Element | Spec | Copy |
|---|---|---|
| Eyebrow | IBM Plex Mono 12px, `letter-spacing: 0.18em`, uppercase, `#A5623B` | For small senior teams and capable agents |
| H1 | Newsreader 78px / `line-height: 1.0` / `letter-spacing: -0.025em`, weight 400, `#20221F`; the phrase "your headcount." is italic and `#35594A`. `margin-top: 28px` | Build above *your headcount.* |
| Supporting line | Geist 19px / 1.6, `#20221F`, `max-width: 540px`, `text-wrap: pretty`, `margin-top: 28px` | Declare the hard parts once. Inherit the controls. Derive the surfaces. Keep the code worth owning — on a stack that has been carrying serious systems for twenty-five years. |
| Primary CTA | Background `#C94D34`, text `#F3EFE4`, padding `16px 28px`, `border-radius: 2px`, Geist 16px/500, trailing `→` with `gap: 10px` | Explore the live demo → |
| Secondary CTA | Text `#35594A`, padding `16px 4px`, `border-bottom: 1px solid #35594A`, no background, no radius | Read the doctrine |
| CTA row | `flex`, `align-items: center`, `gap: 24px`, `margin-top: 40px` | — |
| Trust line | `margin-top: 56px`, `padding-top: 24px`, `border-top: 1px solid #CDC6B7`; `flex` row, `gap: 40px`; IBM Plex Mono 12px, `letter-spacing: 0.06em`, `#405B76` | Open source · Runs on your infrastructure · Gaps named in public (three separate spans, not a single string with middots) |

**Components — right cell**

1. Label: `What was written` — IBM Plex Mono 11px, `letter-spacing: 0.18em`, uppercase, `#A5623B`,
   `margin-bottom: 20px`.
2. Code specimen `<pre>`: background `#F3EFE4` (lighter than the panel it sits on — the plate
   inversion is deliberate), `border: 1px solid #CDC6B7`, `border-radius: 2px`, padding `28px 30px`,
   IBM Plex Mono 14px / `line-height: 1.75`, `white-space: pre`. **Not** a VS Code theme.

   Content is the real base resource from `site/src/pages/index.astro` (`const baseResource`),
   line-wrapped to fit the column:

   ```elixir
   defmodule AshEnterprise.Accounts.Team do
     use AshEnterprise.Platform.Resource,
       domain: AshEnterprise.Accounts,
       cdm: [entity: "Team",
             ownership: :business_owned]

     # only what is specific to Team.
     attributes do
       attribute :name, :string,
         allow_nil?: false, public?: true
     end
   end
   ```

   Token colours: keywords (`defmodule`, `use`, `do`, `end`) `#35594A`; string `"Team"` `#A5623B`;
   atoms (`:business_owned`, `:name`, `:string`) `#405B76`; booleans `#C94D34`; comment `#405B76`
   *italic*; everything else `#20221F`. In the Astro build this should go through
   `CodePanel.astro` with an Atelier token map rather than a hand-marked-up `<pre>`.
3. Label: `What was derived` — same style as above, `margin: 40px 0 16px`.
4. Derived list: `ul`, no bullets, `grid-template-columns: repeat(2, minmax(0,1fr))`,
   `gap: 0 32px`; each `li` padding `10px 0`, `border-top: 1px solid #CDC6B7`, Geist 14px;
   the last two items also carry `border-bottom`. Ten items, in order:
   Tenant-aware schema · User-or-team ownership · Provenance and lifecycle · Optimistic locking ·
   Additive policies · Tamper-evident audit · Soft deletion, cascading · Telemetry and spans ·
   Admin, JSON:API, GraphQL · Agent-visible actions.
5. Link: `Open the generated evidence →` — Geist 15px/500, `#35594A`,
   `border-bottom: 1px solid #35594A`, `align-self: flex-start`, `margin-top: 24px`.

### 2. Section 02 — the leverage (below fold)

**Layout:** `border-top: 1px solid #CDC6B7`, padding `80px 56px 0`, two-column grid
`minmax(0,1fr) minmax(0,1fr)`, `gap: 64px`, `align-items: start`.

- Left: eyebrow `Section 02 — the leverage` (IBM Plex Mono 11px, 0.18em, uppercase, `#A5623B`),
  then H2 — Newsreader 48px / 1.08 / `-0.015em`, weight 400:
  **Five strata. One `use` line.** (`use` set in IBM Plex Mono at `0.72em`, `#35594A`).
- Right: Geist 19px / 1.6, `max-width: 560px`:
  > Every layer below is someone else's solved problem. Ash Enterprise is the top stratum: a
  > chosen subset of the Ash ecosystem, five packages for the parts Ash leaves to the
  > application, and the conventions that hold them together.

### 3. Fig. 1 — the stack elevation

**Purpose:** show that Ash Enterprise is a thin, honest layer on a large existing ecosystem —
it *encompasses* part of the Ash ecosystem, *adds* five first-party packages, and sits on Ash,
Phoenix, Elixir and the BEAM.

**Layout:** container padding `56px 56px 88px`. One CSS grid,
`grid-template-columns: 96px minmax(0,1fr) 300px`, `column-gap: 32px`, `align-items: stretch`.
Five strata, read **top-down from 05 to 01** (top of the stack first — the reading order of an
architectural elevation). Each stratum is three grid cells:

1. **Folio** — IBM Plex Mono 12px, `#A5623B`, `padding-top: 24px`. Values `05`…`01`.
2. **Band** — a bordered box. Strata 04–01 have `margin-top: 12px`.
3. **Margin annotation** — Geist 14px / 1.55, `#20221F`, `border-left: 1px solid #CDC6B7`,
   `padding: 24px 0 0 24px`.

| Folio | Band | Band style | Margin annotation |
|---|---|---|---|
| 05 | **Ash Enterprise** | `border: 1px solid #35594A`, background `#EDE9DC`, padding `22px 24px`; heading `#35594A` | The enterprise substrate Ash leaves to you: ownership hierarchy, tamper-evident audit, legacy strangling, BPMN and DMN as application data. |
| 04 | **The Ash ecosystem** | `border: 1px solid #CDC6B7`, background `#F3EFE4`, padding `22px 24px`; heading row also carries a right-aligned legend `● wired in · ○ available` (IBM Plex Mono 11px, `#405B76`) | Persistence, APIs, admin, jobs, events, soft deletion and LLM tools — all reading the same resources. Ash Enterprise picks eleven and configures them as one system. |
| 03 | **Ash — resources, actions, policies** | `border: 1px solid #CDC6B7`, background `#EDE9DC`, padding `20px 24px` | Model your domain, derive the rest. Every extension above reads the same declarative resource. |
| 02 | **Phoenix & LiveView · Elixir & OTP** | `border: 1px solid #CDC6B7`, background `#EAE5D8`, padding `20px 24px` | Server-rendered interactivity and supervision trees, without a second runtime to operate. |
| 01 | **BEAM — the Erlang virtual machine** | `border: 1px solid #CDC6B7`, background `#E4DFD2`, padding `20px 24px` | Concurrency, isolation and fault tolerance that predate every framework above it. |

Band headings: IBM Plex Mono 12px, `letter-spacing: 0.14em`, uppercase, weight 500.

**Chips.** Strata 05 and 04 contain chip rows: `flex`, `flex-wrap: wrap`, `gap: 8px`; each chip
padding `7px 12px`, IBM Plex Mono 13px, square corners.

- Stratum 05 (nine chips): `AshEnterprise.Platform.Resource` is **filled** — background `#35594A`,
  text `#F3EFE4`. The rest are outlined `1px solid #35594A` on the band background:
  `ash_strangler`, `ash_bpmn`, `ash_decisions`, `ash_rules`, `ash_compliance`, `CDM generators`,
  `Security.ActorContext`.
- Stratum 04, **wired in** (solid border `#CDC6B7`, background `#EDE9DC`, prefix `●`):
  AshPostgres, AshPhoenix, AshJsonApi, AshGraphQL, AshAdmin, AshEvents, AshArchival, AshOban,
  AshAi, OpentelemetryAsh, UsageRules.
- Stratum 04, **available** (`1px dashed #CDC6B7`, no background, text `#405B76`, prefix `○`):
  Reactor, AshAuthentication, AshStateMachine, AshPaperTrail, AshCloak, AshMoney, AshDoubleEntry,
  AshTypescript, AshRateLimiter, AshGeo, and one combined chip
  `AshSqlite · AshCsv · AshCubDB · AshAppSignal`.

The extension names and the "and many more on Hex" idea come from the ecosystem list on
<https://ash-hq.org/>. Chips should link to their hexdocs pages in the real build.

**Caption:** `margin-top: 24px`, Geist 14px / 1.55, `#405B76`, `max-width: 820px`:
> Fig. 1 — The stack read as an elevation. Nothing in strata 01–04 is ours; stratum 05 is the
> part a small team would otherwise hand-build on every project.

## Interactions & behaviour

The prototype is static. Required behaviour in the real build:

- **Nav + CTAs:** every internal href goes through `withBase()`. `Explore the live demo` → the
  demo route; `Read the doctrine` → `/docs/manifesto/`; `Open the generated evidence` → the
  generated-evidence anchor on `/proof/`.
- **Hover:** primary CTA → `opacity: 0.9`, 150ms. Secondary CTA and inline links → colour to
  `#C94D34`, border-colour with it. Chips → border to `#35594A`, `cursor: pointer`, no movement,
  no shadow.
- **Focus:** visible 2px `#405B76` outline with 2px offset on every link and chip.
- **Fig. 1 reveal (optional, from the brief's motion notes):** as the figure enters the viewport,
  strata fade/rise in sequence **01 → 05** (bottom-up, the opposite of reading order — the stack
  builds), 120ms apart, 300ms each, 8px travel. Chips within a stratum appear with it, not
  individually. No looping, no parallax. Respect `prefers-reduced-motion: reduce` by rendering
  the final state immediately.
- The page must be fully legible and credible with JavaScript and animation disabled.

## State management

None. Static content, server-rendered at build time. If the chip legend later becomes an
interactive filter, that is a separate scope.

## Responsive behaviour

Designed at 1440px. Required breakpoint behaviour:

- **< 1024px:** the hero grid collapses to one column — copy first, specimen second. The right
  panel loses `border-left` and gains `border-top`. Padding drops to `64px 32px`.
- **< 1024px, Fig. 1:** the `96px / 1fr / 300px` grid collapses to a single column; the folio
  number moves inline above the band heading; the margin annotation moves below its band and
  loses `border-left` (use `padding-left: 0`).
- **< 768px:** H1 to 48px, H2 to 36px; the derived-outputs list and the code panel become one
  column. The code specimen may scroll horizontally rather than wrap further.
- Nav collapses to the existing site's mobile pattern.

## Design tokens

| Token | Value | Used for |
|---|---|---|
| `--ae-paper` | `#F3EFE4` | Page and left-panel background; code plate inside the right panel |
| `--ae-paper-2` | `#EDE9DC` | Right panel, stratum 05 and 03 bands, "wired in" chips |
| `--ae-paper-3` | `#EAE5D8` | Stratum 02 band |
| `--ae-paper-4` | `#E4DFD2` | Stratum 01 band, canvas behind the artboard |
| `--ae-ink` | `#20221F` | Body text, headings |
| `--ae-workshop` | `#35594A` | Brand green — italic H1 phrase, secondary CTA, Ash Enterprise boundary, keywords |
| `--ae-copper` | `#A5623B` | Eyebrows, folio numbers, specimen labels, code strings |
| `--ae-vermilion` | `#C94D34` | Primary CTA, code booleans, link hover |
| `--ae-blueprint` | `#405B76` | Nav links, annotations, captions, code atoms and comments |
| `--ae-rule` | `#CDC6B7` | All hairlines |

The first four are shades of the same warm flax; only `--ae-paper` is named in the supplied
palette — the other three are the surface steps used to separate strata and panels. If the
codebase prefers a single surface token with opacity steps, keep the *rendered* values.

**Spacing:** 8px base grid throughout — 8, 12, 16, 20, 24, 28, 32, 40, 56, 64, 72, 80, 88, 96.

**Type scale:** H1 78px; H2 48px; body large 19px; body 14–15px; mono labels 11–12px; code 14px.
Line heights: 1.0 (H1), 1.08 (H2), 1.6 (body), 1.75 (code), 1.55 (annotations).

**Fonts:** Newsreader (display, weight 400, italic used), Geist (UI/body, 400/500),
IBM Plex Mono (code, labels, nav, 400/500).

**Radius:** 2px maximum, and only on the code plate and the primary CTA. Everything else square.

**Shadows:** none. Hairlines and inset borders only.

## Dark theme

The design ships in both themes. Dark is a straight token swap — layout, spacing, type and copy
are identical; only colour changes. It binds to the existing `data-theme="dark"` attribute
described in `site/README.md` (do **not** introduce a `.dark` class).

| Role | Light | Dark | Notes |
|---|---|---|---|
| Paper / page | `#F3EFE4` | `#1B1D1A` | Also the code plate inside the right panel |
| Surface 2 | `#EDE9DC` | `#232620` | Right panel, strata 05 and 03 |
| Surface 3 | `#EAE5D8` | `#2A2E27` | Stratum 02 |
| Surface 4 | `#E4DFD2` | `#32362E` | Stratum 01 |
| Ink / text | `#20221F` | `#E8E3D6` | Warm bone, not pure white |
| Workshop green | `#35594A` | `#7FA894` | Same hue, lifted for contrast |
| Copper | `#A5623B` | `#C98A5E` | |
| Vermilion | `#C94D34` | `#E0664A` | |
| Blueprint | `#405B76` | `#8FAAC4` | |
| Rule | `#CDC6B7` | `#3D423A` | |

Two rules that are not a straight swap:

- **Primary CTA.** Light: `#C94D34` background with `#F3EFE4` text. Dark: `#E0664A` background
  with **`#14160F` ink text** — light text on vermilion does not clear 4.5:1 on a dark ground.
- **Filled chip** (`AshEnterprise.Platform.Resource`). Light: `#35594A` on `#F3EFE4` text.
  Dark: `#7FA894` background with `#1B1D1A` text.

The light/dark relationship between the code plate and its panel is **inverted, deliberately**:
in light the plate is lighter than the panel; in dark it is darker. In both cases the plate reads
as a mounted specimen rather than a terminal window. Keep it.

All dark values were checked against their ground at body size: text 13:1, blueprint 7.5:1,
copper 6.9:1, workshop 7.3:1, vermilion 5.6:1.

## Assets

None. No images, no icons, no SVG. Arrows are the text character `→`; chip markers are `●` and
`○`. Fonts load from Google Fonts (Newsreader, Geist, IBM Plex Mono) — self-host them in the
Astro build rather than hotlinking.

## Files

- `AshEnterpriseHero.dc.html` — the approved design (variation 2B).
- `AshEnterpriseHero-all-variations.dc.html` — the five explored variations, for context.
- `support.js` — runtime for opening the HTML files locally.

Source material referenced while designing, in the `ash_enterprise` repo:

- `site/src/pages/index.astro` — `const baseResource` (the specimen), `const inherited`
  (the derived-outputs list), the current hero.
- `site/src/styles/global.css` — existing token scheme the Atelier palette must slot into.
- `site/README.md` — `withBase()` rule, `data-theme` dark-mode contract, asset rules.

## Open questions

1. **Verify the eleven "wired in" extensions against `mix.exs`.** `mix.exs` was not available
   when this was designed (only `site/` was mounted). Directly evidenced in the site source:
   AshEvents, AshArchival, AshAi, `Ash.Tracer`/OpenTelemetry, Oban, and `mix usage_rules.sync`.
   AshPostgres, AshPhoenix, AshJsonApi, AshGraphQL and AshAdmin are inferred from the derived
   surfaces the page already claims. Correct the ● / ○ split before shipping — the whole page
   argues for honest evidence, so this list has to be right.
2. **Dark surface steps.** The four dark paper steps are derived, not supplied by the brand
   palette — confirm them before they enter `global.css`.
3. **`Read the doctrine` vs `Inspect the source`** as the secondary CTA — the brief lists both;
   2B uses Doctrine.
