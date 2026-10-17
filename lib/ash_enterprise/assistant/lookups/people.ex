defmodule AshEnterprise.Assistant.Lookups.People do
  @moduledoc """
  `Lookup.find_people`: the person's contacts whose name or address contains
  the query, as `Person.read` returns them to that person (owner-only). A
  merged duplicate (MDM) is left out; its survivor answers for it. At most
  #{15} people.
  """

  use Ash.Resource.Actions.Implementation

  require Ash.Query

  alias AshEnterprise.Assistant.Lookups.Support
  alias AshEnterprise.Canonical.Person

  @shown 15

  @impl true
  def run(input, _opts, context) do
    Support.gated(input, context, &search(String.trim(input.arguments[:query] || ""), &1))
  end

  defp search("", _opts),
    do: Support.refused("Give part of a name or an email address to search for.")

  defp search(query, opts) do
    pattern = Support.like(query)

    Person
    |> Ash.Query.for_read(:read, %{}, opts)
    |> Ash.Query.filter(
      merged == false and (ilike(name, ^pattern) or ilike(type(email, :string), ^pattern))
    )
    |> Ash.Query.sort(name: :asc_nils_last, email: :asc)
    |> Ash.Query.limit(@shown + 1)
    |> Ash.Query.load([:label, :conversation_count, :next_event])
    |> Ash.read(opts)
    |> case do
      {:ok, people} ->
        {:ok,
         %{
           "count" => min(length(people), @shown),
           "more" => length(people) > @shown,
           "people" => people |> Enum.take(@shown) |> Enum.map(&row/1)
         }}

      error ->
        error
    end
  end

  defp row(person) do
    %{
      "ref" => Support.ref(Person, person),
      "name" => Support.text(person.name),
      "email" => Support.text(person.email),
      "conversations" => person.conversation_count,
      "next_event" => Support.text(person.next_event)
    }
    |> Support.compact()
  end
end
