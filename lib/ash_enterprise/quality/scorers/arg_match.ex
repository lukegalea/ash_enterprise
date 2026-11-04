defmodule AshEnterprise.Quality.Scorers.ArgMatch do
  @moduledoc """
  What a tool call's arguments must hold, as data (`args_match`).

  `expected` is `%{"$or" => [expected, ..]}`, any alternative of which may hold, or maps
  argument names to a literal, which the argument must equal, or to a one-key matcher:

    * `%{"$contains" => "text"}`: the argument, read as text, contains it, ignoring case;
    * `%{"$starts_with" => "text"}`: the argument, read as text, starts with it;
    * `%{"$in" => [..]}`: the argument is one of them (`nil` stands for absent);
    * `%{"$present" => true}`: the argument is a non-empty string;
    * `%{"$window" => ["2026-11-02", "2026-11-04"]}`: the assistant's window argument
      names exactly those days (`AshEnterprise.Assistant.Lookups.Support.days/1`), however
      it is put: a weekday, a named window, a date or a range.
  """

  alias AshEnterprise.Assistant.Lookups.Support

  @doc "Whether `actual`, a call's arguments, holds everything `expected` asks."
  @spec holds?(map(), map()) :: boolean()
  def holds?(%{"$or" => alternatives}, actual) when is_list(alternatives),
    do: Enum.any?(alternatives, &holds?(&1, actual))

  def holds?(expected, actual) when is_map(expected) and is_map(actual) do
    Enum.all?(expected, fn {key, want} -> value?(want, Map.get(actual, to_string(key))) end)
  end

  def holds?(_expected, _actual), do: false

  defp value?(%{"$contains" => text}, got), do: downcase(got) =~ String.downcase(text)
  defp value?(%{"$starts_with" => text}, got), do: String.starts_with?(to_string(got), text)
  defp value?(%{"$in" => options}, got), do: got in options
  defp value?(%{"$present" => true}, got), do: is_binary(got) and got != ""

  defp value?(%{"$window" => [first, last]}, got) when is_binary(got),
    do: Support.days(got) == {:ok, Date.from_iso8601!(first), Date.from_iso8601!(last)}

  defp value?(%{"$window" => _range}, _got), do: false
  defp value?(want, got), do: want == got

  defp downcase(nil), do: ""
  defp downcase(value), do: value |> to_string() |> String.downcase()
end
