# ADR 0006 — daisyUI 5 + Phoenix core_components as the design system

- **Status:** accepted
- **Date:** 2026-08-13

## Context

An ERP/LOB admin UI needs dense data tables, heavy forms, and consistent light/dark theming. The realistic options in
the Phoenix ecosystem as of August 2026:

| Option | Version | License | Delivery |
|---|---|---|---|
| Phoenix core_components + Tailwind v4 + **daisyUI 5** | ships with `phx.new` 1.8.9 | MIT | generated into the app |
| **SaladUI** (shadcn port) | 1.0.0 (2026-08-11) | MIT | mix task copies source in |
| **PetalComponents** | 4.13.0 | MIT | hex package |
| **Fluxon UI** | — | **paid**, $199–699 | closed hex package |
| **Petal Pro** | — | **paid**, $299–9,999 | boilerplate repo |
| **Mishka Chelekom** | 0.0.10-alpha.6 | Apache-2.0 | generators |
| **Backpex** | 0.19.7 | MIT | admin framework, **Ecto-driven** |
| Bloom | 0.0.8 (May 2024) | MIT | unmaintained |

Open-source-only is a project constraint, which removes Fluxon and Petal Pro.

## Decision

**daisyUI 5 + Phoenix 1.8 core_components + Tailwind v4** is the base, exactly as `phx.new` ships it.
**`ash_admin`** provides zero-config CRUD at `/admin`. **`cinder`** (0.17) provides Ash-native data tables.
**`ash_a2ui`** provides declarative, agent-renderable surfaces.

**SaladUI was planned and then rejected on a hard technical conflict.** SaladUI 1.0 declares `igniter` as a plain
runtime dependency. Our `igniter` is `only: [:dev, :test]`, and Mix refuses the mismatch:

```
{:igniter, "~> 0.6", only: [:dev, :test]}   # ours
{:igniter, "~> 0.6"}                        # deps/salad_ui/mix.exs
Remove the :only restriction from your dep
** (Mix) Can't continue due to errors on dependencies
```

Complying would ship a code-generation tool that writes files to disk inside production releases. That is a worse
outcome than doing without a component kit, so SaladUI is out as a *dependency*.

Two further reasons the daisyUI base is the right default regardless:

1. **`mix ash_ai.gen.chat --live` templates assume Tailwind + daisyUI.** Fighting the default costs us the generator
   that produces the agent console.
2. **Agent-editability.** Components we can read and modify are worth more here than components that are marginally
   better but closed. This is also the decisive argument against Fluxon, independent of price.

**Backpex is rejected on architecture, not quality.** It is the most polished admin framework available, but it is
Ecto-schema-driven. On an Ash codebase that means maintaining a parallel schema layer and losing Ash policies at the
admin boundary — precisely the bypass [thesis 1](../manifesto/01-model-your-domain.md) exists to prevent.

## Consequences

**Easier**

- Zero cost, zero lock-in, no license to audit.
- Light/dark theming and a theme toggle ship in the generated layout already.
- `ash_ai.gen.chat` works out of the box.
- Every component is source we can read, modify, and let Claude edit.

**Harder**

- daisyUI has no combobox, command palette, or advanced data grid. `cinder` covers tables; the rest is hand-built.
- Dense enterprise forms — date-range pickers, tag inputs, autocompletes — are genuinely more work than with Fluxon.
  This is the real cost of the constraint and it should be re-examined if the budget ever allows.

## Reversal

**To add SaladUI components anyway** (the intended path): SaladUI is shadcn-style and copies component source into your
project. Generate the components in a throwaway project without the `only:` restriction, then copy the resulting files
into `lib/ash_enterprise_web/components/`. No dependency, no conflict, full editability. Watch for runtime helper
modules that the copied components expect.

**To adopt Fluxon** if the constraint is lifted: add the dep, swap component calls in
`lib/ash_enterprise_web/components/`. Confined to the web layer; no resource or domain code changes.

**To re-evaluate**: SaladUI moving `igniter` to `only: [:dev]` would remove the conflict entirely and is worth checking
on each upgrade.
