[
  import_deps: [
    # ash_a2ui is a git dependency, so its installer never ran -- without this
    # the formatter treats its DSL as ordinary function calls and rewrites
    # `fields [:a, :b]` to `fields([:a, :b])`.
    :ash_a2ui,
    :clarity,
    :cinder,
    :ash_rate_limiter,
    :ash_ai,
    :ash_state_machine,
    :ash_events,
    :ash_oban,
    :oban,
    :ash_graphql,
    :absinthe,
    :ash_json_api,
    :ash_admin,
    :ash_authentication_phoenix,
    :ash_authentication,
    :ash_postgres,
    :ash_phoenix,
    :ash,
    :reactor,
    :ecto,
    :ecto_sql,
    :phoenix
  ],
  # The provider-operation DSL (AshEnterprise.Integration.Nango.Operations) is
  # an in-repo Spark extension with no package to import_deps from.
  locals_without_parens: [
    integration: 1,
    errors: 1,
    operation: 3,
    operation: 4,
    param: 2,
    param: 3
  ],
  subdirectories: ["priv/*/migrations"],
  plugins: [Absinthe.Formatter, Spark.Formatter, Phoenix.LiveView.HTMLFormatter],
  inputs: ["*.{heex,ex,exs}", "{config,lib,test}/**/*.{heex,ex,exs}", "priv/*/seeds.exs"]
]
