# ash_provenance usage rules

- Build every struct through its constructor (`Address.new/1`, `Step.new/1`, `Gap.new/1`, `Explanation.new/1`); each
  validates and has a raising `!` twin. Do not write `%Step{}` literals.
- Name a value with an `Address`. Name a record version with an `EntityRef`. A content digest must be keyed under the
  subject's erasure scope; a bare digest is refused.
- Give each step its relation's required fields. Leave `execution_context` nil when it was not recorded, and leave
  `integrity` nil when the step was not checked. Do not put a status there that nobody verified.
- Use `value: :masked` for a value the reader may not see. Never also supply the value.
- Where the answer stops, add a `Gap` of the right kind. An unreadable antecedent is `Gap.unreadable/1` and carries
  nothing else.
- Summaries are at most 280 bytes. Never put into a summary or label: ids or names of rows the reader cannot see,
  secrets, personal data, or the text of the value itself.
- Set `bounds` honestly: `cut?: true` whenever the walk stopped at `max_depth` or `max_steps`.
- Export with `AshProvenance.Export.ProvO.to_jsonld/1` and encode the returned map yourself.
