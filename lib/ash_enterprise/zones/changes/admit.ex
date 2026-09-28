defmodule AshEnterprise.Zones.Changes.Admit do
  @moduledoc """
  The admission rule on the ingest path: refuses a write whose data may not
  enter the zone its store is declared in.

  Add it to the action that **first writes the data into the zone** — an import,
  an upload, an export landing — on a resource carrying the two tags:

      attributes do
        attribute :data_class, AshEnterprise.Zones.Types.DataClass, public?: true
        attribute :residency, :string,
          public?: true,
          constraints: [match: AshEnterprise.Zones.Residency.pattern()]
      end

      actions do
        create :ingest do
          accept [:data_class, :residency, ...]
          change {AshEnterprise.Zones.Changes.Admit, zone: "my-zone"}
        end
      end

  Leave both attributes nullable. `nil` means *untagged*, and the change refuses
  it with a reason that says so; a `NOT NULL` constraint would refuse it too, but
  with an error that does not explain the rule.

  ## Options

    * `:zone` — required. The id of the zone this store is declared in.
    * `:data_class` — the attribute holding the data class. Default `:data_class`.
    * `:residency` — the attribute holding the residency tag. Default `:residency`.

  The zone declaration is looked up when the action runs, so an unknown or
  unconfigured zone refuses the write (`AshEnterprise.Zones.Errors.UndeclaredZone`)
  rather than failing at compile time. The rule fails closed.

  On an update it checks the values the record would have afterwards, so re-tagging
  a record to something the zone cannot hold is refused as well. It reads current
  values, so it is not atomic; an update action using it needs
  `require_atomic? false`.
  """

  use Ash.Resource.Change

  alias AshEnterprise.Zones.Errors.Inadmissible

  @impl true
  def init(opts) do
    cond do
      not is_binary(opts[:zone]) ->
        {:error,
         "#{inspect(__MODULE__)} needs `zone:`, the id of the zone the store is declared in"}

      not is_atom(Keyword.get(opts, :data_class, :data_class)) or
          not is_atom(Keyword.get(opts, :residency, :residency)) ->
        {:error, "`data_class:` and `residency:` must be attribute names"}

      true ->
        {:ok, opts}
    end
  end

  @impl true
  def change(changeset, opts, _context) do
    class_attr = Keyword.get(opts, :data_class, :data_class)
    residency_attr = Keyword.get(opts, :residency, :residency)

    tags = %{
      data_class: Ash.Changeset.get_attribute(changeset, class_attr),
      residency: Ash.Changeset.get_attribute(changeset, residency_attr)
    }

    case AshEnterprise.Zones.admit(opts[:zone], tags) do
      :ok ->
        changeset

      {:error, %Inadmissible{reason: reason} = error} ->
        field = field_for(reason, class_attr, residency_attr)
        Ash.Changeset.add_error(changeset, %{error | field: field})

      {:error, error} ->
        Ash.Changeset.add_error(changeset, error)
    end
  end

  @class_reasons [:untagged_data_class, :invalid_data_class, :above_ceiling]
  @residency_reasons [
    :untagged_residency,
    :invalid_residency,
    :inadmissible_restriction,
    :restriction_unsatisfied
  ]

  defp field_for(reason, class_attr, _) when reason in @class_reasons, do: class_attr
  defp field_for(reason, _, residency_attr) when reason in @residency_reasons, do: residency_attr
  defp field_for(_reason, _, _), do: nil

  @impl true
  def atomic(_changeset, _opts, _context) do
    {:not_atomic, "zone admission reads the record's tags and the zone declaration"}
  end
end
