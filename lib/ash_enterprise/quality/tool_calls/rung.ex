# The gate is `ash_agent_tools`' (a dev and test dependency), and so is the
# instrument lookup this reuses: the rung exists only where they do.
if Code.ensure_loaded?(AshAgentTools.Gate) do
  defmodule AshEnterprise.Quality.ToolCalls.Rung do
    @moduledoc """
    The pre-flight gate's System One rung for this repository (AST-79): the
    module `AshAgentTools.Gate` calls, in the gate service, for a tool call
    every rules table deferred.

    The rung is off unless `AGENT_GATE_TENANT` names the organisation whose
    ledger records the gate's judgments (`config/runtime.exs`, dev only);
    then

        config :ash_agent_tools, :gate,
          system_one: AshEnterprise.Quality.ToolCalls.Rung,
          system_one_timeout: 8_000

    `judge/2` asks `AshEnterprise.Quality.ToolCalls.assess/2` about the call,
    as the `oban` system actor in that tenant, with the `:winnow_gpu`
    instrument. The gate bands the readings through
    `priv/decisions/agent_gate.dmn`, and lets them make a call stricter only:
    an allow needs certified band tables, a deny is an ask, and an error or a
    timeout is an ask.

    `child_spec/1` is the rung's runtime in the gate daemon, which compiles
    the project but never starts the application: it starts the applications
    the judge path needs and the repo, and nothing else (no endpoint, no
    queues). Where the repo is already running, it starts nothing.
    """

    alias AshEnterprise.Quality.ToolCalls
    alias AshEnterprise.Standards.StandingWorker

    # req_llm registers its providers (the `:typesafe` wire) when it starts.
    @applications [:ecto_sql, :postgrex, :req, :req_llm]

    @doc "The gate's rung contract: `{:ok, %{inputs:, certified:, audit:}}` or `{:error, reason}`."
    @spec judge(map(), keyword()) :: {:ok, map()} | {:error, term()}
    def judge(request, _opts) do
      with {:ok, tenant} <- tenant(),
           {:ok, instrument} <- instrument() do
        request
        |> ToolCalls.subject()
        |> ToolCalls.assess(tenant: tenant, instrument: instrument)
      end
    end

    @doc "The rung's runtime under the gate daemon's supervisor."
    @spec child_spec(term()) :: Supervisor.child_spec()
    def child_spec(_arg) do
      %{id: __MODULE__, start: {__MODULE__, :start_runtime, []}, type: :supervisor}
    end

    @doc false
    def start_runtime do
      {:ok, _started} = Application.ensure_all_started(@applications)

      case Process.whereis(AshEnterprise.Repo) do
        nil -> Supervisor.start_link([AshEnterprise.Repo], strategy: :one_for_one)
        _running -> :ignore
      end
    end

    defp tenant do
      case Application.get_env(:ash_enterprise, __MODULE__, [])[:tenant] do
        tenant when is_binary(tenant) and tenant != "" -> {:ok, tenant}
        _unset -> {:error, :no_gate_tenant}
      end
    end

    # The instrument's identity, read once from the runtime and kept for the
    # daemon's life: the profile and its digest do not change under it.
    defp instrument do
      key = {__MODULE__, :instrument}

      case :persistent_term.get(key, nil) do
        nil ->
          with {:ok, instrument} <- StandingWorker.default_instrument() do
            :persistent_term.put(key, instrument)
            {:ok, instrument}
          end

        instrument ->
          {:ok, instrument}
      end
    end
  end
end
