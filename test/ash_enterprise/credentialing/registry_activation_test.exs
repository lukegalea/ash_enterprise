defmodule AshEnterprise.Credentialing.RegistryActivationTest do
  @moduledoc """
  The governed activation over the real transport path: a lost answer leaves the invocation
  `outcome_unknown`, and reconciling it asks the registry and never sends the activation
  again. The registry is a `Req.Test` stub that, like a real one, accepts the activation and
  then loses the answer.
  """

  # async: false. It swaps the transport's application env, which is node-global.
  use AshEnterprise.DataCase, async: false
  use Oban.Testing, repo: AshEnterprise.Repo

  import AshEnterprise.Test.DailyFixtures, only: [tenant!: 0]
  import AshEnterprise.Test.RegistryActivation

  alias AshEnterprise.Credentialing.{Credential, DemoData, RegistryApi}
  alias AshEnterprise.Credentialing.RegistryApi.Transport
  alias AshEnterprise.Execution

  @moduletag evidence: true

  setup do
    previous = Application.get_env(:ash_enterprise, Transport)
    on_exit(fn -> AshEnterprise.Test.RegistryActivation.restore_env(Transport, previous) end)

    admin = tenant!()
    clinic = DemoData.populate(admin.tenant)
    Oban.drain_queue(queue: :execution)
    %{tenant: admin.tenant, clinic: clinic}
  end

  test "a lost answer leaves the activation outcome_unknown and reconciling it sends nothing", %{
    tenant: tenant,
    clinic: clinic
  } do
    [credential | _] = clinic.credentials
    log = lossy_registry!()
    row = ready!(clinic, credential, tenant)

    assert %{success: 1} = Oban.drain_queue(queue: :execution)

    unknown = Execution.get_invocation!(row.id, oban(tenant))
    assert unknown.status == :outcome_unknown
    assert Agent.get(log, &{&1.posts, &1.gets}) == {1, 0}

    # The credential itself was not recorded: the answer was lost before the write.
    assert Ash.get!(Credential, credential.id, authorize?: false, tenant: tenant).status ==
             :pending

    assert {:ok, :succeeded} = Execution.reconcile_invocation(%{"id" => row.id}, oban(tenant))

    settled = Execution.get_invocation!(row.id, oban(tenant))

    assert {settled.status, settled.reconciled_via, settled.effect_ref, settled.effect_system} ==
             {:succeeded, "reconcile_with", "act-77", "credential-registry"}

    # One POST and one GET: the reconcile asked, and never sent the activation again.
    assert Agent.get(log, &{&1.posts, &1.gets}) == {1, 1}

    assert RegistryApi.reference(tenant, credential.id) == Agent.get(log, & &1.accepted)
  end
end
