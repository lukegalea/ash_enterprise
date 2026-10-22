defmodule AshEnterprise.Canonical.Changes.ProposalTitle do
  @moduledoc """
  A proposal's plain `title`: a structural stand-in naming where it came
  from (`Proposed from gmail`), never its words — those are sealed in
  `commitment` under the source's erasure scope, and a plain copy would
  outlive a shred in the row and in its audit event (ADR 0024).
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    source = Ash.Changeset.get_attribute(changeset, :source) || "a source"
    Ash.Changeset.force_change_attribute(changeset, :title, "Proposed from #{source}")
  end
end
