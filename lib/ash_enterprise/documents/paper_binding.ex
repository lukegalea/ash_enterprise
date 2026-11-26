defmodule AshEnterprise.Documents.PaperBinding do
  @moduledoc """
  What a document kind is rendered with (ADR 0062's binding, on the paper
  kernel's vocabulary): `AshPlanning.Fragment.Binding` on the platform base,
  in table `paper_bindings`, one temporal row per (organization, kind).

  The selector is the canonical-JSON string built from
  `(model_key: document_kind, purpose: "paper.render")`, so the host's only
  purpose for a binding is `AshEnterprise.Documents.Paper.binding_purpose/0`
  and a kind is bound by its string, never re-derived. `selection` pins every
  definition the binding resolves to — schema, layout, theme — exactly in the
  shape `AshPaper.Binding.selection/4` returns, and `backend_profile_hash`
  pins what engine and fonts it was reviewed against
  (`AshPaper.Binding.backend_profile_hash/1`).

  Temporal (ADR 0049): re-binding closes the version valid until `as_of` and
  opens a new one, so "what a tenant's kind of document was bound to on any date"
  is one read as of that date. A run that already rendered never reads this
  live: it pins the binding's hashes into its own snapshot at issue time and
  carries `paper_binding_id`, and a replay reads the pinned snapshot.

  Organization-owned configuration: it carries no owner, and reading or
  writing it takes a role grant. Rows are never soft-deleted
  (`archival?: false`); `unbind` closes the period.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Documents,
    ownership: :organization_owned,
    lifecycle?: false,
    archival?: false,
    fragments: [AshPlanning.Fragment.Binding]

  postgres do
    table "paper_bindings"
    repo AshEnterprise.Repo
  end
end
