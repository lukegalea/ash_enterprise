defmodule AshEnterprise.Mdm.Resolution do
  @moduledoc """
  Who a person resolved to, and when (PROD-47): the merge and unmerge
  history of one golden person, and the people it was at any instant.

  `AshEnterprise.Mdm.SourceIdentity` is temporal. A merge repoints the
  loser's identities at the survivor, which closes their periods at the
  loser and opens new ones at the survivor; an unmerge repoints them back.
  So "who was this person at T" is an as-of read of the identities that
  ever pointed at them, grouped by the golden each pointed at then. Before
  a merge that is two people; after it, one.

  ## Which identities

  Everything starts from the person, read as the caller: a person the
  caller cannot read has no history here (`{:error, :not_found}`). The
  identities that ever pointed at them are found from:

    * the identities pointing at them now, and at the people merged into
      them now (`master_id`), or at the golden that absorbed them;
    * the people their match candidates paired with them (a people sweep's
      staged row names the person it observed), which is how an identity
      that a merge moved here and an unmerge moved back is still found;

  and then each identity's versions (`AshEnterprise.Platform.TemporalHistory`)
  keep only those that pointed at this person at some instant. Every read is
  the caller's, under the resources' own policies: Person is owner-only,
  SourceIdentity and MatchCandidate are grant-gated.

  ## The actor

  `AshEnterprise.Accounts.User` is not temporal, so the actor is the one
  loaded for the request: its grants now decide what the past shows. This
  module only reads (ADR 0049 invariant 7: no as-of writes on
  policy-sensitive surfaces).

  ## Names are today's

  Person is not temporal: the names shown are the people's current names.
  What changes over time here is who resolved to whom, not what they were
  called.
  """

  require Ash.Query

  alias AshEnterprise.BusinessEvents.Ledger
  alias AshEnterprise.Canonical.Person
  alias AshEnterprise.Mdm.{MatchCandidate, SourceIdentity}
  alias AshEnterprise.Platform.TemporalHistory

  # Identity moves inside this window, with the same kind and the same two
  # people, are one moment: a merge repoints each identity in its own write.
  @same_moment_seconds 5

  @typedoc "A moment on the timeline, in `AshA2ui.TimeScrubber`'s mark shape."
  @type mark :: %{
          at: DateTime.t(),
          kind: :resolved | :merged | :unmerged | :retired | :activity,
          label: String.t(),
          description: String.t(),
          tone: :primary | :secondary | :danger | :neutral
        }

  @typedoc "One person as of an instant: who they were and which identities pointed at them."
  @type resolved :: %{
          id: String.t(),
          label: String.t(),
          readable?: boolean,
          identities: [Ash.Resource.record()]
        }

  @typedoc "A person's resolution history."
  @type t :: %__MODULE__{
          person: Ash.Resource.record(),
          identity_ids: [String.t()],
          histories: %{String.t() => [Ash.Resource.record()]},
          labels: %{String.t() => String.t()},
          marks: [mark],
          from: DateTime.t()
        }

  defstruct [:person, :from, identity_ids: [], histories: %{}, labels: %{}, marks: []]

  @doc """
  The resolution history of the person `id`: the identities that ever
  pointed at them, every version of each, the moments it changed, and
  (`activity?: true`, the default) the person's business events from the
  ledger as context marks.

  Options: `:actor`, `:tenant`, `:activity?`.
  """
  @spec history(String.t(), keyword) :: {:ok, t} | {:error, :not_found}
  def history(id, opts) do
    with {:ok, person} <- fetch_person(id, opts) do
      histories = histories(person, opts)
      identity_ids = Map.keys(histories)
      labels = labels(person, histories, opts)

      marks =
        resolution_marks(person.id, histories, labels) ++
          if(Keyword.get(opts, :activity?, true), do: activity_marks(labels, opts), else: [])

      {:ok,
       %__MODULE__{
         person: person,
         identity_ids: identity_ids,
         histories: histories,
         labels: labels,
         marks: Enum.sort_by(marks, & &1.at, DateTime),
         from: span_start(person, histories, marks)
       }}
    end
  end

  @doc """
  The people `history` resolved to as of `at` (`nil` for now): an as-of read
  of its identities, grouped by the golden each pointed at then, the
  person themself first. Only identities the caller may read are shown.
  """
  @spec as_of(t, DateTime.t() | nil, keyword) :: [resolved]
  def as_of(%__MODULE__{identity_ids: []} = history, _at, _opts),
    do: [resolved(history, history.person.id, [])]

  def as_of(%__MODULE__{} = history, at, opts) do
    ids = history.identity_ids

    SourceIdentity
    |> Ash.Query.for_read(:read, %{}, read_opts(opts) ++ as_of_opt(at))
    |> Ash.Query.filter(id in ^ids)
    |> Ash.Query.sort(source: :asc, stream: :asc, external_id: :asc)
    |> Ash.read!()
    |> Enum.group_by(&to_string(&1.golden_id))
    |> Enum.map(fn {golden_id, identities} -> resolved(history, golden_id, identities) end)
    |> Enum.sort_by(&{&1.id != history.person.id, &1.label})
  end

  @doc """
  A one-call answer for "who was this person as of T": the person's
  history read and the people they resolved to at `at`.
  """
  @spec resolved_at(String.t(), DateTime.t() | nil, keyword) ::
          {:ok, %{history: t, people: [resolved]}} | {:error, :not_found}
  def resolved_at(id, at, opts) do
    with {:ok, history} <- history(id, Keyword.put(opts, :activity?, false)) do
      {:ok, %{history: history, people: as_of(history, at, opts)}}
    end
  end

  # --- the person ---------------------------------------------------------

  defp fetch_person(id, opts) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         {:ok, %Person{} = person} <-
           Person
           |> Ash.Query.for_read(:read, %{}, read_opts(opts))
           |> Ash.Query.filter(id == ^id)
           |> Ash.read_one() do
      {:ok, person}
    else
      _missing_unreadable_or_malformed -> {:error, :not_found}
    end
  end

  # --- which identities ----------------------------------------------------

  defp histories(person, opts) do
    seeds = seed_identities(person, opts)

    SourceIdentity
    |> TemporalHistory.versions(seeds, read_opts(opts))
    |> Map.new(fn {id, versions} -> {to_string(id), versions} end)
    |> Map.filter(fn {_id, versions} -> Enum.any?(versions, &(&1.golden_id == person.id)) end)
  end

  # The identities to walk: those on the person and on everyone a merge or
  # a candidate pair ties to them, read now.
  defp seed_identities(person, opts) do
    goldens = [person.id | related_people(person, opts)] |> Enum.reject(&is_nil/1) |> Enum.uniq()

    SourceIdentity
    |> Ash.Query.for_read(:read, %{}, read_opts(opts))
    |> Ash.Query.filter(golden_id in ^goldens)
    |> Ash.read!()
  end

  defp related_people(person, opts) do
    absorbed =
      Person
      |> Ash.Query.for_read(:read, %{}, read_opts(opts))
      |> Ash.Query.filter(master_id == ^person.id)
      |> Ash.Query.select([:id])
      |> Ash.read!()
      |> Enum.map(& &1.id)

    paired =
      MatchCandidate
      |> Ash.Query.for_read(:read, %{}, read_opts(opts))
      |> Ash.Query.filter(golden_id == ^person.id)
      |> Ash.Query.load(:staged_person_id)
      |> Ash.read!()
      |> Enum.map(& &1.staged_person_id)
      |> Enum.filter(&match?({:ok, _uuid}, Ecto.UUID.cast(&1 || "")))

    [person.master_id | absorbed ++ paired]
  end

  # --- labels --------------------------------------------------------------

  # Every golden the histories mention, by name, as the caller reads them.
  # A golden the caller cannot read is labelled without naming it.
  defp labels(person, histories, opts) do
    ids =
      histories
      |> Map.values()
      |> List.flatten()
      |> Enum.map(& &1.golden_id)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    readable =
      Person
      |> Ash.Query.for_read(:read, %{}, read_opts(opts))
      |> Ash.Query.filter(id in ^ids)
      |> Ash.Query.select([:id, :name, :email])
      |> Ash.read!()
      |> Map.new(&{to_string(&1.id), person_label(&1)})

    Map.put(readable, to_string(person.id), person_label(person))
  end

  defp person_label(%{name: name}) when is_binary(name) and name != "", do: name
  defp person_label(%{email: email}) when not is_nil(email), do: to_string(email)
  defp person_label(_person), do: "Unnamed person"

  defp label(labels, id), do: Map.get(labels, to_string(id), "a record you cannot open")

  defp resolved(history, golden_id, identities) do
    %{
      id: golden_id,
      label: label(history.labels, golden_id),
      readable?: Map.has_key?(history.labels, golden_id),
      identities: identities
    }
  end

  # --- marks ---------------------------------------------------------------

  defp resolution_marks(person_id, histories, labels) do
    histories
    |> Map.values()
    |> Enum.flat_map(&transitions/1)
    |> Enum.sort_by(& &1.at, DateTime)
    |> Enum.chunk_while([], &chunk/2, &flush/1)
    |> Enum.map(&mark(&1, person_id, labels))
  end

  # Each version after the first is a move from the golden before it.
  defp transitions([first | _rest] = versions) do
    opened = %{
      at: TemporalHistory.starts_at(first),
      kind: :resolved,
      from: nil,
      to: first.golden_id,
      identity: first
    }

    moves =
      versions
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.with_index(1)
      |> Enum.reject(fn {[before, now], _index} -> before.golden_id == now.golden_id end)
      |> Enum.map(fn {[before, now], index} ->
        earlier = versions |> Enum.take(index) |> Enum.map(& &1.golden_id)

        kind =
          cond do
            is_nil(now.golden_id) -> :retired
            now.golden_id in earlier -> :unmerged
            true -> :merged
          end

        %{
          at: TemporalHistory.starts_at(now),
          kind: kind,
          from: before.golden_id,
          to: now.golden_id,
          identity: now
        }
      end)

    [opened | moves]
  end

  defp chunk(move, []), do: {:cont, [move]}

  defp chunk(move, [last | _rest] = group) do
    if same_moment?(move, last), do: {:cont, [move | group]}, else: {:cont, group, [move]}
  end

  defp flush([]), do: {:cont, []}
  defp flush(group), do: {:cont, group, []}

  defp same_moment?(a, b) do
    a.kind == b.kind and a.from == b.from and a.to == b.to and
      DateTime.diff(a.at, b.at, :second) <= @same_moment_seconds
  end

  # A group's mark sits at its LAST move, so landing on it shows every
  # identity of the moment already moved.
  defp mark([last | _rest] = group, person_id, labels) do
    count = length(group)
    from = label(labels, last.from)
    to = label(labels, last.to)

    sources =
      group |> Enum.map(& &1.identity.source) |> Enum.uniq() |> Enum.map_join(", ", &to_string/1)

    {label, description, tone} =
      case last.kind do
        :resolved ->
          {"Resolved", "#{identities(count)} (#{sources}) resolved to #{to}", :neutral}

        :merged ->
          {"Merged", "#{from} merged into #{to}: #{identities(count)} moved", :primary}

        :unmerged ->
          {"Unmerged", "#{to} separated from #{from}: #{identities(count)} moved back",
           :secondary}

        :retired ->
          {"Retired", "#{identities(count)} stopped resolving to #{from}", :danger}
      end

    %{
      at: last.at,
      kind: last.kind,
      label: label,
      description: description,
      tone: tone,
      about: person_id
    }
  end

  defp identities(1), do: "1 identity"
  defp identities(count), do: "#{count} identities"

  # --- the ledger, as context ----------------------------------------------

  @activity %{
    "message.received" => "Arrived",
    "message.sent" => "Sent",
    "calendar_event.scheduled" => "Scheduled",
    "calendar_event.changed" => "Moved",
    "calendar_event.cancelled" => "Cancelled"
  }

  @activity_kinds [
    :"message.received",
    :"message.sent",
    :"calendar_event.scheduled",
    :"calendar_event.changed",
    :"calendar_event.cancelled"
  ]

  @activity_limit 60

  # The business events about the people in this history: a message from
  # one of them arrived, a meeting they organize moved. Owner-only rows, so
  # the caller sees their own ledger.
  defp activity_marks(labels, opts) do
    ids = Map.keys(labels)
    kinds = @activity_kinds

    Ledger
    |> Ash.Query.for_read(
      :by_region,
      %{region: AshEnterprise.BusinessEvents.region()},
      read_opts(opts)
    )
    |> Ash.Query.filter(
      action in ^kinds and (data[:sender_id] in ^ids or data[:organizer_id] in ^ids)
    )
    |> Ash.Query.sort(occurred_at: :desc)
    |> Ash.Query.limit(@activity_limit)
    |> Ash.read!()
    |> Enum.map(fn event ->
      kind = to_string(event.action)

      %{
        at: event.occurred_at,
        kind: :activity,
        label: Map.fetch!(@activity, kind),
        description: activity_description(kind),
        tone: :neutral,
        about: nil
      }
    end)
  rescue
    # The ledger is context, not the history: an unreadable ledger leaves
    # the resolution marks standing.
    _error in [Ash.Error.Forbidden, Ash.Error.Invalid] -> []
  end

  defp activity_description("message.received"), do: "A message from them arrived"
  defp activity_description("message.sent"), do: "A message to them went out"

  defp activity_description("calendar_event.scheduled"),
    do: "A meeting they organize was scheduled"

  defp activity_description("calendar_event.changed"), do: "A meeting they organize moved"

  defp activity_description("calendar_event.cancelled"),
    do: "A meeting they organize was cancelled"

  # --- helpers -------------------------------------------------------------

  defp span_start(person, histories, marks) do
    starts =
      Enum.map(marks, & &1.at) ++
        (histories |> Map.values() |> List.flatten() |> Enum.map(&TemporalHistory.starts_at/1))

    case starts do
      [] -> person.created_on || DateTime.add(DateTime.utc_now(), -30, :day)
      instants -> instants |> Enum.min(DateTime) |> DateTime.add(-1, :hour)
    end
  end

  defp read_opts(opts), do: [actor: opts[:actor], tenant: opts[:tenant]]

  defp as_of_opt(nil), do: []
  defp as_of_opt(%DateTime{} = at), do: [as_of: at]
end
