defmodule AshEnterprise.Credentialing.ClinicScenarioTest do
  @moduledoc """
  The seeded clinic, end to end: the demo seed is idempotent, and the coordinator's
  request to activate a seeded credential runs through `invoke` to a recorded registry
  reference.

  Until approvals are bound to a committee task, the committee's decision is applied the
  way the job runner applies it: `apply_decision` as the `oban` system actor.
  """

  use AshEnterprise.DataCase, async: false
  use Oban.Testing, repo: AshEnterprise.Repo

  import AshEnterprise.Test.DailyFixtures, only: [tenant!: 0]

  require Ash.Query

  alias AshEnterprise.Credentialing
  alias AshEnterprise.Credentialing.{Clinic, Clinician, Credential, DemoData}
  alias AshEnterprise.Execution
  alias AshEnterprise.Execution.Invocation.ExecuteWorker
  alias AshEnterprise.Platform.{Seeder, SystemActor}
  alias AshEnterprise.Security
  alias AshEnterprise.Security.ActorContext

  @activate "AshEnterprise.Credentialing.Credential.activate_credential"

  setup do
    admin = tenant!()
    %{tenant: admin.tenant, clinic: DemoData.populate(admin.tenant)}
  end

  defp as_person(user, tenant),
    do: [
      actor: ActorContext.attach(user, ActorContext.build(user, tenant: tenant)),
      tenant: tenant
    ]

  defp oban(tenant), do: [actor: SystemActor.oban(), tenant: tenant]

  defp count(resource, tenant),
    do: resource |> Ash.read!(tenant: tenant, authorize?: false) |> length()

  test "the seed is idempotent and the coordinator owns the clinic's records", %{
    tenant: tenant,
    clinic: clinic
  } do
    counts = fn -> Enum.map([Clinic, Clinician, Credential], &count(&1, tenant)) end
    assert counts.() == [1, 3, 3]

    again = DemoData.populate(tenant)
    assert counts.() == [1, 3, 3]
    assert Enum.map(again.credentials, & &1.id) == Enum.map(clinic.credentials, & &1.id)

    assert Enum.all?(clinic.credentials, &(&1.status == :pending))
    assert Enum.all?(clinic.credentials, &(&1.owner_id == clinic.coordinator.id))

    # The committee reads the clinic's records and may not change them.
    member = hd(clinic.committee)
    [credential | _] = clinic.credentials
    assert length(Credentialing.list_credentials!(as_person(member, tenant))) == 3

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
               "idempotent" => true,
               "approver_role" => "credentialing_committee",
               "reconcile_with" => "lookup_activation"
             }

    assert [%{"id" => id, "version_number" => _}] = row.preconditions
    assert id == credential.id
    refute_enqueued(worker: ExecuteWorker, args: %{"primary_key" => %{"id" => row.id}})

    approved =
      Execution.apply_invocation_decision!(
        row,
        %{outcome: :approved, decided_by_id: member.id},
        oban(tenant)
      )

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

    # The stub registry keeps no record, so it cannot confirm the activation.
    assert Credentialing.lookup_activation!(credential.id, coordinator) ==
             %{"status" => "unknown", "reference" => nil}
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
