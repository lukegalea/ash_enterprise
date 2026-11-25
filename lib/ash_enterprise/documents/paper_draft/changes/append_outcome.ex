defmodule AshEnterprise.Documents.PaperDraft.Changes.AppendOutcome do
  @moduledoc """
  Appends one `issue_draft` outcome to the draft's `issue_outcomes`, oldest first.

  The outcome arrives as `record_issue_outcome`'s `outcome` argument, or in the
  `context:` option of the write it describes (`%{paper: %{issue_outcome: map}}`
  on `apply` or `mark_stale`), so an issue and its record, or a staleness mark and
  its record, are one write. An update with neither is untouched. The draft's
  optimistic lock orders concurrent appends: one written from a stale copy fails
  rather than dropping the other.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    case outcome(changeset) do
      %{} = outcome ->
        existing = changeset.data.issue_outcomes || []
        Ash.Changeset.force_change_attribute(changeset, :issue_outcomes, existing ++ [outcome])

      nil ->
        changeset
    end
  end

  @impl true
  def atomic(changeset, _opts, _context) do
    case outcome(changeset) do
      nil -> {:atomic, %{}}
      _outcome -> {:not_atomic, "appends to the stored list"}
    end
  end

  defp outcome(changeset) do
    get_in(changeset.context, [:paper, :issue_outcome]) ||
      Ash.Changeset.get_argument(changeset, :outcome)
  end
end
