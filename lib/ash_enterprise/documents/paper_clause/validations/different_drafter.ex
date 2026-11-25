defmodule AshEnterprise.Documents.PaperClause.Validations.DifferentDrafter do
  @moduledoc """
  Maker-checker: the person who drafted a clause may not admit it. A second
  pair of eyes reads the wording before any binding can pin it, so the refuse
  lives on the `admit` action — a validation of who is acting, not a
  `forbid_if` on rows.

  Attribution is the row's own provenance: `created_by_id` was stamped from the
  creating actor, and the acting id is extracted the same way
  `AshEnterprise.Platform.Changes.StampProvenance` extracts it. A system actor
  has no id, so a system-drafted clause (created_by_id null) cannot be admitted
  by a system actor either: two nulls are not two people.
  """

  use Ash.Resource.Validation

  alias AshEnterprise.Platform.SystemActor

  @impl true
  def validate(changeset, _opts, context) do
    if actor_id(context.actor) == changeset.data.created_by_id do
      {:error,
       field: :status, message: "the person who drafted a clause may not admit it (maker-checker)"}
    else
      :ok
    end
  end

  defp actor_id(%SystemActor{}), do: nil
  defp actor_id(%{id: id}), do: id
  defp actor_id(_), do: nil
end
