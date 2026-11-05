defmodule AshEnterprise.Execution.Changes.ResolveEntries do
  @moduledoc """
  A manifest's `resolve`: pins each request to the entry it resolves to now
  (`AshEnterprise.Execution.Release.Entries.resolve/3`) and records `manifest_digest`, the
  SHA-256 of the RFC 8785 canonical JSON (`AshAgent.Digest`) of the entries ordered by kind
  and name. A request that cannot be resolved fails the whole resolve, naming each, so a
  manifest never holds a partial release.
  """

  use Ash.Resource.Change

  alias AshEnterprise.Execution.Release.{Entries, Requests}

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, &resolve/1)
  end

  defp resolve(changeset) do
    tenant = changeset.tenant

    results =
      for %{"kind" => kind, "key" => key} <- Requests.normalise(changeset.data.requests) do
        Entries.resolve(String.to_existing_atom(kind), key, tenant)
      end

    case for({:error, message} <- results, do: message) do
      [] ->
        entries = for {:ok, entry} <- results, do: entry
        entries = Enum.sort_by(entries, &{&1["annotations"]["kind"], &1["name"]})

        Ash.Changeset.force_change_attributes(changeset, %{
          entries: entries,
          manifest_digest: AshAgent.Digest.sha256_hex(entries)
        })

      problems ->
        Ash.Changeset.add_error(changeset,
          field: :requests,
          message: "cannot be resolved: " <> Enum.join(problems, "; ")
        )
    end
  end
end
