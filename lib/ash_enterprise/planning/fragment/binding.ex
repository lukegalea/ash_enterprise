defmodule AshEnterprise.Planning.Fragment.Binding do
  @moduledoc """
  The pure shape of a planning binding: for one tenant, which pinned definitions answer
  `(model_key, purpose)` for as long as the binding is valid.

  A binding is temporal (`strategy :context`, period `valid_at`): re-binding closes the
  version valid until `as_of` and opens a new one, so "what was bound last Monday" is a
  read `as_of` that Monday. There is no `current` flag and no superseded chain.

  The tenant column (`organization_id`) is the host's multitenancy attribute; the fragment
  declares none, so a host that scopes differently is not forced into this one. Unique
  `selector` per tenant is therefore declared here as an ordinary identity, and a temporal
  resource makes it unique at every instant.

  ## The selector

  `selector` is the canonical-JSON string `{"model_key":"…","purpose":"…"}` (keys sorted,
  no whitespace). It is built from the `model_key` and `purpose` arguments, never accepted
  whole, so two spellings of one selector cannot exist.

  ## The selection

  `selection` pins every definition the binding resolves to, one map per definition:
  `%{"kind" => …, "key" => …, "version" => …, "content_hash" => …}` (all strings), stored in
  `(kind, key, version)` order. It is what a snapshot's `definitions` are built from.
  """

  use Spark.Dsl.Fragment, of: Ash.Resource

  alias AshEnterprise.Planning.Fragment.Binding.Changes

  temporal do
    strategy :context
    attribute :valid_at
  end

  attributes do
    uuid_primary_key :id

    attribute :selector, :string do
      allow_nil? false
      public? true
      description ~S|The canonical-JSON string `{"model_key":"…","purpose":"…"}`.|
    end

    attribute :selection, {:array, :map} do
      allow_nil? false
      public? true
      default []

      description """
      The pinned definitions: `kind`, `key`, `version`, `content_hash` per entry, all strings,
      in `(kind, key, version)` order.
      """
    end

    attribute :backend_profile_hash, :string do
      allow_nil? false
      public? true
      constraints match: ~r/\A[0-9a-f]{64}\z/
      description "Lowercase hex SHA-256 of the backend profile the binding was reviewed against."
    end
  end

  actions do
    defaults [:read]

    create :bind do
      description "Bind `(model_key, purpose)` to a selection, valid from `as_of` onward."
      accept [:selection, :backend_profile_hash]

      argument :model_key, :string do
        allow_nil? false
        constraints min_length: 1, max_length: 255
      end

      argument :purpose, :string do
        allow_nil? false

        constraints match: ~r/\A[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)*\z/,
                    max_length: 255

        description ~S|The dotted purpose, e.g. `"planning.personal_week"`.|
      end

      change Changes.BuildSelector
      change Changes.NormalizeSelection
    end

    update :rebind do
      description "Change what the selector resolves to, from `as_of` onward. The selector itself never changes."
      accept [:selection, :backend_profile_hash]
      require_atomic? false

      change Changes.NormalizeSelection
    end

    destroy :unbind do
      description "End the binding at `as_of`. History stays readable `as_of` earlier instants."
      require_atomic? false
    end
  end

  identities do
    identity :unique_selector, [:selector]
  end
end

defmodule AshEnterprise.Planning.Fragment.Binding.Changes.BuildSelector do
  @moduledoc false
  # Pure: the selector is a function of the two arguments alone.

  use Ash.Resource.Change

  @impl true
  def temporal_safe?(_opts), do: true

  @impl true
  def change(changeset, _opts, _context) do
    model_key = Ash.Changeset.get_argument(changeset, :model_key)
    purpose = Ash.Changeset.get_argument(changeset, :purpose)

    if is_binary(model_key) and is_binary(purpose) do
      Ash.Changeset.force_change_attribute(changeset, :selector, selector(model_key, purpose))
    else
      changeset
    end
  end

  @doc "The canonical-JSON selector string for `(model_key, purpose)`."
  @spec selector(String.t(), String.t()) :: String.t()
  def selector(model_key, purpose) do
    ~s({"model_key":#{Jason.encode!(model_key)},"purpose":#{Jason.encode!(purpose)}})
  end
end

defmodule AshEnterprise.Planning.Fragment.Binding.Changes.NormalizeSelection do
  @moduledoc false
  # Pure: each entry must carry exactly `kind`, `key`, `version`, `content_hash` as strings
  # (atom or string keys in), is stored string-keyed, and the list is stored in
  # `(kind, key, version)` order so equal selections have equal bytes.

  use Ash.Resource.Change

  @fields ~w(kind key version content_hash)

  @impl true
  def temporal_safe?(_opts), do: true

  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.fetch_change(changeset, :selection) do
      {:ok, entries} when is_list(entries) -> normalize(changeset, entries)
      _unchanged -> changeset
    end
  end

  defp normalize(changeset, entries) do
    entries
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
      case entry(entry) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
    |> case do
      {:ok, normalized} ->
        sorted = Enum.sort_by(normalized, &{&1["kind"], &1["key"], &1["version"]})

        if length(Enum.uniq_by(sorted, &{&1["kind"], &1["key"], &1["version"]})) == length(sorted) do
          Ash.Changeset.force_change_attribute(changeset, :selection, sorted)
        else
          Ash.Changeset.add_error(changeset,
            field: :selection,
            message: "names a (kind, key, version) more than once"
          )
        end

      {:error, message} ->
        Ash.Changeset.add_error(changeset, field: :selection, message: message)
    end
  end

  defp entry(%{} = entry) do
    stringified = Map.new(entry, fn {key, value} -> {to_string(key), value} end)

    cond do
      Enum.sort(Map.keys(stringified)) != Enum.sort(@fields) ->
        {:error, "each entry must have exactly #{Enum.join(@fields, ", ")}"}

      not Enum.all?(@fields, &(is_binary(stringified[&1]) and stringified[&1] != "")) ->
        {:error, "every field of an entry must be a non-empty string"}

      not Regex.match?(~r/\A[0-9a-f]{64}\z/, stringified["content_hash"]) ->
        {:error, "content_hash must be lowercase hex SHA-256"}

      true ->
        {:ok, stringified}
    end
  end

  defp entry(_other), do: {:error, "each entry must be a map"}
end
