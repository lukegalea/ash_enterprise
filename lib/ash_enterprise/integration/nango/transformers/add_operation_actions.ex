defmodule AshEnterprise.Integration.Nango.Transformers.AddOperationActions do
  @moduledoc """
  Turns each declared `operation` into one generic action plus a code
  interface of the same name.

  Every generated action takes the operation's params as arguments and one
  routing argument, `linked_account_id`. It never takes a connection id or a
  provider config key; those are resolved inside the action from the actor.
  """

  use Spark.Dsl.Transformer

  alias Ash.Resource.Builder
  alias AshEnterprise.Integration.Nango.{Info, Operation, Param, RunOperation}

  @routing_argument :linked_account_id

  @doc false
  def routing_argument, do: @routing_argument

  # Actions must exist before Ash derives primary actions, accept lists, input
  # caches and code interfaces from them.
  @impl true
  def before?(transformer) do
    transformer |> inspect() |> String.starts_with?("Ash.Resource.Transformers.")
  end

  @impl true
  def transform(dsl_state) do
    dsl_state
    |> Info.operations()
    |> Enum.reduce_while({:ok, dsl_state}, fn operation, {:ok, dsl} ->
      case add_operation(dsl, operation) do
        {:ok, dsl} -> {:cont, {:ok, dsl}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp add_operation(dsl, %Operation{} = operation) do
    with {:ok, arguments} <- build_arguments(operation),
         {:ok, dsl} <-
           Builder.add_action(dsl, :action, operation.name,
             returns: :map,
             description: description(operation),
             arguments: arguments,
             run: {RunOperation, operation: operation.name}
           ) do
      Builder.add_interface(dsl, operation.name, action: operation.name)
    end
  end

  defp build_arguments(%Operation{params: params}) do
    routing =
      Builder.build_action_argument(@routing_argument, :uuid,
        allow_nil?: true,
        description: """
        Which of the actor's own linked accounts to call through. Optional when
        the actor has exactly one active linked account for this integration.
        Must be owned by the actor; it is a routing hint, not a credential.
        """
      )

    (Enum.map(params, &build_param/1) ++ [routing])
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, argument}, {:ok, acc} -> {:cont, {:ok, [argument | acc]}}
      {:error, error}, _ -> {:halt, {:error, error}}
    end)
    |> case do
      {:ok, arguments} -> {:ok, Enum.reverse(arguments)}
      error -> error
    end
  end

  defp build_param(%Param{} = param) do
    opts =
      [
        allow_nil?: param.allow_nil? and param.in != :path,
        constraints: param.constraints,
        description: param.description
      ]
      |> maybe_put(:default, param.default)
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    Builder.build_action_argument(param.name, param.type, opts)
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp description(%Operation{description: nil, method: method, path: path}),
    do: "Proxied through Nango: #{method |> to_string() |> String.upcase()} #{path}"

  defp description(%Operation{description: description}), do: description
end
