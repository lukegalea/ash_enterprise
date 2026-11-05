defmodule AshEnterprise.Execution.Release.Requests do
  @moduledoc """
  A manifest draft's `requests`: each names a `kind` this build knows
  (`AshEnterprise.Execution.Release.Entries.kinds/0`) and a `key`, and none is named twice.

  As a validation it checks them; `normalise/1` gives them string keys, which is how they
  read back from the database, so a draft just created and one loaded are read the same.
  """

  use Ash.Resource.Validation

  alias AshEnterprise.Execution.Release.Entries

  @doc "`requests` with string keys."
  @spec normalise([map()]) :: [%{String.t() => term()}]
  def normalise(requests),
    do:
      Enum.map(requests || [], fn request ->
        Map.new(request, fn {k, v} -> {to_string(k), v} end)
      end)

  @impl true
  def validate(changeset, _opts, _context) do
    requests = normalise(Ash.Changeset.get_attribute(changeset, :requests))
    kinds = Enum.map(Entries.kinds(), &Atom.to_string/1)

    cond do
      requests == [] ->
        {:error, field: :requests, message: "must name at least one thing to release"}

      bad = Enum.find(requests, &(not valid?(&1, kinds))) ->
        {:error,
         field: :requests,
         message: "#{inspect(bad)} needs a kind (#{Enum.join(kinds, ", ")}) and a key"}

      length(Enum.uniq_by(requests, &{&1["kind"], &1["key"]})) < length(requests) ->
        {:error, field: :requests, message: "names the same thing twice"}

      true ->
        :ok
    end
  end

  defp valid?(%{"kind" => kind, "key" => key}, kinds),
    do: kind in kinds and is_binary(key) and key != ""

  defp valid?(_request, _kinds), do: false
end
