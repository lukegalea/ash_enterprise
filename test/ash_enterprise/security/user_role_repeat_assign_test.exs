defmodule AshEnterprise.Security.UserRoleRepeatAssignTest do
  @moduledoc """
  Assigning a role someone already holds, in the same scope, is the same intent twice: it
  returns the assignment in force and records nothing, so a recipe watching role
  assignments starts one process for one assignment
  (`AshEnterprise.Security.Changes.ReturnHeldAssignment`).

  Before, `assign` upserted and the audit wrapper recorded the upsert as a second `:assign`
  event, identical to the first, and a published recipe on `UserRole` creates started its
  process twice. The governed path (`assign_governed`) had the same shape and is pinned
  here too. A repeat that changes when the grant ends is a change, and is still recorded.
  SYNTHETIC data only.
  """

  use AshEnterprise.DataCase, async: false

  import AshEnterprise.Test.AssistantFixtures, only: [colleague!: 1, colleague!: 2]

  require Ash.Query

  alias AshEnterprise.Accounts.User
  alias AshEnterprise.Audit.EventLog
  alias AshEnterprise.Bpmn.{Definition, Dispatch, HumanTask, Subscription}
  alias AshEnterprise.Execution
  alias AshEnterprise.Platform.{Seeder, SystemActor}
  alias AshEnterprise.Security.{Role, UserRole}
  alias AshEnterprise.Test.AssistantFixtures

  @process "test.review_role_change"

  @xml """
  <?xml version="1.0" encoding="UTF-8"?>
  <bpmn2:definitions xmlns:bpmn2="http://www.omg.org/spec/BPMN/20100524/MODEL"
                     xmlns:ash="https://github.com/lukegalea/ash_bpmn/ns">
    <bpmn2:process id="P" isExecutable="true">
      <bpmn2:startEvent id="S"><bpmn2:outgoing>F</bpmn2:outgoing></bpmn2:startEvent>
      <bpmn2:endEvent id="E"><bpmn2:incoming>F</bpmn2:incoming></bpmn2:endEvent>
      <bpmn2:sequenceFlow id="F" sourceRef="S" targetRef="E"/>
    </bpmn2:process>
  </bpmn2:definitions>
  """

  setup do
    %{organization: organization, business_unit: unit} =
      Seeder.seed_tenant(
        unique_name: "repeat-#{System.unique_integer([:positive])}",
        email: "repeat-#{System.unique_integer([:positive])}@example.com"
      )

    tenant = organization.id
    opts = [actor: SystemActor.process(), tenant: tenant]

    %{key: @process, name: @process, xml: @xml}
    |> Definition.create!(opts)
    |> Definition.publish!(opts)

    subscription =
      %{
        key: "test.role_assigned",
        match_resource: "AshEnterprise.Security.UserRole",
        match_action_type: :create,
        process_key: @process
      }
      |> Subscription.create!(opts)
      |> Subscription.publish!(opts)

    role =
      Role
      |> Ash.Changeset.for_create(:create, %{name: "Repeat Reader"},
        actor: SystemActor.seed(),
        tenant: tenant
      )
      |> Ash.create!()

    user =
      User
      |> Ash.Changeset.for_create(
        :register_with_password,
        %{
          email: "repeat-member-#{System.unique_integer([:positive])}@example.test",
          password: "password1234",
          password_confirmation: "password1234"
        },
        authorize?: false
      )
      |> Ash.create!()

    %{tenant: tenant, unit: unit, role: role, user: user, subscription: subscription}
  end

  defp assign!(ctx, extra \\ %{}) do
    UserRole
    |> Ash.Changeset.for_create(
      :assign,
      Map.merge(
        %{user_id: ctx.user.id, role_id: ctx.role.id, scoping_business_unit_id: ctx.unit.id},
        extra
      ),
      actor: SystemActor.seed(),
      tenant: ctx.tenant
    )
    |> Ash.create!()
  end

  defp in_force(tenant, user_id) do
    UserRole
    |> Ash.Query.filter(user_id == ^user_id)
    |> Ash.read!(authorize?: false, tenant: tenant)
  end

  defp assignment_events(tenant, ids) do
    EventLog
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(resource == ^UserRole and record_id in ^List.wrap(ids))
    |> Ash.Query.sort(sequence: :asc)
    |> Ash.read!(actor: SystemActor.process(), tenant: tenant)
  end

  defp dispatches(tenant, subscription) do
    Dispatch
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(subscription_id == ^subscription.id)
    |> Ash.read!(actor: SystemActor.process(), tenant: tenant)
  end

  defp sweep!(tenant),
    do: AshBpmn.Triggers.SweepWorker.perform(%Oban.Job{args: %{"tenant" => tenant}})

  test "assigning a held role again returns the assignment and records no second event", ctx do
    first = assign!(ctx)
    second = assign!(ctx)

    assert second.id == first.id
    assert second.created_on == first.created_on
    assert [_one] = in_force(ctx.tenant, ctx.user.id)

    assert [%{action: :assign, action_type: :create}] = assignment_events(ctx.tenant, first.id)
  end

  test "so a recipe on role assignment starts its process once", ctx do
    assign!(ctx)
    assign!(ctx)
    sweep!(ctx.tenant)

    assert [%{status: :started}] = dispatches(ctx.tenant, ctx.subscription)

    # A sweep after a further repeat finds nothing new.
    assign!(ctx)
    sweep!(ctx.tenant)
    assert [_one] = dispatches(ctx.tenant, ctx.subscription)
  end

  test "a repeat that changes when the grant ends is a change, and is recorded", ctx do
    first = assign!(ctx)
    ends = DateTime.add(DateTime.utc_now(), 30, :day)

    changed = assign!(ctx, %{valid_until: ends})
    assert changed.id == first.id
    assert DateTime.compare(changed.valid_until, ends) == :eq
    assert [_first, _change] = assignment_events(ctx.tenant, first.id)

    # The same end again is the same intent.
    assert assign!(ctx, %{valid_until: ends}).id == first.id
    assert [_first, _change] = assignment_events(ctx.tenant, first.id)
  end

  test "a revoked role assigned again is a new assignment, and is recorded", ctx do
    first = assign!(ctx)
    Ash.destroy!(first, actor: SystemActor.seed(), tenant: ctx.tenant)

    again = assign!(ctx)
    refute again.id == first.id
    assert [%{action: :assign}] = assignment_events(ctx.tenant, again.id)
  end

  describe "the governed path" do
    alias AshAgent.Invocation.Executor

    @assign "AshEnterprise.Security.UserRole.assign_governed"

    setup do
      requester = AssistantFixtures.tenant!()

      %{
        requester: requester,
        approver: colleague!(requester, admin?: true),
        newcomer: colleague!(requester)
      }
    end

    # Requested by the requester, approved by another administrator, then run as the job
    # runner runs it.
    defp run_governed!(requester, approver, args) do
      row =
        Execution.invoke!(@assign, args, %{key: "test:#{Ash.UUIDv7.generate()}"},
          actor: requester.actor,
          tenant: requester.tenant
        )

      task = Ash.load!(row, :approval_task, authorize?: false).approval_task

      HumanTask
      |> Ash.ActionInput.for_action(:approve, %{record_id: task.id},
        actor: approver.actor,
        tenant: requester.tenant
      )
      |> Ash.run_action!()

      oban = [actor: SystemActor.oban(), tenant: requester.tenant]
      ready = Execution.apply_invocation_decision!(row, oban)
      {:ok, claimed} = Executor.claim(ready, oban)
      assert {:ok, :succeeded} = Executor.run_claimed(claimed, oban)
    end

    test "a second approved assignment of a held role records no second event", %{
      requester: requester,
      approver: approver,
      newcomer: newcomer
    } do
      args = %{"user_id" => newcomer.user.id, "role_id" => requester.role.id}

      run_governed!(requester, approver, args)
      assert [assignment] = in_force(requester.tenant, newcomer.user.id)

      run_governed!(requester, approver, args)
      assert [%{id: id}] = in_force(requester.tenant, newcomer.user.id)
      assert id == assignment.id

      assert [%{action: :assign_governed}] = assignment_events(requester.tenant, assignment.id)
    end
  end
end
