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
  surface's resource and every context resource. Keep it to resources an
  operator may reasonably see end-to-end.
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
- ❌ `nested_form` in specs — not composable dynamically (needs
  `manage_relationship` knowledge); declare such surfaces in the DSL.
