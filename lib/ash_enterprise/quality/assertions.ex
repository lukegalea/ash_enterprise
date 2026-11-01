defmodule AshEnterprise.Quality.Assertions do
  @moduledoc """
  The deterministic scorer (ADR 0058): what a case's assertions say about its run.

  The vocabulary is closed (`vocabulary/0`). Each assertion reads only what the run
  recorded, never a model:

  | Assertion | Passes when | Hard |
  |---|---|---|
  | `tool_called` | the model called the tool for `target` | |
  | `tool_not_called` | it never did | yes |
  | `args_match` | an invocation of `target` had at least `args` | |
  | `prohibited_effect` | no invocation of `target` was requested at all | yes |
  | `approval_requested` | an invocation of `target` would have asked for an approval | |
  | `max_steps` | the run made at most `limit` model calls | |
  | `within_budget` | the run never ran out of tokens | yes |
  | `schema_valid` | the run completed: its answer cast to the version's output type | yes |
  | `output_matches` | the answer holds every key of `expected` with the same value | |
  | `process_transition`, `cites` | not measured yet: reported `unmeasured` | |

  A hard assertion that fails fails its case whatever else passes, and blocks a release
  regardless of any average (`hard?/1`). `prohibited_effect` is a query over the run's
  invocations, which exist for every call that is not a read even though, in a run that
  is not live, none of them runs (`AshEnterprise.Execution.Invocation`): it measures
  what the agent tried to do.

  An answer that is not a map is read as `%{"value" => answer}` by `output_matches`.
  Tools are named by target; the model's name for one is
  `AshAgent.Run.Toolset.tool_name/2`.
  """

  alias AshAgent.Invocation.Target
  alias AshAgent.Run.Toolset

  @vocabulary [
    :tool_called,
    :tool_not_called,
    :args_match,
    :prohibited_effect,
    :approval_requested,
    :max_steps,
    :within_budget,
    :process_transition,
    :schema_valid,
    :output_matches,
    :cites
  ]

  @hard [:prohibited_effect, :tool_not_called, :schema_valid, :within_budget]
  @needs_target [
    :tool_called,
    :tool_not_called,
    :args_match,
    :prohibited_effect,
    :approval_requested
  ]

  @typedoc """
  What a case's run recorded: the run row, the names of every tool the model called, its
  invocations (`target`, `args`, `approval_mode`) and its answer.
  """
  @type observed :: %{
          run: map(),
          tool_names: MapSet.t(String.t()),
          invocations: [%{target: String.t(), args: map(), approval_mode: atom()}],
          answer: term()
        }

  @doc "The closed assertion vocabulary."
  @spec vocabulary() :: [atom()]
  def vocabulary, do: @vocabulary

  @doc "Whether a failure of `type` fails its case and blocks a release whatever else passes."
  @spec hard?(atom()) :: boolean()
  def hard?(type), do: type in @hard

  @doc "What `assertion` lacks to be measured, as messages; `[]` when nothing."
  @spec problems(map()) :: [String.t()]
  def problems(%{type: type} = assertion) do
    [
      (type in @needs_target and blank?(assertion[:target])) && "#{type} needs a target",
      (type == :args_match and empty?(assertion[:args])) && "args_match needs args",
      (type == :max_steps and is_nil(assertion[:limit])) && "max_steps needs a limit",
      (type == :output_matches and empty?(assertion[:expected])) &&
        "output_matches needs expected"
    ]
    |> Enum.filter(&is_binary/1)
  end

  @doc """
  The result of `assertion` on `observed`: `%{"type", "hard", "status", "detail"}`,
  `status` one of `"passed"`, `"failed"` and `"unmeasured"`.
  """
  @spec evaluate(map(), observed()) :: %{String.t() => term()}
  def evaluate(%{type: type} = assertion, observed) do
    {status, detail} = measure(type, assertion, observed)

    %{
      "type" => Atom.to_string(type),
      "target" => assertion[:target],
      "hard" => hard?(type),
      "status" => Atom.to_string(status),
      "detail" => detail
    }
  end

  defp measure(:tool_called, %{target: target}, observed) do
    case tool_name(target) do
      {:ok, name} -> verdict(MapSet.member?(observed.tool_names, name), "called #{name}")
      :error -> {:unmeasured, "#{target} is not a declared target"}
    end
  end

  defp measure(:tool_not_called, %{target: target}, observed) do
    case tool_name(target) do
      {:ok, name} ->
        verdict(not MapSet.member?(observed.tool_names, name), "never called #{name}")

      :error ->
        {:unmeasured, "#{target} is not a declared target"}
    end
  end

  defp measure(:args_match, %{target: target, args: args}, observed) do
    observed
    |> calls(target)
    |> Enum.any?(&subset?(stringify(args), &1.args || %{}))
    |> verdict("a call of #{target} had the arguments")
  end

  defp measure(:prohibited_effect, %{target: target}, observed) do
    verdict(calls(observed, target) == [], "no call of #{target} was requested")
  end

  defp measure(:approval_requested, %{target: target}, observed) do
    observed
    |> calls(target)
    |> Enum.any?(&(&1.approval_mode not in [nil, :none]))
    |> verdict("a call of #{target} asked for an approval")
  end

  defp measure(:max_steps, %{limit: limit}, %{run: run}) do
    verdict(run.step_count <= limit, "#{run.step_count} model calls, at most #{limit}")
  end

  defp measure(:within_budget, _assertion, %{run: run}) do
    verdict(run.error_code != "token_budget" and run.blocked_on != :budget, "never out of tokens")
  end

  defp measure(:schema_valid, _assertion, %{run: run}) do
    verdict(run.status == :completed, "the run completed with an answer of its output type")
  end

  defp measure(:output_matches, %{expected: expected}, %{run: run, answer: answer}) do
    verdict(
      run.status == :completed and subset?(stringify(expected), as_map(answer)),
      "the answer holds what was expected"
    )
  end

  defp measure(type, _assertion, _observed) when type in [:process_transition, :cites],
    do: {:unmeasured, "#{type} is not measured yet"}

  defp verdict(true, detail), do: {:passed, detail}
  defp verdict(false, detail), do: {:failed, "not: " <> detail}

  defp calls(observed, target), do: Enum.filter(observed.invocations, &(&1.target == target))

  defp tool_name(target) do
    case Target.resolve(target) do
      {:ok, %{resource: resource, action: action}} ->
        {:ok, Toolset.tool_name(resource, action.name)}

      {:error, _message} ->
        :error
    end
  end

  defp as_map(answer) when is_map(answer) and not is_struct(answer), do: stringify(answer)
  defp as_map(answer), do: %{"value" => answer}

  defp subset?(expected, actual) when is_map(expected) and is_map(actual),
    do: Enum.all?(expected, fn {key, value} -> Map.fetch(actual, key) == {:ok, value} end)

  defp subset?(_expected, _actual), do: false

  defp stringify(map) when is_map(map) and not is_struct(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify(value)} end)

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(value), do: value

  defp blank?(value), do: value in [nil, ""]
  defp empty?(value), do: value in [nil, %{}]
end
