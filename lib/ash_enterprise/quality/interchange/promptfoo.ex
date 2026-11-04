defmodule AshEnterprise.Quality.Interchange.Promptfoo do
  @moduledoc """
  Cases from a promptfoo YAML config's tests (https://www.promptfoo.dev/docs/configuration/expected-outputs/),
  to seed a suite with deterministic cases. Import only: promptfoo is not a source of truth.

  A test is a case: its input is `vars.input` or `vars.question`, its id `metadata.id` or,
  failing that, the slug of its `description` (a test with neither is refused: a case's
  id must be stable). Its `contains`, `icontains`, `contains-all`, `icontains-all`,
  `contains-any` and `icontains-any` assertions become one `facts` assertion, read
  without regard to case (promptfoo's `contains` is exact: that is lost). Any other
  assertion type refuses the import and is named: a rule a suite cannot measure would
  otherwise be dropped without a word.
  """

  @all ~w(contains icontains contains-all icontains-all)
  @any ~w(contains-any icontains-any)

  @doc "The cases in `yaml`: `{:ok, cases}` or `{:error, message}`."
  @spec parse(String.t()) :: {:ok, [map()]} | {:error, String.t()}
  def parse(yaml) when is_binary(yaml) do
    with {:ok, config} <- read(yaml),
         tests when is_list(tests) <- tests(config) do
      to_cases(tests)
    else
      {:error, message} when is_binary(message) -> {:error, message}
      _other -> {:error, "no tests to read"}
    end
  end

  defp to_cases(tests) do
    tests
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {test, number}, {:ok, cases} ->
      case to_case(test) do
        {:ok, kase} -> {:cont, {:ok, [kase | cases]}}
        {:error, message} -> {:halt, {:error, "test #{number}: #{message}"}}
      end
    end)
    |> case do
      {:ok, cases} -> {:ok, Enum.reverse(cases)}
      error -> error
    end
  end

  defp read(yaml) do
    case YamlElixir.read_from_string(yaml) do
      {:ok, config} -> {:ok, config}
      {:error, _error} -> {:error, "not YAML"}
    end
  end

  defp tests(%{"tests" => tests}) when is_list(tests), do: tests
  defp tests(tests) when is_list(tests), do: tests
  defp tests(_config), do: nil

  defp to_case(%{} = test) do
    vars = test["vars"] || %{}
    input = vars["input"] || vars["question"]

    with {:ok, id} <- id(test),
         true <- is_binary(input) or {:error, "needs vars.input or vars.question"},
         {:ok, facts} <- facts(List.wrap(test["assert"])) do
      {:ok,
       %{
         id: id,
         input: input,
         assertions:
           if(facts == [],
             do: [],
             else: [%{"type" => "facts", "expected" => %{"facts" => facts}}]
           )
       }}
    end
  end

  defp to_case(_test), do: {:error, "not a test"}

  defp id(%{"metadata" => %{"id" => id}}) when is_binary(id) and id != "", do: {:ok, id}

  defp id(%{"description" => description}) when is_binary(description) do
    case description
         |> String.downcase()
         |> String.replace(~r/[^a-z0-9]+/, "_")
         |> String.trim("_") do
      "" -> {:error, "needs metadata.id or a description"}
      slug -> {:ok, slug}
    end
  end

  defp id(_test), do: {:error, "needs metadata.id or a description"}

  defp facts(assertions) do
    Enum.reduce_while(assertions, {:ok, []}, fn
      %{"type" => type, "value" => value}, {:ok, facts} when type in @all ->
        {:cont, {:ok, facts ++ Enum.map(List.wrap(value), &to_string/1)}}

      %{"type" => type, "value" => value}, {:ok, facts} when type in @any ->
        {:cont, {:ok, facts ++ [Enum.map(List.wrap(value), &to_string/1)]}}

      %{"type" => type}, _facts ->
        {:halt, {:error, "the #{type} assertion is not one a suite measures"}}

      _other, _facts ->
        {:halt, {:error, "an assertion has no type"}}
    end)
  end
end
