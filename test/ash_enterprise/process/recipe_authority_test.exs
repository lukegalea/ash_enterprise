defmodule AshEnterprise.Process.RecipeAuthorityTest do
  @moduledoc """
  A recipe's `authority`: who the steps of the process it starts may run as.

  An event grants nothing. A subscription is `:human_tasks_only` unless it says otherwise,
  `:causing_person` only for the one key the allowlist names, and never `:standing_grant`
  through plain `publish`. Publishing checks the diagram it can see; the step checks again,
  because the diagram can change under a published subscription.

  The refusals come first. The seeded access-request recipe, the one that runs as the
  causing person, is driven end to end in `AccessRequestDemoTest`.
  """

  use AshEnterprise.DataCase, async: false
  use Oban.Testing, repo: AshEnterprise.Repo

  require Ash.Query

  alias AshEnterprise.Bpmn.{Definition, Dispatch, Instance, Subscription}
  alias AshEnterprise.Bpmn.Subscription.Authority
  alias AshEnterprise.Platform.{Seeder, SystemActor}
  alias AshEnterprise.Process.{ActionInvoker, RecipeAuthority}
  alias AshEnterprise.Security.{AccessRequest, Role}
  alias AshEnterprise.Test.DailyFixtures

  @allowlisted "access_request.submitted"

  @people_only """
  <?xml version="1.0" encoding="UTF-8"?>
  <bpmn2:definitions xmlns:bpmn2="http://www.omg.org/spec/BPMN/20100524/MODEL"
                     xmlns:ash="https://github.com/lukegalea/ash_bpmn/ns"
                     id="Definitions_people_only" targetNamespace="https://example.com/bpmn">
    <bpmn2:process id="Process_people_only" isExecutable="true">
      <bpmn2:startEvent id="Start"><bpmn2:outgoing>Flow_1</bpmn2:outgoing></bpmn2:startEvent>
      <bpmn2:userTask id="Review" name="Review the request">
        <bpmn2:extensionElements>
          <ash:taskConfig>
            <ash:candidates><ash:candidate kind="role" of="Administrator"/></ash:candidates>
            <ash:outcomes>
              <ash:outcome name="confirmed"/>
              <ash:outcome name="challenged"/>
            </ash:outcomes>
          </ash:taskConfig>
        </bpmn2:extensionElements>
        <bpmn2:incoming>Flow_1</bpmn2:incoming>
        <bpmn2:outgoing>Flow_2</bpmn2:outgoing>
      </bpmn2:userTask>
      <bpmn2:endEvent id="End"><bpmn2:incoming>Flow_2</bpmn2:incoming></bpmn2:endEvent>
      <bpmn2:sequenceFlow id="Flow_1" sourceRef="Start" targetRef="Review"/>
      <bpmn2:sequenceFlow id="Flow_2" sourceRef="Review" targetRef="End"/>
    </bpmn2:process>
  </bpmn2:definitions>
  """

  # One step, and it acts: it rejects the request it was started for, so whether it ran
  # is visible on the request.
  @acting """
  <?xml version="1.0" encoding="UTF-8"?>
  <bpmn2:definitions xmlns:bpmn2="http://www.omg.org/spec/BPMN/20100524/MODEL"
                     xmlns:ash="https://github.com/lukegalea/ash_bpmn/ns"
                     id="Definitions_acting" targetNamespace="https://example.com/bpmn">
    <bpmn2:process id="Process_acting" isExecutable="true">
      <bpmn2:startEvent id="Start"><bpmn2:outgoing>Flow_1</bpmn2:outgoing></bpmn2:startEvent>
      <bpmn2:TASKTYPE id="Reject" name="Reject the request">
        <bpmn2:extensionElements><ash:taskConfig action="reject_request"/></bpmn2:extensionElements>
        <bpmn2:incoming>Flow_1</bpmn2:incoming>
        <bpmn2:outgoing>Flow_2</bpmn2:outgoing>
      </bpmn2:TASKTYPE>
      <bpmn2:endEvent id="End"><bpmn2:incoming>Flow_2</bpmn2:incoming></bpmn2:endEvent>
      <bpmn2:sequenceFlow id="Flow_1" sourceRef="Start" targetRef="Reject"/>
      <bpmn2:sequenceFlow id="Flow_2" sourceRef="Reject" targetRef="End"/>
    </bpmn2:process>
  </bpmn2:definitions>
  """

  setup do
    %{organization: organization, user: admin, business_unit: unit} =
      Seeder.seed_tenant(
        unique_name: "recipe-#{System.unique_integer([:positive])}",
        email: "recipe-#{System.unique_integer([:positive])}@example.com"
      )

    role =
      Role
      |> Ash.Changeset.for_create(:create, %{name: "Report Reader"},
        actor: SystemActor.seed(),
        tenant: organization.id
      )
      |> Ash.create!()

    %{tenant: organization.id, admin: admin, unit: unit, role: role}
  end

  defp opts(tenant), do: [actor: SystemActor.process(), tenant: tenant]

  defp process!(tenant, xml) do
    key = "recipe-probe-#{System.unique_integer([:positive])}"
    publish_process!(tenant, key, xml)
    key
  end

  defp publish_process!(tenant, key, xml) do
    definition = Definition.create!(%{key: key, name: key, xml: xml}, opts(tenant))
    assert definition.errors in [nil, []], "#{key} did not compile: #{inspect(definition.errors)}"
    Definition.publish!(definition, opts(tenant))
  end

  defp acting(type), do: String.replace(@acting, "TASKTYPE", type)

  # A draft watching access requests being submitted. `forced` writes the authority
  # straight onto the row, past the action that chooses it, to show that publish refuses
  # it on its own.
  defp draft!(tenant, attrs, forced \\ nil) do
    Subscription
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(
        %{
          key: "recipe-#{System.unique_integer([:positive])}",
          match_resource: "AshEnterprise.Security.AccessRequest",
          match_action: :submit,
          match_action_type: :create,
          process_key: "nothing-published-under-this-key"
        },
        attrs
      ),
      opts(tenant)
    )
    |> then(fn changeset ->
      if forced,
        do: Ash.Changeset.force_change_attribute(changeset, :authority, forced),
        else: changeset
    end)
    |> Ash.create!()
  end

  defp message({:error, error}), do: Exception.message(error)

  defp submit!(ctx) do
    AccessRequest.submit!(
      %{
        justification: "I need this to run the quarterly compliance report for my region.",
        requested_role_tier: :standard,
        requested_role_id: ctx.role.id,
        scoping_business_unit_id: ctx.unit.id
      },
      actor: ctx.admin,
      tenant: ctx.tenant
    )
  end

  # The sweep as production runs it. A started process's first advance is a job, runnable
  # only once the instance and its dispatch row have committed together; the suite's inline
  # engine would run it inside the sweep's transaction instead, before the dispatch row that
  # names the recipe exists. So the sweep only enqueues, and `advance!/0` runs the jobs after.
  defp sweep!(tenant) do
    inline = Application.get_env(:ash_bpmn, :oban_testing)
    Application.put_env(:ash_bpmn, :oban_testing, nil)

    try do
      AshBpmn.Triggers.SweepWorker.perform(%Oban.Job{args: %{"tenant" => tenant}})
    after
      Application.put_env(:ash_bpmn, :oban_testing, inline)
    end
  end

  # Later advances run inline, and a step that fails raises there.
  defp advance! do
    for job <- all_enqueued(worker: AshBpmn.Runtime.AdvanceWorker) do
      perform_job(AshBpmn.Runtime.AdvanceWorker, job.args)
    end
  end

  defp reload(request, tenant) do
    AccessRequest
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^request.id)
    |> Ash.read_one!(opts(tenant))
  end

  defp started(tenant) do
    Dispatch
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(status == :started)
    |> Ash.read!(opts(tenant))
  end

  defp instance!(id, tenant) do
    Instance
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^id)
    |> Ash.read_one!(opts(tenant))
  end

  describe "a human-only recipe" do
    test "refuses a diagram with a service task", %{tenant: tenant} do
      key = process!(tenant, acting("serviceTask"))
      draft = draft!(tenant, %{process_key: key})

      assert draft.authority == :human_tasks_only

      assert {:error, _} = result = Subscription.publish(draft, opts(tenant))
      assert message(result) =~ "human-tasks-only recipe cannot start #{key}"
      assert message(result) =~ "serviceTask Reject"

      assert Ash.reload!(draft, opts(tenant)).status == :draft
    end

    test "refuses a diagram with a send task", %{tenant: tenant} do
      key = process!(tenant, acting("sendTask"))

      assert {:error, _} =
               result =
               tenant |> draft!(%{process_key: key}) |> Subscription.publish(opts(tenant))

      assert message(result) =~ "sendTask Reject"
    end

    test "whose process gained a service task after publish runs nothing", ctx do
      key = process!(ctx.tenant, @people_only)

      subscription =
        ctx.tenant |> draft!(%{process_key: key}) |> Subscription.publish!(opts(ctx.tenant))

      assert subscription.authority == :human_tasks_only

      # The diagram changes under the published recipe: the sweep starts the latest
      # published version, and that one acts.
      publish_process!(ctx.tenant, key, acting("serviceTask"))

      request = submit!(ctx)
      sweep!(ctx.tenant)

      assert_raise RuntimeError, ~r/\{:no_authority, :human_tasks_only\}/, &advance!/0

      assert [%Dispatch{instance_id: instance_id, subscription_id: subscription_id}] =
               started(ctx.tenant)

      assert subscription_id == subscription.id
      instance = instance!(instance_id, ctx.tenant)

      # The step ran nothing: the request is not rejected.
      assert reload(request, ctx.tenant).decision_outcome == nil

      engine_ctx = %{instance: instance, subject: request, tenant: ctx.tenant}

      assert RecipeAuthority.check(engine_ctx) == {:error, {:no_authority, :human_tasks_only}}

      assert ActionInvoker.invoke("reject_request", engine_ctx) ==
               {:error, {:no_authority, :human_tasks_only}}

      assert reload(request, ctx.tenant).decision_outcome == nil
    end

    test "publishes over a diagram of people's tasks only", %{tenant: tenant} do
      key = process!(tenant, @people_only)

      assert %Subscription{status: :published, authority: :human_tasks_only} =
               tenant |> draft!(%{process_key: key}) |> Subscription.publish!(opts(tenant))
    end
  end

  describe "a resource with no tenant" do
    for authority <- Authority.values() do
      test "is refused for a #{authority} recipe", %{tenant: tenant} do
        draft =
          draft!(
            tenant,
            %{
              key: @allowlisted,
              match_resource: "AshEnterprise.Accounts.User",
              match_action: nil,
              match_action_type: nil
            },
            unquote(authority)
          )

        assert {:error, _} = result = Subscription.publish(draft, opts(tenant))
        assert message(result) =~ "may not match AshEnterprise.Accounts.User: it has no tenant"
      end
    end
  end

  describe "the causing-person allowlist" do
    test "holds exactly one key" do
      assert Authority.causing_person_keys() == [@allowlisted]
    end

    test "refuses a second key at publish", %{tenant: tenant} do
      draft = draft!(tenant, %{key: "another.key"}, :causing_person)

      assert {:error, _} = result = Subscription.publish(draft, opts(tenant))
      assert message(result) =~ ~s|"another.key" may not run as the causing person|
    end

    test "refuses a second key on a draft", %{tenant: tenant} do
      draft = draft!(tenant, %{key: "another.key"})

      assert {:error, _} =
               result = Subscription.set_authority(draft, :causing_person, opts(tenant))

      assert message(result) =~ ~s|"another.key" may not run as the causing person|
    end

    test "is not something a person can choose, even for the allowlisted key", ctx do
      draft = draft!(ctx.tenant, %{key: @allowlisted})

      # Without authorization, so what refuses is the choice itself and not a missing grant.
      assert {:error, _} =
               result =
               draft
               |> Ash.Changeset.for_update(:set_authority, %{authority: :causing_person},
                 actor: DailyFixtures.actor(ctx.admin),
                 tenant: ctx.tenant,
                 authorize?: false
               )
               |> Ash.update()

      assert message(result) =~ "only the setup path chooses the causing person"
    end

    test "widened to two keys, refuses both", %{tenant: tenant} do
      previous = Application.get_env(:ash_enterprise, Subscription)

      on_exit(fn -> Application.put_env(:ash_enterprise, Subscription, previous) end)

      Application.put_env(:ash_enterprise, Subscription,
        causing_person_keys: [@allowlisted, "another.key"]
      )

      for key <- [@allowlisted, "another.key"] do
        draft = draft!(tenant, %{key: key}, :causing_person)
        assert {:error, _} = result = Subscription.publish(draft, opts(tenant))
        assert message(result) =~ "may not run as the causing person"
      end
    end

    test "a step of the allowlisted recipe's process runs as the person who caused it", ctx do
      key = process!(ctx.tenant, acting("serviceTask"))

      ctx.tenant
      |> draft!(%{key: @allowlisted, process_key: key})
      |> Subscription.set_authority!(:causing_person, opts(ctx.tenant))
      |> Subscription.publish!(opts(ctx.tenant))

      request = submit!(ctx)
      sweep!(ctx.tenant)
      assert reload(request, ctx.tenant).decision_outcome == nil

      # The dispatch row names the recipe before its step runs, and the step runs.
      assert [%Dispatch{}] = started(ctx.tenant)
      advance!()

      assert reload(request, ctx.tenant).decision_outcome == :rejected
    end
  end

  describe "a standing grant" do
    test "is refused by plain publish", %{tenant: tenant} do
      draft = draft!(tenant, %{}, :standing_grant)

      assert {:error, _} = result = Subscription.publish(draft, opts(tenant))
      assert message(result) =~ "a standing grant is published by the person accountable"
    end

    test "cannot be chosen on a draft", %{tenant: tenant} do
      assert {:error, _} =
               result =
               tenant |> draft!(%{}) |> Subscription.set_authority(:standing_grant, opts(tenant))

      assert message(result) =~ "a standing grant is published by the person accountable"
    end

    test "is refused at the step, should a row carry one", ctx do
      key = process!(ctx.tenant, @people_only)

      subscription =
        ctx.tenant |> draft!(%{process_key: key}) |> Subscription.publish!(opts(ctx.tenant))

      Ash.Seed.update!(subscription, %{authority: :standing_grant})

      publish_process!(ctx.tenant, key, acting("serviceTask"))
      request = submit!(ctx)
      sweep!(ctx.tenant)

      assert_raise RuntimeError, ~r/\{:no_authority, :standing_grant\}/, &advance!/0

      assert [%Dispatch{instance_id: instance_id}] = started(ctx.tenant)
      instance = instance!(instance_id, ctx.tenant)

      assert RecipeAuthority.check(%{instance: instance, tenant: ctx.tenant}) ==
               {:error, {:no_authority, :standing_grant}}

      assert reload(request, ctx.tenant).decision_outcome == nil
    end
  end

  describe "publishing fixes the authority" do
    test "a published recipe's authority cannot be changed", %{tenant: tenant} do
      published = tenant |> draft!(%{}) |> Subscription.publish!(opts(tenant))

      assert {:error, _} =
               result = Subscription.set_authority(published, :human_tasks_only, opts(tenant))

      assert message(result) =~ "authority is chosen on a draft"
    end

    test "choosing a draft's authority does not establish the tenant's cursor", %{
      tenant: tenant
    } do
      tenant |> draft!(%{}) |> Subscription.set_authority!(:human_tasks_only, opts(tenant))

      assert [] = Ash.read!(AshEnterprise.Bpmn.Cursor, authorize?: false, tenant: tenant)
    end
  end

  describe "a process no recipe started" do
    test "runs its steps as before", %{tenant: tenant} do
      assert RecipeAuthority.check(%{}) == :ok

      key = process!(tenant, @people_only)
      [definition] = Definition.latest_published!(key, opts(tenant))

      instance =
        AshBpmn.start_instance!(AshEnterprise.Bpmn,
          definition: definition,
          subject: %{__struct__: AccessRequest, id: Ash.UUID.generate()},
          actor: SystemActor.process(),
          tenant: tenant
        )

      assert RecipeAuthority.check(%{instance: instance, tenant: tenant}) == :ok
    end
  end
end
