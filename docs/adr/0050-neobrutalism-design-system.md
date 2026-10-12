# ADR 0050 — A neobrutalism token system, dark by default, replaces daisyUI

- **Status:** accepted
- **Date:** 2026-10-12
- **Supersedes:** [ADR 0006](0006-design-system.md) (daisyUI 5 + Phoenix core_components)

## Context

ADR 0006 adopted daisyUI 5 on top of Phoenix 1.8's generated core_components. By October 2026 three things had
changed.

1. **clinic-demo already had a finished design system** for the same stack (Phoenix 1.8, Tailwind v4, A2UI, ash_bpmn,
   ash_decisions): neobrutalism, after the "blue" scheme on [neobrutalism.dev](https://www.neobrutalism.dev). It is one
   ink colour shared by text, borders, shadows and focus rings, 2px borders, a hard 4px offset shadow, 5px radii, DM Sans
   at 500 for body and 700 for headings, Archivo Black for the loudest tier only, a lift/press motion pair and vivid
   poster secondaries. It lives in one token sheet (`assets/css/neobrutalism.css` in clinic-demo, origin/main `2bb9a81`)
   and reaches A2UI through the `--a2ui-*` custom-property seam ADR 0006 already relied on. Adopting it gives both
   applications one visual language.

2. **clinic-demo's palette is light only.** The dogfood instance is used mostly in a dark room, and dark was asked
   for as the default. neobrutalism.dev's own dark scheme keeps black borders and shadows. Measured against a dark
   navy surface, a black edge is about 1.2:1, so the hard edges, which are the point of the style, mostly disappear.

3. **daisyUI was barely load-bearing.** It was used in eight templates and the two layout modules. No Cinder table is rendered anywhere,
   even though Cinder's daisy theme was imported and configured. ash_bpmn, ash_decisions and the A2UI catalogs style
   themselves through custom properties and never used daisy classes. The two reasons ADR 0006 gave for keeping daisy
   no longer held: AGENTS.md, which is generated from phoenix's usage rules, already says to hand-write components
   rather than use daisyUI, and `ash_ai.gen.chat` is not used for the agent console.

## Decision

**The design system is a token sheet plus hand-written components, with no component library.**

- `assets/css/neobrutalism.css` holds raw per-theme custom properties, a Tailwind v4 `@theme inline` mapping (`bg-main`,
  `text-foreground`, `border-border`, `rounded-base`, `shadow-shadow`, `shadow-lift`, `shadow-press`, `font-heading`,
  `font-display`, ...), pattern utilities, and two bridges: `--a2ui-*` for A2UI, and `--ash-admin-*` for the admin
  catalog, whose fallbacks are light-only literals.
- `CoreComponents` carries `button/1` (variants `primary | accent | neutral | ghost`, sizes `xs | sm | md`) and
  `button_class/2` for elements that cannot be a `<button>`, as well as `badge/1`, `card/1`, `callout/1`, inputs,
  `table/1` and `table_class/0`. Templates use those, or token utilities. They never use literal colours.
- **Dark is the default theme.** The root layout's script applies dark when nothing is stored, without storing it.
  `system`, `light` and `dark` are explicit, stored choices behind the existing toggle. The bare `:root` block is
  also dark, so a page whose script did not run is still dark.
- **The light theme is clinic-demo's palette unchanged**, except `--error`. clinic's `hsl(0 100% 45%)` measures 3.99:1
  on the pale page, so light uses `hsl(0 100% 40%)`.
- daisyUI is removed: the Tailwind plugin, both daisy themes, Cinder's daisy theme import and config, and the
  `:daisyui` git dependency.
- The type is self-hosted (`priv/static/fonts`, SIL OFL 1.1, notices in `priv/static/fonts/OFL.txt`), so text metrics
  never depend on a font CDN.

### The dark palette

| Token | Dark | Light | Role |
|---|---|---|---|
| `--background` | `#0e1525` | `hsl(214 95% 93%)` `#dcebfe` | page |
| `--secondary-background` | `#1a2338` | `#ffffff` | cards, inputs, tables |
| `--foreground` | `#eef2fb` | `#000000` | text |
| `--border`, `--shadow-color` | `#e6ecf8` | `#000000` | 2px edges, hard offset shadows |
| `--ring` | `#eef2fb` | `#000000` | focus |
| `--main` | `hsl(217 100% 66%)` `#5294ff` | same | primary fill |
| `--main-foreground`, `--on-vivid` | `#000000` | `#000000` | ink on any vivid fill |
| `--error` | `hsl(0 100% 71%)` `#ff6b6b` | `hsl(0 100% 40%)` `#cc0000` | error text |
| yellow, pink, green, orange, violet, cyan, red | clinic values | clinic values | poster fills |
| `--neutral` | `hsl(220 12% 70%)` `#a9afbc` | `hsl(220 14% 91%)` | inert fills |

The dark page is a deep navy, the dark counterpart of the light theme's pale blue, so the two themes read as one
product. **The ink inverts**: borders and shadows are a blue-white, the same family as the text. That keeps the style's
defining rule, one ink for everything, and keeps the hard edges at 13 to 15:1 against both dark surfaces. The vivid
fills keep their exact light-theme values and their black ink in both themes. Each still clears 5.4:1 against the dark
page, so the fills do not need toning down. Because `--foreground` is light on dark, any vivid fill names its ink
explicitly (`text-on-vivid`).

### Measured contrast (WCAG 2.x relative luminance)

| Pair | Dark | Light |
|---|---|---|
| Body text on page | 16.25:1 | 17.35:1 |
| Body text on raised surface | 13.96:1 | 21.00:1 |
| Muted text (`/70`) on page | 8.35:1 | 7.80:1 |
| Muted text (`/70`) on surface | 7.53:1 | 8.52:1 |
| Border / shadow vs page | 15.37:1 | 17.35:1 |
| Border / shadow vs surface | 13.21:1 | 21.00:1 |
| Error text on page | 6.57:1 | 4.86:1 |
| Error text on surface | 5.64:1 | 5.89:1 |
| Black ink on main `#5294ff` | 7.04:1 | 7.04:1 |
| Black ink on yellow `#ffd738` | 15.05:1 | 15.05:1 |
| Black ink on pink `#ff6bba` | 8.07:1 | 8.07:1 |
| Black ink on green `#3adf63` | 11.90:1 | 11.90:1 |
| Black ink on orange `#ff9729` | 9.74:1 | 9.74:1 |
| Black ink on violet `#b88fff` | 8.40:1 | 8.40:1 |
| Black ink on cyan `#1fe0f9` | 13.07:1 | 13.07:1 |
| Black ink on red `#ff4747` | 6.26:1 | 6.26:1 |
| Black ink on neutral | 9.58:1 | 16.96:1 |

An axe `color-contrast` sweep (WCAG 2.1 AA) of sign-in, the demo hub, users, teams (browse and the create panel),
directory, tasks, processes, decisions, triggers, the helper, the BPMN designer, the DMN editor and legacy parties is
clean in both themes.

### Deviations from clinic-demo, and why

- **A2UI's secondary is the raised surface with ink text, not yellow with black ink.** A2UI's basic Button always
  draws its text in `--a2ui-color-on-secondary`, and the admin action bar sets that button's background to
  transparent. With clinic's black on-secondary, the Cancel button on the create panel was black on navy, 1.34:1
  (found by the e2e axe scan). Yellow stays available as the app-side `accent` variant.
- **Inside the admin catalog only, the light theme's primary is `#1d4ed8` with white ink.** The catalog uses its
  primary as both a fill and as the text of its quiet View/Edit buttons, and main blue as text on white is 2.9:1. The
  deeper blue holds 6.7:1 in both roles.
- **The DMN editor's tabs use ink text with a main-blue underline.** ash_decisions colours the active tab's text with
  the primary (2.46:1 on the light page) and dims the key with opacity (1.68:1).

### Third-party surfaces

- **bpmn-js / dmn-js** in dark: their palette primitives (`--color-white`, the `--color-grey-225-10-*` scale) are
  re-mapped onto the tokens, the renderers' inline default fills and strokes are flipped by attribute match, as before,
  and dmn-js's hardcoded-black bpmn.io watermark is recoloured to the ink. The bpmn.io licence requires the watermark
  to stay visible.
- **ash_bpmn's chrome** switched part of its palette on `prefers-color-scheme`, which ignores the app's toggle. Those
  roles and its live-token highlights are now pinned to `data-theme`.
- **ash_authentication_phoenix** screens are restyled through `AshEnterpriseWeb.AuthOverrides` with the same tokens.

## Consequences

**Easier**

- One visual language with clinic-demo. A component or pattern moves between them by copying.
- Dark and light come from one set of utilities. A template never chooses colours per theme.
- The dependency list is shorter by one git dependency and one Tailwind plugin.

**Harder**

- No component library. Dropdowns, modals and comboboxes are written by hand. ADR 0006 already noted daisyUI had no
  combobox, so the practical loss is small, but it is real for dense forms.
- A Cinder table, if one is ever added, needs a theme written in the tokens: a `use Cinder.Theme` module (Cinder's
  shipped themes are literal Tailwind palettes).
- The A2UI and admin bridges map many roles. When ash_a2ui adds a role with a light-only fallback, dark shows it
  first. The axe tests in `assets/e2e` are the guard.
- The documentation screenshots under `docs/screenshots/` predate this and show the daisy look until they are recaptured.

## Reversal

Everything is in the web layer: `assets/css/neobrutalism.css`, `assets/css/app.css`, `CoreComponents`, `Layouts`, the
root layout, `AuthOverrides`, and about eight templates. To return to daisyUI, re-add the dependency and the plugin
blocks, which are recoverable from the commit that removed them, and swap the component recipes back. That is about a
day. To keep the system but change the palette, edit the two token blocks at the top of `neobrutalism.css`. Every
utility and both bridges follow.
