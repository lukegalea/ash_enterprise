### The ask

Code interfaces generate functions (`create_user/2`, `get_user!/2`, …) whose
input contracts Ash knows completely at compile time — but the generated
functions carry no type specs, so dialyzer sees `any()` and none of it checks.

Would you be open to Ash generating `@spec`s (and the input `@type`s they
need) for code interface functions, behind an opt-in compile-time flag?

### Working prototype

We've been running a fork that does this
([`feature/generated-action-specs`](https://github.com/lukegalea/ash/tree/feature/generated-action-specs)):

```elixir
@type submit_input :: %{
  required(:justification) => String.t(),
  optional(:requested_role_tier) => :standard | :elevated | :privileged,
  required(:requested_role_id) => String.t()
}
@spec submit!(submit_input() | [submit_input()] | keyword() | keyword() | nil,
             keyword() | nil) :: Ash.Resource.Record.t() | Ash.BulkResult.t()
```

We generate specs for create/update/destroy inputs (closed maps from accepted
attributes + belongs_to FK inputs), positional-arg variants, and `can_*`
helpers. Fork suite green (4200+ tests) with a dialyzer conformance suite
fixture repo asserting: valid calls typecheck, missing keys and typo'd keys
flagged, no false positives.

### Why we built it

It fell out of [ash_agent_tools](https://github.com/lukegalea/ash_agent_tools)
— a read-only introspection plane for coding agents (describe/validate/
context + an MCP daemon), now public. The tooling answers "what does this
action accept" from the resource layer; generating the same contracts as
dialyzer-visible specs was the static half of the same idea. Dogfooding the
fork across a real app found real edges — most notably that the first cut
omitted `belongs_to` FK inputs from the generated maps (fixed in the fork),
and it's what surfaced the `get_by` casting regression tests in #2955.

### Notes for an upstream version

- Flag placement: we use a compile-time `generate_interface_specs` config,
  read at macro expansion — needs a decision on where that lives upstream
- The FK-input case (accepted relationship keys in the input map) needs the
  generator to synthesize the FK attribute the transformer creates later
- Happy to split out whatever subset is uncontroversial, or to rework the
  fork's generator against whatever API shape you'd prefer
