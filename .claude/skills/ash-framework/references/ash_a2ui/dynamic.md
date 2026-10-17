# Rules for agent-composed surfaces

`AshA2ui.Dynamic` builds surfaces from a runtime, JSON-serializable **spec**
(typically LLM tool output) with the same rigor as the compile-time DSL: the
spec mirrors the DSL vocabulary, references everything by name, and the
server resolves/validates/encodes. The spec is **never raw A2UI JSON**.

## Resolving

```elixir
allowlist = AshA2ui.Dynamic.allowlist([MyApp.Feedback, MyApp.Accounts.User])
# or: AshA2ui.Dynamic.extension_resources(:my_app) |> AshA2ui.Dynamic.allowlist()

case AshA2ui.Dynamic.resolve(spec, allowlist: allowlist) do
  {:ok, surface} -> surface                            # %AshA2ui.Dynamic.Surface{}
  {:error, errors} -> AshA2ui.Dynamic.Error.messages(errors)  # feed back to the LLM
end
```

- **The allowlist is host configuration, not client input.** It gates the
  surface's resource, every context resource, every related table's
  `resource` and every `sections` source. Keep it to resources an operator
  may reasonably see end-to-end.
- Other `resolve/2` options: `:surface_id`, `:spec_version` (`"0.9.1"` or
  `"1.0"`), and `:via_allowlist` — the modules a spec's `via`-delegated row
  actions may dispatch to. It defaults to none, so a spec carrying `via` is
  rejected unless the host passes it; like `:allowlist`, it is host
  configuration.
- The spec vocabulary covers components, fields, queries (presets, range
  filters), `row_layout` (with `badge_text` and `badge_tones`), form
  `groups` and `nested_forms`, sectioned tables (`sections`), `action`
  metadata (`label`, `refreshes`, `prompt_fields`, `visible_when`, `via`), contexts
  (`contexts`, plus `select_context` / `context_filter` /
  `require_context` on tables and `detail` components), related tables
  (`"resource": "<allowlisted name>"` on a table) and reference links on
  fields (`"link": "<relationship>"` or `{"surface": "<key>", "path":
  ["<attr>"]}`, `"links"`, `"link_label"`). It has no vocabulary for
  inline editing, file export, wizard steps, bulk actions or boards.
- Link surface keys stay strings (never atoms); names in specs become
  atoms only after the identifier-format and size checks, and resources
  only ever come from the allowlist.
- Validation runs the **same verifier modules** the DSL compiles with, over
  a synthetic DSL state — same checks, same messages. Every verifier runs,
  so the error list covers multiple mistakes at once.
- Errors are structured (`path` + `message`, Jason-encodable). Return
  `AshA2ui.Dynamic.Error.messages(errors)` as the tool error result so the
  agent can self-correct.

## LLM integration

- Hand `AshA2ui.Dynamic.spec_schema(allowlist)` to the LLM as the tool
  parameter schema — it constrains resource names to the allowlist and
  documents every knob.
- Embed `AshA2ui.Dynamic.describe_resources(allowlist)` (fields, enum
  values, actions, relationships) in the tool description or system prompt;
  an LLM cannot compose against fields it cannot see.
- Prefer curated/declared surfaces when one fits; compose dynamically only
  when none does.

## Serving (the tamper-proofing contract)

- **Resolve once, server-side; keep the `%Surface{}` in server state**
  (LiveView assign, ETS, cache) keyed by `surface.surface_id`.
- Route client `action` envelopes through
  `AshA2ui.Dynamic.handle_action(server_held_surface, envelope, actor: actor)`.
  Never rebuild a surface from anything the client echoes back.
- Drop the stored struct when the surface is dismissed.
- `build_surface/2` / `build_data_model/2` / `handle_action/3` take the
  standard `:actor` / `:tenant` / `:authorize?` options; authorization is
  actor-based with `authorize?: true` by default, exactly as on declared
  surfaces.

## The spec lifecycle (persist / diff / promote)

- Persist specs with `AshA2ui.Dynamic.serialize(spec_or_surface)` — the
  canonical versioned envelope (sorted keys, `spec_format` field). Never
  store ad-hoc JSON encodings; canonical form is what makes fingerprints
  and diffs stable. `AshA2ui.Dynamic.fingerprint/1` is the content identity.
- Load stored specs with `AshA2ui.Dynamic.deserialize(serialized, allowlist: ...)`
  — it re-validates against the **current** resource state through
  `resolve/2`. Treat errors as reviewable drift (show them to the admin),
  not as exceptions. Re-validate on every open, not only on save.
- Before a human approves a new or updated spec, show
  `AshA2ui.Dynamic.diff(stored, proposed) |> AshA2ui.Dynamic.Diff.summary()`
  — entity-level change lines, not a raw JSON diff.
- Promote long-lived specs to checked-in code with
  `AshA2ui.Dynamic.to_dsl_source(spec, module: MyApp.UI.FooUI, allowlist: ...)`;
  commit the generated module and drop (or archive) the stored spec so
  there is one source of truth.

## Importing declared surfaces and the composer

- `AshA2ui.Dynamic.Importer.import/1` turns a declared surface (a resource or
  `AshA2ui.Standalone` module) into the equivalent spec. It returns
  `{:ok, spec, rejections}`: every declared feature the spec cannot carry
  (inline editing, export, wizard steps, bulk actions, boards,
  `surface_id`, `record_label`, `spec_version`) is a visible rejection with
  a reason, never a silent drop. Contexts, related tables and links import
  as spec vocabulary. Show the rejections to whoever edits the spec.
- `AshA2ui.Web.ComposerLive` (`use AshA2ui.Web.ComposerLive, surfaces: [...]`)
  is the self-hosted editor over that pipeline: import, edit, resolve on
  every change, export as a standalone module. Mount it behind the same
  authentication as any admin tool; its `:allowlist` follows the rules
  above. Its derived allowlist holds only the listed surfaces' own
  resources: pass context destinations and related-table resources as
  `:allowlist` extras, or their imports do not resolve.

## Avoid list

- ❌ Constructing `%AshA2ui.Dynamic.Surface{}` by hand — only
  `AshA2ui.Dynamic.resolve/2` may build one.
- ❌ Resolving specs received from the browser/client — specs come from the
  server-side agent loop only.
- ❌ Letting the LLM emit A2UI messages, component trees, or data-model
  paths directly.
- ❌ Widening the allowlist to "all resources" without considering policies —
  a dynamic surface on a policy-less resource is not access control.
- ❌ Using dynamic specs for surfaces a human authors — write the DSL and
  get compile-time diagnostics instead.
- ❌ `via` in specs without the host's `:via_allowlist` — delegates run host
  code, so the callable modules are resolve-time host configuration (the
  parser still rejects modules/functions that do not exist).
