defmodule AshEnterprise.Credentialing.ReleaseDemoData do
  @moduledoc """
  What showcase slice 4 stands on in the clinic (`/app/showcase/credentialing`, beats 16 to
  19), added by `AshEnterprise.Credentialing.LicenceDemoData.populate/2` once the directors
  and the published licence reader exist:

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
    candidate = candidate!(director, deputy, tenant)
    suite = suite!(director, tenant)

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

    %{candidate: candidate, suite: suite, routing: routing, activation: activation}
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
