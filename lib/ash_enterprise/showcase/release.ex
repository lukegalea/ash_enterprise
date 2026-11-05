defmodule AshEnterprise.Showcase.Release do
  @moduledoc """
  The release slice of the showcase (`/app/showcase/credentialing`, beats 16 to 19): what
  the tour reads of the licence reader's candidate release (ADR 0058), and its controls.

  ## What the tour reads

  `read/1` returns

      %{candidate:, shadow:, routing:, activation:}

    * `candidate`, the newest release manifest of the licence reader
      (`AshEnterprise.Credentialing.LicenceReaderCandidate`, measured on
      `AshEnterprise.Credentialing.ReaderSuite`) as `%{manifest:, run:, lanes:, results:,
      problems:}`, or `nil` when none was drafted: `lanes` is the finished run's quality,
      injection and safety summaries, `results` its cases (`case_id`, `status`, `tainted`,
      `injection?`), `problems` the reasons the gate gave when it refused (F9);
    * `shadow`, the suite runs made in shadow mode, newest first, each `%{run:, calls:}`,
      `calls` the tool calls its cases made as `%{target:, status:, simulated?:}` (F12);
    * `routing`, `%{table_version:, cases:}`: the version of the routing table the active
      release pins, and for each case the version its own release pinned (F10);
    * `activation`, `%{release:}`, the active release that covers `activate_credential`, which
      a request's approval is bound to (F3).

  Everything is read for the viewer's tenant without authorization below the viewer's own
  right to read credentials, as the tour's other reads are: only statuses, versions,
  digests and ids leave.

  ## Controls

  `measure/1`, `request/1` and `shadow/1` are the application's own actions, run as the
  viewer: a viewer who may not do them is refused, as anywhere. `route/2` evaluates a case's
  routing as the case would. `deploy_change/1` and `change_routing/1` stand in for a deploy
  and for an edit of the table, so they run two directors through the release path
  (`AshEnterprise.Credentialing.ReleaseDemoData.release!/5`), and refuse unless the demo flag
  is on (`AshEnterprise.Showcase.fault_controls?/0`).
  """

  alias AshEnterprise.Credentialing.{
    LicenceReader,
    ReaderSuite,
    ReleaseDemoData,
    RoutingTable
  }

  alias AshEnterprise.Execution
  alias AshEnterprise.Execution.Release.Entries
  alias AshEnterprise.Quality
  alias AshEnterprise.Quality.SuiteRun
  alias AshEnterprise.Security.ActorContext
  alias AshEnterprise.Showcase

  @doc "The key of the candidate's release: the agent's own."
  @spec key() :: String.t()
  def key, do: LicenceReader.key()

  @doc "What `read/2` returns before anything has been read."
  @spec empty() :: map()
  def empty,
    do: %{
      candidate: nil,
      shadow: [],
      routing: %{table_version: nil, cases: []},
      activation: %{release: nil}
    }

  @doc "See the moduledoc. `cases` are `AshEnterprise.Showcase.Case.cases/1`'s."
  @spec read(term(), [map()]) :: map()
  def read(actor, cases) do
    tenant = ActorContext.tenant(actor)

    active =
      Map.new(
        Execution.active_release_manifests!(authorize?: false, tenant: tenant),
        &{&1.key, &1}
      )

    %{
      candidate: candidate(tenant),
      shadow: shadow_runs(tenant),
      routing: routing(active[ReleaseDemoData.routing_key()], cases, tenant),
      activation: %{release: active[ReleaseDemoData.activation_key()]}
    }
  end

  # --- the candidate ----------------------------------------------------------------

  defp candidate(tenant) do
    case manifests(tenant, key(), 1) do
      [manifest] ->
        run = offline_run(manifest, tenant)

        %{
          manifest: manifest,
          run: run,
          lanes: lanes(run),
          results: results(run, tenant),
          problems: problems(manifest)
        }

      [] ->
        nil
    end
  end

  defp manifests(tenant, key, limit) do
    Execution.list_release_manifests!(
      authorize?: false,
      tenant: tenant,
      query: [filter: [key: key], sort: [version: :desc], limit: limit]
    )
  end

  defp offline_run(manifest, tenant) do
    Quality.list_suite_runs!(
      authorize?: false,
      tenant: tenant,
      query: [
        filter: [release_manifest_id: manifest.id, mode: :offline],
        sort: [created_on: :desc],
        limit: 1
      ]
    )
    |> List.first()
  end

  defp lanes(%{status: :finished, summary: summary}),
    do: Map.take(summary, ["quality", "injection", "safety"])

  defp lanes(_unfinished), do: nil

  defp results(%{status: :finished, id: id}, tenant) do
    injection = injection_cases()

    Quality.list_case_results!(
      authorize?: false,
      tenant: tenant,
      query: [filter: [suite_run_id: id], sort: [case_id: :asc]]
    )
    |> Enum.map(
      &%{
        case_id: &1.case_id,
        status: &1.status,
        tainted: &1.tainted,
        injection?: &1.case_id in injection
      }
    )
  end

  defp results(_unfinished, _tenant), do: []

  defp injection_cases do
    for %{id: id, tags: tags} <- ReaderSuite.cases(), "injection" in tags, do: id
  end

  defp problems(%{gate_result: %{"problems" => problems}}) when is_list(problems), do: problems
  defp problems(_unchecked), do: []

  # --- shadow runs ------------------------------------------------------------------

  defp shadow_runs(tenant) do
    runs =
      Quality.list_suite_runs!(
        authorize?: false,
        tenant: tenant,
        query: [filter: [mode: :shadow], sort: [created_on: :desc], limit: 3]
      )

    for run <- runs, do: %{run: run, calls: calls(run, tenant)}
  end

  defp calls(run, tenant) do
    keys = for %{id: id} <- ReaderSuite.cases(), do: SuiteRun.run_key(run.id, id, 1)

    ids =
      Execution.list_agent_runs!(
        authorize?: false,
        tenant: tenant,
        query: [filter: [run_key: [in: keys]]]
      )
      |> Enum.map(& &1.id)

    Execution.list_invocations!(
      authorize?: false,
      tenant: tenant,
      query: [filter: [run_id: [in: ids]], sort: [invocation_key: :asc]]
    )
    |> Enum.map(&%{target: &1.target, status: &1.status, simulated?: &1.simulated == true})
  end

  # --- the routing table ------------------------------------------------------------

  defp routing(active, cases, tenant) do
    ids = for %{instance: %{release_manifest_id: id}} when is_binary(id) <- cases, do: id

    pinned =
      Execution.list_release_manifests!(
        authorize?: false,
        tenant: tenant,
        query: [filter: [id: [in: ids]]]
      )
      |> Map.new(&{&1.id, &1})

    %{
      table_version: active && table_version(active),
      cases:
        for %{instance: instance, credential: credential} <- cases do
          %{
            id: instance.id,
            number: credential && credential.number,
            table_version: pinned |> Map.get(instance.release_manifest_id) |> table_version()
          }
        end
    }
  end

  defp table_version(nil), do: nil

  defp table_version(manifest) do
    case Entries.find(manifest.entries, :decision, RoutingTable.key()) do
      %{"annotations" => %{"version" => version}} -> version
      nil -> nil
    end
  end

  # --- controls: the application's own actions, as the viewer ----------------------

  @doc """
  Drafts a release of the licence reader's latest published version with its suite, pins
  it, and starts the suite run that measures it. The run finishes in the background.
  """
  @spec measure(term()) :: {:ok, struct()} | {:error, term()}
  def measure(actor) do
    opts = opts(actor)

    with {:ok, manifest} <-
           Execution.create_release_draft(
             %{
               key: key(),
               requests: [
                 %{kind: "agent", key: key()},
                 %{kind: "suite", key: ReaderSuite.key()}
               ]
             },
             opts
           ),
         {:ok, manifest} <- Execution.resolve_release_manifest(manifest, %{}, opts),
         {:ok, suite} <- suite(opts) do
      Quality.start_suite_run(suite.id, key(), %{release_manifest_id: manifest.id}, opts)
    end
  end

  @doc """
  Asks for the newest release of the reader to be released: the gate runs first. `{:ok, _}`
  when it passes and an approval is asked for; `{:error, error}` when it refuses, the reasons
  left on the manifest (`read/2`'s `problems`).
  """
  @spec request(term()) :: {:ok, map()} | {:error, term()}
  def request(actor) do
    opts = opts(actor)

    case manifests(ActorContext.tenant(actor), key(), 1) do
      [manifest] -> Execution.request_release(manifest.id, opts)
      [] -> {:error, :no_release}
    end
  end

  @doc "Reruns the reader's suite in shadow mode: the same cases, beside live work, with no effect."
  @spec shadow(term()) :: {:ok, struct()} | {:error, term()}
  def shadow(actor) do
    opts = opts(actor)

    with {:ok, suite} <- suite(opts),
         do: Quality.start_suite_run(suite.id, key(), %{mode: :shadow}, opts)
  end

  @doc "Evaluates the routing of the case `instance_id` as that case would: `{route, table version}`."
  @spec route(term(), Ash.UUID.t()) :: {:ok, {String.t(), pos_integer()}} | {:error, term()}
  def route(actor, instance_id) do
    tenant = ActorContext.tenant(actor)

    case Ash.get(AshEnterprise.Bpmn.Instance, instance_id, authorize?: false, tenant: tenant) do
      {:ok, instance} -> RoutingTable.route(tenant, instance)
      {:error, error} -> {:error, error}
    end
  end

  defp suite(opts) do
    Quality.latest_published_suite(ReaderSuite.key(), Keyword.put(opts, :not_found_error?, false))
    |> case do
      {:ok, %{} = suite} -> {:ok, suite}
      _none -> {:error, :no_suite}
    end
  end

  defp opts(actor), do: [actor: actor, tenant: ActorContext.tenant(actor)]

  # --- controls: the demo build's -------------------------------------------------

  @doc "The release that covers `activate_credential` is replaced by one with another digest (F3)."
  @spec deploy_change(Ash.UUID.t()) :: {:ok, map()} | {:error, :fault_controls_off}
  def deploy_change(tenant), do: if_on(fn -> ReleaseDemoData.deploy_change!(tenant) end)

  @doc "The routing table's next version is published and released (F10)."
  @spec change_routing(Ash.UUID.t()) :: {:ok, map() | :unchanged} | {:error, :fault_controls_off}
  def change_routing(tenant), do: if_on(fn -> ReleaseDemoData.change_routing!(tenant) end)

  defp if_on(fun) do
    if Showcase.fault_controls?(), do: {:ok, fun.()}, else: {:error, :fault_controls_off}
  end
end
