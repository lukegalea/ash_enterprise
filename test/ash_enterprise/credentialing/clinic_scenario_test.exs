defmodule AshEnterprise.Credentialing.ClinicScenarioTest do
  @moduledoc """
  The seeded clinic, end to end: the demo seed is idempotent and leaves its credentials
  in several states, and the coordinator's request to activate a seeded credential runs
  through `invoke` to a recorded registry reference, which `lookup_activation` (the
  target's `reconcile_with`) can then find.

  The request opens an approval task for the credentialing committee; a member decides
  it through the task's approve door, and the decision is applied the way the
  `:apply_decision` job applies it: `apply_decision` as the `oban` system actor.
  """

  use AshEnterprise.DataCase, async: false
  use Oban.Testing, repo: AshEnterprise.Repo

  # The clinic's demo data ingests its licence documents into the evidence store.
  @moduletag evidence: true

  import AshEnterprise.Test.DailyFixtures, only: [tenant!: 0]

  require Ash.Query

  alias AshAgent.Invocation.{Failure, Target}
  alias AshEnterprise.Bpmn.HumanTask
  alias AshEnterprise.Credentialing
  alias AshEnterprise.Credentialing.{Clinic, Clinician, Credential, DemoData}
  alias AshEnterprise.Credentialing.{Registry, RegistryError}
  alias AshEnterprise.Execution
  alias AshEnterprise.Execution.{Approval, Invocation}
  alias AshEnterprise.Execution.Invocation.ExecuteWorker
  alias AshEnterprise.Platform.{Seeder, SystemActor}
  alias AshEnterprise.Security
  alias AshEnterprise.Security.ActorContext

  @activate "AshEnterprise.Credentialing.Credential.activate_credential"

  setup do
    admin = tenant!()
    clinic = DemoData.populate(admin.tenant)

    # The seed published the licence reader and ran its publish itself; the job the
    # decision queued finds it done.
    Oban.drain_queue(queue: :execution)

    %{tenant: admin.tenant, clinic: clinic}
  end

  defp as_person(user, tenant),
    do: [
      actor: ActorContext.attach(user, ActorContext.build(user, tenant: tenant)),
      tenant: tenant
    ]

  defp oban(tenant), do: [actor: SystemActor.oban(), tenant: tenant]

  defp activations(tenant) do
    Invocation
    |> Ash.Query.filter(target == ^@activate)
    |> Ash.read!(tenant: tenant, authorize?: false)
  end

  defp count(resource, tenant),
    do: resource |> Ash.read!(tenant: tenant, authorize?: false) |> length()

  test "the seed is idempotent and the coordinator owns the clinic's records", %{
    tenant: tenant,
    clinic: clinic
  } do
    counts = fn ->
      Enum.map([Clinic, Clinician, Credential], &count(&1, tenant)) ++
        [length(activations(tenant))]
    end

    assert counts.() == [1, 5, 5, 2]

    again = DemoData.populate(tenant)
    assert counts.() == [1, 5, 5, 2]
    assert Enum.map(again.credentials, & &1.id) == Enum.map(clinic.credentials, & &1.id)
    assert Enum.map(again.requests, & &1.id) == Enum.map(clinic.requests, & &1.id)

    assert Enum.all?(clinic.credentials, &(&1.status == :pending))
    assert Enum.all?(clinic.credentials, &(&1.owner_id == clinic.coordinator.id))

    # Two of them were asked for: one waits for the committee, one was rejected by it.
    assert Enum.map(again.requests, &{&1.status, &1.error_code}) == [
             {:awaiting_approval, nil},
             {:rejected, "approval_rejected"}
           ]

    assert Enum.all?(again.requests, &(&1.owner_id == clinic.coordinator.id))

    # The committee reads the clinic's records and may not change them.
    member = hd(clinic.committee)
    [credential | _] = clinic.credentials
    assert length(Credentialing.list_credentials!(as_person(member, tenant))) == 5

    refute Ash.can?({credential, :activate_credential}, as_person(member, tenant)[:actor],
             tenant: tenant
           )
  end

  test "an activation is invoked, approved by another person, and recorded once", %{
    tenant: tenant,
    clinic: clinic
  } do
    [credential | _] = clinic.credentials
    coordinator = as_person(clinic.coordinator, tenant)
    [member | _] = clinic.committee

    row =
      Execution.invoke!(
        @activate,
        %{"id" => credential.id},
        %{key: "clinic-demo:activate:#{credential.id}"},
        coordinator
      )

    assert {row.status, row.approval_mode} == {:awaiting_approval, :four_eyes}
    assert row.executing_principal == %{type: :person, id: clinic.coordinator.id}

    assert Map.take(row.effects, ~w(kind open_world idempotent approver_role reconcile_with)) ==
             %{
               "kind" => "edit",
               "open_world" => true,
               "idempotent" => false,
               "approver_role" => "credentialing_committee",
               "reconcile_with" => "lookup_activation"
             }

    assert [%{"id" => id, "version_number" => _}] = row.preconditions
    assert id == credential.id
    refute_enqueued(worker: ExecuteWorker, args: %{"primary_key" => %{"id" => row.id}})

    approval_key = Approval.key()
    row_id = row.id

    task =
      HumanTask
      |> Ash.Query.filter(subject_id == ^row_id and node_id == ^approval_key)
      |> Ash.read_one!(authorize?: false, tenant: tenant)

    # The coordinator asked, so only another person decides.
    decide = fn who ->
      HumanTask
      |> Ash.ActionInput.for_action(:approve, %{record_id: task.id}, as_person(who, tenant))
      |> Ash.run_action()
    end

    assert {:error, _} = decide.(clinic.coordinator)
    assert {:ok, _} = decide.(member)

    approved = Execution.apply_invocation_decision!(row, oban(tenant))

    assert {approved.status, approved.approved_by_id} == {:ready, member.id}
    assert %{success: 1} = Oban.drain_queue(queue: :execution)

    done = Execution.get_invocation!(row.id, oban(tenant))
    assert done.status == :succeeded

    active = Credentialing.get_credential!(credential.id, coordinator)
    assert active.status == :active
    assert "stub-registry:" <> _ = active.registry_reference
    assert active.activated_at

    assert Ash.load!(done, [:result], oban(tenant)).result ==
             %{"resource" => inspect(Credential), "id" => credential.id}

    # The same request again is the same row, which has already run.
    again =
      Execution.invoke!(
        @activate,
        %{"id" => credential.id},
        %{key: "clinic-demo:activate:#{credential.id}"},
        coordinator
      )

    assert {again.id, again.status} == {row.id, :succeeded}

    # The registry holds the activation, so its lookup can confirm it, in the shape a
    # `reconcile_with` lookup answers; the registry was asked once.
    assert Credentialing.lookup_activation!(credential.id, coordinator) ==
             %{
               "outcome" => "succeeded",
               "effect_ref" => active.registry_reference,
               "effect_system" => "credential-registry"
             }

    assert Registry.activations(credential.id) == 1
  end

  test "reconciliation can ask the registry: the lookup takes the target's own arguments", %{
    tenant: tenant,
    clinic: clinic
  } do
    [credential | _] = clinic.credentials
    {:ok, target} = Target.resolve(@activate)
    opts = as_person(clinic.coordinator, tenant)

    lookup = fn ->
      Target.lookup(target, "activate:#{credential.id}", %{"id" => credential.id}, opts)
    end

    # Nothing activated yet: a stub that forgets on restart cannot say "never", only
    # "unknown", which leaves the question to a person.
    assert {:ok, %{outcome: :unknown, effect_ref: nil}} = lookup.()

    {:ok, reference} = Registry.activate(credential.id)

    assert {:ok,
            %{outcome: :succeeded, effect_ref: ^reference, effect_system: "credential-registry"}} =
             lookup.()
  end

  test "a registry failure is typed, so an invocation can classify it" do
    unavailable = RegistryError.exception(reason: :unavailable)
    refused = RegistryError.exception(reason: :refused)

    assert Failure.classify(Ash.Error.to_ash_error(unavailable)) ==
             {:transient, "registry_unavailable"}

    assert Failure.classify_started(Ash.Error.to_ash_error(refused)) ==
             {:permanent, "registry_refused"}
  end

  test "a new tenant's Administrator holds the credentialing privileges" do
    seeded = Seeder.seed_tenant(unique_name: "clinic-#{System.unique_integer([:positive])}")

    for resource <- [Clinic, Clinician, Credential] do
      name = inspect(resource)

      granted =
        Security.RolePrivilege
        |> Ash.Query.filter(role_id == ^seeded.role.id and privilege.resource_name == ^name)
        |> Ash.Query.load(:privilege)
        |> Ash.read!(actor: SystemActor.seed(), tenant: seeded.organization.id)
        |> Enum.map(& &1.privilege.access_right)

      assert :read in granted, "#{name} read"
      assert :write in granted, "#{name} write"
      assert :create in granted, "#{name} create"
    end
  end
end
