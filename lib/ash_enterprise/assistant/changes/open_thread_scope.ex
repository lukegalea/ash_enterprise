defmodule AshEnterprise.Assistant.Changes.OpenThreadScope do
  @moduledoc """
  Opens a new thread's own erasure scope (`data_subject`, ref
  `assistant_thread:<thread id>`) and names it on the changeset, so the
  seal that follows (`AshEnterprise.Erasure.Changes.SealUnderScope`) has a
  key to use.

  The thread's id is chosen here, before the insert, because the scope's
  ref is built from it. The scope is opened by the system actor, as the
  ingest adapters open theirs: a tenant role cannot write
  `AshEnterprise.Erasure.Scope` (operator-only), and opening one says
  nothing about content — the ref is an opaque id and the label is fixed.

  In `change/3` rather than a hook because the seal runs in `change/3` and
  Ash checks required attributes before hooks. A create that fails after
  this leaves an empty scope behind, which seals nothing.
  """

  use Ash.Resource.Change

  alias AshEnterprise.Erasure
  alias AshEnterprise.Platform.SystemActor

  @label "Assistant conversation"

  @impl true
  def change(changeset, _opts, _context) do
    id = Ash.Changeset.get_attribute(changeset, :id) || Ash.UUID.generate()

    case Erasure.ensure_scope(:data_subject, scope_ref(id), %{label: @label},
           actor: SystemActor.system()
         ) do
      {:ok, %{status: :active} = scope} ->
        changeset
        |> Ash.Changeset.force_change_attribute(:id, id)
        |> Ash.Changeset.force_change_attribute(:erasure_scope_id, scope.id)

      {:ok, _shredded} ->
        Ash.Changeset.add_error(changeset, field: :erasure_scope_id, message: "is shredded")

      {:error, error} ->
        Ash.Changeset.add_error(changeset, error)
    end
  end

  @doc "The scope ref of the thread with `id`."
  @spec scope_ref(Ash.UUID.t()) :: String.t()
  def scope_ref(id), do: "assistant_thread:#{id}"
end
