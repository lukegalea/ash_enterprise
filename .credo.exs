# Credo configuration.
#
# CI runs `mix credo --strict`, and it gates. A linter that is allowed to be red
# is a linter nobody reads, so anything disabled here is disabled deliberately
# and says why -- the same standard `docs/adr/` holds architectural decisions to.
%{
  configs: [
    %{
      name: "default",

      # AshCredo contributes Ash-aware checks and a run-scoped cache. It must be
      # registered rather than listed under `checks:`, or the checks run uncached
      # and without their defaults. Several of them introspect compiled modules,
      # which is why CI compiles before it lints.
      plugins: [{AshCredo, []}],
      checks: %{
        disabled: [
          # `Credo.Check.Design.AliasUsage` wants `Ash.Error.Changes.InvalidAttribute`
          # aliased to a bare `InvalidAttribute`. In an Ash codebase that makes the
          # code worse, not better: the framework namespaces several similarly-named
          # types (`Ash.Error.Changes.InvalidAttribute`,
          # `Ash.Error.Query.InvalidFilterValue`, `Ash.Error.Invalid.*`), and the
          # full path is the part that tells a reader which layer raised. The check
          # fires 46 times across this repository and every one of them is a
          # fully-qualified Ash or Elixir stdlib call in exactly the idiom the Ash
          # guides use.
          #
          # This is off for a reason rather than off for convenience. If a future
          # change makes it fire on genuinely deep *application* modules --
          # `AshEnterprise.Something.Deeply.Nested` -- reconsider it rather than
          # leaving this comment to justify a wider silence than it was written for.
          {Credo.Check.Design.AliasUsage, []}
        ]
      }
    }
  ]
}
