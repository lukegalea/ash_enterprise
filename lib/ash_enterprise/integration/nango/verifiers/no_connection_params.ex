defmodule AshEnterprise.Integration.Nango.Verifiers.NoConnectionParams do
  @moduledoc """
  Refuses a provider-operation declaration that would let a caller choose whose
  credentials to spend (ADR 0011: "a generated action that accepts a connection
  identifier from input is a bug, not a configuration option").

  Also checks the declaration is internally consistent: every `{placeholder}`
  in a path has an `in: :path` param and vice versa, body params only appear on
  `:post` operations, and no param collides with the routing argument.

  Like every Spark verifier this runs after compilation and reports through
  `--warnings-as-errors`; test it by calling `verify/1` on the DSL state.
  """

  use Spark.Dsl.Verifier

  alias AshEnterprise.Integration.Nango.{Info, Operation, Param}
  alias AshEnterprise.Integration.Nango.Transformers.AddOperationActions
  alias Spark.Error.DslError

  # Normalized (lowercase, separators stripped) names a param may never take,
  # either as its argument name or as its wire name.
  @forbidden ~w(connection connectionid connectionref nangoconnectionid providerconfigkey
                integration integrationid authorization)

  @impl true
  def verify(dsl_state) do
    module = Spark.Dsl.Verifier.get_persisted(dsl_state, :module)

    dsl_state
    |> Info.operations()
    |> Enum.flat_map(&problems/1)
    |> case do
      [] ->
        :ok

      [{operation, message} | _] ->
        {:error,
         DslError.exception(
           module: module,
           path: [:nango, :operation, operation],
           message: message
         )}
    end
  end

  defp problems(%Operation{} = operation) do
    placeholders = Operation.placeholders(operation)
    path_params = for %Param{in: :path} = p <- operation.params, do: Atom.to_string(p.name)

    forbidden =
      for %Param{} = p <- operation.params, forbidden?(p) do
        {operation.name,
         "param #{inspect(p.name)} names a connection or credential. The connection is derived " <>
           "from the actor's linked account inside the action and is never an argument (ADR 0011)."}
      end

    routing =
      for %Param{name: name} <- operation.params,
          name == AddOperationActions.routing_argument() do
        {operation.name,
         "param #{inspect(name)} collides with the generated routing argument of the same name."}
      end

    missing =
      for name <- placeholders, name not in path_params do
        {operation.name, "path placeholder {#{name}} has no `param :#{name}, ..., in: :path`."}
      end

    orphaned =
      for name <- path_params, name not in placeholders do
        {operation.name, "path param #{inspect(name)} does not appear in the path."}
      end

    body =
      for %Param{in: :body} = p <- operation.params, operation.method != :post do
        {operation.name, "body param #{inspect(p.name)} on a #{operation.method} operation."}
      end

    forbidden ++ routing ++ missing ++ orphaned ++ body
  end

  defp forbidden?(%Param{} = param) do
    normalize(Atom.to_string(param.name)) in @forbidden or
      normalize(Param.wire_name(param)) in @forbidden
  end

  defp normalize(name), do: name |> String.downcase() |> String.replace(~r/[^a-z]/, "")
end
