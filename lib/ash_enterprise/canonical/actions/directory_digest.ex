defmodule AshEnterprise.Canonical.Actions.DirectoryDigest do
  @moduledoc """
  `Person.directory_digest`: the people directory as plain text for a terminal
  transcript (the ACP `people` prompt). Same read, same actor and policies as
  the People surface; at most #{30} lines.
  """

  use Ash.Resource.Actions.Implementation

  require Ash.Query

  alias AshEnterprise.Canonical.Person

  @max 30

  @impl true
  def run(input, _opts, context) do
    opts = Ash.Context.to_opts(context)
    search = input.arguments[:search]

    Person
    |> Ash.Query.for_read(:read, %{}, opts)
    |> narrow(search)
    |> Ash.Query.load([:label, :organized_event_count])
    |> Ash.Query.sort(name: :asc_nils_last, email: :asc)
    |> Ash.read(opts)
    |> case do
      {:ok, people} -> {:ok, render(people, search)}
      {:error, error} -> {:error, error}
    end
  end

  defp narrow(query, search) when search in [nil, ""], do: query

  defp narrow(query, search) do
    term = String.trim(search)
    Ash.Query.filter(query, contains(name, ^term) or contains(email, ^Ash.CiString.new(term)))
  end

  defp render([], nil), do: "People — nobody yet."
  defp render([], search), do: "People matching \"#{search}\" — nobody."

  defp render(people, search) do
    heading =
      if search in [nil, ""],
        do: "People — #{length(people)}",
        else: "People matching \"#{search}\" — #{length(people)}"

    lines =
      people
      |> Enum.take(@max)
      |> Enum.map(fn person ->
        email = if person.email, do: "  <#{person.email}>", else: ""
        "  #{person.label || "(no name)"}#{email}  · #{person.organized_event_count} events"
      end)

    more = if length(people) > @max, do: ["  … and #{length(people) - @max} more"], else: []
    Enum.join([heading | lines ++ more], "\n")
  end
end
