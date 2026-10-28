# AshAgent fragments

**Not yet built.** No fragment ships in this version.

When they land, this page will list each fragment, what it declares (attributes, actions, calculations, state
machine), the columns the host adds, and an example of including it:

```elixir
use Ash.Resource,
  data_layer: AshPostgres.DataLayer,
  fragments: [...]
```

The fragments will declare no `multitenancy` block, triggers, policies, relationships to host resources, identities on
tenant columns or encryption block. The host adds those.
