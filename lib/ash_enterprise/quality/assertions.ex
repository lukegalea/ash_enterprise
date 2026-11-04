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
  | `facts` | the answer carries every key fact (`Scorers.KeyFacts`) | |
  | `cites` | the answer cites every expected ref (`Scorers.CitationCoverage`) | |
  | `surface` | a call composed a surface (`Scorers.SurfaceComposed`) | |
  | `proposal` | a call proposed a change of the kind, or none did (`Scorers.ProposalMade`) | |
  | `calls_accepted` | every tool call was accepted by its tool (`Scorers.CallsAccepted`) | |
  | `process_transition` | not measured yet: reported `unmeasured` | |

  A hard assertion that fails fails its case whatever else passes, and blocks a release
  regardless of any average (`hard?/1`). `prohibited_effect` is a query over the run's
  invocations, which exist for every call that is not a read even though, in a run that
  is not live, none of them runs (`AshEnterprise.Execution.Invocation`): it measures
  what the agent tried to do.

  An answer that is not a map is read as `%{"value" => answer}` by `output_matches`.
  Tools are named by target; the model's name for one is
  `AshAgent.Run.Toolset.tool_name/2`. A target with no `.` is a tool's own name, for an
  agent whose tools are not governed actions (the assistant's `calendar_events`), and
  `args_match` values may be matchers (`Scorers.ArgMatch`).

  The scorers beyond the closed few above (`AshEnterprise.Quality.Scorer`) take what
  `t:observed/0` optionally adds: `calls` and `refs`.
  """

  alias AshAgent.Invocation.Target
  alias AshAgent.Run.Toolset
  alias AshEnterprise.Quality.Scorers

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
    :cites,
    :facts,
    :surface,
    :proposal,
    :calls_accepted
  ]

  @scorers %{
    facts: Scorers.KeyFacts,
    cites: Scorers.CitationCoverage,
    surface: Scorers.SurfaceComposed,
    proposal: Scorers.ProposalMade,
    calls_accepted: Scorers.CallsAccepted
  }

  @hard [:prohibited_effect, :tool_not_called, :schema_valid, :within_budget]
  @needs_target [
    :tool_not_called,
    :args_match,
    :prohibited_effect,
    :approval_requested
  ]

  @typedoc """
  What a case's run recorded: the run row, the names of every tool the model called, its
  invocations (`target`, `args`, `approval_mode`) and its answer; for an agent that answers
  with cited text, optionally its `calls` (`name`, `arguments`, `ok`, `surface?`,
  `proposal`) and the `refs` its tools returned.
  """
  @type observed :: %{
          required(:run) => map(),
          required(:tool_names) => MapSet.t(String.t()),
          required(:invocations) => [%{target: String.t(), args: map(), approval_mode: atom()}],
          required(:answer) => term(),
          optional(:calls) => [map()],
          optional(:refs) => [String.t()]
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
      missing(type, assertion)
    ]
    |> Enum.filter(&is_binary/1)
  end

  defp missing(:tool_called, a),
    do: (blank?(a[:target]) and empty?(a[:any_of])) && "tool_called needs a target"

  defp missing(:args_match, a), do: empty?(a[:args]) && "args_match needs args"
  defp missing(:max_steps, a), do: is_nil(a[:limit]) && "max_steps needs a limit"
  defp missing(:output_matches, a), do: empty?(a[:expected]) && "output_matches needs expected"
  defp missing(:facts, a), do: empty?(expected(a, "facts")) && "facts needs expected facts"
  defp missing(:cites, a), do: empty?(expected(a, "refs")) && "cites needs expected refs"

  defp missing(:proposal, a),
    do: not Map.has_key?(a[:expected] || %{}, "kind") && "proposal needs an expected kind"

  defp missing(_type, _assertion), do: nil

  defp expected(assertion, key), do: (assertion[:expected] || %{})[key]

  @doc """
  The result of `assertion` on `observed`: `%{"type", "hard", "status", "detail"}`,
  `status` one of `"passed"`, `"failed"` and `"unmeasured"`.
  """
  @spec evaluate(map(), observed()) :: %{String.t() => term()}
  def evaluate(%{type: type} = assertion, observed) do
    {status, detail, measure} = type |> measure(assertion, observed) |> with_measure()

    result = %{
      "type" => Atom.to_string(type),
      "target" => assertion[:target],
      "hard" => hard?(type),
      "status" => Atom.to_string(status),
      "detail" => detail
    }

    if measure, do: Map.put(result, "measure", measure), else: result
  end

  @doc """
  A case's status from its assertion results: `:failed` when any failed; else `:errored`
  when its run did not complete; else `:unmeasured` when none passed; else `:passed`.
  """
  @spec case_status([map()], boolean()) :: :passed | :failed | :errored | :unmeasured
  def case_status(results, completed?) do
    statuses = Enum.map(results, & &1["status"])

    cond do
      "failed" in statuses -> :failed
      not completed? -> :errored
      "passed" not in statuses -> :unmeasured
      true -> :passed
    end
  end

  defp with_measure({status, detail, measure}), do: {status, detail, measure}
  defp with_measure({status, detail}), do: {status, detail, nil}

  defp measure(:tool_called, assertion, observed) do
    wanted = [assertion[:target] | assertion[:any_of] || []] |> Enum.reject(&blank?/1)

    case for(target <- wanted, {:ok, name} <- [tool_name(target)], do: name) do
      [] ->
        {:unmeasured, "#{Enum.join(wanted, " or ")} is not a declared target"}

      names ->
        verdict(
          Enum.any?(names, &MapSet.member?(observed.tool_names, &1)),
          "called " <> Enum.join(names, " or ")
        )
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
    |> Enum.any?(&Scorers.ArgMatch.holds?(stringify(args), stringify(&1.args || %{})))
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

  defp measure(type, assertion, observed) when is_map_key(@scorers, type),
    do: Map.fetch!(@scorers, type).measure(assertion, observed)

  defp measure(:process_transition, _assertion, _observed),
    do: {:unmeasured, "process_transition is not measured yet"}

  defp verdict(true, detail), do: {:passed, detail}
  defp verdict(false, detail), do: {:failed, "not: " <> detail}

  defp calls(observed, target), do: Enum.filter(observed.invocations, &(&1.target == target))

  defp tool_name(nil), do: :error

  defp tool_name(target) do
    if String.contains?(target, "."), do: governed_tool_name(target), else: {:ok, target}
  end

  defp governed_tool_name(target) do
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
  defp empty?(value), do: value in [nil, %{}, []]
end
