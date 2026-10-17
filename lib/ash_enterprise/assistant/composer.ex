defmodule AshEnterprise.Assistant.Composer do
  @moduledoc """
  Turns the assistant's small `compose_surface` request into an
  `AshA2ui.Dynamic` spec, and resolves it against the composer's allowlist.

  ## Why a small request and not the whole spec

  `AshA2ui.Dynamic.spec_schema/1` is the full DSL vocabulary — forms,
  contexts, nested forms, `via` delegates — and the resources' descriptions
  list every system attribute. That is far more than a ~27B model should be
  asked to fill in, and most of it (forms, row actions) has no business in a
  read-only chat. So the model names *what* to show and *how* (a table, a
  calendar, a board) with a handful of options, and this module writes the
  spec from a curated catalogue: per source, the columns worth showing, the
  read action, the date fields a calendar places by and the enumerated
  attribute a board's lanes split on.

  The spec it writes is then resolved exactly as any composed spec is
  (`AshA2ui.Dynamic.resolve/2`): the allowlist, the parser, the compile-time
  verifiers, the composed-board cell cap. A request this module cannot turn
  into a spec, or a spec the server refuses, comes back as short reasons the
  model can act on.

  ## Read-only, as the person

  No spec written here has a form, a row action or a bulk action, so a
  composed surface can only show rows. It is built with the person as actor
  (`authorize?: true`): the rows are the ones their policies allow, decided
  when the surface is built and again on every refresh.

  ## Structural only

  The spec carries resource, field, read-action and lane names from the
  catalogue below — never text from the request. The model's title is shown
  in the chat; a pinned app's title is derived from the spec
  (`structural_title/1`), so a stored spec quotes nothing.
  """

  alias AshEnterprise.Agents.MorningBrief
  alias AshEnterprise.Assistant.ReplyDraft
  alias AshEnterprise.Bpmn.HumanTask
  alias AshEnterprise.Canonical.{CalendarEvent, Conversation, Message, Person, Task}

  @displays ~w(table calendar board)
  @table_windows ~w(today tomorrow this_week upcoming)

  @catalogue %{
    "events" => %{
      resource: CalendarEvent,
      label: "Calendar events",
      columns: ~w(title when location organizer_label status attendee_count),
      default: ~w(title when location organizer_label),
      read: "read",
      windows: Map.new(@table_windows, &{&1, &1}),
      dates: {"starts_at", "ends_at"},
      lanes: ~w(status),
      sort: {"starts_at", "asc"},
      sortable: ~w(starts_at)
    },
    "tasks" => %{
      resource: Task,
      label: "Tasks",
      columns: ~w(title due_at status source),
      default: ~w(title due_at status),
      read: "mine",
      dates: {"due_at", nil},
      labels: %{"due_at" => "Due"},
      lanes: ~w(status),
      statuses: ~w(open done cancelled),
      sort: {"due_at", "asc"},
      sortable: ~w(due_at)
    },
    "conversations" => %{
      resource: Conversation,
      label: "Conversations",
      columns: ~w(subject latest_message last_activity message_count kind_label),
      default: ~w(subject latest_message last_activity message_count),
      read: "read",
      sources: %{"gmail" => "gmail", "slack" => "slack"},
      lanes: ~w(kind),
      sort: {"last_message_at", "desc"},
      sortable: ~w(last_message_at message_count)
    },
    "messages" => %{
      resource: Message,
      label: "Messages",
      columns: ~w(sent sender_label preview direction),
      default: ~w(sent sender_label preview),
      read: "read",
      dates: {"sent_at", nil},
      lanes: ~w(direction),
      sort: {"sent_at", "desc"},
      sortable: ~w(sent_at)
    },
    "people" => %{
      resource: Person,
      label: "People",
      columns:
        ~w(label email next_event conversation_count sent_message_count organized_event_count),
      default: ~w(label email next_event conversation_count),
      read: "read",
      search: ~w(name email),
      sort: {"name", "asc"},
      sortable: ~w(name email conversation_count sent_message_count)
    },
    "briefs" => %{
      resource: MorningBrief,
      label: "Morning briefs",
      columns: ~w(brief_date headline status summary),
      default: ~w(brief_date headline status),
      read: "read",
      dates: {"brief_date", nil},
      lanes: ~w(status),
      sort: {"brief_date", "desc"},
      sortable: ~w(brief_date)
    },
    "approvals" => %{
      resource: HumanTask,
      label: "Approvals",
      columns: ~w(name subject_label waiting_since status due_at),
      default: ~w(name subject_label waiting_since),
      read: "awaiting_me",
      dates: {"due_at", nil},
      labels: %{"due_at" => "Due", "subject_label" => "Subject"},
      lanes: ~w(status),
      sort: nil,
      sortable: []
    },
    "drafts" => %{
      resource: ReplyDraft,
      label: "Reply drafts",
      columns: ~w(conversation_subject body created_on),
      default: ~w(conversation_subject body created_on),
      labels: %{"conversation_subject" => "Conversation", "created_on" => "Drafted"},
      read: "mine",
      sort: {"created_on", "desc"},
      sortable: ~w(created_on)
    }
  }

  @sources @catalogue |> Map.keys() |> Enum.sort()

  @typedoc "A composed surface, ready to build as the person."
  @type composed :: %{
          request: map(),
          spec: map(),
          surface: AshA2ui.Dynamic.Surface.t(),
          title: String.t(),
          notes: [String.t()]
        }

  @doc "What the compose tool can show, in the order its schema lists them."
  @spec sources() :: [String.t()]
  def sources, do: @sources

  @doc "The displays a surface may use."
  @spec displays() :: [String.t()]
  def displays, do: @displays

  @doc """
  The resources a composed spec may name: the host allowlist, keyed by the
  composer's source names. Configuration, never input.
  """
  @spec allowlist() :: %{String.t() => module()}
  def allowlist do
    @catalogue
    |> Map.new(fn {name, entry} -> {name, entry.resource} end)
    |> AshA2ui.Dynamic.allowlist()
  end

  @doc """
  Composes `request` (the tool's arguments, string or atom keys) into a
  resolved surface: `{:ok, composed}` or `{:error, [reason]}`.

  `opts`: `:surface_id` (default: a fresh one).
  """
  @spec compose(map(), keyword()) :: {:ok, composed()} | {:error, [String.t()]}
  def compose(request, opts \\ []) do
    request = normalize(request)

    with {:ok, entry} <- source(request),
         {:ok, display} <- display(request),
         {:ok, spec, notes} <- spec(request, entry, display),
         {:ok, surface} <- resolve(spec, opts) do
      {:ok,
       %{
         request: request,
         spec: spec,
         surface: surface,
         title: request["title"] || spec["title"],
         notes: notes
       }}
    end
  end

  @doc """
  Resolves a stored spec (`AshA2ui.Dynamic.serialize/1` form) again, against
  the allowlist as it is now. `{:ok, surface}` or `{:error, [reason]}`.
  """
  @spec reload(String.t(), keyword()) ::
          {:ok, AshA2ui.Dynamic.Surface.t()} | {:error, [String.t()]}
  def reload(serialized, opts \\ []) when is_binary(serialized) do
    resolve_opts = Keyword.put(Keyword.take(opts, [:surface_id]), :allowlist, allowlist())

    case AshA2ui.Dynamic.deserialize(serialized, resolve_opts) do
      {:ok, surface} -> {:ok, surface}
      {:error, errors} -> {:error, AshA2ui.Dynamic.Error.messages(errors)}
    end
  end

  @doc "A title for a spec, from its structure only (for a pinned app)."
  @spec structural_title(map()) :: String.t()
  def structural_title(%{"show" => show} = request) do
    label = @catalogue |> Map.fetch!(show) |> Map.fetch!(:label)

    [label, display_label(request["display"]), window_label(request["window"])]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  # -- the request --------------------------------------------------------------

  # String keys, trimmed strings, blanks dropped, so a request compares and
  # stores the same whichever way it arrived.
  defp normalize(request) do
    request
    |> Map.new(fn {key, value} -> {to_string(key), clean(value)} end)
    |> Map.reject(fn {_key, value} -> value in [nil, "", []] end)
    |> Map.take(~w(show display columns window status channel group_by title))
  end

  defp clean(value) when is_binary(value), do: String.trim(value)
  defp clean(value) when is_atom(value) and not is_nil(value), do: Atom.to_string(value)
  defp clean(values) when is_list(values), do: values |> Enum.map(&clean/1) |> Enum.uniq()
  defp clean(value), do: value

  defp source(%{"show" => show}) do
    case Map.fetch(@catalogue, show) do
      {:ok, entry} -> {:ok, entry}
      :error -> {:error, ["show must be one of: #{Enum.join(@sources, ", ")}"]}
    end
  end

  defp source(_request), do: {:error, ["show is required: #{Enum.join(@sources, ", ")}"]}

  defp display(request) do
    display = Map.get(request, "display", "table")

    if display in @displays,
      do: {:ok, display},
      else: {:error, ["display must be one of: #{Enum.join(@displays, ", ")}"]}
  end

  # -- writing the spec -----------------------------------------------------------

  defp spec(request, entry, display) do
    {columns, notes} = columns(request, entry)

    with {:ok, component, query, notes} <-
           component(display, request, entry, columns, notes) do
      spec =
        %{
          "resource" => request["show"],
          "title" => structural_title(Map.put(request, "display", display)),
          "components" => [component],
          "queries" => [query]
        }
        |> put_present("fields", field_overrides(entry, columns))

      {:ok, spec, notes}
    end
  end

  defp columns(request, entry) do
    asked = List.wrap(request["columns"])
    {known, unknown} = Enum.split_with(asked, &(&1 in entry.columns))

    notes =
      if unknown == [],
        do: [],
        else: [
          "ignored unknown columns #{Enum.join(unknown, ", ")}; " <>
            "#{request["show"]} has #{Enum.join(entry.columns, ", ")}"
        ]

    {if(known == [], do: entry.default, else: Enum.take(known, 6)), notes}
  end

  defp component("calendar", request, entry, columns, notes) do
    case Map.get(entry, :dates) do
      {date_field, end_field} ->
        component =
          %{
            "kind" => "table",
            "display" => "calendar",
            "fields" => columns,
            "read_action" => read_action(request, entry),
            "date_field" => date_field,
            "granularity" => granularity(request["window"], request["show"]),
            "query" => "rows"
          }
          |> put_present("end_date_field", end_field)

        query = %{"name" => "rows", "page_size" => 100} |> with_filter(request, entry)
        {:ok, component, query, notes}

      nil ->
        {:error, ["#{request["show"]} have no date to place on a calendar; use a table"]}
    end
  end

  defp component("board", request, entry, columns, notes) do
    lanes = Map.get(entry, :lanes, [])
    lane = request["group_by"] || List.first(lanes)

    cond do
      lanes == [] ->
        {:error, ["#{request["show"]} have nothing to split into board lanes; use a table"]}

      lane not in lanes ->
        {:error, ["a #{request["show"]} board splits by #{Enum.join(lanes, ", ")}"]}

      true ->
        values = lane_values(entry, lane, request)
        [title | meta] = columns

        component = %{
          "kind" => "table",
          # A board is headed by its component's name.
          "name" => request["show"],
          "display" => "board",
          "fields" => columns,
          "read_action" => read_action(request, entry),
          "query" => "rows",
          "row_layout" => %{"title" => title, "meta" => Enum.take(meta, 3)},
          "sections" => %{
            "scope_by" => lane,
            "values" => values,
            "labels" => Map.new(values, &{&1, humanize(&1)})
          }
        }

        query = %{"name" => "rows", "page_size" => 10} |> with_sort(entry)
        {:ok, component, query, notes}
    end
  end

  defp component("table", request, entry, columns, notes) do
    {read, notes} = table_read(request, entry, notes)

    component = %{
      "kind" => "table",
      "fields" => columns,
      "read_action" => read,
      "query" => "rows"
    }

    query =
      %{"name" => "rows", "page_size" => 25}
      |> with_sort(entry)
      |> with_filter(request, entry)
      |> put_present("search_fields", Map.get(entry, :search))

    {:ok, component, query, notes}
  end

  # Events have windowed read actions; nothing else is cut by a window in a
  # table (the calendar reads its own visible window).
  defp table_read(%{"window" => window} = request, %{windows: windows} = entry, notes) do
    case Map.fetch(windows, window) do
      {:ok, read} ->
        {read, notes}

      :error ->
        {read_action(request, entry),
         notes ++
           [
             "an events table can be cut to #{Enum.join(@table_windows, ", ")}; " <>
               "showing all events, soonest first (or use display calendar)"
           ]}
    end
  end

  defp table_read(%{"window" => _window} = request, entry, notes),
    do:
      {read_action(request, entry),
       notes ++ ["#{request["show"]} tables are not cut by a window; showing newest first"]}

  defp table_read(request, entry, notes), do: {read_action(request, entry), notes}

  # Conversations by channel go through the Gmail and Slack read actions.
  defp read_action(%{"channel" => channel}, %{sources: sources} = entry),
    do: Map.get(sources, channel, entry.read)

  defp read_action(_request, entry), do: entry.read

  # Tasks by status: a preset the table opens on (`any` shows them all).
  defp with_filter(query, %{"status" => status}, %{statuses: statuses})
       when status in ["open", "done", "cancelled"] do
    if status in statuses do
      Map.merge(query, %{
        "presets" => [%{"name" => status, "filter" => %{"status" => status}}],
        "default_preset" => status
      })
    else
      query
    end
  end

  defp with_filter(query, _request, _entry), do: query

  defp with_sort(query, %{sort: {field, direction}, sortable: sortable}) do
    query
    |> Map.put("default_sort", [%{"field" => field, "direction" => direction}])
    |> Map.put("sortable", sortable)
  end

  defp with_sort(query, _entry), do: query

  defp lane_values(%{statuses: statuses}, "status", %{"status" => status})
       when status in ["open", "done", "cancelled"],
       do: if(status in statuses, do: [status], else: statuses)

  defp lane_values(entry, lane, _request) do
    entry.resource
    |> Ash.Resource.Info.attribute(String.to_existing_atom(lane))
    |> enum_values()
    |> Enum.map(&to_string/1)
    |> Enum.take(AshA2ui.Dynamic.max_composed_cells())
  end

  defp enum_values(%{constraints: constraints}), do: Keyword.get(constraints, :one_of, [])

  # Labels from the catalogue, and datetime columns shown as dates rather
  # than raw timestamps.
  defp field_overrides(entry, columns) do
    labels = Map.get(entry, :labels, %{})

    columns
    |> Enum.flat_map(fn column ->
      override =
        %{}
        |> put_present("label", labels[column])
        |> put_present("format", if(datetime?(entry.resource, column), do: "date"))

      if override == %{}, do: [], else: [Map.put(override, "name", column)]
    end)
    |> case do
      [] -> nil
      overrides -> overrides
    end
  end

  defp datetime?(resource, column) do
    case Ash.Resource.Info.attribute(resource, String.to_existing_atom(column)) do
      %{type: type} -> type in [Ash.Type.UtcDatetimeUsec, Ash.Type.UtcDatetime, Ash.Type.DateTime]
      nil -> false
    end
  end

  defp granularity(window, _source) when window in ["today", "tomorrow"], do: "day"

  defp granularity(window, _source) when window in ["this_week", "next_7_days", "upcoming"],
    do: "week"

  defp granularity(_window, "events"), do: "week"
  defp granularity(_window, _source), do: "month"

  defp resolve(spec, opts) do
    resolve_opts = Keyword.put(Keyword.take(opts, [:surface_id]), :allowlist, allowlist())

    case AshA2ui.Dynamic.resolve(spec, resolve_opts) do
      {:ok, surface} -> {:ok, surface}
      {:error, errors} -> {:error, AshA2ui.Dynamic.Error.messages(errors)}
    end
  end

  # -- labels ------------------------------------------------------------------------

  defp display_label("calendar"), do: "calendar"
  defp display_label("board"), do: "board"
  defp display_label(_table), do: nil

  defp window_label(nil), do: nil

  defp window_label(window) when window in @table_windows,
    do: humanize(window) |> String.downcase()

  defp window_label(_other), do: nil

  defp humanize(value), do: value |> String.replace("_", " ") |> String.capitalize()

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
