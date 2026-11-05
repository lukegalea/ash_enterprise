defmodule Battery.Bpmn.PinnedDecisionResolver do
  @moduledoc """
  The battery's stand-in for a host that pins decisions per case: an
  `AshBpmn.DecisionResolver` that evaluates the decision version pinned for the
  business rule task's subject (`pin/2`), and the latest published one for any subject
  nothing pins.

  The engine hands the resolver the subject and the instance in its context; this is what
  a host reads to give a case the decision version of the release it started under.
  """

  @behaviour AshBpmn.DecisionResolver

  alias Battery.Bpmn.DecisionResolver

  @doc "Pins the subject `subject_id` to the definition `definition_id`."
  @spec pin(Ash.UUID.t(), Ash.UUID.t()) :: :ok
  def pin(subject_id, definition_id),
    do: :persistent_term.put({__MODULE__, subject_id}, definition_id)

  @doc "Forgets every pin."
  @spec clear() :: :ok
  def clear do
    for {{__MODULE__, _id} = key, _value} <- :persistent_term.get(),
        do: :persistent_term.erase(key)

    :ok
  end

  @impl true
  def decide(ref, inputs, context) do
    subject_id = context[:subject] && context[:subject].id

    case :persistent_term.get({__MODULE__, subject_id}, nil) do
      nil ->
        DecisionResolver.decide(ref, inputs, context)

      definition_id ->
        with {:ok, definition} <- Ash.get(Battery.Decisions.Definition, definition_id),
             do: DecisionResolver.evaluate(definition, inputs)
    end
  end

  @impl true
  defdelegate exists?(ref), to: DecisionResolver
end
