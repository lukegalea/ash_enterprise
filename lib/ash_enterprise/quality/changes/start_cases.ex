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

  alias AshAgent.AgentVersion.Definition
  alias AshEnterprise.Execution
  alias AshEnterprise.Quality.{Case, Suite, SuiteRun}

  @epoch 1

  @impl true
  def change(changeset, _opts, context) do
    changeset
    |> Ash.Changeset.before_action(&pin(&1, context))
    |> Ash.Changeset.after_action(&start_cases(&1, &2, context))
  end

  defp pin(changeset, context) do
    tenant = changeset.tenant
    opts = Ash.Context.to_opts(context, tenant: tenant)
    suite_id = Ash.Changeset.get_attribute(changeset, :suite_id)
    agent = Ash.Changeset.get_attribute(changeset, :agent_key)
    mode = Ash.Changeset.get_attribute(changeset, :mode)
    named = Ash.Changeset.get_attribute(changeset, :agent_version_id)

    with {:ok, %Suite{} = suite} <- Ash.get(Suite, suite_id, opts),
         {:ok, %{} = version} <- candidate(mode, named, agent, opts, tenant),
         :ok <- runnable(suite, mode),
         :ok <- variables(mode, suite, version) do
      changeset
      |> Ash.Changeset.force_change_attributes(%{
        agent_version_id: version.id,
        candidate_digest: version.content_hash,
        suite_content_hash: suite.content_hash
      })
      |> Ash.Changeset.set_context(%{quality: %{suite: suite, version: version}})
    else
      {:error, error} -> Ash.Changeset.add_error(changeset, error)
    end
  end

  defp runnable(%Suite{status: :published}, _mode), do: :ok
  defp runnable(%Suite{status: :draft}, :adhoc), do: :ok

  defp runnable(%Suite{status: status}, mode) do
    {:error,
     Ash.Error.Changes.InvalidAttribute.exception(
       field: :suite_id,
       message:
         "is #{status}; #{if mode == :adhoc, do: "a retired", else: "only a published"} suite is not run"
     )}
  end

  defp candidate(:adhoc, nil, _agent, _opts, _tenant),
    do:
      {:error,
       Ash.Error.Changes.InvalidArgument.exception(
         field: :agent_version_id,
         message: "is required: an adhoc suite run names the version it tries"
       )}

  defp candidate(:adhoc, id, agent, opts, _tenant) do
    case Execution.get_agent_version(id, opts) do
      {:ok, %{key: ^agent, status: status} = version} when status in [:draft, :published] ->
        {:ok, version}

      {:ok, _other} ->
        {:error,
         Ash.Error.Changes.InvalidArgument.exception(
           field: :agent_version_id,
           message: "is not a draft or published version of #{agent}"
         )}

      {:error, error} ->
        {:error, error}
    end
  end

  defp candidate(_mode, named, _agent, _opts, _tenant) when not is_nil(named),
    do:
      {:error,
       Ash.Error.Changes.InvalidArgument.exception(
         field: :agent_version_id,
         message: "is only for an adhoc suite run; the others measure the published version"
       )}

  defp candidate(_mode, nil, agent, _opts, tenant) do
    case Execution.latest_published_agent_version(agent,
           authorize?: false,
           tenant: tenant,
           not_found_error?: false
         ) do
      {:ok, nil} ->
        {:error,
         Ash.Error.Changes.InvalidAttribute.exception(
           field: :agent_key,
           message: "has no published version"
         )}

      other ->
        other
    end
  end

  # Before any run exists: what each case leaves the prompt without.
  defp variables(:adhoc, suite, version) do
    gaps =
      for c <- suite.cases,
          missing = Definition.missing_variables(version.instructions, Case.variables(c)),
          missing != [],
          do: "case #{c[:id]} gives no value for #{Enum.join(missing, ", ")}"

    case gaps do
      [] ->
        :ok

      gaps ->
        {:error,
         Ash.Error.Changes.InvalidAttribute.exception(
           field: :suite_id,
           message: Enum.join(gaps, "; ")
         )}
    end
  end

  defp variables(_mode, _suite, _version), do: :ok

  defp start_cases(changeset, suite_run, context) do
    %{suite: suite} = changeset.context.quality
    opts = Ash.Context.to_opts(context, tenant: changeset.tenant)

    Enum.reduce_while(suite.cases, {:ok, suite_run}, fn c, ok ->
      extra =
        %{
          mode: run_mode(suite_run.mode),
          fixtures: c[:fixtures] || %{},
          origin: :eval,
          run_key: SuiteRun.run_key(suite_run.id, c[:id], @epoch)
        }
        |> adhoc(suite_run, c)

      case Execution.start_agent_run(suite_run.agent_key, c[:input], extra, opts) do
        {:ok, _run} -> {:cont, ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  # An adhoc run pins the version it tries, and carries the case's variable values.
  defp adhoc(extra, %{mode: :adhoc} = suite_run, c),
    do:
      Map.merge(extra, %{
        agent_version_id: suite_run.agent_version_id,
        variables: Case.variables(c)
      })

  defp adhoc(extra, _suite_run, _c), do: extra

  defp run_mode(:offline), do: :eval
  defp run_mode(:adhoc), do: :eval
  defp run_mode(:shadow), do: :shadow
end
