defmodule AshEnterprise.Credentialing.Changes.OpenClinicianScope do
  @moduledoc """
  Gives a clinician their own erasure scope (`data_subject`, ref `clinician:<id>`, an
  opaque id) when they have none, so that what the application copies about them can be
  sealed under it: an agent run about the clinician, its journal and its tool calls
  (`AshEnterprise.Execution.Changes.SealingScope`). Shredding the scope erases those
  copies; the clinic's own record of the clinician stays (ADR 0024).

  On `register` the clinician's id is chosen here, before the insert, because the scope's
  ref is built from it. The scope is opened by the system actor, as the other scope
  openers do (`AshEnterprise.Assistant.Changes.OpenThreadScope`): a tenant role cannot
  write `AshEnterprise.Erasure.Scope`, and opening one says nothing about content.
  A shredded scope is never reopened.
  """

  use Ash.Resource.Change

  alias AshEnterprise.Erasure
  alias AshEnterprise.Platform.SystemActor

  @label "Clinician"

  @impl true
  def change(changeset, _opts, _context) do
    if Ash.Changeset.get_attribute(changeset, :erasure_scope_id) do
      changeset
    else
      id = Ash.Changeset.get_attribute(changeset, :id) || Ash.UUID.generate()

      case Erasure.ensure_scope(:data_subject, scope_ref(id), %{label: @label},
             actor: SystemActor.system()
           ) do
        {:ok, %{status: :active} = scope} ->
          changeset
          |> with_id(id)
          |> Ash.Changeset.force_change_attribute(:erasure_scope_id, scope.id)

        {:ok, _shredded} ->
          Ash.Changeset.add_error(changeset, field: :erasure_scope_id, message: "is shredded")

        {:error, error} ->
          Ash.Changeset.add_error(changeset, error)
      end
    end
  end

  defp with_id(%{action_type: :create} = changeset, id),
    do: Ash.Changeset.force_change_attribute(changeset, :id, id)

  defp with_id(changeset, _id), do: changeset

  @doc "The scope ref of the clinician with `id`."
  @spec scope_ref(Ash.UUID.t()) :: String.t()
  def scope_ref(id), do: "clinician:#{id}"
end
