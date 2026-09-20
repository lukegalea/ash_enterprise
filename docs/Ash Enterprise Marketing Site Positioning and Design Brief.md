# Ash Enterprise Marketing Site: Positioning and Design Brief

## Executive direction

Ash Enterprise should stop presenting itself first as an argument and start presenting itself as a **force multiplier for ambitious small teams**. The strongest positioning is:

> **A master-crafted enterprise application framework for small teams and capable agents.**
> 
> Declare the hard parts once. Ship the software a serious customer expects.

The recommended creative direction is **The Enterprise Atelier**: a warm, editorial, unusually human framework site that feels like a beautifully made technical field guide. It should combine the confidence of an architectural pattern book, the tactility of a small workshop, and the precision of executable code—without becoming nostalgic, twee, or visually noisy.

The strategic change is not to remove the manifesto, proofs, controls, or technical depth. It is to **stage them**. The homepage should sell the possibility, demonstrate the leverage, prove one end-to-end claim, and then offer progressively deeper paths into the live application, code, controls, and manifesto.

The page should make a technical founder or CTO understand five things in under ten seconds:

- This is an opinionated framework for enterprise-grade applications.
- It is designed for a small, senior team working with coding agents.
- Cross-cutting concerns are declared once and inherited everywhere.
- The proof is a running application and inspectable code, not marketing promises.
- The next action is to explore the live demo.

That clarity matters because users commonly leave pages within 10–20 seconds unless the value proposition earns more attention, and most readers scan rather than consume a page word by word.[^1][^2]

## What strong framework sites do

The best framework homepages do not begin by enumerating their architecture. They establish a memorable promise, make the category legible, and then let code substantiate the promise.

| Site | Memorable move | Lesson for Ash Enterprise |
|---|---|---|
| Ash | “Model your domain, derive the rest” turns declarative design into a compact benefit.[^3][^4] | Extend the parent idea into the enterprise domain rather than re-explaining Ash from scratch. |
| Phoenix | “Peace of mind from prototype to production” joins speed and longevity, then immediately shows a concise LiveView example.[^5] | Lead with the emotional outcome and show one coherent code-to-product story. |
| Laravel | Positions strong opinions as decisions developers and agents no longer need to make.[^6] | Opinionated defaults are especially valuable in the agentic era; say this directly. |
| Rails | Reframes convention over configuration as leverage for agents and connects a tiny code surface to company-scale ambition.[^7] | “Small input, large outcome” is a marketable product truth, not merely an implementation detail. |
| Django | Uses a durable audience-and-outcome phrase—“perfectionists with deadlines”—then supports it with speed, security, and scale.[^8][^9] | Name the user and their tension in one phrase. |
| Supabase | “Build in a weekend. Scale to millions.” pairs an ambitious outcome with tangible capabilities, runnable code, customer proof, and compliance signals.[^10] | Alternate aspiration, working product, and trust rather than isolating trust at the bottom. |
| Temporal | Opens on a high-stakes outcome, explains the painful failure mode in plain language, then reveals the mechanism.[^11] | Start with why a CTO cares; introduce the implementation after the stakes are clear. |
| Fly.io | Adopts a sharply opinionated agent-era narrative while retaining concrete infrastructure facts.[^12] | A point of view can be the brand, but every poetic claim needs a concrete proof beside it. |
| htmx | Makes simplicity visceral with a tiny example and a playful, anti-corporate voice.[^13] | Personality and technical seriousness can reinforce rather than undermine each other. |

Three patterns recur:

- **A compressed thesis:** one sentence that can survive as a social post, talk title, or recommendation between CTOs.
- **An immediate specimen:** code, a live interaction, or a recognizable product surface near the promise.
- **Progressive disclosure:** the homepage creates desire and confidence; docs, doctrine, architecture, and controls satisfy deeper evaluation.

Ash Enterprise already has unusually strong raw material: real code, real screens, a running system, explicit trade-offs, testable controls, and a public ledger of gaps. The problem is sequencing, not substance.

## Current-site diagnosis

The existing homepage behaves like an excellent technical monograph placed where a marketing homepage should be. It contains roughly 10,000 words, 19 major section headings, 12 preformatted specimens, 7 large tables, and more than 30 product images. That density rewards a reader already convinced enough to study it, but asks a first-time visitor to understand the entire proof before receiving a compact statement of value.

Its opening line—“Point an agent at the app you have. Get the one an enterprise will buy.”—is provocative and distinctive. However, it first frames Ash Enterprise as a transformation or migration mechanism, while the full project is broader: a reusable application foundation, an enterprise control model, an agent-compatible development environment, and a proof-oriented reference architecture.

The site currently makes four jobs compete on a single page:

- **Marketing:** why a founder or CTO should care.
- **Product tour:** what the running application can do.
- **Technical doctrine:** why the design decisions are coherent.
- **Assurance package:** what is shipped, partial, planned, or open and where the evidence lives.

All four are valuable. They should become four layers rather than four simultaneous voices.

### Keep

- The uncompromising honesty of “shipped / partial / planned / open.”
- The code as evidence.
- The one-line resource declaration as the central product icon.
- The “agents are users, not a side door” argument.
- The explicit legacy-database and enterprise-control stories.
- The manifesto as the intellectual foundation.
- The exact evidence links and executable control map.

### Change

- Replace the thesis-first homepage with an outcome-first narrative.
- Reduce homepage copy by roughly 70–80%; move full arguments to dedicated essays.
- Show one end-to-end specimen instead of many unrelated feature proofs.
- Reframe the roadmap count as radical transparency, not as the dominant product score.
- Introduce the intended team—small, senior, agent-augmented—above the fold.
- Replace the generic polished-SaaS visual language with a recognizable editorial system.
- Make the live demo the primary CTA; GitHub and the manifesto become secondary paths.

## Positioning system

### Category

**An opinionated enterprise application framework for Elixir and Ash.**

Avoid “template” in the primary category. “Template” suggests scaffolding that becomes obsolete after generation; the product’s value is a continuing set of declarations, inherited controls, derived surfaces, verifiers, and conventions. “Reference architecture” is accurate but sounds observational. “Framework” conveys an active development model and better matches the intended ambition.

The footer or FAQ can remain exact:

> Open-source framework, reference implementation, and executable argument. Not a hosted product.

### Audience

Primary:

- Technical founders and CTOs building high-stakes B2B software.
- Small senior teams taking on requirements normally associated with much larger organizations.
- Teams already using Elixir/Ash or willing to choose the stack for leverage and reliability.

Secondary:

- Staff engineers and enterprise architects evaluating authorization, tenancy, auditability, migration, workflows, and agent safety.
- AI-native teams that need agents to work inside the same domain and authorization model as people.
- Consultants and product studios delivering custom enterprise systems repeatedly.

### Core promise

**A small team can build software worthy of a large customer without repeatedly hand-building the enterprise substrate.**

This is stronger than “rapid enterprise development.” Speed is an effect. The deeper value is controlled leverage: more ambition per person, fewer forgotten obligations, and a codebase whose declarations remain legible to both humans and agents.

### Brand pillars

| Pillar | Promise | Proof form |
|---|---|---|
| Master-crafted | Strong, coherent decisions replace a pile of loosely integrated packages. | One resource declaration, named conventions, compile-time refusal, executable doctrine. |
| High leverage | A small declaration produces schema, policy, audit, surfaces, APIs, telemetry, and agent tools. | Interactive “declare → derive” specimen. |
| Enterprise by inheritance | The compliant path is the easiest path; forgetting a cross-cutting concern takes effort. | Base resource code plus generated outputs and tests. |
| Humans and agents together | Agents invoke existing actions as existing users, through the same policies. | Tool declaration, proposal/approval flow, actor-bound live demo. |
| Honest evidence | Claims point to running software, tests, controls, or explicitly named gaps. | Evidence links, control ledger, verification commands, open rows. |
| Calm ambition | Small teams can take on serious clients without adopting the rituals or surface area of a giant platform group. | Voice, customer scenario, architectural economy. |

### Message hierarchy

1. **Ambition:** Build the enterprise system your small team should not be able to build.
2. **Mechanism:** Declare the domain and cross-cutting concerns once; derive the rest.
3. **Collaboration model:** Humans make decisions; agents multiply execution; both operate inside the same rules.
4. **Proof:** Run it, inspect the code, follow each claim to a test or control.
5. **Doctrine:** Read why the framework refuses certain designs.

## Creative brief A: The Enterprise Atelier

**Recommendation: pursue this direction.**

### Concept

A master craftsperson’s studio for serious software: warm materials, editorial pacing, exact instruments, and a few beautifully presented specimens. “Artisanal” appears as care, restraint, and coherence—not as rustic decoration.

The site feels like a limited-run architecture journal crossed with an immaculate workshop ledger. The emotional message is: **a small group with excellent tools and judgment can produce work of institutional quality.**

### Visual language

- Warm bone or flax background rather than pure white.
- Charcoal ink, deep bottle green, oxidized copper, and a restrained vermilion for status or action.
- A literary serif for display text, a calm grotesk for interface copy, and a practical monospace for code.
- Hairline rules, folio numbers, margin notes, proof stamps, material swatches, and quiet asymmetry.
- Product screenshots presented as tipped-in plates with captions, not floating SaaS cards.
- Code presented as a typeset specimen with line annotations and derived outcomes in the margin.
- Subtle paper grain only at large surfaces; no fake torn edges, wax seals, coffee stains, or faux handwriting.

Suggested type families:

- Display: Newsreader, Source Serif 4, or Instrument Serif.
- Sans: Geist, Inter, or Suisse-style neutral grotesk.
- Mono: IBM Plex Mono, Berkeley Mono if licensing permits, or Commit Mono.

### Signature interaction

The hero contains the resource declaration on a narrow “work order.” As the visitor scrolls or taps **See what this line makes**, the declaration stays pinned while outputs arrive one at a time:

- Tenant-aware schema.
- Additive authorization.
- Tamper-evident audit.
- Admin and API surfaces.
- Agent-safe actions.
- Telemetry and lifecycle.

This interaction makes the central product truth physically understandable: the input remains small while the consequence expands.

### Tone

- Assured, hospitable, exact.
- Short sentences and concrete nouns.
- Occasional dry wit.
- No “revolutionary,” “seamless,” “effortless,” “next-generation,” or “AI-powered.”
- Prefer “built in,” “derived,” “refused,” “verified,” and “shown running.”

### Hero candidate

> **Serious enterprise software. Small-team scale.**
>
> Ash Enterprise is a master-crafted Elixir framework for senior teams and capable agents building ambitious systems for demanding customers. Declare the domain once. Inherit the controls. Derive the surfaces. Keep the code worth owning.
>
> **Explore the live workshop** · View the source

Alternative, more provocative:

> **Build above your headcount.**
>
> An opinionated enterprise framework where a small team and smart agents can ship authorization, audit, tenancy, workflow, APIs, and admin surfaces as one coherent system—not seven integration projects.

### Why it fits

This direction translates the project’s existing intellectual seriousness into an inviting experience. It also fits a founder/CTO audience: craft signals judgment, the restrained presentation avoids hype, and the live specimen preserves technical credibility. It aligns with Ash’s own promise to model the domain and derive the rest.[^3][^4]

## Creative brief B: The Pattern Library

### Concept

An enterprise architecture pattern book where every capability is a reusable plate: identity, ownership, audit, workflow, decisions, legacy mapping, and agent surfaces. The homepage behaves like a curated catalog of patterns that snap together through the resource model.

This is more systematic and less romantic than the Atelier. It presents Ash Enterprise as a **coherent grammar for enterprise software**, not a bag of components.

### Visual language

- Cream and slate base with indigo blueprint lines and red editorial marks.
- Modular plates labeled with pattern number, status, inputs, outputs, and evidence.
- ER diagrams, policy graphs, state machines, and code shown with a common visual grammar.
- Strong horizontal rhythm and tabbed technical specimens.
- “Shipped / partial / planned / open” becomes a catalog notation rather than a dashboard score.

### Signature interaction

Visitors assemble a hypothetical application by selecting constraints such as multi-tenant, legacy database, maker-checker approval, external IdP, or agent tools. The site reveals which declarations, derived surfaces, controls, and known gaps apply.

### Hero candidate

> **The enterprise patterns are already known. Declare them once.**
>
> Ash Enterprise turns ownership, tenancy, authorization, audit, workflow, and agent access into a coherent application model—derived from the same resources, tested as one system.

### Trade-off

This direction offers the clearest bridge to architects and enterprise evaluators, but it risks feeling like documentation again if the homepage exposes too many plates. It should be chosen only if the interactive catalog can remain visibly simple.

## Creative brief C: Small Crew, Great Works

### Concept

A quiet editorial story about disproportionate teams: a small, capable crew using durable tools to undertake work normally assigned to a much larger organization. The metaphor can borrow lightly from shipbuilding and navigation—keel, rigging, charts, watches—but must stay subordinate to software.

The brand idea is: **the framework carries the structural load so the crew can concentrate on the voyage.**

### Visual language

- Midnight navy, sailcloth, weathered red, and signal yellow.
- Large editorial photography or commissioned line illustration used sparingly.
- Diagrammatic “voyage charts” for legacy migration, request flow, and evidence chains.
- Typographic scale inspired by old technical manuals, but rendered with contemporary spacing and motion.

### Signature interaction

An animated route follows one enterprise change from a legacy write through the ledger, canonical action, event, projection, and visible surface. Each stage exposes code or evidence on demand.

### Hero candidate

> **A small crew can build a very large system.**
>
> Ash Enterprise gives experienced teams and coding agents the structure to take on demanding enterprise software—without assembling the same controls by hand on every voyage.

### Trade-off

This is the most emotionally memorable direction and the strongest source of LinkedIn-ready campaign material. It is also the easiest to over-theme. Maritime language should appear in illustration and occasional headings, never in core product terminology.

## Recommended homepage

The homepage should be a **seven-minute guided argument** for a motivated technical leader and a **30-second scan** for everyone else.

### Navigation

- Product
- Live Demo
- Proof
- Doctrine
- Docs
- GitHub

The manifesto becomes **Doctrine**, a more approachable label that still preserves conviction. “Controls” becomes part of **Proof**, alongside tests, roadmap, and explicit gaps.

Persistent primary CTA: **Explore live demo**.

### Section 1: Hero

Purpose: identify category, audience, outcome, and next action.

Recommended copy:

> **Serious enterprise software. Small-team scale.**
>
> A master-crafted Elixir and Ash framework for senior teams and capable agents building ambitious systems for demanding customers. Declare the hard parts once—authorization, tenancy, audit, workflow, APIs, and agent access—and inherit them everywhere.
>
> **Explore the live demo** · Inspect the source
>
> Open source · Runs on your infrastructure · Gaps named in public

Visual: a restrained resource declaration beside a slowly unfolding set of derived outputs. No abstract AI orb, gradient mesh, or generic dashboard montage.

### Section 2: The leverage specimen

Heading:

> **One declaration. A system of consequences.**

Show the real base-resource declaration at readable size. Let the visitor select or hover over `ownership`, `audit`, `archival`, `domain`, or `cdm`; each token highlights the exact schema, policy, UI, event, or test it causes.

Keep the code genuine and short. Framework sites earn trust through working specimens and public documentation rather than generic claims; technical evaluators especially look for architecture, APIs, sample code, migration paths, failure modes, and self-service evaluation.[^14][^15][^16]

### Section 3: The team model

Heading:

> **Humans set direction. Agents multiply the work. The framework holds the line.**

Use a three-column editorial composition:

- **Your team owns judgment:** domain boundaries, exceptions, irreversible decisions.
- **Agents move quickly:** generate resources, inspect the running system, propose changes, and operate existing actions.
- **The framework enforces coherence:** the same policies, actions, audit, and actor context apply regardless of who initiated the work.

This is where “agents are users, not a side door” becomes a crisp commercial differentiator.

### Section 4: Ambition without departments

Heading:

> **The capabilities large customers ask for. Without a department for each one.**

Use six substantial capabilities, not a 20-card feature grid:

| Capability | Outcome sentence | Proof link |
|---|---|---|
| Identity and authorization | Ownership, hierarchy, sharing, and additive grants come from one actor model. | Open policy graph |
| Audit and evidence | Every action is attributable; the chain can reveal tampering and export an auditor’s window. | Verify the chain |
| Workflow and decisions | BPMN and DMN become versioned application data, with human approvals and FEEL conditions. | Run a process |
| Legacy adoption | Map rather than rewrite; move through reversible phases while the old system keeps running. | Watch the projection |
| Derived surfaces | Admin, API, GraphQL, and agent tools read the same domain and policies. | Open the surfaces |
| Tenant-safe agents | Models receive existing actions, not a privileged mutation path. | Inspect the tool declaration |

### Section 5: Live proof

Heading:

> **Not a diagram of a future product. A running application.**

Offer three guided demo journeys rather than an unstructured collection of screenshots:

- **For the CTO:** legacy write → live projection → audit event → tenant-visible surface.
- **For the architect:** resource declaration → policy graph → generated APIs → conformance test.
- **For the AI lead:** user request → agent proposal → human approval → existing action → attributed event.

Each journey should take 60–90 seconds. Technical demos work best when they follow a problem, solution, and observable outcome rather than presenting an exhaustive feature tour.[^17]

### Section 6: Radical honesty

Heading:

> **Built answers. Named gaps. No architecture theatre.**

Do not lead with “17 / 55.” Lead with the principle, then show the live ledger:

- 17 shipped.
- 14 partial.
- 9 planned.
- 15 open.

Add one sentence:

> Every status is generated from the same roadmap file used by the documentation and CI. Follow any answer to its evidence—or to the gap it still names.

This changes the emotional meaning from “mostly unfinished” to “unusually inspectable.” Keep a link to the full 55-question ledger and display only six representative questions on the homepage.

### Section 7: Doctrine

Heading:

> **Strong opinions, held in code.**

Feature three compact principles:

- **Batteries are inherited, not installed.**
- **Authorization is a union of grants.**
- **Agents are users.**

Each gets 40–60 words and a “Read the argument” link. Rails has long used doctrine to turn technical opinions into identity; its current homepage still makes those opinions part of the product promise.[^7]

### Section 8: Closing invitation

> **Bring the application you have. Build the one your largest customer expects.**
>
> Run the reference application, follow a real enterprise flow, and decide which parts are worth keeping.
>
> **Explore the live demo** · Clone the repository · Read the doctrine

## Code as visual proof

The site should avoid both common extremes: code as decorative wallpaper and code as an unreadable wall. Use a small number of carefully edited, real specimens.

### Specimen sequence

1. **The declaration:** one `use AshEnterprise.Platform.Resource` example.
2. **The derived model:** selected columns, policy graph, and surfaces.
3. **The human-agent action:** existing Ash action exposed as a tool with the requesting actor.
4. **The evidence:** verification or conformance command with genuine output.

Every specimen needs three layers:

- **What was written.**
- **What was derived.**
- **Why the CTO should care.**

For example:

```elixir
defmodule Acme.Accounts.Team do
  use AshEnterprise.Platform.Resource,
    domain: Acme.Accounts,
    cdm: [entity: "Team", ownership: :business_owned]

  attributes do
    attribute :name, :string, allow_nil?: false, public?: true
  end
end
```

Beside it—not beneath ten paragraphs—show:

> From this resource: tenant scope, user-or-team ownership, provenance, optimistic locking, lifecycle, additive policies, audit events, soft deletion, telemetry, admin defaults, JSON:API, GraphQL, and agent-visible actions where explicitly allowed.

Add “Open the generated evidence” for readers who want every field and mechanism.

## Art direction details

### Composition

Use generous vertical intervals, occasional full-width editorial statements, and asymmetric two-column spreads. Avoid the repeated rounded-card grid that makes most developer sites interchangeable.

A useful ratio is:

- 60% editorial typography and negative space.
- 25% real code and diagrams.
- 15% interface imagery and status evidence.

### Color

Recommended palette:

| Role | Direction | Example |
|---|---|---|
| Paper | Warm flax | `#F3EFE4` |
| Ink | Near-black charcoal | `#20221F` |
| Workshop green | Primary brand | `#35594A` |
| Copper | Secondary accent | `#A5623B` |
| Vermilion | CTA / critical mark | `#C94D34` |
| Blueprint | Technical annotation | `#405B76` |
| Muted rule | Hairlines | `#CDC6B7` |

Use semantic colors sparingly for shipped, partial, planned, and open. Status should remain accessible through text and iconography, not color alone.

### Motion

- Slow, purposeful reveals connected to causality.
- Derived artifacts should appear from the declaration, not fly in independently.
- Diagram edges may draw themselves only when the related concept enters view.
- Respect reduced-motion preferences.
- No infinite marquees, orbiting logos, parallax paper, or cursor-following effects.

### Illustration

Commissioned line illustrations could show a workbench, a team at a plan table, or an architectural cutaway in a contemporary editorial style. They should communicate concentration and scale, not literalize every feature. Product claims must remain attached to real code, real screens, and real diagrams.

## Voice and copy

### Voice rules

- Speak to an experienced peer.
- Prefer declarative sentences.
- Use enterprise vocabulary only when it denotes a real mechanism.
- State constraints and refusals proudly.
- Make the surprising sentence short; put proof immediately after it.
- Never pretend “low effort” means trivial work. Say **high leverage**, **fewer repeated decisions**, or **less incidental machinery**.

### Phrase bank

Good:

- Built for small teams with large obligations.
- The enterprise substrate, inherited.
- Strong opinions, executable.
- Make the compliant path the easy path.
- The code is the claim.
- Agents move fast. The framework keeps the rules.
- Derived, not duplicated.
- Software worth owning.
- Ambition without headcount.
- Gaps included.

Avoid:

- Enterprise-grade AI-powered platform.
- Accelerate digital transformation.
- Effortless compliance.
- Single pane of glass.
- Seamlessly integrate.
- Ten times your developers.
- Production ready, unless immediately scoped to a specific demonstrated capability.

### Headline shortlist

1. **Serious enterprise software. Small-team scale.**
2. **Build above your headcount.**
3. **The enterprise substrate, inherited.**
4. **Master-crafted for ambitious systems.**
5. **Declare the hard parts once.**
6. **A small team can build a very large system.**

Best combination:

- Eyebrow: **For small senior teams and capable agents**
- H1: **Serious enterprise software. Small-team scale.**
- Supporting line: **Declare the hard parts once. Inherit the controls. Derive the surfaces. Keep the code worth owning.**

## LinkedIn fit

The site should be designed as a source of social artifacts, not merely as the destination for them.

### Shareable units

- A hero OG card containing the headline and one-line declaration.
- A before/after carousel: “what teams hand-wire” versus “what the resource inherits.”
- A six-slide “Agents are users, not a side door” argument.
- A short screen recording of the declare-to-derive interaction.
- A recurring “Named gap of the week” post linking to the evidence ledger.
- A diagram card tracing a legacy write into the modern, audited surface.
- A compact control card: claim, mechanism, test, known limit.

### Social copy shape

A strong post should follow:

1. Contrarian or ambitious statement.
2. Concrete enterprise pain.
3. One real code specimen or diagram.
4. Explicit limitation.
5. Link to the live proof.

Example:

> Most agent frameworks invent a second authorization path.
>
> Ash Enterprise does not give the model a privileged mutation API. It exposes an existing Ash action, with the requesting human as the actor, through the same policies and audit path.
>
> The model proposes. A person approves. The application acts.
>
> See the full flow running →

This tone respects the technical audience’s skepticism. Developer marketing is strongest when public docs, working code, open-source artifacts, and fast self-service evaluation replace gated collateral and generic sales claims.[^18][^16]

## Information architecture

Recommended top-level structure:

| Route | Job |
|---|---|
| `/` | Market the outcome, demonstrate leverage, and direct visitors to live proof. |
| `/demo` | Three guided journeys through the running system. |
| `/product` | Capabilities organized by buyer problem, not package name. |
| `/proof` | Enterprise question ledger, controls, tests, status, and evidence. |
| `/doctrine` | Edited manifesto index and core theses. |
| `/adopt` | Who should use it, architecture, prerequisites, migration paths, and first project. |
| `/docs` | Existing technical documentation. |
| `/roadmap` | Full generated roadmap and open gaps. |

Do not force a buyer to understand CDM, DMN, FEEL, BPMN, A2UI, OpenLineage, and Nango from the homepage. Those terms belong in capability details and proof pages after the buyer understands the problem each solves.

## Build approach

The new site can remain in Astro and preserve the existing generated data sources. The important architectural move is content separation:

- Treat `roadmap.json`, controls, tests, screenshots, and code excerpts as a structured evidence layer.
- Create short marketing components that reference that evidence instead of reproducing it.
- Keep long-form manifesto pages canonical and link into precise anchors.
- Build the interactive declaration specimen from a data map so it cannot silently drift from the base resource.
- Preserve excellent static rendering, keyboard access, reduced motion, semantic headings, and linkable sections.

### Delivery phases

**Phase 1 — Message prototype**

- Rewrite hero and first four sections in plain HTML.
- Use existing screenshots and one real code specimen.
- Test the five-second comprehension questions: What is it? Who is it for? Why is it different? What should the visitor do?

**Phase 2 — Visual system**

- Produce one desktop and one mobile art-direction page for the Enterprise Atelier.
- Establish typography, color, code, figures, statuses, links, and editorial spacing.
- Build the OG-card system at the same time.

**Phase 3 — Live proof**

- Create three guided demo journeys.
- Add declaration-to-derived-output interaction.
- Instrument CTA clicks, demo starts, journey completion, docs visits, and GitHub transitions.

**Phase 4 — Content migration**

- Move thesis-heavy homepage material to Doctrine.
- Move complete status tables to Proof and Roadmap.
- Retain exact inbound anchors where feasible.

### Success measures

- A technical founder can accurately describe the product after five seconds.
- More visitors start a guided demo than open the manifesto from the homepage.
- Demo starters continue into source, proof, or docs.
- LinkedIn shares resolve to specific claims and specimens, not only the generic homepage.
- The homepage remains credible when read without animations.
- No marketing statement lacks a path to code, a running surface, a test, or an explicitly named gap.

## Final recommendation

Build **The Enterprise Atelier** and use **Serious enterprise software. Small-team scale.** as the first message to test. Preserve the current site’s rigor by turning it into a linked proof system beneath a much shorter, calmer, more human homepage.

The defining experience should be the declaration-to-derived-system specimen. It captures the technical architecture, the business value, the Ash philosophy, and the human-agent collaboration model in a single interaction. Everything else—the workshop aesthetic, editorial typography, guided demos, doctrine, and evidence ledger—should support that one product truth:

> **A small, explicit declaration can carry an enterprise-sized obligation.**

---

## References

1. [Nielsen Norman Group: 20 Years - NN/G](https://www.nngroup.com/articles/nielsen-norman-group-20-years/) - Overview & links to the top-hits UX articles, videos, & user-research results across 20 years, from ...

2. [Website Design for Scannability – 8 UI Tips and Proven ...](https://www.uxpin.com/studio/blog/website-design-for-scannability/) - This article describes the various scanning patterns users adopt for different tasks and best practi...

3. [Ash Framework](https://ash-hq.org/) - Model your domain, derive the rest. The Elixir backend framework for unparalleled productivity. Decl...

4. [Design Principles — ash v3.32.1](https://hexdocs.pm/ash/design-principles.html) - The real superpower behind Ash is the declarative design pattern. All behavior is driven by explicit...

5. [Phoenix/Elixir can handle 2 million websocket connections ...](https://www.phoenixframework.org/) - Phoenix is a web framework for the Elixir programming language that gives you peace of mind from dev...

6. [Introduction](https://laravel.com/framework/docs/4.2/introduction) - Laravel is a framework for building modern web apps and AI agents. Expressive syntax, built-in tools...

7. [Fresh pitch for the agentic age · rails/website@8e26188](https://github.com/rails/website/commit/8e261885e35839a2d11795dfd01ec23b8a1cfc29) - Contribute to rails/website development by creating an account on GitHub.

8. [Django](https://github.com/django) - Django has 31 repositories available. Follow their code on GitHub.

9. [The web framework for perfectionists with deadlines | Django](https://www.djangoproject.com/?ref=mlq-ai) - The web framework for perfectionists with deadlines.

10. [Supabase | The Postgres Development Platform](https://supabase.com/) - Build production-grade applications with a Postgres database, Authentication, instant APIs, Realtime...

11. [Durable Execution Solutions](https://temporal.io/) - Build invincible apps with Temporal's open source durable execution platform. Eliminate complexity a...

12. [Fly.io](https://fly.io/) - Fly.io is where agents run and where the things they create go live. Let agents prototype, iterate, ...

13. [</> htmx - high power tools for html](https://htmx.org/) - htmx gives you access to AJAX, CSS Transitions, WebSockets and Server Sent Events directly in HTML, ...

14. [How do I market to engineers and technical buyers?](https://www.pedowitzgroup.com/how-do-i-market-to-engineers-and-technical-buyers) - Market to engineers and technical buyers by replacing hype with proof, technical depth, clear docume...

15. [B2D Sales: The Complete Guide to Selling DevTools and ...](https://www.reo.dev/blog/b2d-sales) - The complete guide to B2D sales for DevTools. Learn how developers buy, how to qualify intent, suppo...

16. [Developer Marketing · Pillar Reference for DevTools GTM](https://gtm-labs.co/developer-marketing) - Developer marketing vs traditional B2B across 8 axes, with the five channels that actually work for ...

17. [How to Build a High-Converting Product Demo in 2026 - MotionGility](https://motiongility.com/technical-product-demo-strategy/) - Learn a proven Technical Product Demo Strategy to create engaging product demos that simplify comple...

18. [Developer GTM — GTM Skill - LeadMagic](https://leadmagic.io/gtm-skills/developer-gtm) - Build a developer go-to-market motion the way Vercel, Stripe, and Twilio do — open-source/framework ...

