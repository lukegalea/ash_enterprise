defmodule AshEnterprise.Assistant.History do
  @moduledoc """
  Reading a thread back: for the page, and for the model's next turn.

  Every read is the actor's own (`Thread.read`, `Turn.for_thread`, owner-only
  and self-service), so a thread id from a URL is only a request: another
  person's thread is `:not_found`, never distinguished from one that does
  not exist.

  ## Withheld turns

  A turn whose tool results came from an erasure scope that has since been
  shredded (`Turn.source_scope_ids`) is **withheld**: the page shows that
  it was, not what it said, and it is never sent to the model again. The
  scope statuses are read by the system actor — structural facts (an id and
  `:active`/`:shredded`) about scopes the turn already names; nothing else.
  See `AshEnterprise.Assistant.Thread` for what this does and does not erase.
  """

  require Ash.Query

  alias AshEnterprise.Assistant.{Thread, Turn}
  alias AshEnterprise.Erasure.Scope
  alias AshEnterprise.Platform.SystemActor

  @typedoc "A turn as the page and the runner see it."
  @type entry :: %{turn: Turn.t(), withheld?: boolean()}

  @doc "The actor's thread `id` with its turns, or `{:error, :not_found}`."
  @spec load(String.t(), keyword()) ::
          {:ok, %{thread: Thread.t(), turns: [entry()]}} | {:error, :not_found}
  def load(id, opts) do
    with {:ok, uuid} <- cast(id),
         {:ok, %Thread{} = thread} <-
           Thread.get(uuid, Keyword.put(opts, :not_found_error?, false)),
         {:ok, turns} <- Turn.for_thread(thread.id, opts) do
      {:ok, %{thread: thread, turns: entries(turns)}}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc "The actor's threads, most recently active first."
  @spec threads(keyword()) :: [Thread.t()]
  def threads(opts) do
    case Thread.mine(Keyword.merge(opts, page: [limit: 30], load: [:last_turn_at])) do
      {:ok, %{results: threads}} -> threads
      {:ok, threads} when is_list(threads) -> threads
      _ -> []
    end
  end

  @doc "Turns with `withheld?` decided from their source scopes."
  @spec entries([Turn.t()]) :: [entry()]
  def entries(turns) do
    shredded = shredded(Enum.flat_map(turns, &(&1.source_scope_ids || [])))

    Enum.map(turns, fn turn ->
      %{
        turn: turn,
        withheld?: Enum.any?(turn.source_scope_ids || [], &MapSet.member?(shredded, &1))
      }
    end)
  end

  @doc """
  The prior conversation as model messages: complete, readable turns only,
  the last `max` of them, question and answer text and nothing else (tool
  results are not replayed — the model looks again if it needs to).
  """
  @spec messages([entry()], pos_integer()) :: [ReqLLM.Message.t()]
  def messages(entries, max \\ 12) do
    entries
    |> Enum.filter(&replayable?/1)
    |> Enum.take(-max)
    |> Enum.map(fn %{turn: turn} ->
      case turn.role do
        :user -> ReqLLM.Context.user(text(turn.content))
        :assistant -> ReqLLM.Context.assistant(text(turn.content))
      end
    end)
  end

  defp replayable?(%{withheld?: true}), do: false

  defp replayable?(%{turn: %{status: :complete, content: content}}) when is_binary(content),
    do: String.trim(content) != ""

  defp replayable?(_entry), do: false

  defp text(content) when is_binary(content), do: content
  defp text(_shredded), do: ""

  defp shredded([]), do: MapSet.new()

  defp shredded(ids) do
    ids = Enum.uniq(ids)

    Scope
    |> Ash.Query.filter(id in ^ids and status == :shredded)
    |> Ash.Query.select([:id])
    |> Ash.read!(actor: SystemActor.system())
    |> MapSet.new(& &1.id)
  end

  defp cast(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :not_found}
    end
  end

  defp cast(_id), do: {:error, :not_found}
end
