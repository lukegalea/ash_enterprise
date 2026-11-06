defmodule AshEnterprise.Credentialing.RegistryDisclosureGateTest do
  @moduledoc """
  The registry's disclosure gate on this host's zone model (ADR 0042: leaving the zone is a
  disclosure). The package proves that a refusal sends nothing; this proves the host's
  decision: in-cluster is allowed, a sub-processor needs the tenant's recorded opt-in and the
  flow guard off, and the gate reads only what justifies the send.
  """

  # async: false. It swaps the transport's application env and the :ai flow guard, both
  # node-global.
  use AshEnterprise.DataCase, async: false

  import AshEnterprise.Test.DailyFixtures, only: [tenant!: 0]

  alias AshEnterprise.Accounts.Organization
  alias AshEnterprise.Credentialing.{DemoData, RegistryApi}
  alias AshEnterprise.Credentialing.RegistryApi.Transport
  alias AshEnterprise.Platform.SystemActor

  @moduletag evidence: true

  setup do
    previous = Application.get_env(:ash_enterprise, Transport)
    previous_ai = Application.get_env(:ash_enterprise, :ai)

    on_exit(fn ->
      AshEnterprise.Test.RegistryActivation.restore_env(Transport, previous)
      AshEnterprise.Test.RegistryActivation.restore_env(:ai, previous_ai)
    end)

    admin = tenant!()
    clinic = DemoData.populate(admin.tenant)
    Oban.drain_queue(queue: :execution)

    %{admin: admin, credential: hd(clinic.credentials)}
  end

  defp registry!(residency) do
    # A stub that counts every request that reaches the registry.
    sent = :counters.new(1, [])

    Req.Test.stub(Transport, fn conn ->
      :counters.add(sent, 1, 1)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(201, ~s({"id": "act-1"}))
    end)

    Application.put_env(:ash_enterprise, Transport,
      base_url: "http://registry.test",
      api_key: "synthetic-key",
      residency: residency,
      req_options: [plug: {Req.Test, Transport}]
    )

    sent
  end

  defp activate(admin, credential, disclosure_ref \\ nil) do
    arguments = %{
      reference: RegistryApi.reference(admin.tenant, credential.id),
      licence_number: credential.number,
      disclosure_ref: disclosure_ref || credential.id
    }

    # The governed act's context, which is what the grant admits; the gate decides next.
    RegistryApi.activate(arguments,
      actor: admin.actor,
      tenant: admin.tenant,
      context: %{ash_agent: %{invocation_id: Ash.UUID.generate()}}
    )
  end

  defp opt_in!(tenant) do
    Organization
    |> Ash.get!(tenant, authorize?: false)
    |> Ash.Changeset.for_update(:update, %{sub_processor_opt_in: true}, actor: SystemActor.seed())
    |> Ash.update!()
  end

  test "an in-cluster registry is allowed", %{admin: admin, credential: credential} do
    sent = registry!(:in_cluster)

    assert {:ok, %{"id" => "act-1"}} = activate(admin, credential)
    assert :counters.get(sent, 1) == 1
  end

  test "a sub-processor registry is refused without the tenant's opt-in, and nothing is sent", %{
    admin: admin,
    credential: credential
  } do
    sent = registry!(:sub_processor)

    assert {:error, error} = activate(admin, credential)

    assert %AshOperations.Error{reason: :disclosure_refused, provider_code: "residency_denied"} =
             AshOperations.Error.unwrap(error)

    assert :counters.get(sent, 1) == 0
  end

  test "the opt-in lets it through, and the flow guard refuses it again", %{
    admin: admin,
    credential: credential
  } do
    sent = registry!(:sub_processor)
    opt_in!(admin.tenant)

    assert {:ok, %{"id" => "act-1"}} = activate(admin, credential)
    assert :counters.get(sent, 1) == 1

    # REQUIRE_IN_ZONE_MODELS: nothing leaves the zone, whatever the tenant recorded.
    Application.put_env(:ash_enterprise, :ai, require_in_zone_models: true)

    assert {:error, error} = activate(admin, credential)
    assert AshOperations.Error.reason(error) == :disclosure_refused
    assert :counters.get(sent, 1) == 1
  end

  test "a disclosure_ref the actor cannot read is refused", %{
    admin: admin,
    credential: credential
  } do
    sent = registry!(:in_cluster)

    assert {:error, error} = activate(admin, credential, Ash.UUID.generate())

    assert %AshOperations.Error{reason: :disclosure_refused, provider_code: "ref_unreadable"} =
             AshOperations.Error.unwrap(error)

    # Not even a UUID: still a refusal, never a crash.
    assert {:error, error} = activate(admin, credential, "not-a-uuid")
    assert AshOperations.Error.reason(error) == :disclosure_refused
    assert :counters.get(sent, 1) == 0
  end

  test "with no tenant there is nothing to decide from", %{credential: credential} do
    gate = AshOperations.Info.disclosure_gate(RegistryApi)

    assert gate.authorize(%{disclosure_ref: credential.id}, %{actor: nil, tenant: nil}) ==
             {:error, "no_tenant"}
  end
end
