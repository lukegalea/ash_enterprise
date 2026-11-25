defmodule AshEnterprise.Documents.PaperClause.Changes.HashRuns do
  @moduledoc """
  Computes `content_hash` from the drafted runs: `AshPaper.Clause.hash/1` of
  the same wording `to_kernel/1` hands the kernel. Never an accepted input —
  the hash is a consequence of the wording, so what a binding pins and what a
  run records cannot drift from what was drafted.
  """

  use Ash.Resource.Change

  alias AshEnterprise.Documents.PaperClause

  @impl true
  def temporal_safe?(_opts), do: true

  @impl true
  # Malformed runs were refused by `WellFormedRuns`; there is no wording to hash.
  def change(%Ash.Changeset{valid?: false} = changeset, _opts, _context), do: changeset

  def change(changeset, _opts, _context) do
    # The hash covers the wording alone (`AshPaper.Clause.hash/1`): a draft's
    # version, assigned as it is written, does not enter it, so a draft not
    # numbered yet hashes as its first version would.
    kernel =
      struct(PaperClause, %{
        key: Ash.Changeset.get_attribute(changeset, :key),
        locale: Ash.Changeset.get_attribute(changeset, :locale),
        version: Ash.Changeset.get_attribute(changeset, :version) || 1,
        runs: Ash.Changeset.get_attribute(changeset, :runs)
      })
      |> PaperClause.to_kernel()

    # `writable? false` is the contract with callers; the change itself writes
    # the derived value the same way `Admit` writes `admitted_by_id`.
    Ash.Changeset.force_change_attribute(changeset, :content_hash, AshPaper.Clause.hash(kernel))
  end
end
