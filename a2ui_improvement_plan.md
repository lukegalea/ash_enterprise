<img src="https://r2cdn.perplexity.ai/pplx-full-logo-primary-dark%402x.png" style="height:64px;margin-right:32px"/>

# https://github.com/lukegalea/ash_a2ui looks terrible! As seen in https://lukegalea.github.io/ash_enterprise/ - for example, pagination in rendered UI shows regardless of number in set. Create vs edit vs view unclear not labeled. Not indicated visually in any reasonable way. Research generative user interfaces and the gap between we have and what we need and propose a solution. I have been eyeing a mechanism employed by deepseek dsh shell, but I think might be overly complicated to kind of quickly solve this problem of making our interfaces actually look and behave and work well

You’re right: **AshA2ui is protocol-complete but interaction-design incomplete**. The fastest credible fix is **not** to put another LLM in the rendering loop; it is to add a deterministic semantic presentation layer and a production-quality Ash catalog, then reserve generative composition for genuinely ad hoc agent surfaces.

## The actual gap

The current encoder translates Ash metadata almost directly into Basic Catalog primitives. In particular, declaring a query always inserts pagination, the form is an unlabeled `Column` ending in a generic “Save” button, and selecting a row through a button labeled “Select” implicitly populates that form—so the user must infer whether they are viewing or editing from side effects.


| Current behavior | User-visible problem | Missing abstraction |
| :-- | :-- | :-- |
| `query` implies pagination components | Previous/page/next appear for one page or even a tiny result set | Collection navigation state |
| One persistent form for create and update | Blank form, selected record, create, and edit are visually conflated | Explicit task mode |
| Row button says “Select” | It does not communicate “View” or “Edit” | User intent |
| Submit button always says “Save” | It does not confirm whether a record will be created or changed | Contextual primary action |
| Generic `status_text` | Success, error, loading, and warning states look equivalent | Typed feedback |
| Primitive rows, columns, cards | Valid wire structure does not produce a coherent application | Semantic components |
| Basic Catalog as production UI | Every surface inherits generic renderer behavior | Product catalog and design system |

This is why additional CSS alone will not solve it. Styling can make “Select” attractive, but it cannot decide whether the action means view or edit, whether the form should exist, or whether pagination has anything to navigate.

## Research direction

Generative UI implementations generally fall into three categories:


| Pattern | Model decides | Appropriate here |
| :-- | :-- | :-- |
| Data-driven | Data for a predefined component | Excellent for routine Ash surfaces |
| Declarative composition | Components and arrangement from an approved registry | Good for agent-composed surfaces |
| Open-ended generation | HTML, React, or another executable UI representation | Too risky and inconsistent for enterprise CRUD |

A2UI itself supports the middle ground: its Basic Catalog is a starter set, while custom catalogs let an application restrict surfaces to its own components and visual language. The specification explicitly says most production applications will define a catalog reflecting their design system. [^1_1][^1_2]

AG-UI’s generative-UI draft proposes a two-stage process: first determine **what experience is needed**, then let a specialized generator decide **how to represent it**. That separation is useful, but a second model should be optional—not required to make a one-row admin table usable. [^1_3]

If the DeepSeek Harness mechanism you mean is the `dsh-ui` fence, its valuable ideas are the **typed artifact envelope, browser-side registry, and action event loop**. Its ecosystem describes inline UI specifications rendered by a browser plugin with events flowing back to the model; that is compelling for conversational artifacts, but it would add unnecessary generation, latency, versioning, and failure modes to deterministic resource screens. [^1_4]

## Proposed architecture

Insert an **experience compiler** between `ResolvedView` and the protocol encoder:

```text
Ash resource metadata
        +
Authorized capabilities
        +
Surface declaration
        +
Runtime collection state
        │
        ▼
Experience resolver
  - user intent
  - form mode
  - collection pattern
  - navigation visibility
  - action hierarchy
  - feedback semantics
        │
        ▼
Semantic Ash catalog
  EntityPage
  DataGrid
  RecordPanel
  Pagination
  EmptyState
  StatusBanner
        │
        ▼
A2UI messages
        │
        ▼
Lit / React / LiveView renderer
```

Ash remains the authority for fields, types, actions, relationships, policies, and validation. The new layer owns only presentation decisions: what task the user is performing, which controls are meaningful, and how those controls should be arranged.

Conceptually:

```elixir
AshA2ui.Experience.resolve(
  resolved_view,
  records: records,
  query_state: query_state,
  ui_state: ui_state,
  capabilities: authorized_capabilities,
  client: client_capabilities
)
```

It would return a renderer-neutral structure such as:

```elixir
%AshA2ui.Experience{
  intent: :browse,
  collection: %{
    pattern: :data_grid,
    empty?: false,
    pagination: %{
      visible?: false,
      previous?: false,
      next?: false,
      page: 1,
      range: {1, 7},
      total: 7
    }
  },
  record_panel: %{
    visible?: false,
    mode: nil,
    title: nil,
    primary_label: nil
  },
  feedback: %{kind: nil, message: nil}
}
```


## Explicit task modes

Create, view, and edit should become separate application states rather than interpretations of whether `/form/id` happens to be populated.


| Mode | Heading | Body | Primary action |
| :-- | :-- | :-- | :-- |
| Browse | “Tickets” | Collection, filters, create action | None |
| Create | “Create ticket” | Editable create fields | “Create ticket” |
| View | Ticket display label | Read-only detail fields | “Edit ticket,” if authorized |
| Edit | “Edit ticket” | Editable update fields | “Save changes” |
| Confirm destructive action | “Delete ticket?” | Impact and record identity | “Delete ticket” |

The collection should therefore expose distinct events:

```text
start_create
view_record
start_edit
cancel_record_task
submit_create
submit_update
```

Do not keep `select_row` as a user-facing semantic. It may remain an internal compatibility event, but generated controls should say exactly what they do: **View**, **Edit**, **Approve**, or **Delete**.

A sensible default experience is:

- Start in browse mode with no blank form visible.
- Show “Create ticket” only when create is available and authorized.
- Open create in a modal on compact surfaces or a side panel on wider administrative surfaces.
- Open view as a detail panel or dedicated card.
- Enter edit only from an explicit Edit action.
- Return to view or browse after a successful save.
- Keep validation errors in the panel rather than collapsing or resetting it.
- Use record identity in headings, such as “Edit Acme Veterinary Clinic,” when a display attribute exists.

This requires adding state such as:

```json
{
  "ui": {
    "intent": "browse",
    "recordPanel": {
      "visible": false,
      "mode": null,
      "title": "",
      "primaryLabel": "",
      "recordId": null,
      "dirty": false,
      "busy": false
    },
    "feedback": {
      "kind": null,
      "message": ""
    }
  }
}
```


## Pagination behavior

The current encoder emits pagination whenever a query exists, independently of whether navigation is useful. GOV.UK and the New York State design system both recommend rendering nothing when there is only one page; established pagination guidance also calls for suppressing unavailable previous and next controls and communicating the current position or result range. [^1_5][^1_6][^1_7]

The policy should be:

```elixir
visible? = page > 1 or has_next_page?
previous? = page > 1
next? = has_next_page?
```

If an exact total is affordable, show:

```text
1–25 of 137                         Previous  Page 1 of 6  Next
```

If calculating a total is expensive, fetch `page_size + 1` rows and show:

```text
Showing 1–25                        Next
```

On the first page with no overflow, render no pagination at all. On later pages, retain Previous even if a deletion has made the current page sparse.

For Basic Catalog compatibility, this can be implemented immediately using the zero-or-one `List` visibility technique already used for conditional row actions:

```json
{
  "pagination": {
    "visible": [],
    "previousVisible": [],
    "nextVisible": []
  }
}
```

Each value becomes either `[]` or `[{"id":"pagination"}]`, allowing pagination and individual controls to disappear without extending the protocol. That is an expedient compatibility mechanism; the custom catalog should ultimately provide a real `Pagination` component with `page`, `pageSize`, `total`, and `hasNext` properties.

## A semantic catalog

The Basic Catalog deliberately offers generic primitives, while custom catalogs are the intended mechanism for binding A2UI to a real application design system. [^1_1][^1_2] AshA2ui should ship an opinionated catalog—perhaps `https://ash-a2ui.dev/catalogs/admin/v1`—while retaining the Basic Catalog encoder as an interoperability fallback.

I would start with these components:


| Component | Responsibility |
| :-- | :-- |
| `EntityPage` | Page title, description, primary action and overall layout |
| `DataGrid` | Columns, rows, responsive layout, row identity and action menu |
| `RecordPanel` | Explicit create, view or edit mode |
| `FieldDisplay` | Read-only values with appropriate formatting |
| `FormSection` | Labeled field grouping and responsive columns |
| `Pagination` | Result range and conditional navigation |
| `EmptyState` | Zero-result explanation and suggested action |
| `ActionBar` | Primary, secondary and destructive action hierarchy |
| `StatusBanner` | Typed success, error, warning and progress feedback |
| `ConfirmDialog` | Destructive or consequential action confirmation |

These are semantic rather than business-specific. `RecordPanel` knows what “edit mode” means, but it does not know anything about tickets, users, or veterinary clinics.

The renderer can then map them to Lit, React, Shoelace, DaisyUI, a house design system, or another component set. Catalog negotiation lets clients request the richer catalog while unknown clients continue receiving the Basic Catalog representation. [^1_2]

## Default experience rules

Avoid making every resource author specify UX mechanics. Add global defaults and expose local overrides only when a surface genuinely differs:

```elixir
config :ash_a2ui, :experience,
  collection: :data_grid,
  create: :modal,
  view: :drawer,
  edit: :drawer,
  pagination: :auto,
  density: :comfortable,
  destructive_actions: :confirm
```

An exceptional surface could override them:

```elixir
a2ui do
  experience do
    collection :cards
    create :inline
    view :detail
    edit :modal
  end
end
```

The resolver should derive most behavior:

- Create action present and authorized → show the create affordance.
- Update action present and authorized → show Edit.
- Read-only surface → row interaction means View, never Select.
- No detail-worthy fields → omit View rather than creating an empty panel.
- Zero records → render an empty state, not an empty card stack.
- One page → omit pagination.
- Destructive action → use destructive styling and confirmation.
- Validation errors → retain mode, values, and selected record.
- Mutation in progress → disable the primary action and show explicit progress.


## Generative composition

Once deterministic screens are sound, add generation above the experience compiler—not inside the renderer. The model should generate a constrained **surface recipe**, never raw HTML, CSS, React, or unrestricted A2UI.

For example:

```json
{
  "purpose": "triage pending referrals",
  "resource": "MyApp.Referrals.Referral",
  "sections": [
    {
      "kind": "collection",
      "fields": ["patient_name", "status", "created_at"],
      "preset": "pending",
      "presentation": "data_grid"
    },
    {
      "kind": "record_panel",
      "mode": "view",
      "fields": ["patient_name", "notes", "referrer"]
    }
  ]
}
```

The recipe pipeline should be:

1. The agent describes the intended task.
2. A UI planner selects patterns from the host’s approved vocabulary.
3. Existing AshA2ui dynamic verifiers validate resources, fields, actions and allowlists.
4. The deterministic experience compiler fills in modes, labels, navigation and feedback.
5. The catalog renderer owns accessibility, responsiveness and visual consistency.
6. Actions return through the existing authorized Ash action path.

This preserves the best part of DeepSeek’s approach—the model can choose an appropriate registered experience—without requiring it to redraw ordinary CRUD screens on every request. It also follows the A2UI principle that the client controls the trusted component implementation, while the server or agent sends structure and data. [^1_1]

## Accessibility contract

The richer catalog should treat accessibility as part of each component’s contract, not something individual generated surfaces must remember. WCAG requires labels or instructions for inputs, textual identification of detected errors, and programmatically determinable status messages that assistive technology can announce without moving focus. [^1_8][^1_9]

At minimum:

- Every field receives a persistent visible label.
- Required state is communicated through text and semantics, not color alone.
- Errors are adjacent to fields and associated through `aria-describedby`.
- Invalid fields use `aria-invalid`.
- Success and non-blocking changes use `role="status"`.
- Blocking errors use `role="alert"`.
- Modals and drawers move focus correctly and restore it on close.
- Pagination identifies the current page and its controlled collection.
- Icon buttons have accessible names; common actions should retain visible text.
- View mode uses text semantics rather than disabled form inputs.


## Delivery sequence

### Immediate patch

Ship this first without waiting for a new catalog:

- Add explicit `/ui/intent` and `/ui/record_panel` state.
- Replace `select_row` controls with View and Edit controls.
- Add a visible form heading bound to mode-specific server state.
- Use “Create {resource}” and “Save changes,” not “Save.”
- Hide the form until create or edit is initiated.
- Add Cancel.
- Emit pagination visibility sentinels from query state.
- Hide Previous and Next when unavailable.
- Add empty-state copy.
- Type the status state as success, error, warning or progress.

This can remain byte-compatible for existing surfaces behind an option such as `experience_version: 1`.

### Production catalog

Next, introduce the semantic catalog and map it to a polished Lit renderer:

- Establish spacing, typography, color, elevation and focus tokens.
- Implement the semantic components above.
- Add responsive table-to-card behavior.
- Support catalog capability negotiation and Basic Catalog fallback.
- Keep event envelopes and Ash authorization unchanged.
- Move ID-based renderer special cases into explicit component semantics.


### Agent planning

Only after those foundations are stable:

- Define a versioned `SurfaceRecipe` JSON Schema.
- Let an optional UI-planner model produce recipes.
- Validate recipes with the existing dynamic allowlist and verifier pipeline.
- Cache accepted recipes by recipe hash, catalog version and resource fingerprint.
- Record generated recipe, model version, validation failures and user actions.
- Require ordinary server-side authorization for every read and mutation.


## Acceptance suite

The conformance suite currently proves that payloads are valid; add an **experience conformance suite** proving that they are usable.


| Scenario | Required result |
| :-- | :-- |
| 0 records | Empty state; no pagination |
| 1 record | One row/card; no pagination |
| Exactly `page_size` | No pagination unless another page is known |
| `page_size + 1` | Next control and result-range context |
| First page | No Previous |
| Last page | No Next |
| Create-only resource | Create mode; no Edit affordance |
| Update-only resource | Explicit Edit; no blank create form |
| Read-only resource | View mode; no form controls |
| Validation failure | Edit/create mode retained; values retained; errors associated |
| Successful create | Success announced; collection refreshed; panel closes or becomes View |
| Unauthorized update | Edit control absent and server still rejects forged events |
| Narrow viewport | Collection becomes cards or horizontally managed grid |
| Keyboard-only use | Logical focus order and visible focus |
| Screen reader use | Modes, headings, errors and status changes announced |

Use Elixir contract tests for the experience state machine, renderer component tests for semantics, Playwright visual regression for each mode and result count, and automated accessibility checks. Screenshot tests should supplement—not replace—assertions such as “pagination is absent when `has_next_page?` is false.”

The key product decision is therefore: **make AshA2ui deterministic and excellent by default, then let agents compose those excellent primitives**. Do not ask an LLM to compensate for missing application semantics that Ash already knows well enough to derive.

<span style="display:none">[^1_10][^1_100][^1_101][^1_102][^1_103][^1_104][^1_105][^1_106][^1_107][^1_108][^1_109][^1_11][^1_110][^1_111][^1_112][^1_113][^1_114][^1_115][^1_116][^1_117][^1_118][^1_119][^1_12][^1_120][^1_121][^1_122][^1_123][^1_124][^1_125][^1_126][^1_127][^1_128][^1_129][^1_13][^1_130][^1_131][^1_132][^1_133][^1_134][^1_135][^1_136][^1_137][^1_138][^1_139][^1_14][^1_140][^1_141][^1_142][^1_143][^1_144][^1_145][^1_146][^1_147][^1_148][^1_149][^1_15][^1_150][^1_151][^1_152][^1_16][^1_17][^1_18][^1_19][^1_20][^1_21][^1_22][^1_23][^1_24][^1_25][^1_26][^1_27][^1_28][^1_29][^1_30][^1_31][^1_32][^1_33][^1_34][^1_35][^1_36][^1_37][^1_38][^1_39][^1_40][^1_41][^1_42][^1_43][^1_44][^1_45][^1_46][^1_47][^1_48][^1_49][^1_50][^1_51][^1_52][^1_53][^1_54][^1_55][^1_56][^1_57][^1_58][^1_59][^1_60][^1_61][^1_62][^1_63][^1_64][^1_65][^1_66][^1_67][^1_68][^1_69][^1_70][^1_71][^1_72][^1_73][^1_74][^1_75][^1_76][^1_77][^1_78][^1_79][^1_80][^1_81][^1_82][^1_83][^1_84][^1_85][^1_86][^1_87][^1_88][^1_89][^1_90][^1_91][^1_92][^1_93][^1_94][^1_95][^1_96][^1_97][^1_98][^1_99]</span>

<div align="center">⁂</div>

[^1_1]: https://a2ui.org/concepts/components/

[^1_2]: https://a2ui.org/specification/v0.9.1-a2ui/

[^1_3]: https://docs.ag-ui.com/drafts/generative-ui

[^1_4]: https://deepseekdocs.com/en/ecosystem

[^1_5]: https://design-system.service.gov.uk/components/pagination/

[^1_6]: https://designsystem.digital.gov/components/pagination/

[^1_7]: https://designsystem.ny.gov/components/pagination/

[^1_8]: https://www.w3.org/TR/WCAG21/

[^1_9]: https://www.w3.org/WAI/WCAG22/quickref/

[^1_10]: https://github.com/lukegalea/ash_a2ui

[^1_11]: https://lukegalea.github.io/ash_enterprise/

[^1_12]: https://arxiv.org/pdf/2405.04434.pdf

[^1_13]: https://arxiv.org/pdf/2412.19437.pdf

[^1_14]: http://arxiv.org/pdf/2503.06552.pdf

[^1_15]: https://arxiv.org/pdf/2401.14196.pdf

[^1_16]: https://arxiv.org/pdf/2504.03219.pdf

[^1_17]: https://www.cureus.com/articles/341667-deepseek-in-healthcare-revealing-opportunities-and-steering-challenges-of-a-new-open-source-artificial-intelligence-frontier

[^1_18]: https://dsh-in-depth.com/frontend/web-frontend

[^1_19]: https://www.developersdigest.tech/blog/deepseek-harness-dsh-first-look

[^1_20]: https://arxiv.org/html/2605.24830v1

[^1_21]: https://www.themoonlight.io/en/review/macaron-a2ui-a-model-for-generative-ui-in-personal-agents

[^1_22]: https://github.com/deepseek-ai/deepseek-harness/blob/master/packages/bundle/web-app/README.md

[^1_23]: https://github.com/whyihaveyou/dsh-suite

[^1_24]: https://github.com/0xsline/awesome-deepseek-harness

[^1_25]: https://github.com/deepseek-ai/deepseek-harness/blob/master/docs/architecture.md

[^1_26]: https://github.com/deepseek-ai/deepseek-harness

[^1_27]: https://github.com/deepseek-ai/deepseek-harness/blob/master/apps/cli/README.md

[^1_28]: https://github.com/zhu1090093659/dsh-web

[^1_29]: https://open-design.ai/plugins/dsh-genui/

[^1_30]: https://www.open-harness.net/

[^1_31]: https://github.com/Dominic789654/awesome-deepseek-harness

[^1_32]: https://www.dshplugin.store/plugin/CNSeniorious000/dsh-generative-ui

[^1_33]: https://arxiv.org/pdf/2301.11529.pdf

[^1_34]: https://arxiv.org/html/2403.04984v1

[^1_35]: https://arxiv.org/ftp/arxiv/papers/2311/2311.16601.pdf

[^1_36]: https://arxiv.org/html/2411.01606v1

[^1_37]: https://a2ui.org/specification/v1.0-a2ui/

[^1_38]: https://a2ui.org/concepts/catalogs/

[^1_39]: https://github.com/google/A2UI/blob/main/specification/v0_8/docs/a2ui_protocol.md

[^1_40]: https://deepwiki.com/google/A2UI/6.5-custom-component-catalogs

[^1_41]: https://vercel.com/academy/ai-sdk/multi-step-and-generative-ui

[^1_42]: https://deepwiki.com/google/A2UI/7.7-theming-and-styling

[^1_43]: https://developers.openai.com/plugins/concepts/ui-guidelines

[^1_44]: https://vercel.com/docs/ai-sdk

[^1_45]: https://vercel.com/blog/vercel-ai-sdk-3-1-modelfusion-joins-the-team

[^1_46]: https://ai-sdk-patterns.vercel.app/patterns/generative-ui

[^1_47]: https://deepwiki.com/google/A2UI/7.6-creating-custom-components

[^1_48]: https://vercel.com/blog/ai-sdk-3-generative-ui

[^1_49]: https://vercel.com/ai-sdk

[^1_50]: https://www.openui.com/docs/api-reference

[^1_51]: https://note.com/npaka/n/n057940d5ad03?hl=en

[^1_52]: http://arxiv.org/pdf/2501.13145.pdf

[^1_53]: http://arxiv.org/pdf/2404.05719.pdf

[^1_54]: https://dl.acm.org/doi/pdf/10.1145/3640543.3645176

[^1_55]: http://arxiv.org/pdf/2405.03716.pdf

[^1_56]: https://dl.acm.org/doi/pdf/10.1145/3613904.3642466

[^1_57]: http://arxiv.org/pdf/2402.06089.pdf

[^1_58]: https://arxiv.org/pdf/2302.10395.pdf

[^1_59]: https://arxiv.org/html/2608.09819v2

[^1_60]: https://www.alphaxiv.org/abs/2608.09819

[^1_61]: https://www.w3.org/WAI/tutorials/forms/labels/

[^1_62]: https://www.w3.org/WAI/tutorials/page-structure/labels/

[^1_63]: https://www.aditus.io/aria/aria-current/

[^1_64]: https://diyasabh.com/genui-paper.pdf

[^1_65]: https://stackoverflow.com/questions/49792819/accessibility-for-blind-people

[^1_66]: https://www.w3.org/WAI/WCAG22/Techniques/aria/ARIA6

[^1_67]: https://developer.mozilla.org/en-US/docs/Learn_web_development/Core/Accessibility/WAI-ARIA_basics

[^1_68]: https://accessibility.build/guides/accessible-pagination

[^1_69]: https://www.a11y-collective.com/blog/aria-current/

[^1_70]: https://www.w3.org/WAI/WCAG21/Techniques/aria/ARIA6

[^1_71]: https://www.ijisae.org/index.php/IJISAE/article/download/8142/7142/13704

[^1_72]: https://macaron.im/mindlab/research/ui4a-a-component-native-harness-for-generative-ui

[^1_73]: https://papers.ssrn.com/sol3/papers.cfm?abstract_id=5247018

[^1_74]: https://dsh.pub/en/plugins/?category=models

[^1_75]: https://dshdocs.com/

[^1_76]: https://cordisplugin.com/plugins/giiiiiithub-terminal

[^1_77]: https://github.com/topics/deepseek-harness?l=shell

[^1_78]: https://dsh.reshub.vip/

[^1_79]: https://www.laserlloyd.com/projects/deepseek-harness-dsh-first-look/

[^1_80]: https://arxiv.org/html/2212.13253v3

[^1_81]: http://arxiv.org/pdf/2309.01770.pdf

[^1_82]: https://a2ui.org/guides/theming/

[^1_83]: https://dev.to/ravidasari/day-3-generative-ui-gen-2-declarative-specs-with-a2ui-34eg

[^1_84]: https://a2ui.org/specification/v0.8-a2ui/

[^1_85]: https://developers.googleblog.com/introducing-a2ui-an-open-project-for-agent-driven-interfaces/

[^1_86]: https://a2ui.org/

[^1_87]: https://developers.googleblog.com/a2ui-v0-9-generative-ui/

[^1_88]: https://a2ui.org/specification/v0.9-evolution-guide/

[^1_89]: https://a2ui.org/specification/v0.9-a2ui/

[^1_90]: https://github.com/google/a2ui

[^1_91]: https://ag-ui.ai/en

[^1_92]: https://docs.ag-ui.com/concepts/generative-ui-specs

[^1_93]: https://dev.to/czmilo/the-complete-guide-to-a2ui-protocol-building-agent-driven-uis-with-googles-a2ui-in-2026-146p

[^1_94]: https://github.com/daniel-nagy/md-data-table

[^1_95]: https://baymard.com/blog/false-simplicity

[^1_96]: https://baymard.com/blog/mobile-checkout

[^1_97]: https://designmybit.com/designing-high-performance-forms-5-research-backed-ux-principles/

[^1_98]: https://baymard.com/blog/mobile-form-usability-label-position

[^1_99]: https://www.iqpc.com/media/1003982/60262.pdf

[^1_100]: https://baymard.com/blog/mobile-forms-avoid-inline-labels

[^1_101]: https://m1.material.io/components/data-tables.html

[^1_102]: https://note.com/asuka_uiux/n/nc8d16bb427b3?hl=en

[^1_103]: https://m2.material.io/components/data-tables

[^1_104]: https://m2.material.io/develop/web/components/data-tables

[^1_105]: https://fomr.io/blog/form-ux-best-practices

[^1_106]: https://material-table-core.github.io/demos/pagination/basic/

[^1_107]: https://b13.com/blog/best-practices-and-usability-for-online-forms

[^1_108]: https://ecomhint.com/blog/ecommerce-form-design

[^1_109]: http://arxiv.org/pdf/2502.17714.pdf

[^1_110]: https://arxiv.org/html/2503.04084v1

[^1_111]: https://pmc.ncbi.nlm.nih.gov/articles/PMC11623163/

[^1_112]: https://peerj.com/articles/cs-2421

[^1_113]: https://arxiv.org/html/2406.13631

[^1_114]: https://www.computersciencejournals.com/ijcai/article/193/6-2-48-100.pdf

[^1_115]: https://citeseerx.ist.psu.edu/document?repid=rep1\&type=pdf\&doi=7ac76f61bc533fac0a41a3f2270070405268ee3d

[^1_116]: https://arxiv.org/abs/2505.15049

[^1_117]: https://kgajos.seas.harvard.edu/papers/kgajos-chi08-predictability.pdf

[^1_118]: https://www.alphaxiv.org/abs/2601.22759

[^1_119]: https://arxiv.org/html/2604.25455v1

[^1_120]: https://ejournal.sidyanusa.org/index.php/jkdn/article/download/1339/737/5724

[^1_121]: https://openaccess-api.cms-conferences.org/articles/download/978-1-964867-75-5_244

[^1_122]: https://arxiv.org/html/2605.15124v1

[^1_123]: https://www.mdpi.com/2073-431X/14/10/418

[^1_124]: https://www.mdpi.com/2073-431X/15/4/238

[^1_125]: https://www.semanticscholar.org/paper/Predictability-and-accuracy-in-adaptive-user-Gajos-Everitt/11912f36179d4d5ce29bc1f9fd291119783a6e6e

[^1_126]: https://ejournal.sidyanusa.org/index.php/jkdn/article/view/1339

[^1_127]: https://arxiv.org/abs/2501.13145

[^1_128]: https://onlinelibrary.wiley.com/doi/10.1155/ahci/7442179

[^1_129]: https://github.com/Dominic789654/awesome-deepseek-harness/blob/main/README.zh-CN.md

[^1_130]: https://deepseekdocs.com/en/

[^1_131]: https://tanhdev.com/posts/generative-ui-with-mcp-ai-native-frontend/

[^1_132]: https://www.techbridgeinnovation.co/blog/generative-ui

[^1_133]: https://agentwiki.org/generative_ui

[^1_134]: https://github.com/openai/openai-structured-outputs-samples/blob/main/generative-ui/README.md

[^1_135]: https://deepseekdocs.com/en/docs/getting-started/quickstart

[^1_136]: https://docs.cloud.google.com/gemini/enterprise/docs/a2ui-agents/a2ui-component-gallery-reference

[^1_137]: https://docs.ag-ui.com/concepts/architecture

[^1_138]: https://a2ui.org/specification/v1.0-basic-catalog-implementation-guide/

[^1_139]: https://docs.ag-ui.com/introduction

[^1_140]: https://aws.amazon.com/blogs/machine-learning/build-generative-ui-for-ai-agents-on-amazon-bedrock-agentcore-with-the-ag-ui-protocol/

[^1_141]: https://downloads.hindawi.com/journals/ahci/2011/202701.pdf

[^1_142]: https://www.aclweb.org/anthology/2021.naacl-main.222.pdf

[^1_143]: https://wcagwise.com/guides/accessible-forms-guide/

[^1_144]: https://www.w3.org/WAI/WCAG21/Techniques/general/G83

[^1_145]: https://designsystem.emarsys.net/components/pagination/guidelines

[^1_146]: https://aaardvarkaccessibility.com/wcag-plain-english/4-1-3-status-messages/

[^1_147]: https://www.w3.org/WAI/curricula/developer-modules/forms/

[^1_148]: https://design-system.nice.org.uk/components/pagination/

[^1_149]: https://prioritypixels.co.uk/insights/designing-accessible-forms-labels-errors-validation/

[^1_150]: https://design-system.w3.org/components/pagination.html

[^1_151]: https://design.basis.com/components/pagination

[^1_152]: https://design.sis.gov.uk/components/navigation/pagination-bar/code/


---

# Great work. Map this into an "ash way" maximalist technical requirements doc, ifnyoy can see my private repos ai-sdlc style

What about the broader agent canvas as well as naked objects? Access to resources directly from a resource diagram? What about mixing that with the agent such that physical movement through a space made up of the resources and the domains and the application, the interfaces forming within them in the chat alongside calling the movie and controlling the viewport or at least attempting to nudge it

Yes—I can see the private `ai-sdlc` repository and its acceptance style: immutable criterion IDs, Given/When/Then assertions, explicit risk and verification levels, exact test paths, acceptance written before implementation, and CI as the evidence producer.

The broader architecture should be **objects, capabilities, projections, and scenes—not pages**. Ash supplies the canonical world model; A2UI forms interfaces around objects; the canvas spatializes their relationships; and the agent shares that scene with the user while proposing—not imperatively seizing—selection, focus, viewport movement, and presentation changes.

# TRD: AshCanvas

**Status:** Proposed\
**Working name:** `AshCanvas`\
**Initial implementation namespace:** `AshA2ui.Canvas`\
**Architectural intent:** A navigable, agent-coauthored projection of an Ash application\
**Primary host:** Phoenix LiveView\
**Projection protocol:** A2UI\
**Agent transport:** AG-UI, with direct LiveView support first\
**Graph renderer:** Cytoscape.js-based custom element\
**Acceptance model:** `ai-sdlc` oracle-first YAML

## Decision

An Ash application SHALL be representable as an authorized, navigable object graph in which:

- The application contains domains.
- Domains contain resources.
- Resources expose attributes, relationships, calculations, aggregates, actions, policies, state machines and collection lenses.
- Records are runtime objects reached through resource collection lenses.
- Relationships form traversable edges.
- Ash actions are the only executable verbs.
- A2UI surfaces are projections of objects and tasks, not the objects themselves.
- A scene is the user’s current arrangement, selection, viewport and open projections.
- The agent is a participant in that scene, acting under the user’s identity and permissions.
- The agent MAY propose navigation and viewport changes.
- The host MUST arbitrate proposed movement and preserve user control.

The implementation SHALL NOT turn A2UI into a game engine, encode spatial coordinates in Ash resources, or permit a model to emit arbitrary HTML, CSS, JavaScript, selectors or renderer commands.

## Core thesis

Ash already has almost every semantic primitive needed for a generative application environment. Ash resources contain the nouns, actions contain the verbs, relationships contain navigability, policies contain capability boundaries, queries contain collection semantics, and calculations contain derived meaning. Ash is explicitly designed around declarative resources and domains rather than handwritten controller paths. [^2_1][^2_2]

The missing layer is a first-class **object and scene model**:

```text
Ash metadata and runtime records
            │
            ▼
       Object Graph
            │
    ┌───────┴────────┐
    ▼                ▼
Experience         Scene
Compiler            Model
    │                │
    ▼                ▼
A2UI surfaces    Spatial canvas
    │                │
    └───────┬────────┘
            ▼
    Shared agent session
```

The existing agent console is already close to the correct trust boundary: models return inert intents or surface specifications, reads run through policies, mutations become inspectable proposals, client actions return through the server-held presentation, and no client-echoed surface is trusted. `AshCanvas` SHALL generalize that architecture rather than replace it.

## The Ash ontology

The conceptual model SHALL follow this mapping:


| Ash concept | Canvas meaning |
| :-- | :-- |
| Application | World |
| Domain | Region |
| Resource | Object type or room |
| Record | Object instance |
| Relationship | Traversable edge or portal |
| Read action | Collection or object lens |
| Create action | Object construction capability |
| Update action | Object transformation capability |
| Destroy action | Destructive capability |
| Generic action | Contextual affordance |
| Calculation | Derived observable |
| Aggregate | Collection-level observable |
| Policy | Capability boundary |
| State machine | Permitted movement through lifecycle state |
| A2UI surface | Task-specific projection |
| Query | Bounded collection lens |
| Notification | World-state change |
| Agent | Actor-aware guide and planner |
| Scene | Current subjective view of the world |

“Region,” “room” and “portal” are interaction metaphors only. The canonical model SHALL use typed graph objects and edges, not literal geometry.

## Naked objects

A **naked object** is an Ash entity represented without requiring an authored page or surface. It is not a raw struct and is never an authorization bypass.

Every naked object SHALL be represented by an `ObjectRef`:

```elixir
defmodule AshCanvas.ObjectRef do
  @type kind ::
          :application
          | :domain
          | :resource
          | :record
          | :relationship
          | :action
          | :calculation
          | :aggregate
          | :policy
          | :state_machine
          | :surface

  @type t :: %__MODULE__{
          id: String.t(),
          kind: kind(),
          application: atom(),
          domain: atom() | nil,
          resource: atom() | nil,
          identity: map() | nil,
          revision: String.t() | nil
        }
end
```

An `ObjectRef` MUST contain identity, not authority or data. Resolving it MUST require the actor, tenant and host registry:

```elixir
AshCanvas.resolve(object_ref,
  actor: current_user,
  tenant: tenant,
  catalog: MyApp.CanvasCatalog
)
```

Resolution SHALL produce:

```elixir
%AshCanvas.Object{
  ref: object_ref,
  label: "Dana Example",
  description: nil,
  properties: [...],
  relationships: [...],
  capabilities: [...],
  projections: [...],
  provenance: %{resource: MyApp.Accounts.User}
}
```


### Object projections

A naked object MAY advertise several projections:


| Object | Derived projections |
| :-- | :-- |
| Application | Domain map, capability search, operational overview |
| Domain | Resource graph, domain actions, documentation |
| Resource | Browse records, schema, actions, policies, state machine |
| Record | View, edit, relationships, history, contextual actions |
| Relationship | Related collection, graph expansion |
| Action | Input form, consequence description, invocation proposal |
| Policy | Policy graph and actor-specific explanation |
| State machine | State chart and available transitions |

The projection registry SHALL distinguish between:

- `:inspect` — read-only semantic description.
- `:browse` — an authorized collection.
- `:view` — a record detail.
- `:create` — explicit creation task.
- `:edit` — explicit update task.
- `:act` — contextual action invocation.
- `:diagram` — graph or state-machine representation.
- `:history` — authorized audit or event history.

The experience compiler from the previous proposal SHALL generate these projections. There MUST NOT be a separately handwritten “resource page” implementation.

## Capability envelopes

Objects SHALL expose authorized capabilities rather than renderer-specific buttons:

```elixir
%AshCanvas.Capability{
  id: "accounts.user:update",
  verb: :update,
  action: :update,
  object: user_ref,
  label: "Edit user",
  consequence: :mutation,
  confirmation: :none,
  input_projection: :edit,
  result_projection: :view,
  authorized?: true
}
```

Capabilities SHALL be generated from existing Ash actions and policies. UI code MUST NOT call a resource action merely because it knows its name.

Capability resolution SHALL obey these rules:

- Resource-level capabilities MAY be resolved when the resource is entered.
- Record-specific capabilities MUST be resolved against the loaded record.
- Destructive and consequential actions MUST declare confirmation semantics.
- A hidden capability MUST remain impossible to invoke through a forged event.
- Capability inputs MUST be cast through the Ash action.
- Field visibility MUST obey field policies.
- All execution MUST use the scene actor and tenant.
- A model MUST NOT gain a broader capability set than the person whose scene it inhabits.


## Canonical graph

`AshDiagram` currently proves that application, domain, resource, inherited attributes, policies and state machines can be derived. Its tests explicitly require inherited platform fields, authorization paths and state transitions to appear in generated diagrams.

That derivation SHALL be moved behind or extended with a canonical graph AST. `AshCanvas` MUST NOT parse Mermaid source or rendered SVG to recover application semantics.

```elixir
%AshCanvas.Graph{
  revision: "sha256:...",
  roots: ["application:ash_enterprise"],
  nodes: %{
    "domain:accounts" => %Node{kind: :domain, ...},
    "resource:accounts.user" => %Node{kind: :resource, ...}
  },
  edges: [
    %Edge{
      kind: :contains,
      from: "domain:accounts",
      to: "resource:accounts.user"
    },
    %Edge{
      kind: :relationship,
      name: :roles,
      from: "resource:accounts.user",
      to: "resource:security.role"
    }
  ]
}
```


### Stable identities

Node identifiers MUST be:

- Deterministic across application restarts.
- Independent of visual coordinates.
- Stable across non-semantic source formatting changes.
- Opaque to clients where module disclosure is inappropriate.
- Versioned when graph semantics change.
- Resolved only through a host-configured registry.

Client input MUST NOT be converted to atoms or module names.

### Graph layers

The graph SHALL distinguish these layers:


| Layer | Contents | Availability |
| :-- | :-- | :-- |
| Structural | Applications, domains, resources, relationships | Build-time snapshot |
| Behavioral | Actions, policies, state machines | Build-time snapshot |
| Experiential | Lenses, projections, labels, display rules | Build-time or configured |
| Runtime | Records and authorized capabilities | Actor and tenant scoped |
| Operational | Notifications, activity, health and provenance | Explicitly enabled |
| Ephemeral | Selection, open panels, highlights and agent cues | Scene scoped |

Structural metadata MUST NOT be silently exposed to every end user. A host catalog SHALL determine which metadata objects are discoverable by each audience.

## Semantic space

The “physical” application space SHALL use **semantic zoom**, not a fixed giant graph containing every record.


| Zoom level | Visible world |
| :-- | :-- |
| Application | Domains and major external systems |
| Domain | Resources and inter-domain edges |
| Resource | Relationships, actions, policies and collection entry points |
| Collection | Authorized records loaded through a named query |
| Record | Fields, capabilities and expandable related records |
| Detail | History, calculations, state transitions and focused workflows |

Graph libraries support controlled pan, zoom, fit and animated focus, while also distinguishing user-generated viewport interaction from programmatic changes. [^2_3][^2_4][^2_5] Level-of-detail rendering is an established graph-navigation technique for presenting coarse information at low zoom and richer content after zooming in. [^2_6]

Records MUST therefore enter the scene progressively:

1. A resource appears as one node.
2. Activating its collection lens opens a collection projection.
3. Selecting a record creates or resolves its `ObjectRef`.
4. Choosing “Show relationships” expands only that record’s authorized neighborhood.
5. Leaving the record scope MAY collapse ephemeral record nodes.
6. Pinned objects remain in the scene until explicitly removed.

The system MUST NOT attempt to lay out an entire production database as a graph.

## Scene model

The conversation, canvas and rendered surfaces SHALL share one server-held scene.

```elixir
defmodule AshCanvas.Scene do
  defstruct [
    :id,
    :actor_ref,
    :tenant,
    :graph_revision,
    :revision,
    :route,
    :selection,
    :viewport,
    :open_projections,
    :pinned_objects,
    :expanded_objects,
    :conversation,
    :agent_mode,
    :follow_mode
  ]
end
```

A scene is not the application state. It is the current participant’s view of application state.

### Scene state

```json
{
  "revision": 41,
  "route": [
    "application:ash_enterprise",
    "domain:accounts",
    "resource:accounts.user"
  ],
  "selection": {
    "primary": "record:accounts.user:opaque-id",
    "secondary": []
  },
  "viewport": {
    "center": {"x": 1240, "y": 840},
    "zoom": 1.25,
    "visibleObjects": [
      "resource:accounts.user",
      "resource:security.role"
    ],
    "source": "user"
  },
  "openProjections": [
    {
      "id": "surface:user-detail",
      "object": "record:accounts.user:opaque-id",
      "lens": "view",
      "placement": "dock"
    }
  ]
}
```

The server SHALL retain semantic state: route, selection, opened projections and pinned objects. The client MAY own raw pixel coordinates and layout caches, but SHALL report meaningful viewport changes back as throttled observations.

## User movement

User navigation SHALL be treated as first-class interaction:

- Clicking selects an object.
- Double-clicking or pressing Enter enters its default lens.
- Escape moves to the semantic parent.
- Relationship activation traverses or expands an edge.
- Breadcrumbs expose the current semantic route.
- Search resolves objects, not URLs.
- The command palette opens capabilities and projections.
- Back and forward restore semantic scene history.
- Panning alone does not change the selected object.
- Zooming across a semantic threshold changes level of detail but not authorization.

Selecting a resource node SHALL allow direct access to:

- Browse records.
- Create a record, if authorized.
- Inspect resource schema.
- Inspect relationships.
- Inspect actions.
- Inspect policy structure, if the audience may see it.
- Inspect lifecycle state machine.
- Ask the agent about this resource.

Selecting a record node SHALL allow direct access to:

- View.
- Edit.
- Run authorized actions.
- Expand selected relationships.
- Show provenance or history.
- Add the object as explicit conversation context.


## Chat and canvas

The host SHOULD present three logical regions, adaptable to viewport size:

```text
┌────────────────────────────────────────────────────────────┐
│ Application route, search and scene controls               │
├────────────────────────────┬───────────────────────────────┤
│                            │ Conversation                  │
│ Navigable canvas           │                               │
│                            │ Inline A2UI projections       │
│                            │                               │
├────────────────────────────┴───────────────────────────────┤
│ Optional object stage / dock                               │
└────────────────────────────────────────────────────────────┘
```

These are not independent applications. They are projections of one scene.

### Bidirectional grounding

The canvas SHALL ground the conversation:

- Selecting an object adds a context chip to the composer.
- The agent receives selected object, semantic route, visible neighborhood and open projections.
- Clicking an object reference in chat requests canvas focus.
- An inline surface retains its source `ObjectRef`.
- Interacting with an inline surface MAY update selection.
- A result record created by an action MAY appear and become highlighted.
- Dismissing a surface does not delete or deselect its object.
- Notifications update projections without automatically moving the camera.

Task-driven models are an effective basis for malleable interfaces because natural-language and direct-manipulation changes can operate on the same underlying semantic model. [^2_7] Here, the task model is derived from Ash resources and current scene state rather than invented independently by the model.

### Surface placement

A projection SHALL support these placements:


| Placement | Use |
| :-- | :-- |
| `:inline` | A result embedded in the conversation |
| `:dock` | Persistent inspector beside the canvas |
| `:overlay` | Modal or consequential task |
| `:node` | Compact representation attached to an object |
| `:stage` | Large focused projection replacing most of the canvas |
| `:external` | Host-approved handoff to a specialized application |

The same `SurfaceInstance` SHOULD move between placements without being rebuilt where the renderer supports it.

## Agent participation

The agent SHALL receive a bounded scene context:

```elixir
%AshCanvas.AgentContext{
  selected: selected_object_summary,
  route: scene.route,
  visible: visible_object_summaries,
  open_projections: projection_summaries,
  recent_scene_events: recent_events,
  capabilities: advertised_frontend_capabilities,
  actor: actor_context
}
```

It MUST NOT receive every node, record or field in the application by default.

### Agent outputs

The agent MAY return:

- A textual response.
- An inert mutation proposal.
- A projection request.
- A graph expansion request.
- A navigation intent.
- A scene choreography.
- A constrained dynamic surface specification.
- A request for human input.

AG-UI supports client-defined frontend tools passed to the agent at runtime, allowing the frontend to decide which UI capabilities exist for the present user and application state. [^2_8] AG-UI integrations also support shared-state snapshots, tool lifecycle events and human-input checkpoints, making it a suitable transport for scene synchronization while A2UI remains responsible for rendered surfaces. [^2_9]

## Navigation intents

The model MUST NOT call `cy.pan`, `cy.zoom`, DOM selectors or equivalent renderer APIs. It SHALL issue semantic navigation intents:

```elixir
%AshCanvas.NavigationIntent{
  id: UUIDv7.generate(),
  source: :agent,
  operation: :focus,
  targets: [user_resource_ref],
  effect: :spotlight,
  strength: :suggest,
  reason: "The role assignment action belongs to User",
  expected_scene_revision: 41,
  ttl_ms: 10_000,
  fallback: :reveal_in_breadcrumb
}
```

Supported operations SHALL initially be:

- `:reveal`
- `:focus`
- `:fit`
- `:spotlight`
- `:trace`
- `:enter`
- `:leave`
- `:open_projection`
- `:place_projection`
- `:pin`
- `:unpin`

Supported strengths SHALL be:


| Strength | Meaning |
| :-- | :-- |
| `:suggest` | Indicate a target without moving the viewport |
| `:guide` | Perform a small movement if the user is idle |
| `:request` | Ask the host to move and report the outcome |
| `:system` | Reserved for restoration or accessibility behavior |

Models MUST NOT emit `:system`.

### Arbitration

The host SHALL respond to an intent with:

```elixir
{:ok, :accepted}
{:ok, :deferred}
{:ok, :presented_as_suggestion}
{:error, :stale_scene}
{:error, :user_active}
{:error, :target_not_visible}
{:error, :unauthorized}
{:error, :unsupported}
```

The viewport policy SHALL enforce:

- Recent manual navigation wins over agent movement.
- Pointer-down, drag, pinch and wheel activity cancel pending motion.
- Reduced-motion preferences disable animated travel.
- Focus MUST NOT be moved merely because the visual viewport moved.
- Cross-domain jumps SHOULD begin as suggestions unless follow mode is enabled.
- Background notifications MUST NOT move the viewport.
- Repeated equivalent intents MUST be idempotent.
- Stale intents MUST be rejected by scene revision.
- The user can disable agent viewport movement globally.
- The user can temporarily enable “follow agent.”
- Every movement initiated by the agent must have a visible explanation or provenance cue.

This is the correct meaning of “nudge”: the agent states the semantic destination and desired effect; the client decides whether, when and how to move.

## Scene choreography

The “movie” concept SHOULD become a constrained `ScenePlan`, not a series of arbitrary UI commands.

```elixir
%AshCanvas.ScenePlan{
  id: "explain-role-assignment",
  title: "How a role reaches a user",
  expected_scene_revision: 41,
  interruptible?: true,
  cues: [
    %{op: :focus, target: user_resource_ref},
    %{op: :trace, path: [user_resource_ref, membership_ref, role_ref]},
    %{op: :open_projection, target: role_ref, lens: :view},
    %{op: :narrate, text: "A user receives the role through this membership."},
    %{op: :await_user, event: :continue},
    %{op: :spotlight, target: privilege_ref}
  ]
}
```

A scene plan SHALL support:

- Pause.
- Resume.
- Skip cue.
- Stop.
- Manual takeover.
- Reduced-motion rendering.
- A visible cue list.
- Semantic fallback when a target is absent.
- Revalidation at each cue.
- Cancellation when the scene revision becomes incompatible.

The model MAY compose ephemeral scene plans from an allowlisted cue vocabulary. Persisted tours SHOULD later be ordinary Ash resources with versioning, ownership, policies and audit history.

Raw camera coordinates, CSS selectors, unbounded delays and executable callbacks MUST NOT be accepted from generated scene plans.

## Renderer decision

The first interactive canvas SHOULD use Cytoscape.js behind a custom element and LiveView hook:

```html
<ash-canvas
  graph-revision="sha256:..."
  scene-id="..."
></ash-canvas>
```

Cytoscape.js already provides selection, pan, zoom, fit, viewport updates and animated focus primitives. [^2_3][^2_4] It also distinguishes user-originated drag, pinch and wheel viewport changes, which is essential for cancelling or deferring agent movement. [^2_5]

Mermaid SHALL remain a documentation and export projection. It SHOULD NOT be the interactive scene runtime because the current output is string-oriented and Mermaid’s default strict security mode disables click behavior. [^2_10]

## Protocol boundaries

No protocol SHALL become the canonical model.


| Layer | Responsibility |
| :-- | :-- |
| Ash | Data, actions, relationships, calculations and authorization |
| AshCanvas Graph | Canonical application and object topology |
| AshCanvas Scene | Selection, route, projections and navigation intent |
| Experience compiler | Task mode, affordances, labels and interaction behavior |
| A2UI | Declarative surface projection |
| AG-UI | Conversation, agent events, shared state and frontend tools |
| LiveView | First-party transport and lifecycle |
| MCP Apps | Optional portable embedded application bridge |
| A2A | Future agent-to-agent surface transport |
| Cytoscape | Spatial rendering and local viewport mechanics |

MCP Apps now defines UI resources linked to tools with bidirectional host communication, making it a reasonable future bridge for exposing an AshCanvas projection inside third-party conversational hosts. [^2_11][^2_12] A2UI clients similarly track active surfaces and their data models, while A2A capability metadata can negotiate supported catalogs. [^2_13][^2_14]

### Frontend capabilities

The host SHALL advertise functions such as:

```json
{
  "canvasCapabilities": {
    "version": "1",
    "functions": [
      "canvas.reveal",
      "canvas.focus",
      "canvas.fit",
      "canvas.trace",
      "canvas.openProjection",
      "canvas.presentScenePlan"
    ],
    "motion": {
      "enabled": true,
      "reduced": false,
      "followAgent": false
    }
  }
}
```

A model or remote agent MUST treat absent capabilities as unavailable.

## Extension DSL

The maximalist default is derivation. DSL SHALL only describe information Ash cannot infer.

```elixir
defmodule MyApp.Accounts do
  use Ash.Domain,
    extensions: [AshCanvas.Domain]

  canvas do
    label "Accounts"
    description "People, organizations and ownership"
    audiences [:admin, :support]
  end
end
```

```elixir
defmodule MyApp.Accounts.User do
  use Ash.Resource,
    extensions: [AshA2ui, AshCanvas.Resource]

  canvas do
    display_attribute :email

    lenses [:browse, :view, :edit, :relationships, :history]

    relationship :roles do
      traversal :expand
      label "Assigned roles"
    end

    action :deactivate do
      consequence :destructive
      confirmation :required
    end
  end
end
```

Default inference SHALL cover:

- Labels from resource and field names.
- Record labels from configured display attributes and known candidates.
- Relationships from resource metadata.
- Collection lenses from primary read actions.
- Create and edit lenses from primary create and update actions.
- State transitions from `AshStateMachine`.
- A2UI field controls from types and constraints.
- Destructive semantics from action type and explicit metadata.
- Available actions from authorization.
- Diagram content from domains and resources.


## Runtime modules

The initial module boundaries SHOULD be:

```text
AshA2ui.Canvas
AshA2ui.Canvas.ObjectRef
AshA2ui.Canvas.Object
AshA2ui.Canvas.ObjectResolver
AshA2ui.Canvas.Catalog
AshA2ui.Canvas.Graph
AshA2ui.Canvas.Graph.Builder
AshA2ui.Canvas.Graph.Diff
AshA2ui.Canvas.Scene
AshA2ui.Canvas.SceneServer
AshA2ui.Canvas.SceneEvent
AshA2ui.Canvas.Navigator
AshA2ui.Canvas.NavigationIntent
AshA2ui.Canvas.ViewportPolicy
AshA2ui.Canvas.ScenePlan
AshA2ui.Canvas.ScenePlan.Validator
AshA2ui.Canvas.Projection
AshA2ui.Canvas.ProjectionRegistry
AshA2ui.Experience
AshA2ui.Experience.Resolver
AshA2ui.Transport.AgUi
AshA2ui.Transport.LiveView
```

It SHOULD begin inside `ash_a2ui` to avoid premature package decomposition. Extraction into `ash_canvas` becomes justified only when a second non-A2UI projection consumes the canonical object and scene model.

## Functional requirements

| ID | Requirement |
| :-- | :-- |
| `CANVAS-GRAPH-001` | Derive a stable graph AST from configured Ash domains and resources |
| `CANVAS-GRAPH-002` | Represent containment, relationships, actions, policies and state machines as typed nodes or edges |
| `CANVAS-GRAPH-003` | Produce graph diffs between revisions |
| `CANVAS-OBJ-001` | Resolve application, domain, resource and record `ObjectRef`s under actor and tenant |
| `CANVAS-OBJ-002` | Expose authorized capabilities and projections for each resolved object |
| `CANVAS-OBJ-003` | Refuse unknown, malformed, undiscoverable or unauthorized references |
| `CANVAS-SCENE-001` | Maintain one server-held semantic scene per active session |
| `CANVAS-SCENE-002` | Synchronize selection, route, open projections and pins across canvas and conversation |
| `CANVAS-SCENE-003` | Keep local layout coordinates distinct from semantic scene state |
| `CANVAS-NAV-001` | Support direct resource access from a graph node |
| `CANVAS-NAV-002` | Support semantic entry, exit, traversal, expansion and history |
| `CANVAS-NAV-003` | Support programmatic reveal, focus, fit, spotlight and trace intents |
| `CANVAS-NAV-004` | Arbitrate agent movement against recent user interaction |
| `CANVAS-NAV-005` | Return structured outcomes for every navigation intent |
| `CANVAS-PROJ-001` | Open view, browse, create, edit and action projections from objects |
| `CANVAS-PROJ-002` | Render the same projection inline, docked, overlaid or staged |
| `CANVAS-PROJ-003` | Preserve explicit create, view and edit task modes |
| `CANVAS-AGENT-001` | Supply bounded scene context to the agent |
| `CANVAS-AGENT-002` | Accept only allowlisted scene and projection intents |
| `CANVAS-AGENT-003` | Support interruptible scene plans |
| `CANVAS-LIVE-001` | Refresh affected projections from Ash notifications |
| `CANVAS-LIVE-002` | Never move the viewport because of a notification alone |
| `CANVAS-A11Y-001` | Provide keyboard equivalents for all graph navigation |
| `CANVAS-A11Y-002` | Honor reduced motion and announce semantic selection changes |
| `CANVAS-PORT-001` | Keep the graph, scene and projection contracts transport-neutral |

## Security requirements

| ID | Requirement |
| :-- | :-- |
| `CANVAS-SEC-001` | Every record read and action invocation runs with the scene actor and tenant |
| `CANVAS-SEC-002` | The client never supplies trusted surface, capability or resource definitions |
| `CANVAS-SEC-003` | The model never receives a direct mutation function |
| `CANVAS-SEC-004` | Mutation proposals remain inert until the required human decision |
| `CANVAS-SEC-005` | Resource discovery is restricted by the host catalog |
| `CANVAS-SEC-006` | Object references cannot cause dynamic atom or module creation |
| `CANVAS-SEC-007` | Generated plans cannot contain HTML, JavaScript, CSS, selectors or arbitrary URLs |
| `CANVAS-SEC-008` | Navigation cannot cause unauthorized data to load |
| `CANVAS-SEC-009` | Field policies apply to object properties and projections |
| `CANVAS-SEC-010` | Forged capabilities are rejected even when their action names exist |
| `CANVAS-SEC-011` | Scene revisions protect against stale generated commands |
| `CANVAS-SEC-012` | Renderer capability negotiation defaults to deny |

## Non-requirements

The first release SHALL NOT:

- Render arbitrary records across the entire application graph.
- Provide a 3D environment.
- Treat physical distance as a security or domain concept.
- Let the model choose exact coordinates.
- Implement collaborative multi-user scenes.
- Persist every pan and zoom as an audited business event.
- Replace Clarity’s static diagrams.
- Replace the existing A2UI protocol encoder.
- Generate arbitrary component implementations.
- Add a second authorization system.
- Require AG-UI for the first LiveView implementation.
- Animate notifications or live updates by moving the camera.
- Infer destructive consequences from action names alone.


## Evidence strategy

The repository’s existing diagram tests establish the right principle: a blank or incomplete generated view must fail in CI instead of becoming a runtime surprise. The `ai-sdlc` acceptance format strengthens that principle by making the acceptance file the immutable pre-implementation oracle and naming the exact automated evidence for each criterion.

Proposed layout:

```text
.sdlc/
  acceptance/
    A2UI-101.yaml   # experience modes and pagination
    A2UI-102.yaml   # canonical object graph
    A2UI-103.yaml   # direct resource navigation
    A2UI-104.yaml   # shared scene
    A2UI-105.yaml   # agent viewport intents
    A2UI-106.yaml   # scene plans
    A2UI-107.yaml   # authorization and tamper cases
  verification.yaml
```


## Acceptance oracle

```yaml
# Acceptance criteria for A2UI-102.
# Written before implementation.
# Criterion ids are immutable.
# CI is the only evidence producer.

item: A2UI-102

criteria:
  - id: A2UI-102/AC-1
    given: >-
      an Ash application with configured domains, resources, relationships,
      actions, policies and state machines
    when: the canonical canvas graph is built
    then: >-
      every configured domain and resource appears under a stable ObjectRef,
      containment and relationship edges are typed, and inherited resource
      metadata remains visible without parsing Mermaid output
    verify: integration
    risk: medium
    test: >-
      test/ash_a2ui/canvas/graph_builder_test.exs::derives_the_complete_application_graph

  - id: A2UI-102/AC-2
    given: >-
      two graph builds over semantically identical resource metadata
    when: source formatting and module compilation order differ
    then: >-
      node ids, edge ids and the semantic graph revision are identical
    verify: property
    risk: medium
    test: >-
      test/ash_a2ui/canvas/graph_identity_property_test.exs::stable_across_non_semantic_changes

  - id: A2UI-102/AC-3
    given: an unregistered module name supplied by the client
    when: it is submitted as an ObjectRef
    then: >-
      resolution returns unknown_object without converting input to an atom,
      loading a module or exposing registry contents
    verify: security
    risk: high
    test: >-
      test/ash_a2ui/canvas/object_resolver_security_test.exs::rejects_unregistered_module_input
```

```yaml
item: A2UI-103

criteria:
  - id: A2UI-103/AC-1
    given: >-
      an authorized actor viewing the domain graph with the User resource visible
    when: the actor activates the User resource node
    then: >-
      User becomes the primary scene selection, the semantic route ends at User,
      and the resource inspector offers browse, schema and only the actions
      available to that actor
    verify: browser
    risk: medium
    test: >-
      test/e2e/canvas_resource_navigation.spec.ts::opens_a_resource_directly_from_the_graph

  - id: A2UI-103/AC-2
    given: an actor without permission to update a selected User record
    when: the record object is resolved and rendered
    then: >-
      no edit capability or edit projection is advertised, and a forged edit
      capability envelope is rejected server-side
    verify: security
    risk: high
    test: >-
      test/ash_a2ui/canvas/capability_security_test.exs::record_capabilities_obey_actor_policy

  - id: A2UI-103/AC-3
    given: a resource with more records than the active query page
    when: the actor enters the resource
    then: >-
      the scene contains the resource and its collection lens but does not add
      every record as a graph node; record nodes appear only after authorized
      collection results are selected or explicitly expanded
    verify: integration
    risk: medium
    test: >-
      test/ash_a2ui/canvas/progressive_disclosure_test.exs::does_not_materialize_the_database_as_a_graph
```

```yaml
item: A2UI-104

criteria:
  - id: A2UI-104/AC-1
    given: >-
      a scene containing the canvas, conversation and a docked A2UI projection
    when: the user selects a record in any one of the three
    then: >-
      all three receive the same primary ObjectRef and scene revision without
      rebuilding unrelated projections
    verify: browser
    risk: medium
    test: >-
      test/e2e/shared_scene.spec.ts::selection_is_shared_across_canvas_chat_and_projection

  - id: A2UI-104/AC-2
    given: a live surface subscribed to Ash notifications
    when: another application changes one of its records
    then: >-
      the affected data projection refreshes, the scene revision advances, and
      the canvas viewport does not pan, zoom or change selection
    verify: browser
    risk: medium
    test: >-
      test/e2e/live_scene.spec.ts::notification_refreshes_data_without_moving_the_user
```

```yaml
item: A2UI-105

criteria:
  - id: A2UI-105/AC-1
    given: >-
      the agent emits a guide-strength focus intent for a visible resource and
      the user has not manually navigated inside the configured quiet period
    when: the viewport policy evaluates the intent
    then: >-
      the host focuses the resource with bounded animation, records accepted as
      the intent result and leaves DOM focus unchanged
    verify: browser
    risk: medium
    test: >-
      test/e2e/agent_navigation.spec.ts::accepts_a_bounded_focus_intent_when_idle

  - id: A2UI-105/AC-2
    given: the user is dragging, pinching, scrolling or has just moved the viewport
    when: an agent guide-strength viewport intent arrives
    then: >-
      the host does not move the viewport and returns user_active or presents
      the target as a non-moving suggestion
    verify: browser
    risk: high
    test: >-
      test/e2e/agent_navigation.spec.ts::manual_navigation_always_wins

  - id: A2UI-105/AC-3
    given: a navigation intent whose expected scene revision is stale
    when: the host evaluates it
    then: >-
      the intent is rejected without movement, projection changes or data loads
    verify: integration
    risk: high
    test: >-
      test/ash_a2ui/canvas/navigation_intent_test.exs::rejects_stale_scene_commands

  - id: A2UI-105/AC-4
    given: reduced motion is active
    when: the host accepts a focus or trace intent
    then: >-
      the semantic destination and highlight are applied without animated travel
    verify: browser
    risk: medium
    test: >-
      test/e2e/agent_navigation_accessibility.spec.ts::honors_reduced_motion
```

```yaml
item: A2UI-106

criteria:
  - id: A2UI-106/AC-1
    given: an allowlisted scene plan with focus, trace, projection and narration cues
    when: the user starts the plan
    then: >-
      cues execute in order, each cue is revalidated against current scene and
      authorization state, and the user can pause, skip or stop at every boundary
    verify: browser
    risk: high
    test: >-
      test/e2e/scene_plan.spec.ts::executes_an_interruptible_validated_tour

  - id: A2UI-106/AC-2
    given: >-
      a generated scene plan containing a raw selector, script, unknown operation,
      unauthorized target or absolute camera coordinates
    when: the plan is validated
    then: >-
      the entire plan is refused with structured correction errors and no cue runs
    verify: security
    risk: high
    test: >-
      test/ash_a2ui/canvas/scene_plan_security_test.exs::refuses_renderer_and_authority_escape_hatches
```


## Delivery plan

### Experience first

Implement the deterministic experience resolver from the earlier proposal:

- Explicit browse, create, view and edit modes.
- Conditional pagination.
- Semantic action labels.
- Empty, loading, success and error states.
- Production Ash catalog.
- Browser and accessibility acceptance suite.

This solves the immediate “the generated application looks terrible” problem without waiting for the spatial canvas.

### Objects second

Introduce:

- Canonical graph AST.
- Stable `ObjectRef`.
- Host catalog.
- Object resolver.
- Capability resolver.
- Resource and record inspectors.
- Direct graph-node-to-projection navigation.

This creates useful naked objects before adding any model-controlled movement.

### Shared scene third

Replace the single `presentation` concept in `AgentLive` with a scene containing:

- Primary selection.
- Semantic route.
- Open projections.
- Inline and dock placement.
- Canvas state.
- Conversation grounding.
- Existing proposal state.

The current server-held presentation and actor-aware action routing should become projection instances within this scene rather than being discarded.

### Agent guidance fourth

Add semantic frontend functions and navigation intents:

- Reveal and focus.
- Spotlight and trace.
- Open and place projection.
- Intent arbitration.
- Manual takeover.
- Reduced motion.
- Structured outcomes visible to the agent.

The first implementation SHOULD default to `:suggest`; agent-follow mode can be introduced only after the host reliably distinguishes user and programmatic viewport changes.

### Choreography last

Add `ScenePlan` only after atomic navigation intents are proven:

- Typed cue schema.
- Validation.
- Playback controls.
- Per-cue authorization.
- Stale-scene handling.
- Recorded outcome.
- Generated plan correction loop.
- Optional persisted tours as Ash resources.


## Central invariant

The strongest formulation is:

> **There are no application pages. There are authorized Ash objects, the capabilities they expose, the projections through which a person can understand or act on them, and scenes that arrange those projections around the task at hand.**

The spatial canvas is therefore not a replacement for chat or A2UI. It is the durable world model linking them: the user can move through the application directly, chat can summon interfaces beside the relevant objects, and the agent can point, reveal, trace and propose movement without ever possessing the viewport, renderer or mutation itself.

<span style="display:none">[^2_100][^2_101][^2_102][^2_103][^2_104][^2_105][^2_106][^2_107][^2_108][^2_109][^2_110][^2_111][^2_112][^2_113][^2_114][^2_115][^2_116][^2_117][^2_118][^2_119][^2_120][^2_121][^2_122][^2_123][^2_124][^2_125][^2_126][^2_127][^2_128][^2_129][^2_130][^2_131][^2_132][^2_133][^2_134][^2_135][^2_136][^2_137][^2_138][^2_139][^2_140][^2_141][^2_142][^2_143][^2_144][^2_145][^2_146][^2_147][^2_148][^2_149][^2_15][^2_150][^2_151][^2_152][^2_153][^2_16][^2_17][^2_18][^2_19][^2_20][^2_21][^2_22][^2_23][^2_24][^2_25][^2_26][^2_27][^2_28][^2_29][^2_30][^2_31][^2_32][^2_33][^2_34][^2_35][^2_36][^2_37][^2_38][^2_39][^2_40][^2_41][^2_42][^2_43][^2_44][^2_45][^2_46][^2_47][^2_48][^2_49][^2_50][^2_51][^2_52][^2_53][^2_54][^2_55][^2_56][^2_57][^2_58][^2_59][^2_60][^2_61][^2_62][^2_63][^2_64][^2_65][^2_66][^2_67][^2_68][^2_69][^2_70][^2_71][^2_72][^2_73][^2_74][^2_75][^2_76][^2_77][^2_78][^2_79][^2_80][^2_81][^2_82][^2_83][^2_84][^2_85][^2_86][^2_87][^2_88][^2_89][^2_90][^2_91][^2_92][^2_93][^2_94][^2_95][^2_96][^2_97][^2_98][^2_99]</span>

<div align="center">⁂</div>

[^2_1]: https://github.com/ash-project/ash

[^2_2]: https://ash.hexdocs.pm/3.24.7/authorize-access-to-resources.html

[^2_3]: http://js.cytoscape.org/

[^2_4]: https://blog.js.cytoscape.org/2016/06/08/glycolysis/

[^2_5]: https://blog.js.cytoscape.org/2021/05/11/3.19.0-release/

[^2_6]: https://docs.yworks.com/yfiles-html/dguide/features/

[^2_7]: https://arxiv.org/html/2503.04084v1

[^2_8]: https://docs.ag-ui.com/concepts/tools

[^2_9]: https://docs.ag2.ai/latest/docs/beta/ag-ui/

[^2_10]: https://mermaid.ai/open-source/config/schema-docs/config-properties-securitylevel.html

[^2_11]: https://blog.modelcontextprotocol.io/tags/apps/

[^2_12]: https://blog.modelcontextprotocol.io/posts/page/2/

[^2_13]: https://docs.crewai.com/v1.14.7/en/learn/a2ui

[^2_14]: https://deepwiki.com/a2ui-project/a2ui/2.1-protocol-v0.9-specification

[^2_15]: https://arxiv.org/pdf/1005.0595.pdf

[^2_16]: https://arxiv.org/pdf/2412.16060.pdf

[^2_17]: https://a2ui.org/specification/v1.0-a2ui/

[^2_18]: https://a2ui.org/concepts/catalogs/

[^2_19]: https://docs.ag2.ai/docs/user-guide/a2ui/capabilities/

[^2_20]: https://docs.ag-ui.com/concepts/state

[^2_21]: https://a2ui.org/catalogs/

[^2_22]: https://a2ui.org/specification/v1.0-evolution-guide/

[^2_23]: https://modelcontextprotocol.io/extensions/apps/overview

[^2_24]: https://www.mcpbundles.com/blog/2025/11/24/mcp-apps-interactive-ui-protocol

[^2_25]: https://deepwiki.com/a2ui-project/a2ui/2.4-catalogs:-definition-and-negotiation

[^2_26]: https://glama.ai/mcp/servers/iamneilroberts/mcp-apps-interactive-ui

[^2_27]: https://deepwiki.com/a2ui-project/a2ui/2.2-protocol-v1.0-specification

[^2_28]: https://a2ui.org/specification/v0.8-a2ui/

[^2_29]: https://docs.ag2.ai/latest/docs/user-guide/ag-ui/

[^2_30]: https://apps.extensions.modelcontextprotocol.io/api/documents/overview.html

[^2_31]: https://learn.microsoft.com/en-us/agent-framework/integrations/by-component/ui/ag-ui/testing-with-dojo

[^2_32]: https://f1000research.com/articles/4-482/v1/pdf

[^2_33]: https://pmc.ncbi.nlm.nih.gov/articles/PMC4752027/

[^2_34]: https://academic.oup.com/bioinformatics/article-pdf/32/2/309/6689178/btv557.pdf

[^2_35]: https://pmc.ncbi.nlm.nih.gov/articles/PMC9889963/

[^2_36]: https://pmc.ncbi.nlm.nih.gov/articles/PMC4708103/

[^2_37]: https://js.cytoscape.org/

[^2_38]: https://github.com/cytoscape/cytoscape.js-panzoom

[^2_39]: https://github.com/cytoscape/cytoscape.js/issues/1691

[^2_40]: https://github.com/cytoscape/cytoscape.js-navigator

[^2_41]: https://github.com/cytoscape/cytoscape.js-panzoom/blob/master/README.md

[^2_42]: https://github.com/cytoscape/cytoscape.js/issues/2477

[^2_43]: https://app.studyraid.com/en/read/11730/371575/zoom-and-pan-controls

[^2_44]: https://reactflow.dev/api-reference/types/react-flow-instance

[^2_45]: https://deepwiki.com/cytoscape/cytoscape.js/6.2-built-in-layouts

[^2_46]: https://stackoverflow.com/questions/37276002/how-to-smoothly-move-from-one-view-to-another-with-cytoscape-js

[^2_47]: https://npmdoc.github.io/node-npmdoc-cytoscape/build/apidoc.html

[^2_48]: https://reactflow.dev/api-reference/components/controls

[^2_49]: https://stackoverflow.com/questions/40687168/cytoscape-how-to-zoom-out-then-zoom-in-when-animating-nodes

[^2_50]: https://app.studyraid.com/en/read/11730/371547/canvas-and-viewport-fundamentals

[^2_51]: https://stackoverflow.com/questions/11316851/how-to-enable-implement-panning-in-cytoscape-js

[^2_52]: https://www.qeios.com/read/definition/77012

[^2_53]: https://arxiv.org/pdf/2312.02992.pdf

[^2_54]: https://www.w3.org/WAI/WCAG22/Techniques/css/C39

[^2_55]: https://www.w3.org/WAI/WCAG21/Understanding/animation-from-interactions

[^2_56]: https://jeikin.com/wcag/2-3-3-animation-from-interactions

[^2_57]: https://www.w3.org/WAI/WCAG22/Techniques/client-side-script/SCR40

[^2_58]: https://accessibility.build/wcag/2-3-3

[^2_59]: https://www.w3.org/WAI/WCAG22/Understanding/animation-from-interactions.html

[^2_60]: https://github.com/w3c/wcag3/issues/183

[^2_61]: https://github.com/w3c/wcag/issues/2250

[^2_62]: https://www.w3.org/TR/WCAG22/

[^2_63]: https://www.digitalpolicy.gov.hk/en/our_work/digital_government/digital_inclusion/accessibility/promulgating_resources/handbook/appendix_a/a16_233_animation_from_interactions.html

[^2_64]: https://www.cs.ubc.ca/~tmm/courses/533-09/projects/dustin/report.pdf

[^2_65]: https://silktide.com/accessibility-guide/the-wcag-standard/2-3/seizures-and-physical-reactions/2-3-3-animation-from-interactions/

[^2_66]: https://www.a11y-collective.com/blog/wcag-animation/

[^2_67]: https://github.com/w3c/wcag/issues/3766

[^2_68]: https://www.academia.edu/17955860/InfoWater_An_Interactive_Technique_to_Support_Browsing_of_Conference_Papers

[^2_69]: https://dl.acm.org/doi/pdf/10.1145/3640543.3645176

[^2_70]: https://www.mdpi.com/0718-1876/19/1/22/pdf?version=1708086409

[^2_71]: https://modelcontextprotocol.io/seps/1865-mcp-apps-interactive-user-interfaces-for-mcp

[^2_72]: https://github.com/google/A2UI/blob/main/specification/v0_8/docs/a2ui_protocol.md

[^2_73]: https://rits.shanghai.nyu.edu/ai/mcp-apps-interactive-uis-become-an-official-part-of-mcp/

[^2_74]: https://a2aprotocol.ai/blog/2026-a2ui-developer-guide

[^2_75]: https://blog.modelcontextprotocol.io/posts/2025-11-21-mcp-apps/

[^2_76]: https://blog.fka.dev/llm/2025-11-22-mcp-apps-101-bringing-interactive-uis-to-ai-conversations/

[^2_77]: https://mcp.directory/blog/mcp-apps-spec-2026-when-should-your-server-render-ui

[^2_78]: https://a2ui.org/specification/v0.9-a2ui/

[^2_79]: https://a2ui.org/guides/authoring-components/

[^2_80]: https://blog.modelcontextprotocol.io/posts/2026-01-26-mcp-apps/

[^2_81]: https://arxiv.org/html/2504.03884v1

[^2_82]: https://arxiv.org/html/2406.18031v1

[^2_83]: https://arxiv.org/pdf/2303.08340.pdf

[^2_84]: https://reactflow.dev/api-reference/types/fit-view-options

[^2_85]: https://deepwiki.com/bcakmakoglu/vue-flow/7.2-programmatic-viewport-control

[^2_86]: https://github.com/xyflow/xyflow/discussions/3228

[^2_87]: https://reactflow.dev/whats-new/2025-03-27

[^2_88]: https://vueflow.dev/typedocs/interfaces/ViewportFunctions.html

[^2_89]: https://reactflow.dev/api-reference/types/viewport

[^2_90]: https://github.com/cytoscape/cytoscape.js/issues/719

[^2_91]: https://cdnjs.com/libraries/cytoscape-panzoom

[^2_92]: https://a2ui.org/specification/v0.8-a2a-extension/

[^2_93]: https://deepwiki.com/a2ui-project/a2ui/2.3-protocol-v0.8-specification

[^2_94]: https://a2ui.org/specification/v0.9.1-a2ui-extension-specification/

[^2_95]: https://docs.ag2.ai/latest/docs/blog/2026/02/17/AG2-AG-UI-Protocol/

[^2_96]: https://www.datacamp.com/tutorial/ag-ui

[^2_97]: https://arxiv.org/pdf/2403.17918.pdf

[^2_98]: https://aclanthology.org/2023.emnlp-demo.51.pdf

[^2_99]: https://arxiv.org/html/2411.17673

[^2_100]: https://arxiv.org/html/2503.11060v1

[^2_101]: https://arxiv.org/pdf/2310.10634.pdf

[^2_102]: https://tldraw.dev/starter-kits/agent

[^2_103]: https://tldraw.dev/starter-kits/overview

[^2_104]: https://tldraw.dev/docs/ai

[^2_105]: https://deepwiki.com/tldraw/tldraw/6.1-agent-starter-kit

[^2_106]: https://github.com/tldraw/tldraw/releases

[^2_107]: https://tldraw.dev/

[^2_108]: https://github.com/tldraw/tldraw

[^2_109]: https://x.com/tldraw/status/2001769174717386880

[^2_110]: https://x.com/tldraw/status/2090514204037922890

[^2_111]: https://www.linkedin.com/posts/sergioriquelme_with-the-new-starter-kits-weve-launched-activity-7374773596067368960-omCc

[^2_112]: https://www.linkedin.com/posts/tldraw_today-were-releasing-the-tldraw-sdk-40-activity-7374503791196282880-c0cW

[^2_113]: https://reactflow.dev/api-reference/react-flow

[^2_114]: https://tldraw.dev/releases/v4.0.0

[^2_115]: https://libraries.io/hex/ash_diagram

[^2_116]: https://github.com/ash-project/ash/blob/main/README.md

[^2_117]: https://medium.com/@lambert.kamaro/2-ash-framework-for-phoenix-developers-domain-resource-0bf7eacb063a

[^2_118]: https://skillsmp.com/skills/clientt-ai-clientt-phoenix-crm-claude-skills-ash-guidelines-skill-md

[^2_119]: https://ash.hexdocs.pm/policies.html

[^2_120]: https://github.com/ash-project/ash/blob/main/documentation/dsls/DSL-Ash.Policy.Authorizer.md

[^2_121]: https://deepwiki.com/google/A2UI/5.5-protocol-specification-v0.10-(proposed)

[^2_122]: https://repo.hex.pm/preview/ash/3.24.1/lib/mix/tasks/ash.generate_resource_diagrams.ex

[^2_123]: https://a2ui.org/

[^2_124]: https://hexdocs.pm/ash/code-interfaces.html

[^2_125]: https://arxiv.org/html/2501.12326

[^2_126]: https://arxiv.org/html/2412.18426

[^2_127]: https://arxiv.org/html/2502.08047

[^2_128]: https://arxiv.org/pdf/2412.11328.pdf

[^2_129]: http://arxiv.org/pdf/2501.13145.pdf

[^2_130]: https://arxiv.org/html/2411.18279v5

[^2_131]: https://workos.com/blog/2026-01-27-mcp-apps

[^2_132]: https://docs.crewai.com/v1.15.18/en/learn/a2ui

[^2_133]: https://docs.crewai.com/v1.15.0/en/learn/a2ui

[^2_134]: https://arxiv.org/pdf/2207.10022.pdf

[^2_135]: https://journals.sagepub.com/doi/pdf/10.1177/2041669517708206

[^2_136]: https://arxiv.org/html/2408.14608

[^2_137]: https://mermaidstudio.dev/docs/configuration/security/

[^2_138]: https://nicegui.io/documentation/mermaid

[^2_139]: https://github.com/cytoscape/cytoscape.js/issues/1329

[^2_140]: https://arxiv.org/html/2411.17174

[^2_141]: https://arxiv.org/pdf/2111.13680.pdf

[^2_142]: https://arxiv.org/html/2412.13273v1

[^2_143]: https://docs.yworks.com/yfiles-html/dguide/view/view_graphcontrol.html

[^2_144]: https://docs.yworks.com/yfiles-html/api/ICommand-usages.html

[^2_145]: https://docs.yworks.com/yfiles-html/dguide/interaction-support/

[^2_146]: https://docs.yworks.com/yfilesajax/yfiles-for-java/tutorial/doc/createViewer/zooming_panning.html

[^2_147]: https://docs.yworks.com/yfilesajax/yfiles-for-java/tutorial/doc/createViewer/index.html

[^2_148]: https://docs.yworks.com/yfiles-html/api/GraphOverviewComponent.html

[^2_149]: https://docs.yworks.com/yfiles-html/api/CanvasComponent.html

[^2_150]: https://docs.yworks.com/yfiles-html/dguide/customizing_graph/index.html

[^2_151]: https://docs.yworks.com/yfiles-html/api/GraphComponent-usages.html

[^2_152]: https://docs.yworks.com/yfiles-html/sitemap.html

[^2_153]: http://docs.yworks.com/yfiles/doc/api/y/view/Graph2DViewMouseWheelZoomListener.html


---

# Great work. Expand to cover ash_bpmn and your reactor workflows. And the ability to visualize and work with both process definitions as well as active running process tokens as well consider leveraging clarity and hash diagrams are at the very least. Architecturally and update the trt technical retire requirement doc

This turns the TRD from a *spatial object model* into a full **executable-enterprise canvas**: processes, running tokens, work items, decisions, and Reactor sagas become first-class naked objects, and the token interpreter your `ash_enterprise` process layer already runs becomes the canonical execution model that the canvas, the chat, and the agent choreography all share. I inspected the `ash_enterprise` process tree — `lib/ash_enterprise/bpmn/` already carries `token.ex`, `human_task.ex`, and `process_event.ex`, `lib/ash_enterprise/process/` carries `definition_loader.ex`, `resolver.ex`, `decision_resolver.ex`, `assignment_resolver.ex`, `action_invoker.ex`, `trigger.ex` and the trigger/cursor/dispatch machinery, and the web layer already has `bpmn/viewer_live.ex`, `bpmn/catalog_live.ex`, and `bpmn/helpers.ex` — plus ADR 0004 `reactor-over-oban-pro` and ADR 0015 `approvals-stay-in-ash` in `docs/adr/`. The amendment below is written against those seams, not against a hypothetical greenfield.

# TRD Amendment 1 — Process \& Orchestration Layer (AshCanvas)

**Amends:** TRD: AshCanvas (objects, capabilities, projections, scenes)\
**Status:** Proposed\
**New namespaces:** `AshA2ui.Canvas.Process`, `AshA2ui.Canvas.Reactor`, `AshA2ui.Canvas.Trace`\
**Existing engines retained:** `ash_bpmn` token interpreter over Postgres/Oban, `ash_decisions` DMN/FEEL, Reactor, `AshDiagram`/Clarity derivations

## Decision (amended)

The canvas object graph SHALL additionally contain:

- **Process definitions** as versioned artifacts (the BPMN document compiled to an immutable graph, which `ash_bpmn` already produces).
- **Process instances** as runtime naked objects — owned, tenant-scoped, audited records, as they already are in `ash_enterprise`.
- **Tokens** as located runtime objects: each token marks a position on a specific versioned definition graph.
- **Work items / human tasks** as naked objects with claim, complete, delegate, and escalate capabilities.
- **Decisions** (DMN) as definition artifacts with evaluation history.
- **Reactor runs** as runtime naked objects whose step DAG, undo stack, and compensation states are derived from the Reactor plan.

The existing engines remain the only executors. The canvas adds **projection and participation**, never a second interpreter. `action_invoker`, `assignment_resolver`, `trigger`, and the Oban-backed token interpreter keep executing exactly as they do today; the canvas observes their events and renders them.[^3_1]

## The unifying isomorphism

This is the architectural heart of the amendment.

A BPMN token interpreter and the canvas scene model are the **same shape**: a marker with identity, state, and provenance, located at a node of a versioned graph, moving along declared edges. The token interpreter moves execution through a process definition; the scene moves a participant through the application graph; Reactor moves data through a dependency DAG. All three are "located entities on graphs."

```text
Process definition graph  ──►  token position   (ash_bpmn, Oban-driven)
Application graph         ──►  scene viewport   (user/agent-driven)
Reactor plan DAG          ──►  step execution   (saga executor)
```

One abstraction covers all three:

```elixir
%AshCanvas.Located{
  ref: ObjectRef.t(),
  graph_revision: String.t(),
  node_id: String.t(),
  state: :active | :waiting | :completed | :failed | :compensated,
  provenance: %{kind: :token | :scene | :reactor_step, actor: ...}
}
```

Consequences of committing to this isomorphism:

- One renderer, one viewport policy, and one trace-playback mechanism serve BPMN diagrams, the app graph, and Reactor DAGs.
- The `ScenePlan` choreography mechanism from the base TRD gains a formal semantics: a plan is a **scripted token walk over a graph** — exactly what a BPMN instance is.
- A running process instance can be *followed* as a live guided tour, and a completed instance can be *replayed* as one, with zero new machinery.
- The agent "movie" question dissolves: the strongest form of agent choreography is not a bespoke cue list but an ephemeral, validated process definition executed by the existing interpreter — with the base TRD's `ScenePlan` as the lightweight, non-persisted subset for conversational moments.


## Extended ontology

| Existing concept | Canvas meaning (amended) |
| :-- | :-- |
| Resource | Object type; may be a process definition, instance, work item, or decision |
| `ash_bpmn` compiled graph | Versioned definition graph — a structural subgraph |
| Process instance | Runtime naked object with lifecycle, variables, correlation id |
| Token | Located object on a definition graph revision |
| Human task / work item | Naked object with approval capabilities and candidate sets |
| DMN decision | Definition artifact plus versioned evaluation log |
| Reactor run | Runtime naked object; step DAG derived from the plan |
| Oban job | Operational object under the operational graph layer |
| Trigger | Structural edge from a world event to a process start |

Existing BPMN machinery in `ash_enterprise` already implements maker-checker by subtraction at candidate resolution, delegation, escalation timers that get cancelled, and work items as ordinary platform resources — so the *object* half of this table is largely built; the amendment is about graph integration and projection.

## Process definition projections

A definition object SHALL expose:


| Projection | Content |
| :-- | :-- |
| `:diagram` | The BPMN 2.0 diagram rendered from the compiled graph, at a pinned version |
| `:definition` | Element-level semantic description: gateways, FEEL expressions, candidate bindings, escalation timers |
| `:versions` | Baseline history, tenant forks, drift-from-baseline report |
| `:decisions` | Linked DMN documents and their versions |
| `:instances` | Bounded, authorized collection of running/finished instances |
| `:design` | The embedded designer as an `:overlay` placement — an existing capability, not a new one |

The `:diagram` projection MUST render from the compiled immutable graph, not from re-parsing the XML ad hoc, so a diagram can never disagree with what the interpreter executes. Where BPMN DI coordinates exist they are honored as layout hints; where absent, layout is derived from graph structure and cached by graph revision.

The existing `bpmn/viewer_live.ex` and `catalog_live.ex` become transport-specific projections of these objects rather than separate pages.

## Live token visualization

The definition diagram projection SHALL support a **token overlay**:

- Active tokens rendered as located markers at their current elements, colored by state.
- Token identity links to its instance object; clicking selects the instance, not just the diagram element.
- Waiting tokens (user tasks, timers) render with their blocking reason and, where authorized, the candidate set and escalation countdown.
- Sub-process or call-activity tokens link to their child definition graph; the viewport can descend into it as ordinary scene navigation.
- Movement updates arrive as notifications and MUST NOT move the viewport by themselves (base TRD `CANVAS-LIVE-002` applies unchanged).

A **trace playback** projection SHALL reconstruct any completed or in-flight instance from its event log as a scene plan: play, pause, scrub, step-through, with per-step narration derived from element names and the recorded FEEL evaluations. Because the DMN engine already records which version decided and what it saw, decision points in the trace can show the actual table row or expression that fired, which is the thing people always want and never get.

## Reactor workflows

ADR 0004 chose Reactor over Oban Pro workflows, and Reactor is a dynamic, concurrent, dependency-resolving saga orchestrator with per-step `compensate/4` and `undo/4` callbacks and an undo stack of previously succeeded steps. Ash integrates with it through `Ash.Reactor` steps whose rollback behavior is configured via `undo`/`undo_action` options — `:never`, `:outside_transaction`, or `:always`.[^3_2][^3_3][^3_4][^3_5][^3_1]

Reactor runs SHALL therefore be projected as naked objects:


| Projection | Content |
| :-- | :-- |
| `:dag` | The step graph with dependencies, sync/async, and undo capability per step |
| `:run` | Current run state: planned, running, halted, failed, undone |
| `:stack` | The undo stack — which succeeded steps would unwind, in what order |
| `:compensation` | Per-step compensation outcomes (retry / continue / ok / error) |
| `:inputs` | Run inputs, redacted per policy |

The `:dag` projection is structurally identical to the BPMN diagram projection — a versioned graph plus located markers — which is the isomorphism paying rent. A failed Reactor run rendered with its unwind path visible is the difference between "the job failed" and "the job failed *here*, unwound *these* three steps, and *this* compensation asked for a retry."

Where Reactor runs are ephemeral (in-process, not persisted), the operational layer MAY project only live in-flight runs; persistence of run history for audit is a host decision, not a canvas requirement.

## Work items as first-class citizens

The work-item inbox is not a page; it is a **lens over candidate work-item objects**, resolved through the same authorized reads the task list already uses. It SHALL appear as:

- A collection projection filtered to the actor's principal ids.
- Chat-addressable: "what's waiting on me" is a declared surface, no model call needed.
- Agent-callable through the existing `ash_ai` tool declaration pattern — a tool is a declaration that an existing action may be called, with the requesting user as actor, through the same policy checks.
- Capable of originating scene navigation: completing a work item MAY return the user to the instance diagram with the token overlay showing where the flow resumed.


## Clarity and AshDiagram integration

`AshDiagram` already derives ER, class, policy, and state-machine diagrams from resources and domains, with tests asserting the derivation stays complete rather than silently degrading — inherited platform attributes visible, grant paths in evaluation order, state transitions rendered. Clarity exposes these as dev-time surfaces.

The amendment's rule: **Clarity and AshDiagram are graph sources, not parallel systems.**

- `AshCanvas.Graph.Builder` SHALL accept AshDiagram/Clarity derivations as inputs to the structural and behavioral layers of the canonical graph.
- Clarity-style projections (ER, policy flow, state machine) become `:diagram` projections on domain, resource, and state-machine objects — available in the canvas when the audience is permitted to see them.
- The existing static Clarity routes remain for the developer boundary; the canvas versions are the same derivation with navigation attached.
- Nothing in the canvas re-implements Mermaid emission as a source of truth; Mermaid remains an export format, per the base TRD's renderer decision.

This means a person can stand on the `UserRole` resource node, see its policy graph (the union of grant paths, in evaluation order), then jump to a running approval instance that is currently blocked on that very policy — one traversal, three projections, zero duplicated diagram code.

## Scene model updates

The scene gains process-aware state and events:

```elixir
%AshCanvas.Scene{
  # ... base fields ...
  followed_instance: ObjectRef.t() | nil,
  playback: %AshCanvas.Trace.Playback{
    instance: ObjectRef.t() | nil,
    position: non_neg_integer(),
    playing?: boolean()
  } | nil
}
```

New scene events: `token_moved`, `token_waiting`, `work_item_created`, `escalation_fired`, `decision_evaluated`, `reactor_step_{succeeded,failed,undone}`. All are observations; none move the viewport. The one sanctioned camera-moving event remains a user action or an arbitrated navigation intent.

### ScenePlan ↔ BPMN mapping

| ScenePlan cue | BPMN equivalent |
| :-- | :-- |
| `:focus`, `:reveal`, `:spotlight` | (viewport policy — canvas-only concern) |
| `:trace` | token path through a definition |
| `:narrate` | text annotation / message event |
| `:open_projection` | task form |
| `:await_user` | user task |
| `:pin` | (canvas-only concern) |

Lightweight agent choreography uses `ScenePlan`; anything with escalation timers, delegation, or multi-tenant persistence uses a real process definition. The boundary is: **if it needs to survive the conversation, it is a process; if it lives only in this conversation, it is a plan.**

## DSL extension

```elixir
defmodule MyApp.Access.RequestProcess do
  use Ash.Resource,
    extensions: [AshCanvas.Resource]  # ash_bpmn config unchanged

  canvas do
    lenses [:diagram, :instances, :versions, :design]
    token_overlay [state: :color, waiting: :reason]
  end
end
```

```elixir
canvas do
  lens :inbox do
    resource MyApp.Process.WorkItem
    filter candidate: :me
    label "Waiting on you"
  end
end
```

Defaults derive everything derivable: `:diagram` from any resource exposing a BPMN graph, `:instances` from the instance resource, token overlay from token state, inbox from work-item candidacy. The DSL exists only for labels, audiences, and lens curation — the maximalist default remains "you wrote the process; the canvas knows the rest."

## Module additions

```text
AshA2ui.Canvas.Process.DefinitionGraph    # wraps ash_bpmn compiled graphs as canvas graphs
AshA2ui.Canvas.Process.TokenOverlay       # located markers over a definition graph
AshA2ui.Canvas.Process.WorkItemLens       # candidate-scoped collection lens
AshA2ui.Canvas.Reactor.RunGraph           # step DAG from a Reactor plan
AshA2ui.Canvas.Reactor.UndoProjection     # undo stack + compensation states
AshA2ui.Canvas.Trace.Playback             # instance event log -> scene plan
AshA2ui.Canvas.Diagram.Projections        # ER/policy/state-machine via AshDiagram sources
```


## Functional requirements (process layer)

| ID | Requirement |
| :-- | :-- |
| `CANVAS-PROC-001` | Project a pinned version of a BPMN definition as a navigable `:diagram` derived from the compiled graph |
| `CANVAS-PROC-002` | Render active tokens as located, state-colored markers linked to their instance objects |
| `CANVAS-PROC-003` | Render waiting tokens with blocking reason, candidate set, and escalation countdown where authorized |
| `CANVAS-PROC-004` | Descend into call activities and sub-processes as ordinary scene navigation |
| `CANVAS-PROC-005` | Reconstruct any instance from its event log as a scrubable trace playback |
| `CANVAS-PROC-006` | Show the fired DMN decision, version, and evaluated inputs at decision points in a trace |
| `CANVAS-PROC-007` | Expose work items as a candidate-scoped lens with claim/complete/delegate capabilities |
| `CANVAS-PROC-008` | Project Reactor runs as step DAGs with per-step undo capability and live execution state |
| `CANVAS-PROC-009` | Project the undo stack and compensation outcomes of a failed or unwinding Reactor run |
| `CANVAS-PROC-010` | Accept AshDiagram/Clarity derivations as graph sources for structural and behavioral layers |
| `CANVAS-PROC-011` | Expose ER, policy, and state-machine diagrams as `:diagram` projections under audience gating |
| `CANVAS-PROC-012` | Update token, work-item, and run projections from notifications without viewport movement |
| `CANVAS-PROC-013` | Map `ScenePlan` cues to process semantics and refuse cues that claim process-authority they lack |

## Security requirements (process layer)

| ID | Requirement |
| :-- | :-- |
| `CANVAS-PSEC-001` | Token overlay visibility obeys the instance's policies; a token is data, and reads are authorized reads |
| `CANVAS-PSEC-002` | Process variables in inspectors and traces are field-policy redacted per audience |
| `CANVAS-PSEC-003` | Candidate sets are exposed only to actors permitted to see them (maker-checker privacy) |
| `CANVAS-PSEC-004` | Claim, complete, delegate, and approve run exclusively through the existing actions — the canvas adds no execution path |
| `CANVAS-PSEC-005` | The designer's write path is the ordinary publish/versioning action set; the canvas never edits a compiled graph in place |
| `CANVAS-PSEC-006` | Tenant-forked definitions are visible only within their tenant's boundary |
| `CANVAS-PSEC-007` | Trace playback replays recorded events; it cannot trigger re-execution of any step |
| `CANVAS-PSEC-008` | Agent work-item tools are `ash_ai`-style declarations over existing actions, inheriting the requesting user's grants |
| `CANVAS-PSEC-009` | Escalation timer state is read-only projection; timers fire in the engine, never in the client |

## Non-requirements (process layer)

The first release SHALL NOT:

- Add a second BPMN interpreter, a second DMN engine, or a Reactor re-implementation.
- Render Oban job internals beyond a bounded operational projection.
- Support collaborative multi-user token following.
- Persist agent ScenePlans as processes automatically.
- Simulate ("dry-run") a definition against hypothetical inputs — that is publish-time analysis territory, still unbuilt upstream.
- Animate token movement as viewport camera movement.


## Acceptance oracle (amendment)

```yaml
item: A2UI-108   # process definitions as objects

criteria:
  - id: A2UI-108/AC-1
    given: >-
      a resource with a published BPMN baseline and a tenant fork on a later
      version
    when: the definition object is resolved and its :diagram projection opened
    then: >-
      the diagram renders from the compiled graph of the selected version,
      version and tenant provenance is shown, and the rendered elements match
      the interpreter's compiled graph element-for-element
    verify: integration
    risk: medium
    test: >-
      test/ash_a2ui/canvas/process/definition_projection_test.exs::diagram_is_derived_from_the_compiled_graph

  - id: A2UI-108/AC-2
    given: an actor outside the tenant of a forked definition
    when: the fork's ObjectRef is resolved
    then: resolution fails as unauthorized without leaking fork existence
    verify: security
    risk: high
    test: >-
      test/ash_a2ui/canvas/process/definition_security_test.exs::tenant_forks_are_invisible_across_tenants
```

```yaml
item: A2UI-109   # live tokens

criteria:
  - id: A2UI-109/AC-1
    given: >-
      an authorized actor viewing a definition diagram while an instance runs
      and one user-task token waits
    when: a notification reports a token transition
    then: >-
      the overlay moves the marker without changing pan, zoom, selection, or
      DOM focus, and the waiting marker shows its reason and candidate set
    verify: browser
    risk: medium
    test: >-
      test/e2e/token_overlay.spec.ts::tokens_move_without_moving_the_user

  - id: A2UI-109/AC-2
    given: an actor not permitted to read the instance
    when: the definition diagram is rendered with the overlay enabled
    then: >-
      the actor sees the definition but no tokens, counters, or waiting
      indicators attributable to that instance
    verify: security
    risk: high
    test: >-
      test/ash_a2ui/canvas/process/token_overlay_security_test.exs::tokens_obey_instance_policies

  - id: A2UI-109/AC-3
    given: a completed instance with a full event log including a gateway decision
    when: the actor opens trace playback and scrubs to the decision point
    then: >-
      playback shows the token at the gateway, the evaluated FEEL inputs, and
      which DMN version and rule produced the taken branch, and at no point
      re-executes any step
    verify: integration
    risk: high
    test: >-
      test/ash_a2ui/canvas/trace/playback_test.exs::replay_is_read_only_and_shows_decision_provenance
```

```yaml
item: A2UI-110   # reactor runs

criteria:
  - id: A2UI-110/AC-1
    given: a failed Reactor run with three succeeded undoable steps and one failed step
    when: the run object's :dag and :stack projections are resolved
    then: >-
      the DAG marks the failed step and the undo-eligible predecessors with
      their undo strategies, and the stack lists them in unwind order
    verify: integration
    risk: medium
    test: >-
      test/ash_a2ui/canvas/reactor/run_projection_test.exs::undo_stack_projects_in_unwind_order

  - id: A2UI-110/AC-2
    given: a Reactor run in flight with concurrent async steps
    when: step events arrive
    then: >-
      step states update on the DAG without layout thrash and without moving
      the viewport
    verify: browser
    risk: medium
    test: >-
      test/e2e/reactor_dag.spec.ts::step_states_update_without_layout_thrash
```

```yaml
item: A2UI-111   # work items

criteria:
  - id: A2UI-111/AC-1
    given: an actor who is a candidate for two work items across two processes
    when: the inbox lens is opened
    then: >-
      only that actor's candidate items appear, each offering claim, complete
      and delegate capabilities exactly as their policies allow
    verify: integration
    risk: medium
    test: >-
      test/ash_a2ui/canvas/process/work_item_lens_test.exs::inbox_is_candidate_scoped

  - id: A2UI-111/AC-2
    given: an actor who completes a work item from the canvas
    when: the engine resumes the instance
    then: >-
      the scene returns to the instance diagram with the token overlay showing
      the resumed position, and the completion is an ordinary audited action
      attributed to the actor
    verify: browser
    risk: high
    test: >-
      test/e2e/work_item_completion.spec.ts::completing_a_task_returns_to_the_resumed_instance
```


## Delivery plan (amended order)

The base plan holds — experience, objects, shared scene, agent guidance, choreography — with one insertion and one substitution:

- **After objects, before shared scene:** definitions and work items. They are naked objects like any other; the inbox lens and `:diagram` projection require no viewport machinery and deliver standalone value immediately.
- **After shared scene:** live token overlay and trace playback, because they consume the scene's no-camera-movement guarantees and notification pipeline.
- **Reactor projections** slot beside the token overlay — same located-marker renderer, different event vocabulary.
- **Choreography last, unchanged in position but reduced in scope:** ScenePlan ships as the conversational subset; the "process as tour" unification is a documented seam, not a first-release feature.


## Central invariant (restated, stronger)

> **There are no pages. There are authorized objects — including processes, tokens, work items, decisions, and saga runs — the capabilities they expose, the projections through which a person understands or acts on them, and the scenes that arrange those projections. Execution lives in the engines; the canvas lives in the projection.**

The process layer is where this stops being an admin UI and becomes an environment you can *stand in*: the same graph that shows you who may approve shows you the approval waiting, and the same scene that carries your conversation can carry a token's journey through a definition you can watch, replay, and — when authorized — nudge forward one human decision at a time.

<span style="display:none">[^3_10][^3_11][^3_12][^3_13][^3_14][^3_15][^3_16][^3_17][^3_6][^3_7][^3_8][^3_9]</span>

<div align="center">⁂</div>

[^3_1]: https://hexdocs.pm/reactor/ecosystem.html

[^3_2]: https://github.com/ash-project/reactor/blob/main/lib/reactor/executor.ex/

[^3_3]: https://harton.nz/blog/announcing-reactor/

[^3_4]: https://github.com/ash-project/ash/blob/main/documentation/topics/advanced/reactor.md

[^3_5]: https://deepwiki.com/ash-project/ash/12.4-reactor-integration

[^3_6]: https://hexdocs.pm/ash/multi-step-actions.html

[^3_7]: https://pmc.ncbi.nlm.nih.gov/articles/PMC10445457/

[^3_8]: https://hexdocs.pm/ash/3.26.0/multi-step-actions.html

[^3_9]: https://arxiv.org/html/2402.18687v2

[^3_10]: https://github.com/ash-project/reactor/blob/main/documentation/tutorials/getting-started-with-reactor.md/

[^3_11]: https://repo.hex.pm/preview/reactor/1.0.5/usage-rules.md

[^3_12]: https://github.com/ash-project/reactor/blob/main/documentation/explanation/ecosystem.md

[^3_13]: https://hex.pm/packages/ash/3.26.0/files/documentation/topics/advanced/reactor.md

[^3_14]: https://github.com/ash-project/ash/blob/main/documentation/dsls/DSL-Ash.Reactor.md

[^3_15]: https://ash-project.github.io/reactor/02-error-handling.html

[^3_16]: https://deepwiki.com/ash-project/reactor/4.3-error-handling-and-compensation

[^3_17]: https://github.com/ash-project/ash


---

# Great work. Expand to cover ash_bpmn and your reactor workflows. And the ability to visualize and work with both process definitions as well as active running process tokens as well consider leveraging clarity and hash diagrams are at the very least. Architecturally and update the trt technical retire requirement doc

The expanded TRD (v0.2) is ready as the attached Markdown document. The key architectural moves for the process/workflow expansion:

## What changed

**Process and workflow objects join the ontology.** `ash_bpmn`'s existing resources — definition, instance, token, human task, task candidate, process event — map directly onto canvas object kinds, which is the whole payoff of the thesis: since a process instance in your engine is already an owned, tenant-scoped, audited Ash resource, the canvas inherits authorization and live updates rather than rebuilding them. Reactor modules introspect via Spark into a step-DAG; their runs are deliberately modeled as *ephemeral telemetry projections*, not durable objects — matching your own ADR 0004, since Reactor's executor state is runtime-only and halting checkpoints rather than parks.

**Two planes, one rule.** The critical design decision is the definition plane vs. instance plane split: BPMN carries authored DI coordinates (drawn in your embedded bpmn-js designer), so the canvas honors that geometry rather than deriving layout — while ER/policy/state-machine/Reactor graphs derive layout ephemerally via AshDiagram's data layer. The instance plane is the same bpmn-js diagram with a token overlay fed by Token rows through the existing PubSub/coalescing path — the same `canvas.addMarker` pattern Camunda's Cockpit has used for a decade, except tokens come from your Postgres interpreter instead of a simulator. That also sidesteps the known token-simulation gateway bugs: you replay *actual* process events, so the taken branch is a fact.[^4_1][^4_2][^4_3][^4_4]

**Tokens are overlay, not topology.** Tokens resolve as ObjectRefs for the agent and inspector but never enter the spatial graph — that's what keeps a 10,000-instance process from becoming 10,000 canvas nodes. Reactor gets the honest treatment too: compensation traces rendered backwards along the DAG (the genuinely valuable visualization), with an explicit "live telemetry, not an audit record" label, per your "the lag is a column" principle.

**Clarity/AshDiagram stay put.** One derivation, two renderers: AshDiagram remains the engine (ideally growing a `Data.Canvas` AST module), Clarity remains the dev-time host, the canvas is the authorized runtime audience. The existing `diagrams_test.exs` pattern extends to: every published definition renderable, every reactor graphable (asserted against Reactor's own planner output), every token element resolvable to the compiled snapshot.

**Acceptance coverage.** Four new oracle files in the ai-sdlc style — A2UI-108 (process objects + authorization), A2UI-109 (live token overlay without camera theft), A2UI-110 (Reactor DAG parity + compensation trace + ephemeral honesty), A2UI-111 (start-from-diagram, snapshot-based version diffing), A2UI-112 (event-log-derived replay plans that terminate honestly on external state change) — each with immutable IDs, risk tiers, and exact test paths.

One sequencing note: I put **process objects third**, ahead of the shared scene, because "start a process from its diagram and watch the token wait at the approval task your candidate join says is yours" is the highest-signal demo the stack can produce — it exercises authorization, live data, the agent's explain-by-reading model, and the honesty constraints in a single flow.

<span style="display:none">[^4_10][^4_11][^4_12][^4_13][^4_14][^4_15][^4_5][^4_6][^4_7][^4_8][^4_9]</span>

<div align="center">⁂</div>

[^4_1]: https://camunda.com/blog/2015/08/rendering-bpmn-and-highlight-current/

[^4_2]: https://docs.openbpm.ru/openbpm/engine/user-guide/process-engine/process-diagram-api.html

[^4_3]: https://deepwiki.com/bpmn-io/bpmn-js-token-simulation

[^4_4]: https://forum.bpmn.io/t/issue-with-process-simulation-advancement-visualization/13585

[^4_5]: https://hexdocs.pm/reactor/Reactor.Mermaid.html

[^4_6]: https://hexdocs.pm/reactor/debugging-workflows.html

[^4_7]: https://preview.hex.pm/preview/reactor/show/documentation/tutorials/01-getting-started.md

[^4_8]: https://hexdocs.pm/reactor/ecosystem.html

[^4_9]: https://github.com/fireproofsocks/mermaid-demo

[^4_10]: https://github.com/ash-project/reactor/blob/main/documentation/tutorials/getting-started-with-reactor.md/

[^4_11]: https://hex.pm/packages/reactor/1.0.4/files/documentation/explanation/concepts.md

[^4_12]: https://www.elixirstreams.com/tips/elixir-1-16-improved-docs

[^4_13]: https://repo.hex.pm/preview/reactor/1.0.4/usage-rules.md

[^4_14]: https://forum.bpmn.io/t/how-to-render-draw-the-current-process-instance-data-flow/2332

[^4_15]: https://mdex.hexdocs.pm/mermaid.html

