defmodule AshEnterprise.Quality.Changes.HashContent do
  @moduledoc """
  Records a suite's `content_hash` at publish: the SHA-256 of the RFC 8785 canonical
  JSON (`AshAgent.Digest`) of its cases, thresholds and primary metric. A suite run
  records the hash it ran, so a result names exactly the cases it measured.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    content = %{
      cases: Ash.Changeset.get_attribute(changeset, :cases),
      thresholds: Ash.Changeset.get_attribute(changeset, :thresholds),
      primary_metric: Ash.Changeset.get_attribute(changeset, :primary_metric)
    }

    Ash.Changeset.force_change_attribute(
      changeset,
      :content_hash,
      AshAgent.Digest.sha256_hex(content)
    )
  end
end
