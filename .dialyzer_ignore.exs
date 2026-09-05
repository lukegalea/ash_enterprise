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
  # 2026-08-19. Postgrex's type-module macro, expanded into a module this
  # application owns (`AshEnterprise.PostgrexTypes` calls
  # `Postgrex.Types.define/3`), so the beam is ours while the source line is the
  # dependency's:
  #
  #   deps/postgrex/lib/postgrex/type_module.ex:1045:improper_list_constr
  #   List construction (cons) will produce an improper list, because its
  #   second argument is binary().
  #
  # Spurious, and confirmed so rather than assumed: the generated code builds an
  # iodata list, where a binary tail is correct and idiomatic -- `["a" | "b"]` is
  # valid iodata and improper only in the sense Dialyzer means. There is nothing
  # to fix in this repository; the alternative to filtering it is a permanently
  # red Dialyzer, which is what makes the other findings unreadable.
  {"deps/postgrex/lib/postgrex/type_module.ex", :improper_list_constr},

  # 2026-09-05. `AshBpmn.Web.DesignerLive.__using__/1` expands into catalogue
  # helpers whose `case` carries a `nil ->` branch for hosts that OMIT the
  # `:decisions` / `:actions` / `:decision_editor` options
  # (`deps/ash_bpmn/lib/ash_bpmn/web/designer_live.ex`, `ash_bpmn_catalogue/2`
  # and `ash_bpmn_editor_href_fn/1`). `AshEnterpriseWeb.Bpmn.DesignerLive`
  # passes all three MFAs at compile time, so in this module's expansion those
  # branches are provably dead -- but the dead branches are the dependency's
  # source, legitimately reachable for other hosts. Same beam-ours /
  # line-theirs situation as the Postgrex entry above; Dialyzer attributes the
  # warnings to the `use` line:
  #
  #   lib/ash_enterprise_web/live/bpmn/designer_live.ex:19:pattern_match
  #   The pattern can never match the type.
  #   Pattern: nil
  #   Type: {AshEnterprise.Process.DesignerCatalogue, :actions | :decisions, []}
  #   Type: {AshEnterprise.Process.DesignerCatalogue, :decision_editor_path, []}
  #
  # The fix belongs in ash_bpmn's macro (or nowhere -- the nil fallback is
  # correct general behavior), not in this wiring. Confirmed against the macro
  # source, not assumed.
  {"lib/ash_enterprise_web/live/bpmn/designer_live.ex", :pattern_match}
]
