defmodule AshEnterprise.Quality.Changes.StartCases do
  @moduledoc """
  A suite run's `start`: pins the candidate and starts one agent run per case, in the
  suite run's transaction.

  The suite is read as the person starting the run and must be published; its
  `content_hash` is recorded as `suite_content_hash`. The candidate is the agent's
  latest published version in the tenant; its id and `content_hash` are recorded as
  `agent_version_id` and `candidate_digest`.

  Each case then starts an `AshEnterprise.Execution.Run` as the same person, so they need
  the agent's start grant (a refusal fails the whole start): the case's `input`, its
  `fixtures`, `origin: :eval`, the run key `AshEnterprise.Quality.SuiteRun.run_key/3`,
  and `mode: :eval` for an `:offline` suite run or `:shadow` for a `:shadow` one. Either
  mode causes no effects.
  """

  use Ash.Resource.Change

  alias AshEnterprise.Execution
  alias AshEnterprise.Quality.{Suite, SuiteRun}

  @epoch 1

  @impl true
  def change(changeset, _opts, context) do
    changeset
    |> Ash.Changeset.before_action(&pin(&1, context))
    |> Ash.Changeset.after_action(&start_cases(&1, &2, context))
  end

  defp pin(changeset, context) do
    tenant = changeset.tenant
    suite_id = Ash.Changeset.get_attribute(changeset, :suite_id)
    agent = Ash.Changeset.get_attribute(changeset, :agent_key)

    with {:ok, %Suite{status: :published} = suite} <-
           Ash.get(Suite, suite_id, Ash.Context.to_opts(context, tenant: tenant)),
         {:ok, %{} = version} <-
           Execution.latest_published_agent_version(agent,
             authorize?: false,
             tenant: tenant,
             not_found_error?: false
           ) do
      changeset
      |> Ash.Changeset.force_change_attributes(%{
        agent_version_id: version.id,
        candidate_digest: version.content_hash,
        suite_content_hash: suite.content_hash
      })
      |> Ash.Changeset.set_context(%{quality: %{suite: suite}})
    else
      {:ok, %Suite{status: status}} ->
        Ash.Changeset.add_error(changeset,
          field: :suite_id,
          message: "is %{status}; only a published suite is run",
          vars: [status: status]
        )

      {:ok, nil} ->
        Ash.Changeset.add_error(changeset,
          field: :agent_key,
          message: "has no published version"
        )

      {:error, error} ->
        Ash.Changeset.add_error(changeset, error)
    end
  end

  defp start_cases(changeset, suite_run, context) do
    %{suite: suite} = changeset.context.quality
    opts = Ash.Context.to_opts(context, tenant: changeset.tenant)

    Enum.reduce_while(suite.cases, {:ok, suite_run}, fn c, ok ->
      extra = %{
        mode: run_mode(suite_run.mode),
        fixtures: c[:fixtures] || %{},
        origin: :eval,
        run_key: SuiteRun.run_key(suite_run.id, c[:id], @epoch)
      }

      case Execution.start_agent_run(suite_run.agent_key, c[:input], extra, opts) do
        {:ok, _run} -> {:cont, ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp run_mode(:offline), do: :eval
  defp run_mode(:shadow), do: :shadow
end
