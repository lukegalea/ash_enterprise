# Dialyzer warning filters.
#
# Seeded EMPIRICALLY, not aspirationally. There is no official guidance for
# running Dialyzer against Ash or Spark, no canonical ignore file published
# upstream, and Spark builds resources through heavy macro expansion -- which
# Dialyzer is well known to produce spurious warnings on.
#
# Because of that, `mix dialyzer` runs NON-BLOCKING in CI. The real quality
# gates are `mix compile --warnings-as-errors`, Credo with ash_credo, and
# Elixir's built-in set-theoretic type checker.
#
# Rules for this file:
#   - Add an entry only after seeing the warning and confirming it is spurious.
#   - Comment WHY, with the date. An unexplained filter is a hidden bug.
#   - `list_unused_filters: true` is set in mix.exs, so stale entries here are
#     reported. Remove them when they stop matching.
#
# Entry forms:
#   {"lib/path/to/file.ex"}                      # whole file
#   {"lib/path/to/file.ex", :warning_type}       # one warning type in a file
#   {"lib/path/to/file.ex", :warning_type, 42}   # one warning, one line
#   ~r/regex against the formatted warning/

[
  # Empty on purpose. Populate from real `mix dialyzer` output rather than
  # pre-emptively silencing categories.
]
