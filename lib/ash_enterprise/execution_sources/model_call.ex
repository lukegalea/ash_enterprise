defmodule AshEnterprise.ExecutionSources.ModelCall do
  @moduledoc """
  Model calls (`AshEnterprise.AI.ModelCall`) as execution entries, under the run whose
  step made them. A call whose token counts or duration never arrived is not recorded
  (`recorded?` false): its cost is unknown, not zero.

  ## Read only through a run the viewer may read

  A model call is operational bookkeeping: it carries no tenant and no owner, and a
  grant to read it reaches every tenant's calls. A correlation id is no boundary either:
  the explorer takes one as free text, and one correlation can carry several tenants'
  work. So this source reads only the calls made by a run in the trace that the viewer
  may read in their tenant, re-read here as the viewer (a trace's root reference is in
  its scope before anything has read it). A call made outside any run is in no trace,
  since nothing on it says whose it is.
  """

  @behaviour AshAgent.Execution.Source

  alias AshAgent.Execution.Source
  alias AshEnterprise.ExecutionSources

  require Ash.Query

  @impl true
  def read(scope, opts) do
    with {:ok, run_ids} <- readable_runs(ExecutionSources.uuids(scope, :run), opts) do
      ExecutionSources.read(
        AshEnterprise.AI.ModelCall,
        [caller: {:prefix, Enum.map(run_ids, &"run:#{&1}:")}],
        opts
      )
    end
  end

  @doc """
  The id of the run whose step made a call named `caller` (`run:<run id>:<step seq>`),
  or nil for a call made outside any run.
  """
  @spec run_id(String.t() | nil) :: String.t() | nil
  def run_id("run:" <> rest) do
    case String.split(rest, ":", parts: 2) do
      [run_id, _seq] -> run_id
      _other -> nil
    end
  end

  def run_id(_caller), do: nil

  # The runs among `ids` the viewer may read, in their tenant.
  defp readable_runs([], _opts), do: {:ok, []}

  defp readable_runs(ids, opts) do
    AshEnterprise.Execution.Run
    |> Ash.Query.for_read(:read, %{}, actor: opts[:actor], tenant: opts[:tenant])
    |> Ash.Query.filter(id in ^ids)
    |> Ash.Query.select([:id])
    |> Ash.read()
    |> case do
      {:ok, runs} -> {:ok, Enum.map(runs, & &1.id)}
      {:error, error} -> {:error, error}
    end
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
  defp run_ref(caller) do
    case run_id(caller) do
      nil -> nil
      run_id -> Source.ref(:run, run_id)
    end
  end

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
