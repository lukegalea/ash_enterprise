defmodule AshEnterprise.Zones.Zone do
  @moduledoc """
  A zone declaration: the record [ADR 0042](../../../docs/adr/0042-in-zone-inference-leaving-the-zone-is-a-disclosure.md)
  calls `Zone`, parsed from data.

  A declaration is **data, not code**. It lives in a JSON file (see
  `AshEnterprise.Zones` for where those files are found), so declaring a zone,
  narrowing one or letting one lapse is an edit to a record someone signs, not a
  code change. This module only parses and validates that record; it knows no
  particular zone. An example lives in `priv/zones/examples/`.

  | Field | Meaning |
  |---|---|
  | `id` | stable slug the ingest path names the zone by |
  | `jurisdiction` | ISO 3166 code of where the zone physically is (`"CA-ON"`) |
  | `classification_ceiling` | the most sensitive `AshEnterprise.Zones.Types.DataClass` it may hold |
  | `inadmissible_restrictions` | residency restrictions it declares it cannot hold (`["US"]`) |
  | `declared_by`, `declared_at` | who authorised the declaration, and when |
  | `review_by` | the date it lapses; after it, nothing is admitted until it is renewed |
  | `basis` | why the declarer has the authority to declare it, in prose |
  | `members`, `stores` | the hosts and stores the declaration covers |
  | `controls` | the controls it relies on, each `in_place` with evidence or a named `gap` |

  A declaration is an operator's authority for the deployment it covers. It is
  not a statement about what any customer agreement permits.
  """

  alias AshEnterprise.Zones.Jurisdiction
  alias AshEnterprise.Zones.Types.DataClass

  @enforce_keys [
    :id,
    :jurisdiction,
    :classification_ceiling,
    :declared_by,
    :declared_at,
    :review_by
  ]
  defstruct [
    :id,
    :jurisdiction,
    :classification_ceiling,
    :declared_by,
    :declared_at,
    :review_by,
    :basis,
    inadmissible_restrictions: [],
    members: [],
    stores: [],
    controls: []
  ]

  @type control :: %{name: String.t(), status: :in_place | :gap, evidence: String.t() | nil}

  @type t :: %__MODULE__{
          id: String.t(),
          jurisdiction: String.t(),
          classification_ceiling: DataClass.t(),
          inadmissible_restrictions: [String.t()],
          declared_by: String.t(),
          declared_at: Date.t(),
          review_by: Date.t(),
          basis: String.t() | nil,
          members: [String.t()],
          stores: [String.t()],
          controls: [control()]
        }

  @id_pattern ~r/\A[a-z0-9][a-z0-9_-]{0,62}\z/

  @doc """
  Builds a zone from a decoded declaration (string keys, as JSON gives them).

  Returns `{:ok, zone}` or `{:error, problems}`, where `problems` lists every
  field that is wrong rather than only the first, so a declaration can be fixed
  in one pass.
  """
  @spec from_map(map()) :: {:ok, t()} | {:error, [String.t()]}
  def from_map(map) when is_map(map) do
    {fields, problems} =
      Enum.reduce(fields(), {%{}, []}, fn {key, spec}, {acc, problems} ->
        case parse(spec, Map.get(map, Atom.to_string(key))) do
          {:ok, value} -> {Map.put(acc, key, value), problems}
          {:error, why} -> {acc, ["#{key} #{why}" | problems]}
        end
      end)

    problems = Enum.reverse(problems) ++ cross_field_problems(fields)

    case problems do
      [] -> {:ok, struct!(__MODULE__, fields)}
      problems -> {:error, problems}
    end
  end

  def from_map(_), do: {:error, ["declaration must be a JSON object"]}

  @doc "Whether the declaration has lapsed on `date` (it is still valid on its `review_by` day)."
  @spec lapsed?(t() | map(), Date.t()) :: boolean()
  def lapsed?(%{review_by: %Date{} = review_by}, %Date{} = date),
    do: Date.compare(date, review_by) == :gt

  def lapsed?(_zone, _date), do: false

  @doc "The controls still recorded as gaps."
  @spec gaps(t()) :: [control()]
  def gaps(%__MODULE__{controls: controls}), do: Enum.filter(controls, &(&1.status == :gap))

  defp fields do
    [
      id: {:required, &slug/1},
      jurisdiction: {:required, &jurisdiction/1},
      classification_ceiling: {:required, &data_class/1},
      inadmissible_restrictions: {:list, &jurisdiction/1},
      declared_by: {:required, &text/1},
      declared_at: {:required, &date/1},
      review_by: {:required, &date/1},
      basis: {:optional, &text/1},
      members: {:list, &text/1},
      stores: {:list, &text/1},
      controls: {:list, &control/1}
    ]
  end

  defp parse({:required, parser}, value), do: required(value, parser)
  defp parse({:optional, parser}, value), do: optional(value, parser)
  defp parse({:list, parser}, value), do: list_of(value, parser)

  defp cross_field_problems(%{declared_at: declared_at, review_by: review_by}) do
    if Date.compare(review_by, declared_at) == :gt,
      do: [],
      else: ["review_by must be after declared_at"]
  end

  defp cross_field_problems(_), do: []

  defp required(nil, _parser), do: {:error, "is required"}
  defp required(value, parser), do: parser.(value)

  defp optional(nil, _parser), do: {:ok, nil}
  defp optional(value, parser), do: parser.(value)

  defp list_of(nil, _parser), do: {:ok, []}

  defp list_of(values, parser) when is_list(values) do
    values
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {value, index}, {:ok, acc} ->
      case parser.(value) do
        {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
        {:error, why} -> {:halt, {:error, "[#{index}] #{why}"}}
      end
    end)
    |> case do
      {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
      error -> error
    end
  end

  defp list_of(_value, _parser), do: {:error, "must be a list"}

  defp text(value) when is_binary(value) do
    if String.trim(value) == "", do: {:error, "must not be blank"}, else: {:ok, value}
  end

  defp text(_), do: {:error, "must be a string"}

  defp slug(value) when is_binary(value) do
    if Regex.match?(@id_pattern, value),
      do: {:ok, value},
      else: {:error, "must be a lowercase slug"}
  end

  defp slug(_value), do: {:error, "must be a string"}

  defp jurisdiction(value) do
    if Jurisdiction.valid?(value),
      do: {:ok, value},
      else:
        {:error,
         "must be an ISO 3166 code, country first (\"CA\", \"CA-ON\"), got #{inspect(value)}"}
  end

  defp data_class(value) do
    case DataClass.match(value) do
      {:ok, class} -> {:ok, class}
      :error -> {:error, "must be one of #{inspect(DataClass.values())}, got #{inspect(value)}"}
    end
  end

  defp date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _} -> {:error, "must be an ISO 8601 date, got #{inspect(value)}"}
    end
  end

  defp date(_), do: {:error, "must be an ISO 8601 date string"}

  defp control(%{"name" => name, "status" => status} = control) when is_binary(name) do
    evidence = Map.get(control, "evidence")

    case status do
      "in_place" when is_binary(evidence) and evidence != "" ->
        {:ok, %{name: name, status: :in_place, evidence: evidence}}

      "in_place" ->
        {:error, "control #{inspect(name)} is in_place but gives no evidence"}

      "gap" ->
        {:ok, %{name: name, status: :gap, evidence: evidence}}

      other ->
        {:error,
         "control #{inspect(name)} has status #{inspect(other)}; use \"in_place\" or \"gap\""}
    end
  end

  defp control(_), do: {:error, "a control needs a name and a status"}
end
