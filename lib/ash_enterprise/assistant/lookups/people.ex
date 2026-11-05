defmodule AshEnterprise.Assistant.Lookups.People do
  @moduledoc """
  `Lookup.Person.find_people`: the person's contacts whose name or address contains
  the query, as `Person.read` returns them to that person (owner-only). A
  merged duplicate (MDM) is left out; its survivor answers for it. At most
  15 people.

  With `as_of` the answer is about that moment (PROD-47): merged records are
  included, because one may have stood alone then, and each person carries
  `records_then`, the separate records their source identities pointed at
  (`AshEnterprise.Mdm.Resolution`, through the same reads the time-travel
  page uses). A bare date means the end of that day, which is what "as of
  last Friday" asks.
  """

  use Ash.Resource.ManualRead

  require Ash.Query

  alias AshEnterprise.Assistant.Lookup
  alias AshEnterprise.Assistant.Lookups.Support
  alias AshEnterprise.Canonical.Person
  alias AshEnterprise.Mdm.Resolution

  @shown 15

  @impl true
  def read(query, _data_layer_query, _opts, context) do
    text = String.trim(query.arguments[:query] || "")

    Support.gated(query, context, fn opts ->
      case Support.as_of(query.arguments[:as_of]) do
        {:ok, as_of} -> search(text, as_of, opts)
        :error -> {:error, "Give as_of as a date (2026-10-16) or a UTC time."}
      end
    end)
  end

  defp search("", _as_of, _opts),
    do: {:error, "Give part of a name or an email address to search for."}

  defp search(query, as_of, opts) do
    pattern = Support.like(query)

    Person
    |> Ash.Query.for_read(:read, %{}, opts)
    |> Ash.Query.filter(ilike(name, ^pattern) or ilike(type(email, :string), ^pattern))
    |> only_goldens(as_of)
    |> Ash.Query.sort(name: :asc_nils_last, email: :asc)
    |> Ash.Query.limit(@shown)
    |> Ash.Query.load([:label, :conversation_count, :next_event])
    |> Ash.read(opts)
    |> case do
      {:ok, people} ->
        {:ok, Enum.map(people, &row(&1, as_of, opts))}

      error ->
        error
    end
  end

  defp only_goldens(query, nil), do: Ash.Query.filter(query, merged == false)
  defp only_goldens(query, _as_of), do: query

  defp row(person, as_of, opts) do
    Support.row(Lookup.Person, %{
      ref: Support.ref(Person, person),
      name: Support.text(person.name),
      email: Support.text(person.email),
      conversations: person.conversation_count,
      next_event: Support.text(person.next_event),
      records_then: as_of && records_then(person, as_of, opts)
    })
  end

  defp records_then(person, as_of, opts) do
    case Resolution.resolved_at(person.id, as_of, opts) do
      {:ok, %{people: people}} ->
        Enum.map(people, &%{"name" => &1.label, "identities" => length(&1.identities)})

      {:error, :not_found} ->
        []
    end
  end
end
