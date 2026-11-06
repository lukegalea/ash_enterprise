defmodule AshEnterprise.ExecutionSources do
  @moduledoc """
  The registry of execution sources: every kind of record an operator follows a piece of
  work through, each an `AshAgent.Execution.Source`, read in this order by
  `AshEnterprise.Execution.Entry`'s `trace`.

  | Name | Module | Reads |
  |---|---|---|
  | `:run` | `ExecutionSources.Run` | agent runs |
  | `:step` | `ExecutionSources.Step` | their journals |
  | `:model_call` | `ExecutionSources.ModelCall` | model calls |
  | `:invocation` | `ExecutionSources.Invocation` | invocations, their attempts and effects |
  | `:human_task` | `ExecutionSources.HumanTask` | approval and process tasks |
  | `:process_event` | `ExecutionSources.ProcessEvent` | process history |
  | `:evaluation` | `ExecutionSources.Evaluation` | decision evaluations |
  | `:judgment` | `ExecutionSources.Judgment` | the judgment ledger |
  | `:case_result` | `ExecutionSources.CaseResult` | evaluation case results |

  ## How a trace reads them

  A trace starts from a correlation id or one record's reference (`"run:<id>"`,
  `"invocation:<id>"`, `"process_instance:<id>"`). Each source reads, **as the viewer**,
  the rows recorded under the correlation id or pointing at a reference already in the
  trace, and the references of the entries it gives join the trace for the sources after
  it: a run's steps are found through the run, an invocation's approval task through the
  invocation. The order above is what lets each find its rows.

  Each source declares a `limit`, the most rows one trace reads from it, and returns a
  cursor when there are more: a long trace pages, it never becomes one large read. Each
  also has a `timeout`. A source that fails, times out or answers with something that is
  not rows is reported as such (`collect/3`), and is never read as "nothing happened".

  ## Adding a source

  Implement `AshAgent.Execution.Source` (usually with `read/4` below doing the read) and
  add a row to `@sources`, after the sources whose references it needs.
  """

  import Ash.Expr, only: [expr: 1, ref: 1]

  alias AshAgent.Execution.Source
  alias AshEnterprise.ExecutionSources, as: S

  @default_timeout 5_000

  @sources [
    {:run, S.Run, limit: 20},
    {:step, S.Step, limit: 100},
    {:model_call, S.ModelCall, limit: 100},
    {:invocation, S.Invocation, limit: 50},
    {:human_task, S.HumanTask, limit: 50},
    {:process_event, S.ProcessEvent, limit: 200},
    {:evaluation, S.Evaluation, limit: 50},
    {:judgment, S.Judgment, limit: 100},
    {:case_result, S.CaseResult, limit: 50}
  ]

  @typedoc "A registered source: its name, module and options (`limit`, `timeout`)."
  @type source :: {atom(), module(), keyword()}

  @typedoc """
  What a trace learned of one source: `:complete`, `:more` (with the cursor of the next
  page), or why it could not be read (`:failed`, `:timed_out`, `:unanswered`).
  """
  @type report :: %{
          source: atom(),
          status: :complete | :more | :failed | :timed_out | :unanswered,
          cursor: String.t() | nil,
          error: String.t() | nil
        }

  @doc "The registered sources, in the order a trace reads them."
  @spec all() :: [source()]
  def all, do: @sources

  @doc "The names of the registered sources."
  @spec names() :: [atom()]
  def names, do: Enum.map(@sources, &elem(&1, 0))

  @doc """
  Reads `sources` in order for `scope` and returns `{entries, reports}`: every entry they
  gave (each tagged with its source's name), oldest first, and one report per source.

  `opts` carries `:actor` and `:tenant`, read as, and `:cursors`, a map from source name
  (a string or an atom) to the cursor a previous trace returned for it. A source that
  could not be read gives one entry of its own, `:uncertain` and not recorded, so a
  timeline read alone still shows the gap.
  """
  @spec collect([source()], Source.scope(), keyword()) :: {[map()], [report()]}
  def collect(sources, scope, opts) do
    now = DateTime.utc_now()

    {entries, reports, _scope} =
      Enum.reduce(sources, {[], [], scope}, &collect_one(&1, &2, opts, now))

    {Enum.sort_by(entries, & &1.at, DateTime), Enum.reverse(reports)}
  end

  # One source: its entries join the trace and their references widen the scope for the
  # sources after it; a source that could not be read leaves its report and a gap entry.
  defp collect_one({name, module, source_opts}, {entries, reports, scope}, opts, now) do
    read_opts = [
      actor: opts[:actor],
      tenant: opts[:tenant],
      limit: Keyword.fetch!(source_opts, :limit),
      after: cursor(opts[:cursors], name)
    ]

    case run(module, scope, read_opts, Keyword.get(source_opts, :timeout, @default_timeout)) do
      {:ok, new, next} ->
        new = Enum.map(new, &Map.put(&1, :source, name))
        status = if next, do: :more, else: :complete
        report = %{source: name, status: status, cursor: next, error: nil}
        {entries ++ new, [report | reports], widen(scope, new)}

      {status, reason} ->
        report = %{source: name, status: status, cursor: nil, error: reason}
        {entries ++ [unread(name, status, reason, now)], [report | reports], scope}
    end
  end

  # The read and the mapping run in a task the trace waits on for at most `timeout`. An
  # exception, an exit or an answer that is not rows is the source's failure.
  defp run(module, scope, read_opts, timeout) do
    task =
      Task.async(fn ->
        try do
          answer(module, module.read(scope, read_opts))
        rescue
          error -> {:failed, Exception.message(error)}
        catch
          kind, reason -> {:failed, Exception.format_banner(kind, reason)}
        end
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      {:exit, reason} -> {:failed, Exception.format_exit(reason)}
      nil -> {:timed_out, "no answer within #{timeout} ms"}
    end
  end

  defp answer(module, {:ok, rows, next})
       when is_list(rows) and (is_nil(next) or is_binary(next)),
       do: {:ok, module.to_entries(rows), next}

  defp answer(_module, {:error, error}), do: {:failed, describe(error)}
  defp answer(_module, other), do: {:unanswered, "answered #{inspect(other, limit: 3)}"}

  defp describe(error) when is_exception(error), do: Exception.message(error)
  defp describe(error), do: inspect(error, limit: 5)

  defp unread(name, status, reason, now) do
    [
      at: now,
      kind: :observation,
      status: :uncertain,
      source_ref: Source.ref(:source, name),
      recorded?: false,
      summary: "#{name} not read (#{status}): #{reason}"
    ]
    |> Source.entry()
    |> Map.put(:source, name)
  end

  defp cursor(nil, _name), do: nil

  defp cursor(cursors, name),
    do: Map.get(cursors, name) || Map.get(cursors, Atom.to_string(name))

  defp widen(scope, entries) do
    refs =
      for entry <- entries, ref <- [entry.source_ref, entry.parent_ref], is_binary(ref), do: ref

    %{scope | refs: Enum.into(refs, scope.refs)}
  end

  @doc """
  Reads `resource`'s rows that match one of `matches` through its primary read action,
  as `opts[:actor]` in `opts[:tenant]`, oldest first by `:time` (default `:created_on`)
  and then id, at most `opts[:limit]` after `opts[:after]`, loading `:load`. `matches` is
  a list of `{field, values}`; a field with no values matches nothing, and with no values
  at all nothing is read. `{:ok, rows, next_cursor}` or `{:error, error}`.
  """
  @spec read(Ash.Resource.t(), [{atom(), [term()]}], keyword(), keyword()) ::
          {:ok, [Ash.Resource.record()], String.t() | nil} | {:error, term()}
  def read(resource, matches, opts, read_opts \\ []) do
    time = Keyword.get(read_opts, :time, :created_on)

    matches =
      for {field, values} <- matches,
          values = Enum.uniq(values),
          values != [],
          do: {field, values}

    with [_ | _] <- matches,
         query = Ash.Query.load(base(resource, matches, time, opts), read_opts[:load] || []),
         {:ok, query} <- after_cursor(query, time, opts[:after]),
         {:ok, rows} <- Ash.read(Ash.Query.limit(query, opts[:limit] + 1)) do
      page(rows, opts[:limit], time)
    else
      [] -> {:ok, [], nil}
      {:error, error} -> {:error, error}
    end
  end

  defp base(resource, [{field, values} | rest], time, opts) do
    condition =
      Enum.reduce(rest, expr(^ref(field) in ^values), fn {field, values}, acc ->
        expr(^acc or ^ref(field) in ^values)
      end)

    resource
    |> Ash.Query.for_read(:read, %{}, actor: opts[:actor], tenant: opts[:tenant])
    |> Ash.Query.do_filter(condition)
    |> Ash.Query.sort([{time, :asc}, {:id, :asc}])
  end

  defp after_cursor(query, _time, nil), do: {:ok, query}

  defp after_cursor(query, time, cursor) do
    with [at, id] <- String.split(cursor, "|", parts: 2),
         {:ok, at, 0} <- DateTime.from_iso8601(at),
         {:ok, id} <- Ecto.UUID.cast(id) do
      {:ok,
       Ash.Query.do_filter(
         query,
         expr(^ref(time) > ^at or (^ref(time) == ^at and id > ^id))
       )}
    else
      _ -> {:error, "unreadable cursor"}
    end
  end

  defp page(rows, limit, time) when length(rows) > limit do
    rows = Enum.take(rows, limit)
    last = List.last(rows)
    {:ok, rows, "#{DateTime.to_iso8601(Map.fetch!(last, time))}|#{last.id}"}
  end

  defp page(rows, _limit, _time), do: {:ok, rows, nil}

  @doc "The ids of `scope`'s references of `type` that are UUIDs."
  @spec uuids(Source.scope(), atom()) :: [Ecto.UUID.t()]
  def uuids(scope, type) do
    for id <- Source.ids(scope, type), {:ok, uuid} <- [Ecto.UUID.cast(id)], do: uuid
  end

  @doc "`scope`'s correlation id, as a list for `read/4` (empty without one)."
  @spec correlation(Source.scope()) :: [String.t()]
  def correlation(%{correlation_id: id}) when is_binary(id) and id != "", do: [id]
  def correlation(_scope), do: []

  @doc "Who a principal (an `executing_principal`) is, for an entry's `actor_label`."
  @spec principal_label(map() | nil) :: String.t() | nil
  def principal_label(nil), do: nil

  def principal_label(principal) do
    case AshAgent.ExecutionIdentity.identity(principal) do
      {"person", id, _, _} -> "person:#{id}"
      {"automation", name, nil, _} -> "automation:#{name}"
      {"automation", name, person, _} -> "automation:#{name} for person:#{person}"
      _other -> nil
    end
  end

  @doc "A person, by user id, for an entry's `actor_label`."
  @spec person_label(Ecto.UUID.t() | nil) :: String.t() | nil
  def person_label(nil), do: nil
  def person_label(id), do: "person:#{id}"
end
