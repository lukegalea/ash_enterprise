defmodule AshEnterprise.Telemetry.Sanitize do
  @moduledoc false

  # What keeps runtime values out of exported telemetry. A trace leaves the process
  # and is read by people who cannot see the customer data behind it, so a stack frame,
  # an exception message or a URL has its values removed before it is recorded.

  @filtered "[Filtered]"
  @max_query_bytes 1_024
  @max_query_pairs 32
  @query_key ~r/\A[A-Za-z0-9_.\-\[\]]{1,64}\z/

  # Exceptions whose message prints a runtime value it was handed.
  @value_fields %{
    BadBooleanError => [:term],
    BadFunctionError => [:term],
    BadMapError => [:term],
    BadStructError => [:term],
    CaseClauseError => [:term],
    ErlangError => [:original],
    KeyError => [:term],
    MatchError => [:term],
    Protocol.UndefinedError => [:value],
    TryClauseError => [:term],
    WithClauseError => [:term]
  }

  @doc """
  A stacktrace with every frame's arguments replaced by their count.

  A frame raised through a function clause carries the argument list, and
  `Exception.format_stacktrace/1` prints it: form values, a socket's assigns.
  """
  @spec stacktrace(term()) :: Exception.stacktrace()
  def stacktrace(frames) when is_list(frames), do: Enum.map(frames, &frame/1)
  def stacktrace(_other), do: []

  defp frame({module, function, args, location}) when is_list(args),
    do: {module, function, length(args), location}

  defp frame({fun, args, location}) when is_function(fun) and is_list(args),
    do: {fun, length(args), location}

  defp frame(frame), do: frame

  @doc "An exception with any runtime value its message would print removed."
  @spec exception(term()) :: term()
  def exception(%BadArityError{args: args} = exception) when is_list(args) do
    %{exception | args: Enum.map(args, fn _arg -> @filtered end)}
  end

  def exception(%Plug.Conn.WrapperError{} = exception) do
    %{
      exception
      | reason: exception(exception.reason),
        stack: stacktrace(exception.stack),
        conn: nil
    }
  end

  def exception(%{__struct__: struct, __exception__: true} = exception) do
    @value_fields
    |> Map.get(struct, [])
    |> Enum.reduce(exception, &Map.put(&2, &1, @filtered))
  end

  def exception(other), do: other

  @doc "At most `max` bytes of `value`, always valid UTF-8."
  @spec truncate(binary(), non_neg_integer()) :: binary()
  def truncate(value, max) when is_binary(value) and is_integer(max) and max >= 0 do
    cut = binary_part(value, 0, min(byte_size(value), max))

    case :unicode.characters_to_binary(cut) do
      valid when is_binary(valid) -> valid
      {_problem, valid, _rest} -> valid
    end
  end

  @doc """
  A query string with its parameter names and none of its values.

  A bare segment could be the secret itself, so only `name=value` keeps its name.
  """
  @spec query(binary()) :: binary()
  def query(""), do: ""

  def query(query) when is_binary(query) do
    query
    |> String.split("&")
    |> Enum.take(@max_query_pairs)
    |> Enum.map_join("&", &query_pair/1)
    |> truncate(@max_query_bytes)
  end

  defp query_pair(pair) do
    case String.split(pair, "=", parts: 2) do
      [key, _value] -> "#{query_key(key)}=#{@filtered}"
      [_bare] -> @filtered
    end
  end

  defp query_key(key) do
    if Regex.match?(@query_key, key), do: key, else: @filtered
  end
end
