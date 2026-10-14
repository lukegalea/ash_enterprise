defmodule AshEnterprise.Mdm.Changes.RecordVerdict do
  @moduledoc """
  Records who confirmed or rejected a review-banded match candidate, as a
  provenance map on the candidate itself (`human_verdict_ref`). The verdict
  is a person's act (ADR 0050 §ActorContext): the action's policy refuses
  system actors, and this change stamps the acting person onto the row so
  the merge that follows a confirm can cite its human authorisation.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    actor = changeset.context[:private][:actor]

    # Changes run at changeset build, before policies refuse system actors,
    # so the actor may be any kind — stamp an id only when there is one.
    by =
      case actor do
        %{id: id} -> to_string(id)
        _ -> nil
      end

    ref = %{
      "verdict" => to_string(changeset.action.name),
      "by" => by,
      "at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    }

    Ash.Changeset.force_change_attribute(changeset, :human_verdict_ref, ref)
  end
end
