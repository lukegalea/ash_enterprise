defmodule AshEnterprise.ExecutionSources.ModelCall do
  @moduledoc """
  Model calls (`AshEnterprise.AI.ModelCall`) as execution entries: the calls recorded
  under the trace's correlation id, under the run whose step made them. A call whose
  token counts or duration never arrived is not recorded (`recorded?` false): its cost is
  unknown, not zero.
  """

  @behaviour AshAgent.Execution.Source

  alias AshAgent.Execution.Source
  alias AshEnterprise.ExecutionSources

  @impl true
  def read(scope, opts) do
    ExecutionSources.read(
      AshEnterprise.AI.ModelCall,
      [correlation_id: ExecutionSources.correlation(scope)],
      opts
    )
  end

  @impl true
  def to_entries(rows), do: Enum.map(rows, &entry/1)

  defp entry(call) do
    recorded? =
      Enum.all?([call.input_tokens, call.output_tokens, call.duration_ms], &is_integer/1)

    Source.entry(
      at: call.created_on,
      kind: :model_call,
      status: status(call.outcome),
      source_ref: Source.ref(:model_call, call.id),
      parent_ref: run_ref(call.caller),
      definition_ref: "#{call.profile}@#{call.model}",
      cost: if(recorded?, do: cost(call)),
      recorded?: recorded?,
      summary: summary(call)
    )
  end

  defp status(:ok), do: :succeeded
  defp status(:error), do: :failed
  defp status(:refused), do: :cancelled
  defp status(_unknown), do: :uncertain

  defp cost(call),
    do: %{tokens: call.input_tokens + call.output_tokens, duration_ms: call.duration_ms}

  # A run's step names its calls `run:<run id>:<step seq>`.
  defp run_ref("run:" <> rest) do
    case String.split(rest, ":", parts: 2) do
      [run_id, _seq] -> Source.ref(:run, run_id)
      _other -> nil
    end
  end

  defp run_ref(_caller), do: nil

  # A refusal is a guardrail's outcome, named on the call it stopped.
  defp summary(call) do
    said =
      Enum.reject(
        [call.outcome == :refused && "refused", call.error_class],
        &(&1 in [nil, false])
      )

    case said do
      [] -> "#{call.operation} by #{call.caller}"
      said -> "#{call.operation} by #{call.caller}: #{Enum.join(said, ", ")}"
    end
  end
end
