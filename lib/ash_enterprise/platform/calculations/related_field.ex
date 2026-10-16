defmodule AshEnterprise.Platform.Calculations.RelatedField do
  @moduledoc """
  A field of a related record, read **as the reader, under their policies**.

      calculate :golden_name, :string,
        {RelatedField, relationship: :golden, field: :name}

      # a key (or the first present of several keys) of a related map field
      calculate :staged_label, :string,
        {RelatedField, relationship: :staged_record, field: :mapped, keys: ["name", "email"]}

  ## Why the load is explicit

  Two shorter ways both leak, and both were tried:

    * `expr(golden.name)` compiles to a join, and the join does not apply the
      related resource's read policies;
    * a module calculation whose `load/3` names the relationship has Ash
      load it as a calculation *dependency*, which Ash does without
      authorization.

  Either way a reader who may not read an owner-only Person saw its name.
  So `calculate/3` loads the relationship itself with `Ash.load/3`, passing
  the calculation's actor, tenant and `authorize?`: an authorized read, so a
  related record the reader may not read is simply absent and the value is
  `nil`. That is one read per batch of records, in the calculation, never in
  a policy check.

  Options: `:relationship` and `:field` (required), `:keys` (for a map
  field: the keys to try, in order), `:default` (the value when nothing is
  readable; `nil` unless given). Values are returned as strings.
  """

  use Ash.Resource.Calculation

  @impl true
  def init(opts) do
    if is_atom(opts[:relationship]) and not is_nil(opts[:relationship]) and
         is_atom(opts[:field]) and not is_nil(opts[:field]),
       do: {:ok, opts},
       else: {:error, "relationship and field are required"}
  end

  # Only the foreign key: the related record is loaded in `calculate/3`, as
  # the reader.
  @impl true
  def load(query, opts, _context), do: source_attribute(query.resource, opts[:relationship])

  @impl true
  def calculate(records, opts, context) do
    with {:ok, loaded} <- load_related(records, opts[:relationship], [opts[:field]], context) do
      {:ok, Enum.map(loaded, &value(&1, opts))}
    end
  end

  @doc """
  Loads `relationship` (with `fields`) onto `records` as the calculation
  context's actor — the authorized read every caller of this module relies on.
  """
  @spec load_related([struct()], atom(), [atom()], map()) :: {:ok, [struct()]} | {:error, term()}
  def load_related([], _relationship, _fields, _context), do: {:ok, []}

  def load_related(records, relationship, fields, context) do
    Ash.load(records, [{relationship, fields}],
      actor: Map.get(context, :actor),
      tenant: Map.get(context, :tenant),
      authorize?: Map.get(context, :authorize?) != false,
      lazy?: false
    )
  end

  @doc "The source attribute `relationship` needs on the record, as a `load/3` list."
  @spec source_attribute(module(), atom()) :: [atom()]
  def source_attribute(resource, relationship) do
    case Ash.Resource.Info.relationship(resource, relationship) do
      %{source_attribute: attribute} -> [attribute]
      nil -> []
    end
  end

  defp value(record, opts) do
    case Map.get(record, opts[:relationship]) do
      %{} = related when not is_struct(related, Ash.NotLoaded) ->
        related |> Map.get(opts[:field]) |> pick(opts[:keys]) |> present(opts[:default])

      _absent_or_unreadable ->
        opts[:default]
    end
  end

  defp pick(%{} = map, [_ | _] = keys), do: Enum.find_value(keys, &present(Map.get(map, &1), nil))
  defp pick(_value, [_ | _]), do: nil
  defp pick(value, _no_keys), do: value

  defp present(nil, default), do: default
  defp present("", default), do: default
  defp present(value, _default), do: to_string(value)
end
