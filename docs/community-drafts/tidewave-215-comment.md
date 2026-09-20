# DRAFT — for Luke's review before posting to tidewave-ai/tidewave_phoenix#215

**Post as:** comment on PR #215 (josevalim's Schemecto tool-definitions PoC)
**Tone rules:** no pitching tool registration (rejected in #237/#242); engage with HIS design; offer ourselves as a demanding use case + data.

---

Following this with interest — we're building Ash-centric agent tooling and want to align with whatever shape this takes rather than fight it.

Some concrete demand signals from an Ash-heavy codebase that might stress-test the schema side:

1. **Nested, type-parameterized inputs.** Ash action inputs aren't flat maps: `{:array, :map}` with per-key constraints, unions with tagged variants, `Ash.Type.CiString`/NewType wrappers. Tool schemas that only handle scalars + shallow maps would force us to degrade everything to strings, which pushes validation back into prose.
2. **Accepted vs. normalized types.** What an action accepts pre-cast (string UUID, case-insensitive atom) differs from what it normalizes to. For tool definitions we'd want the *accepted* shape in the schema and the *normalized* shape in the result payload.
3. **Results with structured errors.** Ash errors are classed trees (Forbidden/Invalid/Framework/Unknown) with per-field paths. A standard envelope for "domain error" vs "tool misuse" would save every framework from inventing one.

We've started shipping the introspection side as plain code + `usage-rules.md` per the pattern you endorsed in #237 (module functions that describe resources/actions, cast-and-validate without executing, policy explanations) — so the natural composition today is agent → `project_eval` → those functions. If Schemecto becomes the tool-definition layer, we'd want to generate those definitions from the same introspection rather than hand-maintain a parallel schema.

Happy to contribute real schema payloads from a production Ash app as test cases for the PoC if useful.
