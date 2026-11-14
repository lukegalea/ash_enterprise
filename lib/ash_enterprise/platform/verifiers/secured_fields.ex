defmodule AshEnterprise.Platform.Verifiers.SecuredFields do
  @moduledoc """
  Compile-time guard on `secured_fields` (`AshEnterprise.Platform.Resource`).

  - Every listed name must be an attribute of the resource. A misspelt name would
    secure nothing and look, in review, as if it secured something; a calculation,
    an aggregate or a relationship is not a column.
  - Not the primary key: Ash shows a primary key to everyone, whatever a field policy
    says, so securing it would be a declaration Ash ignores.
  - Not an ownership or tenant column: the row grant's own depth filter reads
    `owner_id` and `owning_business_unit_id`, and the tenant boundary reads
    `organization_id`, so hiding them would hide what authorization is computed from.
  - No field policies of the resource's own beside the injected ones: the base writes
    one policy per secured field plus `field_policy :*`, and Ash requires every policy
    that applies to a field to pass, so a hand-written block would interact with them
    in ways neither shows. A resource that needs a different rule
    (`AshEnterprise.Integration.LinkedAccount`) declares its own block and no
    `secured_fields`.
  """

  use Spark.Dsl.Verifier

  alias Spark.Dsl.Verifier

  # The columns `AshEnterprise.Platform.Transformers.AddSystemAttributes` adds for
  # ownership and tenancy, which authorization reads.
  @authority_columns [
    :owner_id,
    :owner_type,
    :owning_user_id,
    :owning_team_id,
    :owning_business_unit_id,
    :organization_id
  ]

  @doc "The columns no resource may secure: authorization is computed from them."
  @spec authority_columns() :: [atom()]
  def authority_columns, do: @authority_columns

  @impl true
  def verify(dsl) do
    resource = Verifier.get_persisted(dsl, :module)
    secured = Verifier.get_option(dsl, [:platform], :secured_fields, [])

    problems =
      Enum.flat_map(secured, &field_problems(dsl, &1)) ++ own_policies(dsl, secured)

    case problems do
      [] ->
        :ok

      [message | _] ->
        {:error,
         Spark.Error.DslError.exception(
           module: resource,
           path: [:platform, :secured_fields],
           message: message
         )}
    end
  end

  defp field_problems(dsl, name) do
    attribute = Ash.Resource.Info.attribute(dsl, name)

    cond do
      is_nil(attribute) ->
        ["secured_fields #{inspect(name)}: no such attribute"]

      attribute.primary_key? ->
        [
          "secured_fields #{inspect(name)} is the primary key, which Ash shows to every reader"
        ]

      name in @authority_columns ->
        [
          "secured_fields #{inspect(name)} is an ownership or tenant column, " <>
            "which authorization itself reads"
        ]

      true ->
        []
    end
  end

  defp own_policies(_dsl, []), do: []

  # Ash has expanded `field_policy :*` into every field by the time a verifier runs, so
  # the injected policies are told apart by what they check: a column's own grant, or
  # `always()`.
  defp own_policies(dsl, secured) do
    dsl
    |> Ash.Policy.Info.field_policies()
    |> Enum.reject(&injected?(&1, secured))
    |> case do
      [] ->
        []

      [policy | _] ->
        [
          "declares its own field policy for #{inspect(policy.fields)} beside secured_fields; " <>
            "a resource uses one or the other"
        ]
    end
  end

  defp injected?(%{policies: [%{type: :authorize_if} = check]} = policy, secured) do
    case {check.check_module, check.check_opts[:field], policy.fields} do
      {AshEnterprise.Security.Checks.RoleGrant, field, [field]} -> field in secured
      {Ash.Policy.Check.Static, nil, _fields} -> check.check_opts[:result] == true
      _other -> false
    end
  end

  defp injected?(_policy, _secured), do: false
end
