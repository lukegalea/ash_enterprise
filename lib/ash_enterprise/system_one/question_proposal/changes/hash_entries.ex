defmodule AshEnterprise.SystemOne.QuestionProposal.Changes.HashEntries do
  @moduledoc """
  What `QuestionProposal`'s `:confirm` does to the entries it confirms:
  each one, as the person edited it or as proposed when they did not,
  runs the full decode contract again and gets its question hash
  recomputed (`QuestionProposal.Schema.hashed/1`). Confirmation is the
  moment the person's wording becomes the declaration, so it is never a
  rubber stamp: an entry that fails the contract refuses the whole
  confirmation, naming why, and the record stays `:proposed`.
  """

  use Ash.Resource.Change

  alias AshEnterprise.SystemOne.QuestionProposal.Schema

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> Ash.Changeset.get_attribute(:proposals)
    |> List.wrap()
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
      case Schema.hashed(entry) do
        {:ok, hashed} -> {:cont, {:ok, [hashed | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, reversed} ->
        Ash.Changeset.force_change_attribute(changeset, :proposals, Enum.reverse(reversed))

      {:error, reason} ->
        Ash.Changeset.add_error(changeset, field: :proposals, message: reason)
    end
  end
end
