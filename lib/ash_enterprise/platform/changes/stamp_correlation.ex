defmodule AshEnterprise.Platform.Changes.StampCorrelation do
  @moduledoc """
  Puts the request's correlation id into the changeset context, where AshEvents
  picks it up as audit metadata.

  Applied by `AshEnterprise.Platform.Resource` to every audited resource, so the
  correlation is a property of being a platform resource rather than something
  each action remembers. See `AshEnterprise.Platform.Correlation` for why the
  grouping matters.

  Existing `ash_events_metadata` is merged rather than replaced: an action that
  attaches its own context keeps it, and gains the correlation alongside.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, context) do
    existing =
      changeset.context
      |> Map.get(:ash_events_metadata, %{})
      |> normalize()

    metadata =
      Map.merge(AshEnterprise.Platform.Correlation.audit_metadata(context.actor), existing)

    Ash.Changeset.set_context(changeset, %{ash_events_metadata: metadata})
  end

  defp normalize(map) when is_map(map), do: map
  defp normalize(_), do: %{}
end
