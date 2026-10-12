defmodule AshEnterprise.Erasure.Validations.ConfirmShred do
  @moduledoc """
  A shred is irreversible, so it has to be asked for twice: `confirm` must
  equal the scope's own `ref`, and the scope must still be active.

  Typing the ref is the guard against shredding the wrong scope from a list (a
  scope id is a UUID, and two UUIDs look alike); refusing an already-shredded
  scope keeps the audit trail to exactly one shred event per scope, carrying the
  one reason that applies.
  """

  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    scope = changeset.data
    confirm = Ash.Changeset.get_argument(changeset, :confirm)

    cond do
      scope.status == :shredded ->
        {:error, field: :status, message: "this scope has already been shredded"}

      confirm != scope.ref ->
        {:error,
         field: :confirm, message: "must equal the scope's ref, to confirm which scope to shred"}

      true ->
        :ok
    end
  end
end
