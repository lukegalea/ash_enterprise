defmodule AshEnterprise.SystemOne.JudgedFields.Verifier do
  @moduledoc """
  Refuses, at compile time, a judged-fields resource whose freshness could
  silently go wrong:

  - the primary key must be a single `id` (the facts table's `subject_id`);
  - every declared question needs a `state_shape` whose keys each name an
    attribute of the resource — those are its projection fields, and a key
    that names nothing could never mark a fact stale;
  - an upsert action that may rewrite a projection field must also write
    `judgment_digests`, or the digest would keep describing the old value;
  - when the resource declares AshOban triggers, the reassess trigger must
    exist and run `:reassess_judgments`.
  """

  use Spark.Dsl.Verifier

  alias AshEnterprise.SystemOne.JudgedFields
  alias Spark.Dsl.Transformer
  alias Spark.Error.DslError

  @impl true
  def verify(dsl_state) do
    module = Transformer.get_persisted(dsl_state, :module)
    fields = Transformer.get_persisted(dsl_state, :judged_fields, [])

    errors =
      primary_key_errors(dsl_state, module) ++
        Enum.flat_map(fields, &projection_errors(&1, dsl_state, module)) ++
        upsert_errors(fields, dsl_state, module) ++
        trigger_errors(fields, dsl_state, module)

    case errors do
      [] -> :ok
      errors -> {:error, errors}
    end
  end

  defp primary_key_errors(dsl_state, module) do
    case Ash.Resource.Info.primary_key(dsl_state) do
      [:id] ->
        []

      other ->
        [
          error(
            module,
            [:attributes],
            "judged fields need a single `id` primary key, got #{inspect(other)}"
          )
        ]
    end
  end

  defp projection_errors(%{projection: []} = field, _dsl_state, module) do
    [
      error(
        module,
        [:judgments, field.name],
        "question #{field.name} needs a state_shape naming the attributes its judge sees: they are its projection fields, and without them a fact about it can never read stale"
      )
    ]
  end

  defp projection_errors(field, dsl_state, module) do
    attributes = dsl_state |> Ash.Resource.Info.attributes() |> MapSet.new(&to_string(&1.name))

    case Enum.reject(field.projection, &MapSet.member?(attributes, &1)) do
      [] ->
        []

      missing ->
        [
          error(
            module,
            [:judgments, field.name],
            "question #{field.name}'s state_shape keys #{inspect(missing)} name no attribute of #{inspect(module)}"
          )
        ]
    end
  end

  defp upsert_errors(fields, dsl_state, module) do
    projection = Enum.flat_map(fields, & &1.projection)
    digests = to_string(JudgedFields.digest_attribute())

    dsl_state
    |> Ash.Resource.Info.actions()
    |> Enum.filter(&rewrites_projection_only?(&1, projection, digests))
    |> Enum.map(fn action ->
      error(
        module,
        [:actions, action.name],
        "upsert #{action.name} may rewrite a judged projection field; add #{inspect(JudgedFields.digest_attribute())} to its upsert_fields"
      )
    end)
  end

  # The upsert may rewrite a projection field but leaves the digests behind.
  defp rewrites_projection_only?(
         %{type: :create, upsert?: true, upsert_fields: fields},
         projection,
         digests
       )
       when is_list(fields) do
    upserted = Enum.map(fields, &to_string/1)
    Enum.any?(projection, &(&1 in upserted)) and digests not in upserted
  end

  defp rewrites_projection_only?(_action, _projection, _digests), do: false

  defp trigger_errors([], _dsl_state, _module), do: []

  defp trigger_errors(_fields, dsl_state, module) do
    name =
      Transformer.get_option(dsl_state, [:judged_fields], :reassess_trigger) ||
        :reassess_judgments

    triggers =
      if Code.ensure_loaded?(AshOban.Info),
        do: Transformer.get_entities(dsl_state, [:oban, :triggers]),
        else: []

    case Enum.find(triggers, &(&1.name == name)) do
      %{action: action} when action == :reassess_judgments ->
        []

      %{action: action} ->
        [
          error(
            module,
            [:oban, :triggers, name],
            "trigger #{name} must run :reassess_judgments, not #{inspect(action)}"
          )
        ]

      nil ->
        [
          error(
            module,
            [:oban, :triggers],
            "declare the AshOban trigger #{name} (action :reassess_judgments): a write that turns a judged fact stale enqueues it"
          )
        ]
    end
  end

  defp error(module, path, message),
    do: DslError.exception(module: module, path: path, message: message)
end
