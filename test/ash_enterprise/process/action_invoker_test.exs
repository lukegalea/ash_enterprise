defmodule AshEnterprise.Process.ActionInvokerTest do
  @moduledoc """
  The allowlist, exercised as a registry.

  The property this module exists to keep is the negative one: `invoke/2` dispatches nothing
  that is not in `@registry`, and the catalogue the designer renders is *derived from* that
  same map — so a ref the panel offers and a ref the engine permits cannot drift apart,
  because they are one list by construction.
  """

  use AshEnterprise.DataCase, async: false

  require Ash.Query

  alias AshEnterprise.Platform.{Seeder, SystemActor}
  alias AshEnterprise.Process.ActionInvoker
  alias AshEnterprise.Process.Resolver
  alias AshEnterprise.Security.{AccessRequest, Role, UserRole}

  @unknown_action_xml """
  <?xml version="1.0" encoding="UTF-8"?>
  <bpmn2:definitions xmlns:bpmn2="http://www.omg.org/spec/BPMN/20100524/MODEL"
                     xmlns:ash="https://github.com/lukegalea/ash_bpmn/ns">
    <bpmn2:process id="P" isExecutable="true">
      <bpmn2:startEvent id="S"><bpmn2:outgoing>F</bpmn2:outgoing></bpmn2:startEvent>
      <bpmn2:serviceTask id="Boom" name="Boom">
        <bpmn2:extensionElements>
          <ash:taskConfig action="wipe_all_data"/>
        </bpmn2:extensionElements>
        <bpmn2:incoming>F</bpmn2:incoming>
        <bpmn2:outgoing>F2</bpmn2:outgoing>
      </bpmn2:serviceTask>
      <bpmn2:endEvent id="E"><bpmn2:incoming>F2</bpmn2:incoming></bpmn2:endEvent>
      <bpmn2:sequenceFlow id="F" sourceRef="S" targetRef="Boom"/>
      <bpmn2:sequenceFlow id="F2" sourceRef="Boom" targetRef="E"/>
    </bpmn2:process>
  </bpmn2:definitions>
  """

  setup do
    Seeder.seed_platform_organization()

    %{organization: organization, user: admin, business_unit: unit, role: admin_role} =
      Seeder.seed_tenant(
        unique_name: "invoker-#{System.unique_integer([:positive])}",
        email: "invoker-#{System.unique_integer([:positive])}@example.com"
      )

    on_exit(&Resolver.forget_platform_tenant/0)

    requested_role =
      Role
      |> Ash.Changeset.for_create(:create, %{name: "Report Reader"},
        actor: SystemActor.seed(),
        tenant: organization.id
      )
      |> Ash.create!()

    request =
      AccessRequest.submit!(
        %{
          justification: "I need this to run the quarterly compliance report for my region.",
          requested_role_tier: :standard,
          requested_role_id: requested_role.id,
          scoping_business_unit_id: unit.id
        },
        actor: admin,
        tenant: organization.id
      )

    %{
      tenant: organization.id,
      admin: admin,
      admin_role: admin_role,
      requested_role: requested_role,
      request: request
    }
  end

  defp reload(request, tenant) do
    AccessRequest
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^request.id)
    |> Ash.read_one!(actor: SystemActor.process(), tenant: tenant)
  end

  describe "invoke/2" do
    test "the declared inputs reach the action", %{request: request, tenant: tenant} do
      assert :ok =
               ActionInvoker.invoke("record_risk", %{
                 subject: request,
                 inputs: %{"risk_tier" => "low"},
                 tenant: tenant
               })

      assert reload(request, tenant).risk_tier == :low
    end

    test "a missing declared input fails the node rather than guessing", %{
      request: request,
      tenant: tenant
    } do
      # No `:inputs` at all — a diagram that declares no inputs — reads the same as one whose
      # input evaluated to nothing: the action does not run and the node fails.
      assert {:error, :no_risk_tier_to_record} =
               ActionInvoker.invoke("record_risk", %{subject: request, tenant: tenant})
    end

    test "an unknown action is refused, naming the registry", %{tenant: tenant} do
      assert {:error, {:action_not_allowed, "wipe_all_data", message}} =
               ActionInvoker.invoke("wipe_all_data", %{subject: nil, tenant: tenant})

      assert message =~ "AshEnterprise.Process.ActionInvoker"
    end

    test "grant_role is idempotent across redelivery", %{request: request, tenant: tenant} do
      ctx = %{subject: request, tenant: tenant}

      assert :ok = ActionInvoker.invoke("grant_role", ctx)
      granted = reload(request, tenant)
      assert granted.decision_outcome == :granted

      # Oban redelivers: the second invocation must find the existing assignment rather than
      # duplicate it, and grant the same one again.
      assert :ok = ActionInvoker.invoke("grant_role", ctx)
      assert granted.granted_user_role_id == reload(request, tenant).granted_user_role_id

      # Of the assignments the user already had (the seeded admin holds Administrator), the
      # invocation added exactly the requested role.
      assert [_assignment] =
               UserRole
               |> Ash.Query.for_read(:read)
               |> Ash.Query.filter(
                 user_id == ^granted.created_by_id and role_id == ^ctx.subject.requested_role_id
               )
               |> Ash.read!(actor: SystemActor.process(), tenant: tenant)
    end
  end

  describe "exists?/1" do
    test "every registered ref exists, and nothing else does" do
      assert ActionInvoker.exists?("record_risk")
      assert ActionInvoker.exists?("grant_role")
      assert ActionInvoker.exists?("reject_request")

      refute ActionInvoker.exists?("wipe_all_data")
    end

    test "publishing a diagram that names an unregistered action is refused", %{tenant: tenant} do
      # The engine asks the invoker at publish time, because the export is there: the refusal
      # lands where the diagram is authored rather than when a token reaches the node.
      opts = [actor: SystemActor.process(), tenant: tenant]

      definition =
        AshEnterprise.Bpmn.Definition.create!(
          %{key: "invoker.unknown", name: "unknown action", xml: @unknown_action_xml},
          opts
        )

      assert errors = definition.errors
      assert errors != []
      assert Enum.any?(errors, fn e -> e["message"] =~ "references action 'wipe_all_data'" end)

      assert {:error, _} = AshEnterprise.Bpmn.Definition.publish(definition, opts)
    end
  end

  describe "catalogue/0" do
    test "offers exactly the refs invoke/2 dispatches on" do
      refs = Enum.map(ActionInvoker.catalogue(), & &1.ref)

      assert Enum.sort(refs) == Enum.sort(["record_risk", "grant_role", "reject_request"])

      for ref <- refs do
        assert ActionInvoker.exists?(ref), "#{ref} is offered but not permitted"
      end
    end

    test "an Ash-backed entry is introspected from the real action" do
      entry = Enum.find(ActionInvoker.catalogue(), &(&1.ref == "record_risk"))

      # Straight from the action's own description, so the panel cannot say something the
      # action does not do.
      assert entry.label ==
               "Records what the risk decision returned, so the request shows why it routed."

      assert entry.description == entry.label
      assert entry.args == []
    end

    test "the bespoke entry describes itself" do
      entry = Enum.find(ActionInvoker.catalogue(), &(&1.ref == "grant_role"))

      assert entry.label == "Grant the requested role"
      assert entry.description =~ "finding an existing assignment"
    end
  end
end
