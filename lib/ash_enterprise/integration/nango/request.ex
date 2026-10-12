defmodule AshEnterprise.Integration.Nango.Request do
  @moduledoc """
  Builds the proxied request for a declared operation from the action's
  arguments: path placeholders filled (each value one encoded path segment),
  query parameters under their provider names, an optional JSON body.

  Connection fields are not built here; they are resolved from the actor's
  linked account and added by `AshEnterprise.Integration.Nango.RunOperation`.
  """

  alias AshEnterprise.Integration.Nango.{Operation, Param}

  @spec build(Operation.t(), map()) ::
          {:ok, %{method: atom(), path: String.t(), query: list(), body: map() | nil}}
          | {:error, String.t()}
  def build(%Operation{} = operation, arguments) do
    with {:ok, path} <- fill_path(operation, arguments) do
      {:ok,
       %{
         method: operation.method,
         path: path,
         query: query(operation, arguments),
         body: body(operation, arguments)
       }}
    end
  end

  defp fill_path(%Operation{path: path} = operation, arguments) do
    by_name = Map.new(operation.params, &{Atom.to_string(&1.name), &1})

    Operation.placeholder_regex()
    |> Regex.split(path, include_captures: true)
    |> Enum.reduce_while({:ok, []}, fn segment, {:ok, acc} ->
      case fill_segment(segment, by_name, arguments) do
        {:ok, part} -> {:cont, {:ok, [part | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, parts} -> {:ok, parts |> Enum.reverse() |> Enum.join()}
      error -> error
    end
  end

  # A literal piece of the path passes through; a `{placeholder}` is replaced
  # by its argument, encoded as exactly one segment.
  defp fill_segment(segment, by_name, arguments) do
    with [name] <- Regex.run(Operation.placeholder_regex(), segment, capture: :all_but_first),
         :error <- path_segment(Map.get(arguments, by_name[name].name)) do
      {:error, "invalid value for path param #{name}"}
    else
      nil -> {:ok, segment}
      {:ok, encoded} -> {:ok, encoded}
    end
  end

  # One value is exactly one path segment: `/` is encoded and dot segments are
  # refused, so an argument can never walk the request to another endpoint.
  defp path_segment(value) when is_binary(value) and value not in ["", ".", ".."],
    do: {:ok, URI.encode(value, &URI.char_unreserved?/1)}

  defp path_segment(value) when is_integer(value), do: {:ok, Integer.to_string(value)}
  defp path_segment(_), do: :error

  defp query(%Operation{params: params}, arguments) do
    for %Param{in: :query} = param <- params,
        item <- present(arguments, param) do
      {Param.wire_name(param), query_value(item)}
    end
  end

  # The values to send for a param: none when the argument is nil, each element
  # when it is a list (sent as repeated keys), otherwise the one value.
  defp present(arguments, %Param{name: name}) do
    case Map.get(arguments, name) do
      nil -> []
      value -> List.wrap(value)
    end
  end

  defp query_value(value) when is_binary(value), do: value
  defp query_value(value) when is_boolean(value), do: to_string(value)
  defp query_value(value) when is_atom(value), do: Atom.to_string(value)
  defp query_value(value) when is_integer(value), do: Integer.to_string(value)
  defp query_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp query_value(%Date{} = value), do: Date.to_iso8601(value)
  defp query_value(value), do: to_string(value)

  defp body(%Operation{method: :post, params: params}, arguments) do
    params
    |> Enum.filter(&(&1.in == :body))
    |> Enum.reject(&is_nil(Map.get(arguments, &1.name)))
    |> Map.new(&{Param.wire_name(&1), body_value(Map.get(arguments, &1.name))})
  end

  defp body(_operation, _arguments), do: nil

  defp body_value(value) when is_boolean(value) or is_nil(value), do: value
  defp body_value(value) when is_atom(value), do: Atom.to_string(value)
  defp body_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp body_value(%Date{} = value), do: Date.to_iso8601(value)
  defp body_value(value) when is_list(value), do: Enum.map(value, &body_value/1)
  defp body_value(value), do: value
end
