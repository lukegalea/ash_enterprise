defmodule Battery.Execution.HumanInput do
  @moduledoc """
  An agent's question for a person, as a tool: `request` hands the question on and
  returns an `AshAgent.Invocation.Dispatch`, so the invocation running it is
  `dispatched` (no lease, bounded by its deadline) and the run waits on it as it waits
  on any tool call. The question's task opens with the dispatch
  (`Battery.Execution.OpenInputTask`), and the answer comes back through
  `complete_external` (`Battery.Execution.CollectInput`).
  """

  use Ash.Resource,
    domain: Battery.Domain,
    extensions: [AshAgent.Effects]

  alias AshAgent.Invocation.Dispatch

  @effect_system "human_input"
  @key "invocation.input"

  effects do
    action :request,
      kind: :other,
      destructive?: false,
      idempotent?: true,
      open_world?: false,
      intent: :propose
  end

  resource do
    require_primary_key? false
  end

  actions do
    action :request, :struct do
      description "Ask the person you act for a question, and wait for their answer."
      constraints instance_of: AshAgent.Invocation.Dispatch
      argument :question, :string, allow_nil?: false

      run fn input, _context ->
        case input.context[:ash_agent] do
          %{invocation_id: id} when is_binary(id) ->
            {:ok,
             Dispatch.new(
               effect_system: @effect_system,
               effect_ref: id,
               deadline_at: DateTime.add(DateTime.utc_now(), 7, :day)
             )}

          _not_an_invocation ->
            {:error, "a question is asked through a run's tool call"}
        end
      end
    end
  end

  @doc "The `effect_system` a dispatched question is recorded under."
  def effect_system, do: @effect_system

  @doc "The standalone task key a question's task opens under."
  def key, do: @key
end
