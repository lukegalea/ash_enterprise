defmodule AshEnterprise.Planning.Backend.Fake do
  @moduledoc false
  # Deterministic backend double for CI/tests: no minizinc, no processes beyond
  # one Agent per session. Behaviour is scripted from the problem's `data`
  # (atom or string keys):
  #
  #   * `:fake_candidates` — list of assignment maps (default `[%{}]`)
  #   * `:fake_outcome`    — `:optimal` (default) | `:feasible` (timeout, incomplete)
  #                          | `:infeasible` | `:unknown` | `{:error, kind}`
  #   * `:fake_objective`  — `Decimal`/integer attached to every candidate (default nil)
  #   * `:fake_status_script` — list of `%{stage:, solution_count:}` returned one per
  #                          `status/1` call, last entry repeats (default compiling → solving)
  #
  # `cancel/1` flips the session to a stopped outcome (`:unknown`/`:feasible`,
  # `outcome_reason: :stopped`) exactly like a real graceful stop.

  @behaviour AshEnterprise.Planning.Backend

  alias AshEnterprise.Planning.Backend
  alias AshEnterprise.Planning.Backend.{Error, SolveResult}

  @impl true
  def capabilities, do: Map.new(Backend.capability_keys(), &{&1, true})

  @impl true
  def start(problem, _opts) do
    data = fetch(problem, :data) || %{}

    script =
      fetch(data, :fake_status_script) ||
        [%{stage: :compiling, solution_count: 0}, %{stage: :solving, solution_count: 1}]

    case fetch(data, :fake_outcome) || :optimal do
      {:error, kind} ->
        {:error, %Error{kind: kind, message: "fake_error"}}

      outcome ->
        {:ok, agent} =
          Agent.start(fn ->
            %{
              outcome: outcome,
              candidates: build_candidates(data),
              script: script,
              cancelled?: false,
              done?: false
            }
          end)

        {:ok, %{agent: agent}}
    end
  end

  @impl true
  def await(%{agent: agent}, _timeout) do
    Agent.get_and_update(agent, fn s -> {{:ok, result(s)}, %{s | done?: true}} end)
  catch
    :exit, _ -> {:error, %Error{kind: :backend_crashed, message: "fake_session_gone"}}
  end

  @impl true
  def status(%{agent: agent}) do
    Agent.get_and_update(agent, fn
      %{done?: true} = s ->
        {{:error, :not_running}, s}

      %{script: [one]} = s ->
        {{:ok, Map.put(one, :running_time_ms, 0)}, s}

      %{script: [head | rest]} = s ->
        {{:ok, Map.put(head, :running_time_ms, 0)}, %{s | script: rest}}
    end)
  catch
    :exit, _ -> {:error, :not_running}
  end

  @impl true
  def cancel(%{agent: agent}) do
    Agent.get_and_update(agent, fn
      %{done?: true} = s -> {{:error, :not_running}, s}
      s -> {:ok, %{s | cancelled?: true}}
    end)
  catch
    :exit, _ -> {:error, :not_running}
  end

  defp result(%{cancelled?: true, candidates: cands}) do
    %SolveResult{
      status: if(cands == [], do: :unknown, else: :feasible),
      complete?: false,
      outcome_reason: :stopped,
      payload: %{candidates: cands},
      stats: %{solution_count: length(cands)}
    }
  end

  defp result(%{outcome: :infeasible}),
    do: %SolveResult{status: :infeasible, complete?: true, outcome_reason: :unsat}

  defp result(%{outcome: :unknown}),
    do: %SolveResult{status: :unknown, outcome_reason: :time_limit}

  defp result(%{outcome: :feasible, candidates: cands}) do
    %SolveResult{
      status: :feasible,
      complete?: false,
      outcome_reason: :time_limit,
      payload: %{candidates: cands},
      stats: %{solution_count: length(cands)}
    }
  end

  defp result(%{outcome: :optimal, candidates: cands}) do
    %SolveResult{
      status: :feasible,
      complete?: true,
      optimality: :proven,
      outcome_reason: :normal,
      payload: %{candidates: cands},
      stats: %{solution_count: length(cands)}
    }
  end

  defp build_candidates(data) do
    objective =
      case fetch(data, :fake_objective) do
        nil -> nil
        %Decimal{} = d -> d
        i when is_integer(i) -> Decimal.new(i)
      end

    (fetch(data, :fake_candidates) || [%{}])
    |> Enum.with_index(1)
    |> Enum.map(fn {assignments, index} ->
      %{
        index: index,
        data: assignments,
        objective: objective,
        checker_output: nil,
        checker_ok?: nil
      }
    end)
  end

  defp fetch(%{} = map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp fetch(list, key) when is_list(list), do: Keyword.get(list, key)
  defp fetch(_other, _key), do: nil
end
