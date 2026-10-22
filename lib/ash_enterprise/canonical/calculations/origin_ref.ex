defmodule AshEnterprise.Canonical.Calculations.OriginRef do
  @moduledoc """
  The record a task came from as a typed record reference,
  `"<surface key>:<id>"` — the polymorphic `record` link target, as a human
  task's `subject_ref` is.

  The surface is the registry's for the origin's resource
  (`AshEnterprise.Surfaces.record_surface/2`), matched on the task's
  `source` as the origin's `external_system`: a commitment from a Slack
  conversation opens in Slack, one from a Gmail thread in the Inbox.

  No read: the reference names the record, and whoever follows it reads it
  under their own policies. A type the registry cannot show is no link.
  """

  use Ash.Resource.Calculation

  @impl true
  def load(_query, _opts, _context), do: [:origin_type, :origin_id, :source]

  @impl true
  def calculate(tasks, _opts, _context), do: {:ok, Enum.map(tasks, &typed_ref/1)}

  defp typed_ref(%{origin_type: "Elixir." <> _ = type, origin_id: id, source: source})
       when not is_nil(id) do
    with {:ok, resource} <- resource(type),
         %{key: key} <-
           AshEnterprise.Surfaces.record_surface(resource, %{external_system: source}) do
      "#{key}:#{id}"
    else
      _ -> nil
    end
  end

  defp typed_ref(_task), do: nil

  # Law 10: an origin type is a module this application wrote; an unknown
  # one is no link, never a new atom.
  defp resource(type) do
    module = String.to_existing_atom(type)
    if Ash.Resource.Info.resource?(module), do: {:ok, module}, else: :error
  rescue
    ArgumentError -> :error
  end
end
