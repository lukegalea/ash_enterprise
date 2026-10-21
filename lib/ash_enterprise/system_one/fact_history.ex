defmodule AshEnterprise.SystemOne.FactHistory do
  @moduledoc """
  What was true about a subject at a point in time (PROD-47).

  `AshEnterprise.SystemOne.Fact` is temporal (ADR 0049; the facts
  temporal-swap): a revision splits a fact's period at the admission's
  `effective_at`, and an omission truncates it. So the facts about a
  subject as of T are an as-of read, and a fact's history is its versions
  (`AshEnterprise.Platform.TemporalHistory`): admitted, revised, withdrawn.

  Every read is the caller's. Fact reads are role-gated (`RoleGrant`), so a
  caller without the grant gets no facts, now or then. The actor is not
  temporal: its grants now decide what the past shows.

  A subject is `%{type: String.t() | nil, id: String.t()}`. A `nil` type
  matches every type, for pages that know an id but not which resource's
  facts name it.
  """

  require Ash.Query

  alias AshEnterprise.Platform.TemporalHistory
  alias AshEnterprise.SystemOne.Fact

  @typedoc "A subject: which record the facts are about."
  @type subject :: %{type: String.t() | nil, id: String.t()}

  @doc """
  The facts about `subject` as of `at` (`nil` for now), by predicate.
  """
  @spec at(subject, DateTime.t() | nil, keyword) :: [Ash.Resource.record()]
  def at(subject, at, opts) do
    subject
    |> query(opts ++ as_of_opt(at))
    |> Ash.Query.sort(predicate: :asc, subject_type: :asc)
    |> Ash.read!()
  end

  @doc """
  The history of the facts about `subject`: every version of every fact
  that is current now or at `opts[:at]`, oldest first, and the moments it
  changed as `AshA2ui.TimeScrubber` marks.
  """
  @spec history(subject, keyword) :: %{
          versions: %{String.t() => [Ash.Resource.record()]},
          marks: [map]
        }
  def history(subject, opts) do
    seeds = at(subject, nil, opts) ++ if(opts[:at], do: at(subject, opts[:at], opts), else: [])

    versions =
      Fact
      |> TemporalHistory.versions(seeds, actor: opts[:actor], tenant: opts[:tenant])
      |> Map.new(fn {id, versions} -> {to_string(id), versions} end)

    marks =
      versions
      |> Map.values()
      |> Enum.flat_map(&marks/1)
      |> Enum.sort_by(& &1.at, DateTime)

    %{versions: versions, marks: marks}
  end

  defp marks([first | _rest] = versions) do
    admitted = %{
      at: TemporalHistory.starts_at(first),
      kind: :admitted,
      label: "Admitted",
      description: "#{first.predicate}: #{render(first)}",
      tone: :primary
    }

    revisions =
      versions
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [before, now] ->
        %{
          at: TemporalHistory.starts_at(now),
          kind: :revised,
          label: "Revised",
          description: "#{now.predicate}: #{render(before)} → #{render(now)}",
          tone: :secondary
        }
      end)

    last = List.last(versions)

    withdrawn =
      case TemporalHistory.ends_at(last) do
        nil ->
          []

        ended ->
          [
            %{
              at: ended,
              kind: :withdrawn,
              label: "Withdrawn",
              description: "#{last.predicate} stopped being known",
              tone: :danger
            }
          ]
      end

    [admitted | revisions] ++ withdrawn
  end

  @doc "A fact's value as one line: the value, and whether it holds."
  @spec render(Ash.Resource.record()) :: String.t()
  def render(fact) do
    value =
      case fact.value do
        nil -> "unknown"
        value when is_binary(value) -> value
        value -> inspect(value)
      end

    case fact.holds do
      true -> "#{value} (holds)"
      false -> "#{value} (does not hold)"
      nil -> value
    end
  end

  defp query(%{type: type, id: id}, opts) do
    query =
      Fact
      |> Ash.Query.for_read(:read, %{}, Keyword.take(opts, [:actor, :tenant, :as_of]))
      |> Ash.Query.filter(subject_id == ^to_string(id))

    if is_binary(type) and type != "",
      do: Ash.Query.filter(query, subject_type == ^type),
      else: query
  end

  defp as_of_opt(nil), do: []
  defp as_of_opt(%DateTime{} = at), do: [as_of: at]
end
