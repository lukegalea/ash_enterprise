defmodule Battery.Compliance.Standing do
  @moduledoc """
  An applicant's standing as of an instant: the ash_compliance plane's
  answer, routed through an ash_decisions table.

  Nothing here is stored. Each answer is derived on demand:

    1. `AshCompliance.Compiler.compile/1` gathers the rule-set revisions IN
       FORCE at the instant (`now:` is the gather's as-of) into the effective
       bundle;
    2. `AshRules.evaluate/2` runs that bundle over facts read off the
       applicant;
    3. the published `battery_intake_standing` DMN definition maps the
       overall outcome to a standing (`proceed` / `hold`) through
       `AshDecisions.Evaluator`, which records the evaluation (correlated to
       the applicant) unless told not to (`record: false`).

  `reevaluate_scope/2` answers for every applicant in an organization: what
  the scheduled-activation process runs once the timer has activated a
  revision.
  """

  alias Battery.Compliance.Applicant

  @decision "battery_intake_standing"

  @doc "The DMN definition key the standing is decided by."
  def decision_key, do: @decision

  @doc """
  The applicant's standing as of `at`: `{:ok, "proceed" | "hold"}`.

  `opts` reach `AshDecisions.Evaluator.evaluate/3` (`record: false` answers
  without recording).
  """
  def as_of(%Applicant{} = applicant, %DateTime{} = at, opts \\ []) do
    with {:ok, outcome} <- intake_outcome(applicant, at),
         {:ok, definition} <- Battery.Bpmn.DecisionResolver.latest_published(@decision),
         {:ok, result} <-
           AshDecisions.Evaluator.evaluate(
             definition,
             %{"intake_outcome" => Atom.to_string(outcome)},
             Keyword.merge(
               [
                 evaluation_resource: Battery.Decisions.Evaluation,
                 correlation_id: correlation_id(applicant)
               ],
               opts
             )
           ) do
      {:ok, standing(result.outputs)}
    end
  end

  @doc """
  Re-evaluates every applicant in the organization as of `at`, recording
  one evaluation each. Returns `{:ok, [{applicant_id, standing}]}`.
  """
  def reevaluate_scope(organization_id, %DateTime{} = at) do
    Applicant
    |> Ash.Query.for_read(:in_scope, %{organization_id: organization_id})
    |> Ash.read!()
    |> Enum.reduce_while({:ok, []}, fn applicant, {:ok, acc} ->
      case as_of(applicant, at) do
        {:ok, standing} -> {:cont, {:ok, [{applicant.id, standing} | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, answers} -> {:ok, Enum.reverse(answers)}
      error -> error
    end
  end

  @doc "The intake rules' overall outcome for the applicant, under the revisions in force at `at`."
  def intake_outcome(%Applicant{} = applicant, %DateTime{} = at) do
    with {:ok, bundle, _lineage} <-
           AshCompliance.Compiler.compile(organization_id: applicant.organization_id, now: at),
         {:ok, result} <- AshRules.evaluate(bundle, facts(applicant)) do
      {:ok, result.overall}
    end
  end

  @doc "The evaluation correlation id that ties a recorded evaluation to its applicant."
  def correlation_id(%Applicant{id: id}), do: "applicant:" <> id

  # Post-compile spelling: the bundle crossed encode/decode through the
  # compliance plane, so the subject is the string "applicant".
  defp facts(applicant) do
    [
      {"applicant", :submitted, true},
      {"applicant", :identified, applicant.identified},
      {"applicant", :within_ceiling, applicant.amount < 1000}
    ]
  end

  # A single-output table answers with the scalar; a recorded evaluation
  # spells it `%{"value" => scalar}`.
  defp standing(%{"value" => value}), do: value
  defp standing(%{"standing" => value}), do: value
  defp standing(value), do: value
end
