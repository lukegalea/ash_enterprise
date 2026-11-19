defmodule AshEnterpriseWeb.ApiContract.Deprecations do
  @moduledoc """
  The announcements in `priv/api/deprecations.json`: which element of the pinned API
  contract is going away, when it was announced and when it ends.

  An entry names one element by the id `AshEnterpriseWeb.ApiContract.Diff` gives it
  (`route:get /teams/{id}`, `graphql:Team.name`, ...) or the whole GraphQL endpoint
  (`endpoint:graphql`). The pinned contract may lose an element only when an entry
  names it and its sunset has passed, and the sunset has to be at least
  `minimum_notice_days/0` after the announcement. Pure functions only: the router
  plug reads the file at compile time through `read!/1`.
  """

  @minimum_notice_days 90
  @graphql_element "endpoint:graphql"

  @type entry :: %{
          element: String.t(),
          announced: Date.t(),
          sunset: Date.t(),
          link: String.t()
        }

  @doc "The shortest notice, in days, between an announcement and its sunset."
  def minimum_notice_days, do: @minimum_notice_days

  @doc "The element id that deprecates the whole GraphQL endpoint."
  def graphql_endpoint_element, do: @graphql_element

  @doc "Parse the JSON document into `{entries, retired_entries}`, raising on a malformed one."
  @spec parse!(String.t()) :: {[entry()], [map()]}
  def parse!(json) do
    case Jason.decode!(json) do
      %{"deprecations" => list} = doc when is_list(list) ->
        {Enum.map(list, &entry!/1), List.wrap(doc["retired"])}

      _ ->
        raise ArgumentError, "deprecations.json must be an object with a `deprecations` list"
    end
  end

  @doc "Read and parse a deprecations file."
  @spec read!(Path.t()) :: {[entry()], [map()]}
  # The path is the committed deprecations file, or a test's copy of it.
  # sobelow_skip ["Traversal.FileModule"]
  def read!(path), do: path |> File.read!() |> parse!()

  @doc "The file's content for a list of entries and the retired ones, in canonical form."
  @spec encode([entry()], [map()]) :: String.t()
  def encode(entries, retired) do
    entries = entries |> Enum.sort_by(& &1.element) |> Enum.map(&dump/1)

    AshEnterpriseWeb.ApiContract.canonical_json(%{
      "deprecations" => entries,
      "retired" => retired
    })
  end

  defp dump(entry) do
    %{
      "element" => entry.element,
      "announced" => Date.to_iso8601(entry.announced),
      "sunset" => Date.to_iso8601(entry.sunset),
      "link" => entry.link
    }
  end

  defp entry!(%{"element" => element, "announced" => a, "sunset" => s, "link" => link})
       when is_binary(element) and is_binary(link) do
    %{
      element: element,
      announced: Date.from_iso8601!(a),
      sunset: Date.from_iso8601!(s),
      link: link
    }
  end

  defp entry!(other) do
    raise ArgumentError,
          "a deprecation needs `element`, `announced`, `sunset` and `link`: #{inspect(other)}"
  end

  @doc """
  What is wrong with the entries, given the element ids the pinned contract holds.

  An entry must name a pinned element (or the GraphQL endpoint), must be announced
  before it ends, with at least the minimum notice, and must carry an `https:` link
  to the runbook or notice a caller can read.
  """
  @spec problems([entry()], MapSet.t(String.t())) :: [String.t()]
  def problems(entries, pinned_elements) do
    duplicates =
      entries
      |> Enum.frequencies_by(& &1.element)
      |> Enum.filter(fn {_, n} -> n > 1 end)
      |> Enum.map(fn {element, _} -> "#{element}: announced more than once" end)

    per_entry =
      Enum.flat_map(entries, fn entry ->
        []
        |> add(
          entry.element != @graphql_element and not MapSet.member?(pinned_elements, entry.element),
          "#{entry.element}: names nothing in the pinned contract"
        )
        |> add(
          Date.diff(entry.sunset, entry.announced) < @minimum_notice_days,
          "#{entry.element}: the sunset is #{Date.diff(entry.sunset, entry.announced)} days after the announcement, " <>
            "the minimum is #{@minimum_notice_days}"
        )
        |> add(
          not String.starts_with?(entry.link, "https://"),
          "#{entry.element}: the link must be an https URL"
        )
      end)

    duplicates ++ per_entry
  end

  defp add(list, true, message), do: list ++ [message]
  defp add(list, false, _message), do: list

  @doc "Whether an entry lets its element leave the contract on `today`."
  @spec permits_removal?([entry()], String.t(), Date.t()) :: boolean()
  def permits_removal?(entries, element, today) do
    Enum.any?(entries, fn entry ->
      entry.element == element and Date.compare(entry.sunset, today) != :gt
    end)
  end

  @doc """
  The `Deprecation` and `Sunset` header values for an entry: `@<epoch seconds>`
  (RFC 9745) and an IMF-fixdate (RFC 8594).
  """
  @spec header_values(entry()) :: {String.t(), String.t()}
  def header_values(entry) do
    announced = DateTime.new!(entry.announced, ~T[00:00:00], "Etc/UTC")
    sunset = DateTime.new!(entry.sunset, ~T[00:00:00], "Etc/UTC")

    {"@" <> Integer.to_string(DateTime.to_unix(announced)),
     Calendar.strftime(sunset, "%a, %d %b %Y %H:%M:%S GMT")}
  end
end
