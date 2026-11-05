# Localization: translating the library's strings and the app's labels

ash_a2ui writes some text itself: button labels ("Save", "Cancel", "Next"),
pagination ("1–20 of 143"), empty states ("No Ticket records yet."), panel
titles ("Create Ticket"), feedback ("Updated successfully.") and the
TimeScrubber's text. These strings ship as a gettext catalog,
`priv/gettext/ash_a2ui.pot`, in the `ash_a2ui` domain.

The app owns its display labels: the declared ones (a field's
`label "Due date"`, a surface `title`) and the ones ash_a2ui derives from
field, action and component names (`:due_date` becomes "Due date"). They are
looked up in a second domain, `a2ui_metadata` (the `metadata_domain:`
option), and `mix ash_a2ui.gettext.extract_metadata` writes them to the
app's `priv/gettext/a2ui_metadata.pot`.

Both are translated only when the host passes a translator and a locale.

## Setting it up

- Copy the catalog into the app with `mix ash_a2ui.gen.gettext`, which
  writes `priv/gettext/ash_a2ui.pot`. With `--domain default` (or another
  domain) the entries are merged into that domain's `.pot` instead, between
  `## -- ash_a2ui-gettext:start --` markers, next to any section
  `mix ash.gen.gettext` wrote.
- Run `mix ash_a2ui.gettext.extract_metadata` for the app's labels. It
  resolves and renders every surface of the app (its resources using the
  `AshA2ui` extension and its `AshA2ui.Standalone` modules) through the
  same code as a request, with a recording translator and no records, so
  each msgid is a label a reader sees. Commit the `.pot` and add
  `--check-up-to-date` to CI; it fails when a surface changed and the
  template did not. `--output priv/gettext/<domain>.pot` writes another
  domain (pass the same `metadata_domain:`).
- Run `mix gettext.merge priv/gettext --locale fr` and fill in the
  `msgstr`s of both domains. Re-run after upgrading ash_a2ui or changing a
  surface.
- Do not add the app's labels to the `ash_a2ui` domain: they are looked up
  in the metadata domain only.

## Passing the translator

- Pass `gettext_backend: {MyAppWeb.Gettext, "ash_a2ui"}` and
  `locale: "fr"` to `AshA2ui.Info.build_surface/2`, `build_data_model/2`,
  `AshA2ui.ActionHandler.handle/3` and `AshA2ui.Diagram.refresh_messages/2`.
  Pass the same values to every call for one surface, or a refresh will
  switch language.
- `locale:` is always explicit. ash_a2ui never reads the process's
  Gettext locale (`Gettext.get_locale/1`), because builds run in async
  tasks and PubSub handlers where the ambient locale is not the reader's.
  `gettext_backend:` without `locale:` raises.
- The domain in `{backend, domain}` is the library's. Labels use
  `metadata_domain:` (default `"a2ui_metadata"`) with the same backend.
- For a translation layer that is not Gettext, pass
  `gettext_fn: {Module, :function}` instead. When `function/4` is
  exported, it is called as `Module.function(msgid, bindings, locale, meta)`
  for every message: `locale` is the `locale:` option or `nil`, and `meta`
  is a keyword list with `:domain` (`"ash_a2ui"` for library strings, the
  metadata domain for labels) and, when the message has one, `:context`
  (its `msgctxt`). Otherwise it is called as
  `Module.function(msgid, bindings)`, or with the locale as a third
  argument when `locale:` is given, and receives both domains' messages
  without telling them apart. `bindings` is a keyword list; return the
  translated, interpolated string. Return `nil` for "no translation".
- A label translated with a context (the last argument of
  `AshA2ui.Label.translate/3` and `AshA2ui.L10n.metadata/3`) is looked up
  under that `msgctxt` (`dpgettext` for a backend), and the extractor writes
  it, so a homograph translates separately. A value's label is given the
  name of what it is a value of, `"enum:" <> Atom.to_string(EnumModule)`:
  "Open" the status and "Open" the action are two entries.
- `AshA2ui.LiveRenderer`: pass `locale_fn: &(&1.assigns.locale)` and
  `gettext_backend:` (or `gettext_fn:`, and `metadata_domain:` when not the
  default) to `use AshA2ui.LiveRenderer`. They reach the build, every
  refresh and every action.
- `AshA2ui.TimeScrubber`: pass the same `locale`, `gettext_backend` or
  `gettext_fn` attributes.
- ash_a2ui does not depend on `:gettext`. The host brings it.

## What is and is not translated

- Translated: declared and derived display labels (fields, columns,
  actions, contexts, groups, steps, prompt fields), surface and record
  titles, the other declared display text (column `help_title`, `help` and
  `more_noun`, step and diagram `description`, `search_placeholder`,
  `empty_state` and `no_results_state` text, `prompt_title`, `group_labels`,
  `icon_labels`, `detail_text`, `badge_text`, primary action labels, board
  lane and swimlane headings), the labels of enum and `one_of` choices,
  canvas registry labels, and the library's chrome and feedback templates
  (the presence bar's included). All of it is host text except the chrome,
  so it is looked up in the metadata domain; an enum's labels carry the
  msgctxt `enum:<module>`.
- Never translated: ids, data-model paths, enum and option values, action
  and field names, and record data. Labels derived from records (option
  labels, context labels) are the record's own text.
- Each string is translated once, where it is chosen. A template with a
  translated label inside ("Create %{resource}") gets the translated label
  as a binding.
- A missing translation falls back to the English msgid, string by string.
- Not translated: section headings read from records, and Ash's own error
  messages (translate those with `mix ash.gen.gettext`, as the Ash docs
  describe).
- Canvas: `AshA2ui.Canvas.build_graph/2` and `AshA2ui.Canvas.resolve/2`
  take the same `gettext_backend`, `gettext_fn`, `locale` and
  `metadata_domain` options. The extractor collects every
  `AshA2ui.Canvas.Registry` module of the app.
- `AshA2ui.PresenceBar.bar/1`: pass the same `locale`, `gettext_backend` or
  `gettext_fn` attributes.

## Maintaining the catalog (library contributors)

- Wrap every new user-facing string in `AshA2ui.Gettext.msg/1` (a
  compile-time no-op the extractor looks for) and send it through
  `AshA2ui.L10n.t/3`. Use `%{name}` placeholders, never string
  interpolation, inside a msgid.
- Send every app-owned display string through `AshA2ui.Label.resolve/4`,
  `AshA2ui.Label.translate/3` or `AshA2ui.L10n.metadata/3`, never `t/3`.
  The metadata extractor then collects it with no further change.
- Run `mix ash_a2ui.gettext.extract` and commit the `.pot`. A test fails
  when it is stale.
