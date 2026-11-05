defmodule Battery.Execution.ProcessRun do
  @moduledoc """
  The two service tasks around a process's wait for an agent, the way a host's
  `AshBpmn.ActionInvoker` runs them:

    * `start/1` starts the run the node's `agent` and `input` ask for, as the member who
      started the instance, keyed by the engine's invocation key
      (`bpmn:<instance>:<token>:<node>`), so a redelivery finds the run an earlier
      delivery started and starts none. It answers `run_id`.
    * `outcome/1` reads how the run named by `run_id` ended, from the run, and answers
      `outcome`: a process routes on what the run recorded, not on the message that woke it.
  """

  require Ash.Query

  alias Battery.Execution.{Member, Run}

  @final [:completed, :failed, :cancelled]

  def start(ctx) do
    {instance_id, token_id, node_id} = ctx[:invocation_key]
    key = "bpmn:#{instance_id}:#{token_id}:#{node_id}"

    with {:ok, starter} <- starter(ctx[:instance]),
         {:ok, run} <- run(key, ctx[:inputs], starter) do
      {:ok, %{"run_id" => run.id}}
    end
  end

  def outcome(ctx) do
    with {:ok, starter} <- starter(ctx[:instance]),
         {:ok, run} <- Ash.get(Run, ctx[:inputs]["run_id"], actor: starter) do
      if run.status in @final,
        do: {:ok, %{"outcome" => to_string(run.status)}},
        else: {:error, {:agent_run_not_finished, run.id, run.status}}
    end
  end

  defp starter(%{started_by_id: id}) when is_binary(id), do: Ash.get(Member, id)
  defp starter(_instance), do: {:error, :no_starter}

  defp run(key, %{"agent" => agent, "input" => input}, starter) do
    case Run |> Ash.Query.filter(run_key == ^key) |> Ash.read_one(actor: starter) do
      {:ok, nil} ->
        Run
        |> Ash.Changeset.for_create(
          :start,
          %{agent: agent, input: input, run_key: key, origin: :bpmn},
          actor: starter
        )
        |> Ash.create()

      other ->
        other
    end
  end
end
