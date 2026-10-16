defmodule AshEnterprise.Mdm.Calculations.Survivor do
  @moduledoc """
  Whose value of `field` (`:name` or `:email`) a confirm keeps, as the merge
  applies survivorship: the golden keeps its own value unless it has none and
  the staged row does (`"staged"`), else `"golden"`.

  The golden and the staged row are loaded as the reader
  (`AshEnterprise.Platform.Calculations.RelatedField.load_related/4`). When
  the reader may not read the golden the answer is `nil`, not a guess: an
  unreadable golden looks exactly like one with no values, and saying
  "staged" would be wrong.
  """

  use Ash.Resource.Calculation

  alias AshEnterprise.Platform.Calculations.RelatedField

  @impl true
  def init(opts) do
    if opts[:field] in [:name, :email],
      do: {:ok, opts},
      else: {:error, "field must be :name or :email"}
  end

  @impl true
  def load(_query, _opts, _context), do: [:golden_id, :staged_record_id]

  @impl true
  def calculate(records, opts, context) do
    field = opts[:field]

    with {:ok, records} <- RelatedField.load_related(records, :golden, [field], context),
         {:ok, records} <- RelatedField.load_related(records, :staged_record, [:mapped], context) do
      {:ok, Enum.map(records, &survivor(&1, field))}
    end
  end

  defp survivor(%{golden: %{} = golden} = record, field)
       when not is_struct(golden, Ash.NotLoaded) do
    case {Map.get(golden, field), staged(record, field)} do
      {nil, staged} when not is_nil(staged) -> "staged"
      _golden_keeps -> "golden"
    end
  end

  defp survivor(_unreadable_golden, _field), do: nil

  defp staged(%{staged_record: %{mapped: %{} = mapped}}, field),
    do: Map.get(mapped, Atom.to_string(field))

  defp staged(_record, _field), do: nil
end
