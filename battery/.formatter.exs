[
  # The battery is its own mix project, so the root .formatter.exs never sees
  # it. These are the deps whose DSLs it writes and that export their
  # formatter rules; without them `fields [:a]` would become `fields([:a])`.
  import_deps: [:ash, :ash_postgres, :ash_events, :ash_ai, :ecto, :ecto_sql, :reactor],
  # priv/repo/migrations is left out on purpose: most of it is ported
  # verbatim from the substrates' own suites (see README.md, "Layout"), and
  # reformatting it would make the next re-port a noisy diff.
  # Section order and paren removal come from `config :spark, formatter:` in
  # config/config.exs, copied from the root config so both formatters agree.
  plugins: [Spark.Formatter],
  inputs: ["*.exs", "{config,lib,test}/**/*.{ex,exs}"]
]
