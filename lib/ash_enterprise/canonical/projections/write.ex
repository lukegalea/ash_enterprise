defmodule AshEnterprise.Canonical.Projections.Write do
  @moduledoc """
  The canonical write the provider projectors share: `Ash.create/2`, with a
  failure reduced to structure before it leaves the projector.

  An Ash error from a failed write quotes the value it rejected
  (`InvalidAttribute` renders `"Value: <inspect>"`), and the value is content:
  a display name, an address, a subject. A projector that let the error
  propagate (or raise) would carry plaintext, outside every erasure scope, to
  whatever logs or persists the exception — an Oban job's `errors` among them.
  So a failure becomes `{:error, {:write_failed, resource, fields}}`: the
  resource's short name and the names of the fields that failed, nothing
  else, and the projector counts it and carries on with the next record.
  """

  @type failure :: {:write_failed, String.t(), [atom()]}

  @doc "Create through `changeset` with `opts`; a failure carries field names only."
  @spec create(Ash.Changeset.t(), keyword()) :: {:ok, Ash.Resource.record()} | {:error, failure()}
  def create(%Ash.Changeset{resource: resource} = changeset, opts \\ []) do
    case Ash.create(changeset, opts) do
      {:ok, record} -> {:ok, record}
      {:error, error} -> {:error, failure(resource, error)}
    end
  end

  @doc "The structural form of `error`, a failed write on `resource`."
  @spec failure(module(), term()) :: failure()
  def failure(resource, error) do
    fields =
      error
      |> flatten()
      |> Enum.flat_map(&fields_of/1)
      |> Enum.filter(&is_atom/1)
      |> Enum.uniq()
      |> Enum.sort()

    {:write_failed, resource |> Module.split() |> List.last(), fields}
  end

  defp flatten(%{errors: errors}) when is_list(errors), do: Enum.flat_map(errors, &flatten/1)
  defp flatten(error), do: [error]

  defp fields_of(%{fields: fields}) when is_list(fields) and fields != [], do: fields
  defp fields_of(%{field: field}) when not is_nil(field), do: [field]
  defp fields_of(_error), do: []
end
