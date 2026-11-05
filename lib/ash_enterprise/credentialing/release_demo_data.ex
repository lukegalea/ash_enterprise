defmodule AshEnterprise.Credentialing.ReleaseDemoData do
  @moduledoc """
  What showcase slice 4 stands on in the clinic (`/app/showcase/credentialing`, beats 16 to
  19), added by `AshEnterprise.Credentialing.LicenceDemoData.populate/3` once the directors
  and the published licence reader exist:

    * the **reader's own release**, first: the published reader measured on the suite and
      approved, so live runs start on it and not on whatever is published next;
    * the **candidate**: a prompt change to the licence reader
      (`AshEnterprise.Credentialing.LicenceReaderCandidate`), published beside the first
      version under the same four eyes, and the reader's release suite
      (`AshEnterprise.Credentialing.ReaderSuite`), published;
    * the **routing table**'s first version (`AshEnterprise.Credentialing.RoutingTable`) and
      a release, `credentialing.routing`, pinning it with the case process;
    * a release, `credentialing.activation`, pinning the activation tool, which every
      activation request after it is bound to.

  A release is taken the way two people take one: the clinic director asks, the deputy
  approves, the job runner applies and promotes (`release!/4`). `deploy_change!/1` and
  `change_routing!/1` are the demo build's controls over the same path.

  Idempotent: every step finds its rows first. Synthetic throughout.
  """

  alias AshEnterprise.Credentialing.{
    CaseProcess,
    LicenceDemoData,
    LicenceReader,
    LicenceReaderCandidate,
    ReaderSuite,
    RoutingTable
  }

  alias AshEnterprise.Execution
  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.Process.Binding
  alias AshEnterprise.Quality
  alias AshEnterprise.Security.ActorContext
  alias AshEnterprise.Showcase.Release

  @routing "credentialing.routing"
  @activation "credentialing.activation"
  @activate "AshEnterprise.Credentialing.Credential.activate_credential"
  @lookup "AshEnterprise.Credentialing.Credential.lookup_activation"

  @doc "The key of the release that pins the case process and the routing table."
  @spec routing_key() :: String.t()
  def routing_key, do: @routing

  @doc "The key of the release that pins the activation tool."
  @spec activation_key() :: String.t()
  def activation_key, do: @activation

  @doc "Adds the candidate, the suite and the two releases to `tenant`."
  @spec populate(Ash.UUID.t(), map(), map()) :: map()
  def populate(tenant, director, deputy) do
    suite = suite!(director, tenant)
    reader = release_reader!(tenant, director, deputy)
    candidate = candidate!(director, deputy, tenant)

    RoutingTable.publish_next!(tenant)
    bind_process!(tenant)

    routing =
      released(tenant, @routing) ||
        release!(tenant, director, deputy, @routing, [
          %{kind: "process", key: CaseProcess.key()},
          %{kind: "decision", key: RoutingTable.key()}
        ])

    activation =
      released(tenant, @activation) ||
        release!(tenant, director, deputy, @activation, [%{kind: "tool", key: @activate}])

    %{
      candidate: candidate,
      suite: suite,
      reader: reader,
      routing: routing,
      activation: activation
    }
  end

  @doc """
  The demo build's stand-in for a deploy that changes `activate_credential`: the release
  that covers it is replaced by one that also covers its lookup, so its digest changes, and
  every approval bound to the old one goes stale when it is decided (F3).
  """
  @spec deploy_change!(Ash.UUID.t()) :: map()
  def deploy_change!(tenant) do
    {director, deputy} = directors!(tenant)

    release!(tenant, director, deputy, @activation, [
      %{kind: "tool", key: @activate},
      %{kind: "tool", key: @lookup}
    ])
  end

  @doc """
  The demo build's control over the routing table (F10): the table's next version is
  published and released, so a case that starts now evaluates it and one that started before
  keeps the version it started under. `:unchanged` when the table has no further version.
  """
  @spec change_routing!(Ash.UUID.t()) :: map() | :unchanged
  def change_routing!(tenant) do
    case RoutingTable.publish_next!(tenant) do
      :unchanged ->
        :unchanged

      {:published, _version} ->
        {director, deputy} = directors!(tenant)

        release!(tenant, director, deputy, @routing, [
          %{kind: "process", key: CaseProcess.key()},
          %{kind: "decision", key: RoutingTable.key()}
        ])
    end
  end

  @doc """
  Takes a release the whole way: `director` drafts it, resolves it and asks, `deputy`
  approves, and the promotion runs as the job runner runs it. Returns the active manifest.
  """
  @spec release!(Ash.UUID.t(), map(), map(), String.t(), [map()]) :: map()
  def release!(tenant, director, deputy, key, requests) do
    opts = [actor: person(director, tenant), tenant: tenant]

    manifest =
      %{key: key, requests: requests}
      |> Execution.create_release_draft!(opts)
      |> Execution.resolve_release_manifest!(%{}, opts)

    {:ok, %{"invocation_id" => id}} = Execution.request_release(manifest.id, opts)
    LicenceDemoData.decide!(id, deputy, tenant)
    Execution.get_release_manifest!(manifest.id, authorize?: false, tenant: tenant)
  end

  defp released(tenant, key) do
    [authorize?: false, tenant: tenant]
    |> Execution.active_release_manifests!()
    |> Enum.find(&(&1.key == key))
  end

  # The reader's first version is released, measured on the suite and approved, before the
  # candidate is published: a published candidate is the latest version, and an agent no
  # active release names runs its latest published version live. The release names the
  # first version, so the candidate waits for its own release (ADR 0058).
  defp release_reader!(tenant, director, deputy) do
    case released(tenant, LicenceReader.key()) do
      %{} = manifest ->
        manifest

      nil ->
        actor = person(director, tenant)
        {:ok, run} = Release.measure(actor)
        settle!(run, tenant)

        {:ok, %{"invocation_id" => id}} =
          Execution.request_release(run.release_manifest_id, actor: actor, tenant: tenant)

        LicenceDemoData.decide!(id, deputy, tenant)
        released(tenant, LicenceReader.key())
    end
  end

  # The recorded model answers each case from its transcript. The run's jobs are driven
  # here, in this process, until its cases settle; a queue that is running meanwhile only
  # shares the work.
  defp settle!(run, tenant, rounds \\ 20)

  defp settle!(_run, _tenant, 0), do: raise("the licence reader's suite run did not settle")

  defp settle!(run, tenant, rounds) do
    %{success: steps} = Oban.drain_queue(queue: :agent_runs, with_recursion: true)
    %{success: calls} = Oban.drain_queue(queue: :execution, with_recursion: true)
    current = Quality.get_suite_run!(run.id, authorize?: false, tenant: tenant, load: [:settled])

    cond do
      current.status == :finished ->
        :ok

      current.settled ->
        Quality.finish_suite_run!(current, actor: SystemActor.oban(), tenant: tenant)

      true ->
        if steps + calls == 0, do: Process.sleep(250)
        settle!(run, tenant, rounds - 1)
    end
  end

  defp candidate!(director, deputy, tenant) do
    key = LicenceReader.key()
    {:ok, %{instructions: instructions}} = AshAgent.Agent.declaration(LicenceReaderCandidate)

    published =
      Execution.list_agent_versions!(
        authorize?: false,
        tenant: tenant,
        query: [filter: [key: key, status: :published]]
      )

    case Enum.find(published, &(String.trim(&1.instructions) == String.trim(instructions))) do
      %{} = version -> version
      nil -> LicenceDemoData.publish!(LicenceReaderCandidate, director, deputy, tenant)
    end
  end

  defp suite!(director, tenant) do
    opts = [actor: person(director, tenant), tenant: tenant]

    case Quality.latest_published_suite(ReaderSuite.key(),
           authorize?: false,
           tenant: tenant,
           not_found_error?: false
         ) do
      {:ok, %{} = suite} ->
        suite

      _none ->
        ReaderSuite.key()
        |> Quality.create_suite_draft!(%{cases: ReaderSuite.cases()}, opts)
        |> Quality.publish_suite!(opts)
    end
  end

  # A release looks for the newest process the tenant owns once the tenant is bound to its
  # own copy of the key.
  defp bind_process!(tenant) do
    opts = [actor: SystemActor.process(), tenant: tenant]
    key = CaseProcess.key()

    case Binding.by_key(:process, key, Keyword.put(opts, :not_found_error?, false)) do
      {:ok, %Binding{}} ->
        :ok

      _unbound ->
        {:ok, definition} = CaseProcess.definition(tenant)

        Binding.bind!(
          %{
            kind: :process,
            key: key,
            source: :tenant,
            target_id: definition.id,
            bound_version: definition.version
          },
          opts
        )
    end
  end

  defp directors!(tenant) do
    {LicenceDemoData.user!(LicenceDemoData.director_email(), tenant),
     LicenceDemoData.user!(LicenceDemoData.deputy_email(), tenant)}
  end

  defp person(user, tenant),
    do: ActorContext.attach(user, ActorContext.build(user, tenant: tenant))
end
