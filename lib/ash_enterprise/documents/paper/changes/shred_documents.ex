defmodule AshEnterprise.Documents.Paper.Changes.ShredDocuments do
  @moduledoc """
  On `AshEnterprise.Erasure.Scope`'s `shred`, after the key is destroyed and in
  the same transaction: the issued bytes of every paper run sealed under the
  scope go too, unless another living scope still points at them.

  The key makes a run's `payload`, `facts` and `payload_hash_key` unreadable,
  but the document itself — an `AshEvidence.DocumentVersion`, the PDF that
  says all of it — is not sealed. It is content-addressed per tenant, so two
  runs that rendered identical bytes share one version row. So, per version
  the shredded scope's runs reference (`document_version_id`):

    * no run in a scope that is not shredded references it → the version is
      destroyed (`AshEvidence.Domain.destroy_document_version/2`), and the
      database cascade takes its parse runs and their atoms, the derived text;
    * a run in a living scope still references it → the bytes stay, for that
      run.

  Either way the shredded scope's runs drop their reference
  (`PaperRun.release_document_version`, machinery-only), so the count is the
  live references and the last shred of a shared version destroys it.

  Only paper runs are counted. A version some other pipeline also cites by
  content (an identical upload in the same tenant) is not known here.

  A failure fails the shred: the key, the bytes and the references go
  together or not at all, and the operator retries.

  Before counting, the shred locks the runs that reference the version
  (`FOR UPDATE`, in its own transaction), so a concurrent shred of another
  scope sharing it waits, then sees the first one's released reference and
  destroys the bytes rather than both keeping them.
  """

  use Ash.Resource.Change

  require Ash.Query

  alias AshEnterprise.Documents.PaperRun

  @impl true
  def change(changeset, _opts, _context),
    do: Ash.Changeset.after_action(changeset, fn _changeset, scope -> shred(scope) end)

  defp shred(scope) do
    runs = referencing(scope.id)

    result =
      runs
      |> Enum.uniq_by(&{&1.organization_id, &1.document_version_id})
      # One order for every shred, so two that lock the same versions cannot
      # deadlock on each other.
      |> Enum.sort_by(& &1.document_version_id)
      |> Enum.reduce_while(:ok, fn run, :ok ->
        case destroy_unless_shared(run, scope.id) do
          :ok -> {:cont, :ok}
          {:error, _} = error -> {:halt, error}
        end
      end)

    with :ok <- result,
         :ok <- release(runs) do
      {:ok, scope}
    end
  end

  # Platform tenancy is `global?`: the scope's runs are read across tenants.
  defp referencing(scope_id) do
    PaperRun
    |> Ash.Query.filter(erasure_scope_id == ^scope_id and not is_nil(document_version_id))
    |> Ash.read!(authorize?: false)
  end

  defp destroy_unless_shared(run, scope_id) do
    lock_references(run)

    if shared?(run, scope_id) do
      :ok
    else
      case AshEvidence.Domain.destroy_document_version(run.document_version_id,
             tenant: run.organization_id
           ) do
        :ok -> :ok
        {:ok, _destroyed} -> :ok
        {:error, error} -> {:error, error}
      end
    end
  end

  defp lock_references(run) do
    PaperRun
    |> Ash.Query.filter(
      organization_id == ^run.organization_id and
        document_version_id == ^run.document_version_id
    )
    |> Ash.Query.sort(:id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read!(authorize?: false)
  end

  defp shared?(run, scope_id) do
    PaperRun
    |> Ash.Query.filter(
      organization_id == ^run.organization_id and
        document_version_id == ^run.document_version_id and
        erasure_scope_id != ^scope_id and
        erasure_scope.status != :shredded
    )
    |> Ash.exists?(authorize?: false)
  end

  defp release(runs) do
    Enum.reduce_while(runs, :ok, fn run, :ok ->
      run
      |> Ash.Changeset.for_update(:release_document_version, %{}, tenant: run.organization_id)
      |> Ash.update(authorize?: false)
      |> case do
        {:ok, _released} -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end
end
