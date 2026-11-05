defmodule AshEnterprise.Execution.Changes.Activate do
  @moduledoc """
  What making a manifest the active one of its key does, for `promote` and `rollback`.

  Before the write: the entries must still hold
  (`AshEnterprise.Execution.Release.Entries.problems/2`: an approval may have waited days, and
  a rollback goes back to something that was true some time ago), and the manifest it
  replaces moves to the state named by `replaced` (`:superseded` for a promotion,
  `:rolled_back` for a rollback), as the job runner, so that no two are active at once.
  After it, in the same transaction, the process and decision entries are bound
  (`AshEnterprise.Execution.Release.Bindings`).
  """

  use Ash.Resource.Change

  alias AshEnterprise.Execution
  alias AshEnterprise.Execution.Release.{Bindings, Entries}
  alias AshEnterprise.Platform.SystemActor

  @impl true
  def change(changeset, opts, _context) do
    changeset
    |> Ash.Changeset.before_action(&replace(&1, Keyword.fetch!(opts, :replaced)))
    |> Ash.Changeset.after_action(&bind/2)
  end

  defp replace(changeset, replaced) do
    manifest = changeset.data
    tenant = changeset.tenant

    case Entries.problems(manifest.entries, tenant) do
      [] ->
        previous =
          [authorize?: false, tenant: tenant]
          |> Execution.active_release_manifests!()
          |> Enum.filter(&(&1.key == manifest.key and &1.id != manifest.id))

        for old <- previous do
          Execution.supersede_release_manifest!(old, %{to: replaced},
            actor: SystemActor.oban(),
            tenant: tenant
          )
        end

        Ash.Changeset.set_context(changeset, %{release: %{replaced: previous}})

      problems ->
        Ash.Changeset.add_error(changeset,
          field: :status,
          message: "cannot be released: " <> Enum.join(problems, "; ")
        )
    end
  end

  defp bind(changeset, manifest) do
    replaced = Enum.flat_map(changeset.context.release.replaced, & &1.entries)
    Bindings.apply!(manifest.entries, replaced, changeset.tenant)
    {:ok, manifest}
  end
end
