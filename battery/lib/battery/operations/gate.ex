defmodule Battery.Operations.Gate do
  @moduledoc """
  The battery registry's disclosure gate (`AshOperations.DisclosureGate`): whether a
  `discloses? true` call may send. It decides from the battery's own records and the
  transport's declared residency, never from the payload:

    1. The `disclosure_ref` names a `Battery.Operations.Submission`, read as the actor.
    2. The latest PUBLISHED `battery_disclosure_permitted` decision is evaluated through
       `AshDecisions.Evaluator`, which records the evaluation, over three inputs and
       nothing else: the submission's `data_class` and `consent_on_file`, and the
       transport's `destination_residency`.
    3. The decision's one output is a code. `"permitted"` is `:ok`; any other is a
       refusal, reported as `"<code>@v<version>"`, so the answer names the version of the
       policy that gave it.
  """

  @behaviour AshOperations.DisclosureGate

  alias Battery.Bpmn.DecisionResolver
  alias Battery.Operations.{Submission, Transport}

  @decision "battery_disclosure_permitted"

  @impl AshOperations.DisclosureGate
  def authorize(%{disclosure_ref: ref}, context) do
    with {:ok, submission} <- submission(ref, Map.get(context, :actor)),
         {:ok, definition} <- DecisionResolver.latest_published(@decision),
         {:ok, result} <- evaluate(definition, submission) do
      case result.outputs do
        "permitted" -> :ok
        code when is_binary(code) -> {:error, "#{code}@v#{result.definition_version}"}
        _other -> {:error, "undecided@v#{result.definition_version}"}
      end
    end
  end

  defp submission(ref, actor) do
    case Ash.get(Submission, ref, actor: actor, not_found_error?: false) do
      {:ok, %Submission{} = submission} -> {:ok, submission}
      _unreadable -> {:error, "ref_unreadable"}
    end
  rescue
    # A reference that is not a UUID names nothing.
    _malformed -> {:error, "ref_unreadable"}
  end

  defp evaluate(definition, submission) do
    inputs = %{
      "data_class" => submission.data_class,
      "destination_residency" => Atom.to_string(Transport.residency()),
      "consent_on_file" => submission.consent_on_file
    }

    case AshDecisions.Evaluator.evaluate(definition, inputs,
           evaluation_resource: Battery.Decisions.Evaluation
         ) do
      {:ok, result} -> {:ok, result}
      {:error, _reason} -> {:error, "undecided"}
    end
  end
end
