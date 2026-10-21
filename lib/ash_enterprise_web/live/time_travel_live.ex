defmodule AshEnterpriseWeb.TimeTravelLive do
  @moduledoc """
  `/app/time-travel` — what the platform knew, and when (PROD-47).

  Three pages, one LiveView, all read-only and all driven by `?as_of=`
  (`AshA2ui.AsOf`), with `AshA2ui.TimeScrubber` moving the instant:

    * `:index` — pick a golden person (Person's `:goldens` read, as the
      signed-in person), or name any System One subject.
    * `:person` (`/app/time-travel/people/:id`) — who the person resolved
      to as of the instant (`AshEnterprise.Mdm.Resolution`): before a merge
      the scrubber shows two people, after it one. The marks are the
      merges, unmerges and first resolutions, plus their business events
      from the ledger (a message arrived, a meeting moved) as context, and
      the facts known about them (`AshEnterprise.SystemOne.FactHistory`).
    * `:facts` (`/app/time-travel/subjects/:id?type=`) — what was true about
      one subject as of the instant.

  Every read is the signed-in person's, through the resources' own
  policies, so a person they cannot read has no history here either. The
  history (the walk over every version) is read when the page opens a
  subject; scrubbing only re-reads the instant. Data loads in
  `handle_params/3`, never in `mount/3` (iron law #01).
  """

  use AshEnterpriseWeb, :live_view

  require Ash.Query

  alias AshA2ui.{AsOf, TimeScrubber}
  alias AshEnterprise.Canonical.Person
  alias AshEnterprise.Mdm.Resolution
  alias AshEnterprise.Platform.{LocalTime, TemporalHistory}
  alias AshEnterprise.Security.ActorContext
  alias AshEnterprise.SystemOne.FactHistory

  @people_limit 25

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Time travel",
       as_of: nil,
       opened: nil,
       marks: [],
       from: nil,
       to: nil
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    as_of = AsOf.from_params(params)
    socket = assign(socket, as_of: as_of, to: DateTime.utc_now())

    case socket.assigns.live_action do
      :index -> {:noreply, load_index(socket, params)}
      :person -> {:noreply, load_person(socket, params["id"], as_of)}
      :facts -> {:noreply, load_facts(socket, params, as_of)}
    end
  end

  @impl true
  def handle_event("as_of_scrub", params, socket) do
    %{from: from, to: to, marks: marks} = socket.assigns
    at = TimeScrubber.instant(params, from, to, marks)
    {:noreply, push_patch(socket, to: instant_path(socket, at))}
  end

  def handle_event("search", %{"q" => q}, socket) do
    {:noreply, push_patch(socket, to: ~p"/app/time-travel?#{[q: q]}")}
  end

  def handle_event("open_subject", %{"type" => type, "id" => id}, socket) do
    {:noreply, push_patch(socket, to: subject_path(%{type: blank_to_nil(type), id: id}, nil))}
  end

  # --- loading ---------------------------------------------------------------

  defp load_index(socket, params) do
    q = (params["q"] || "") |> String.trim()

    people =
      Person
      |> Ash.Query.for_read(:goldens, %{}, read_opts(socket))
      |> search(q)
      |> Ash.Query.sort(name: :asc)
      |> Ash.Query.limit(@people_limit)
      |> Ash.read!()

    assign(socket, q: q, people: people, opened: nil)
  end

  defp search(query, ""), do: query

  defp search(query, q),
    do: Ash.Query.filter(query, contains(name, ^q) or contains(email, ^q))

  defp load_person(socket, id, as_of) do
    case person_history(socket, id) do
      {:ok, history, facts_history} ->
        opts = read_opts(socket)
        subject = %{type: nil, id: history.person.id}

        assign(socket,
          opened: {:person, id},
          history: history,
          facts_history: facts_history,
          resolved: Resolution.as_of(history, as_of, opts),
          facts: FactHistory.at(subject, as_of, opts),
          marks: Enum.sort_by(history.marks ++ facts_history.marks, & &1.at, DateTime),
          from: earliest(history.from, facts_history.marks)
        )

      {:error, :not_found} ->
        socket
        |> put_flash(:error, "That person isn't one you can open.")
        |> push_navigate(to: ~p"/app/time-travel")
    end
  end

  # The history is read once per opened person; a scrub reuses it.
  defp person_history(%{assigns: %{opened: {:person, id}}} = socket, id),
    do: {:ok, socket.assigns.history, socket.assigns.facts_history}

  defp person_history(socket, id) do
    opts = read_opts(socket)

    with {:ok, history} <- Resolution.history(id, opts) do
      {:ok, history, FactHistory.history(%{type: nil, id: history.person.id}, opts)}
    end
  end

  defp load_facts(socket, params, as_of) do
    subject = %{type: blank_to_nil(params["type"]), id: params["id"] || ""}

    if subject.id == "" do
      push_navigate(socket, to: ~p"/app/time-travel")
    else
      opts = read_opts(socket)
      opened = {:facts, subject}

      facts_history =
        if socket.assigns.opened == opened,
          do: socket.assigns.facts_history,
          else: FactHistory.history(subject, Keyword.put(opts, :at, as_of))

      assign(socket,
        opened: opened,
        subject: subject,
        facts_history: facts_history,
        facts: FactHistory.at(subject, as_of, opts),
        marks: facts_history.marks,
        from: earliest(DateTime.add(DateTime.utc_now(), -30, :day), facts_history.marks)
      )
    end
  end

  defp earliest(from, marks) do
    marks
    |> Enum.map(& &1.at)
    |> Enum.concat([from])
    |> Enum.min(DateTime)
    |> then(&if(&1 == from, do: from, else: DateTime.add(&1, -1, :hour)))
  end

  defp read_opts(socket) do
    actor = socket.assigns.current_user
    [actor: actor, tenant: ActorContext.tenant(actor)]
  end

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value

  # --- paths -----------------------------------------------------------------

  defp instant_path(%{assigns: %{live_action: :person, history: history}}, at),
    do: person_path(history.person.id, at)

  defp instant_path(%{assigns: %{live_action: :facts, subject: subject}}, at),
    do: subject_path(subject, at)

  defp instant_path(_socket, _at), do: ~p"/app/time-travel"

  defp subject_path(%{type: nil, id: id}, at),
    do: AsOf.put_param(~p"/app/time-travel/subjects/#{id}", at)

  defp subject_path(%{type: type, id: id}, at),
    do: AsOf.put_param(~p"/app/time-travel/subjects/#{id}?#{[type: type]}", at)

  defp person_path(id, at), do: AsOf.put_param(~p"/app/time-travel/people/#{id}", at)

  # The golden surface reads its identities at the same instant.
  defp golden_path(id, at), do: AsOf.put_param(~p"/app/mdm/golden?#{[ctx: [person: id]]}", at)

  # --- render ----------------------------------------------------------------

  @impl true
  def render(%{live_action: :index} = assigns) do
    ~H"""
    <Layouts.app flash={@flash} page={assigns[:page]} width="max-w-5xl">
      <section id="time-travel-people" class="space-y-3">
        <h2 class="font-heading text-lg">People</h2>
        <p class="text-sm text-foreground/70">
          Pick a golden record to see who it resolved to, and when: every merge and unmerge, and
          the people it was at any moment.
        </p>
        <form id="time-travel-search" phx-change="search" phx-submit="search" class="max-w-md">
          <.input type="search" name="q" value={@q} label="Find a person" phx-debounce="250" />
        </form>
        <.empty_state :if={@people == []} icon="hero-user">
          No golden records match. People appear here once the people sweep has resolved them.
        </.empty_state>
        <ul :if={@people != []} id="time-travel-people-list" class="grid gap-2 sm:grid-cols-2">
          <li :for={person <- @people}>
            <.link
              id={"time-travel-person-#{person.id}"}
              navigate={person_path(person.id, nil)}
              class="flex items-center justify-between gap-3 rounded-base border-2 border-border bg-secondary-background px-3 py-2 shadow-shadow transition-all hover:shadow-lift"
            >
              <span class="font-heading">{person_label(person)}</span>
              <span class="truncate text-xs text-foreground/70">{person.email}</span>
            </.link>
          </li>
        </ul>
      </section>

      <section id="time-travel-subject" class="space-y-3 pt-6">
        <h2 class="font-heading text-lg">Facts about any subject</h2>
        <p class="text-sm text-foreground/70">
          What System One knew about a record at any moment: each fact as it was admitted, revised
          or withdrawn.
        </p>
        <form
          id="time-travel-subject-form"
          phx-submit="open_subject"
          class="flex flex-wrap items-end gap-3"
        >
          <.input type="text" name="type" value="" label="Subject type (optional)" />
          <.input type="text" name="id" value="" label="Subject id" required />
          <.button type="submit" variant="primary">Open</.button>
        </form>
      </section>
    </Layouts.app>
    """
  end

  def render(%{live_action: :person} = assigns) do
    ~H"""
    <Layouts.app flash={@flash} page={assigns[:page]} width="max-w-5xl">
      <div :if={assigns[:history]} class="space-y-6">
        <div class="flex flex-wrap items-center justify-between gap-3">
          <div>
            <.link navigate={~p"/app/time-travel"} class="text-sm underline">All people</.link>
            <h2 id="time-travel-person" class="font-display text-2xl">
              {person_label(@history.person)}
            </h2>
          </div>
          <.button
            id="time-travel-golden"
            navigate={golden_path(@history.person.id, @as_of)}
            size="sm"
          >
            {if @as_of, do: "Open the golden record at this moment", else: "Open the golden record"}
          </.button>
        </div>

        <TimeScrubber.scrubber
          id="person-timeline"
          from={@from}
          to={@to}
          as_of={@as_of}
          marks={@marks}
          path={&person_path(@history.person.id, &1)}
          format={&LocalTime.stamp/1}
        />

        <section id="time-travel-resolved" class="space-y-3">
          <h3 class="font-heading text-lg">
            {moment(@as_of)}: {people_count(@resolved)}
          </h3>
          <p class="text-sm text-foreground/70">
            Who each source identity pointed at {moment_lower(@as_of)}. Names are today's.
          </p>
          <.empty_state :if={@resolved == []} icon="hero-clock">
            Nothing had resolved to this person yet.
          </.empty_state>
          <div :if={@resolved != []} class="grid gap-3 md:grid-cols-2">
            <.card
              :for={person <- @resolved}
              id={"resolved-#{person.id}"}
              accent={if(person.id == to_string(@history.person.id), do: "main", else: "violet")}
            >
              <div class="flex items-center justify-between gap-2">
                <span class="font-heading">{person.label}</span>
                <.badge :if={person.id == to_string(@history.person.id)} tone="main">
                  This person
                </.badge>
                <.badge :if={person.id != to_string(@history.person.id)} tone="violet">
                  Separate record
                </.badge>
              </div>
              <.empty_state :if={person.identities == []} icon="hero-link-slash">
                No source identity pointed here at this moment.
              </.empty_state>
              <ul :if={person.identities != []} class="mt-2 space-y-1 text-sm">
                <li :for={identity <- person.identities} id={"identity-#{identity.id}"}>
                  <span class="font-heading">{identity.source}</span>
                  <span class="text-foreground/70">{identity.stream}</span>
                  <span class="break-all">{identity.external_id}</span>
                  <span class="text-xs text-foreground/60">
                    since {LocalTime.stamp(TemporalHistory.starts_at(identity))}
                  </span>
                </li>
              </ul>
            </.card>
          </div>
        </section>

        <.facts_section facts={@facts} as_of={@as_of} />
      </div>
    </Layouts.app>
    """
  end

  def render(%{live_action: :facts} = assigns) do
    ~H"""
    <Layouts.app flash={@flash} page={assigns[:page]} width="max-w-5xl">
      <div :if={assigns[:subject]} class="space-y-6">
        <div>
          <.link navigate={~p"/app/time-travel"} class="text-sm underline">Time travel</.link>
          <h2 id="time-travel-subject-heading" class="font-display text-2xl">
            {@subject.type || "Any type"} · <span class="break-all">{@subject.id}</span>
          </h2>
        </div>

        <TimeScrubber.scrubber
          id="facts-timeline"
          from={@from}
          to={@to}
          as_of={@as_of}
          marks={@marks}
          path={&subject_path(@subject, &1)}
          format={&LocalTime.stamp/1}
        />

        <.facts_section facts={@facts} as_of={@as_of} />
      </div>
    </Layouts.app>
    """
  end

  attr :facts, :list, required: true
  attr :as_of, :any, required: true

  defp facts_section(assigns) do
    ~H"""
    <section id="time-travel-facts" class="space-y-3">
      <h3 class="font-heading text-lg">What was true {moment_lower(@as_of)}</h3>
      <.empty_state :if={@facts == []} icon="hero-light-bulb">
        Nothing was known about them {moment_lower(@as_of)}, or you can't read System One facts.
      </.empty_state>
      <.table :if={@facts != []} id="time-travel-facts-table" rows={@facts}>
        <:col :let={fact} label="Fact">{fact.predicate}</:col>
        <:col :let={fact} label="Value">{FactHistory.render(fact)}</:col>
        <:col :let={fact} label="Known since">
          {LocalTime.stamp(TemporalHistory.starts_at(fact))}
        </:col>
        <:col :let={fact} label="Valid until">
          {if fact.valid_until, do: LocalTime.stamp(fact.valid_until), else: "—"}
        </:col>
      </.table>
    </section>
    """
  end

  defp person_label(%{name: name}) when is_binary(name) and name != "", do: name
  defp person_label(%{email: email}) when not is_nil(email), do: to_string(email)
  defp person_label(_person), do: "Unnamed person"

  defp moment(nil), do: "Now"
  defp moment(at), do: "As of #{LocalTime.stamp(at)}"

  defp moment_lower(nil), do: "now"
  defp moment_lower(at), do: "as of #{LocalTime.stamp(at)}"

  defp people_count([]), do: "nobody yet"
  defp people_count([_one]), do: "1 person"
  defp people_count(people), do: "#{length(people)} people"
end
