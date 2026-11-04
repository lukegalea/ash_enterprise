defmodule AshEnterprise.Quality.Interchange.Samples do
  @moduledoc """
  Inspect `Sample` JSONL for suite cases (ADR 0058): one JSON object per line, each with
  an explicit, stable `id` (https://inspect.aisi.org.uk/datasets.html.md).

  A case is a sample: `id`, `input` and `target`. What a sample has no field for rides in
  its `metadata`: the case's own metadata, and under `"ash_enterprise"` its `fixtures`,
  `split`, `tags` and `assertions`. A line from another tool has none of that: it is a
  case with no assertions. A sample with no `id`, or a list `target`, is read as the id
  it must have (an error otherwise) and its first target (the rest kept in the case's
  metadata under `"targets"`).
  """

  @own "ash_enterprise"

  @doc "The cases as JSONL, one line each, in order."
  @spec export([map()]) :: String.t()
  def export(cases) do
    Enum.map_join(cases, "", fn kase -> Jason.encode!(sample(kase)) <> "\n" end)
  end

  @doc """
  The cases in `jsonl`, as maps a suite's cases take: `{:ok, cases}`, or
  `{:error, message}` naming the first line that is not a sample.
  """
  @spec parse(String.t()) :: {:ok, [map()]} | {:error, String.t()}
  def parse(jsonl) when is_binary(jsonl) do
    jsonl
    |> String.split("\n", trim: true)
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, []}, fn {line, number}, {:ok, cases} ->
      with {:ok, %{} = sample} <- Jason.decode(line),
           {:ok, kase} <- to_case(sample) do
        {:cont, {:ok, [kase | cases]}}
      else
        {:error, message} when is_binary(message) ->
          {:halt, {:error, "line #{number}: #{message}"}}

        _not_json_object ->
          {:halt, {:error, "line #{number}: not a JSON object"}}
      end
    end)
    |> case do
      {:ok, cases} -> {:ok, Enum.reverse(cases)}
      error -> error
    end
  end

  defp sample(kase) do
    own =
      %{
        "fixtures" => kase[:fixtures],
        "split" => kase[:split] && to_string(kase[:split]),
        "tags" => kase[:tags],
        "assertions" => kase[:assertions] && Enum.map(kase[:assertions], &assertion/1)
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    %{
      "id" => kase[:id],
      "input" => kase[:input],
      "target" => kase[:target] || "",
      "metadata" => Map.put(kase[:metadata] || %{}, @own, own)
    }
  end

  defp assertion(assertion) do
    assertion
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new(fn {key, value} ->
      {to_string(key), if(key == :type, do: to_string(value), else: value)}
    end)
  end

  defp to_case(%{"id" => id}) when id in [nil, ""], do: {:error, "a sample needs an id"}

  defp to_case(%{"id" => id} = sample) when is_binary(id) or is_integer(id) do
    metadata = sample["metadata"] || %{}
    {own, metadata} = Map.pop(metadata, @own, %{})
    {target, metadata} = target(sample["target"], metadata)

    case sample["input"] do
      input when is_binary(input) ->
        {:ok,
         %{
           id: to_string(id),
           input: input,
           target: target,
           metadata: metadata,
           fixtures: own["fixtures"] || %{},
           split: own["split"] && String.to_existing_atom(own["split"]),
           tags: own["tags"] || [],
           assertions: own["assertions"] || []
         }}

      _chat_input ->
        {:error, "sample #{id}: only a text input is read"}
    end
  end

  defp to_case(_sample), do: {:error, "a sample needs an id"}

  defp target([first | _] = targets, metadata) when is_binary(first),
    do: {first, Map.put(metadata, "targets", targets)}

  defp target(target, metadata) when is_binary(target), do: {target, metadata}
  defp target(_none, metadata), do: {nil, metadata}
end
