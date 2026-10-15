defmodule AshEnterprise.Platform.Verifiers.SelfServiceActions do
  @moduledoc """
  Compile-time guard on `self_service` (ADR 0052): every action listed must
  exist and be one the self-service grant path can bound.

  - A **generic** action is authorized outright, so it must scope itself to
    the actor by construction — a reviewer's judgement, which is why the list
    is short, local and greppable rather than inferred.
  - A **create** or **read** reaches only rows the actor personally owns
    (`owner_id`), so the resource must be `:user_owned`; on any other
    ownership model there is no owner to bound it by.
  - **Updates and destroys** are refused. Changing or removing an existing
    row is what a role grant is for; self-service only lets a member open and
    see their own.
  """

  use Spark.Dsl.Verifier

  alias Spark.Dsl.Verifier

  @impl true
  def verify(dsl) do
    resource = Verifier.get_persisted(dsl, :module)
    ownership = Verifier.get_option(dsl, [:platform], :ownership, :user_owned)

    dsl
    |> Verifier.get_option([:platform], :self_service, [])
    |> Enum.find_value(:ok, fn name ->
      case problem(Ash.Resource.Info.action(dsl, name), ownership) do
        nil ->
          nil

        message ->
          {:error,
           Spark.Error.DslError.exception(
             module: resource,
             path: [:platform, :self_service],
             message: "self_service #{inspect(name)}: #{message}"
           )}
      end
    end)
  end

  defp problem(nil, _ownership), do: "no such action"
  defp problem(%{type: :action}, _ownership), do: nil

  defp problem(%{type: type}, :user_owned) when type in [:create, :read], do: nil

  defp problem(%{type: type}, ownership) when type in [:create, :read],
    do: "a #{type} is bounded by owner_id, which a #{inspect(ownership)} resource does not have"

  defp problem(%{type: type}, _ownership),
    do: "#{type} actions cannot be self-service; changing an existing row takes a role grant"
end
