defmodule AshEnterprise.Process.StandingGrantTest do
  @moduledoc """
  A recipe published as a standing grant (ADR 0069): a person runs `publish_granted`, and the
  steps of every process that version starts run as the `recipe_runner` automation principal
  acting for them, on the intersection of the two, rebuilt at every claim.

  The refusals come first: who may not publish one, what a version may not inherit, and the
  ways its steps run nothing (a publisher who has gone, a grant revoked or lapsed, a tenant
  that is not the instance's, a step that would run outside the grant, a target the publisher
  could not run although the runner could). Then the positive path: the step runs as the
  intersection, attributed to the accountable person, with the dispatch, event and grant on
  the audit entry, and a call activity's child keeps it.

  The person whose write causes the event (the clinic's administrator) is deliberately not
  the publisher: the cause is recorded on the dispatch and is never authority.
  SYNTHETIC data only.
  """

  use AshEnterprise.DataCase, async: false
  use Oban.Testing, repo: AshEnterprise.Repo

  import AshEnterprise.Test.Process.EvidenceChecks, only: [clinic!: 0]

  require Ash.Query

  alias AshEnterprise.Bpmn.{Definition, Dispatch, Instance, Subscription}
  alias AshEnterprise.Bpmn.Subscription.Authority
  alias AshEnterprise.Credentialing
  alias AshEnterprise.Credentialing.Credential
  alias AshEnterprise.Execution.{Identity, Invocation}
  alias AshEnterprise.Platform.{AutomationPrincipal, Correlation, SystemActor}
  alias AshEnterprise.Process.{ActionInvoker, RecipeAuthority}
  alias AshEnterprise.Security.{ActionReach, ActorContext, AgentStartGrant}
  alias AshEnterprise.Test.DailyFixtures
  alias AshEnterprise.Test.Execution.Authority, as: Grants

  @check_expiry """
  <?xml version="1.0" encoding="UTF-8"?>
  <bpmn2:definitions xmlns:bpmn2="http://www.omg.org/spec/BPMN/20100524/MODEL"
                     xmlns:ash="https://github.com/lukegalea/ash_bpmn/ns"
                     id="Definitions_standing_check" targetNamespace="https://example.com/bpmn">
    <bpmn2:process id="Process_standing_check" isExecutable="true">
      <bpmn2:startEvent id="Start"><bpmn2:outgoing>F1</bpmn2:outgoing></bpmn2:startEvent>
      <bpmn2:serviceTask id="CheckExpiry" name="Check the licence expiry">
        <bpmn2:extensionElements><ash:taskConfig action="check_licence_expiry"/></bpmn2:extensionElements>
        <bpmn2:incoming>F1</bpmn2:incoming>
        <bpmn2:outgoing>F2</bpmn2:outgoing>
      </bpmn2:serviceTask>
      <bpmn2:endEvent id="End"><bpmn2:incoming>F2</bpmn2:incoming></bpmn2:endEvent>
      <bpmn2:sequenceFlow id="F1" sourceRef="Start" targetRef="CheckExpiry"/>
      <bpmn2:sequenceFlow id="F2" sourceRef="CheckExpiry" targetRef="End"/>
    </bpmn2:process>
  </bpmn2:definitions>
  """

  # A step whose action is a legacy registry entry: it would run as the process actor.
  @legacy """
  <?xml version="1.0" encoding="UTF-8"?>
  <bpmn2:definitions xmlns:bpmn2="http://www.omg.org/spec/BPMN/20100524/MODEL"
                     xmlns:ash="https://github.com/lukegalea/ash_bpmn/ns"
                     id="Definitions_standing_legacy" targetNamespace="https://example.com/bpmn">
    <bpmn2:process id="Process_standing_legacy" isExecutable="true">
      <bpmn2:startEvent id="Start"><bpmn2:outgoing>F1</bpmn2:outgoing></bpmn2:startEvent>
      <bpmn2:serviceTask id="Legacy" name="A legacy step">
        <bpmn2:extensionElements><ash:taskConfig action="ACTION"/></bpmn2:extensionElements>
        <bpmn2:incoming>F1</bpmn2:incoming>
        <bpmn2:outgoing>F2</bpmn2:outgoing>
      </bpmn2:serviceTask>
      <bpmn2:endEvent id="End"><bpmn2:incoming>F2</bpmn2:incoming></bpmn2:endEvent>
      <bpmn2:sequenceFlow id="F1" sourceRef="Start" targetRef="Legacy"/>
      <bpmn2:sequenceFlow id="F2" sourceRef="Legacy" targetRef="End"/>
    </bpmn2:process>
  </bpmn2:definitions>
  """

  @parent """
  <?xml version="1.0" encoding="UTF-8"?>
  <bpmn2:definitions xmlns:bpmn2="http://www.omg.org/spec/BPMN/20100524/MODEL"
                     xmlns:ash="https://github.com/lukegalea/ash_bpmn/ns"
                     id="Definitions_standing_parent" targetNamespace="https://example.com/bpmn">
    <bpmn2:process id="Process_standing_parent" isExecutable="true">
      <bpmn2:startEvent id="Start"><bpmn2:outgoing>F1</bpmn2:outgoing></bpmn2:startEvent>
      <bpmn2:callActivity id="Child" name="Run the check">
        <bpmn2:extensionElements><ash:process key="CHILD_KEY"/></bpmn2:extensionElements>
        <bpmn2:incoming>F1</bpmn2:incoming>
        <bpmn2:outgoing>F2</bpmn2:outgoing>
      </bpmn2:callActivity>
      <bpmn2:endEvent id="End"><bpmn2:incoming>F2</bpmn2:incoming></bpmn2:endEvent>
      <bpmn2:sequenceFlow id="F1" sourceRef="Start" targetRef="Child"/>
      <bpmn2:sequenceFlow id="F2" sourceRef="Child" targetRef="End"/>
    </bpmn2:process>
  </bpmn2:definitions>
  """

  @subscription_grants [{Subscription, :read, :global}, {Subscription, :write, :global}]

  setup do
    clinic = clinic!()
    admin = clinic.admin

    # The publisher may publish recipes and read credentials; the narrow one may only
    # publish. Neither is the administrator, whose write is the event's cause.
    publisher =
      DailyFixtures.member!(
        admin,
        "Recipe publisher #{unique()}",
        @subscription_grants ++ [{Credential, :read, :global}]
      )

    narrow = DailyFixtures.member!(admin, "Narrow publisher #{unique()}", @subscription_grants)

    %{clinic: clinic, admin: admin, tenant: clinic.tenant, publisher: publisher, narrow: narrow}
  end

  defp unique, do: System.unique_integer([:positive])
  defp system(tenant), do: [actor: SystemActor.process(), tenant: tenant]

  defp process!(tenant, xml, key \\ nil) do
    key = key || "standing-#{unique()}"

    definition = Definition.create!(%{key: key, name: key, xml: xml}, system(tenant))
    assert definition.errors in [nil, []], "#{key} did not compile: #{inspect(definition.errors)}"
    Definition.publish!(definition, system(tenant))
    key
  end

  # A draft that starts `process_key` whenever a credential is recorded.
  defp draft!(tenant, process_key, key \\ nil) do
    Subscription
    |> Ash.Changeset.for_create(
      :create,
      %{
        key: key || "standing.recipe.#{unique()}",
        match_resource: "AshEnterprise.Credentialing.Credential",
        match_action: :record,
        match_action_type: :create,
        process_key: process_key
      },
      system(tenant)
    )
    |> Ash.create!()
  end

  defp publish_granted!(draft, person),
    do: Subscription.publish_granted!(draft, actor: person.actor, tenant: person.tenant)

  defp runner_role!(admin, grants), do: Grants.automation_role!(admin, :recipe_runner, grants)

  # The event: the administrator records a credential.
  defp record_credential!(ctx) do
    Credentialing.record_credential!(
      %{
        kind: :licence,
        number: "DEMO-RN-#{unique()}",
        expires_on: Date.add(Date.utc_today(), 200),
        clinician_id: ctx.clinic.credential.clinician_id
      },
      actor: ctx.admin.actor,
      tenant: ctx.tenant
    )
  end

  # The sweep as production runs it: the first advance is a job that runs once the instance
  # and its dispatch row have committed together (see `RecipeAuthorityTest`).
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

  defp started!(tenant) do
    assert [dispatch] =
             Dispatch
             |> Ash.Query.filter(status == :started)
             |> Ash.read!(authorize?: false, tenant: tenant)

    {dispatch, Ash.get!(Instance, dispatch.instance_id, authorize?: false, tenant: tenant)}
  end

  defp invocations(tenant) do
    Invocation
    |> Ash.Query.sort(created_on: :asc)
    |> Ash.read!(actor: SystemActor.oban(), tenant: tenant)
  end

  defp grant!(subscription) do
    AgentStartGrant
    |> Ash.Query.filter(agent_key == ^Authority.grant_key(subscription))
    |> Ash.read_one!(authorize?: false, tenant: subscription.organization_id)
  end

  defp acting_for(person, name) do
    AutomationPrincipal.acting(
      apply(AutomationPrincipal, name, []),
      person.user.id,
      "standing-grant-test",
      ActorContext.intersect(
        ActorContext.build(person.user, tenant: person.tenant),
        ActorContext.build_automation(name, person.tenant)
      )
    )
  end

  defp engine_publish_granted(draft, actor, tenant) do
    draft
    |> Ash.Changeset.for_update(:publish_granted, %{},
      actor: actor,
      tenant: tenant,
      context: %{private: %{ash_bpmn?: true}}
    )
    |> Ash.update()
  end

  defp message({:error, error}), do: Exception.message(error)

  defp team!(admin, member) do
    team =
      AshEnterprise.Accounts.Team
      |> Ash.Changeset.for_create(
        :create,
        %{name: "Ward #{unique()}", owning_business_unit_id: admin.user.owning_business_unit_id},
        actor: SystemActor.seed(),
        tenant: admin.tenant
      )
      |> Ash.create!()

    AshEnterprise.Accounts.TeamMembership
    |> Ash.Changeset.for_create(:create, %{team_id: team.id, user_id: member.user.id},
      actor: SystemActor.seed(),
      tenant: admin.tenant
    )
    |> Ash.create!()

    team
  end

  # The steps an action runs, by module (and the attribute a built-in names).
  defp step_modules(action_name) do
    Subscription
    |> Ash.Resource.Info.action(action_name)
    |> Map.fetch!(:changes)
    |> Enum.map(fn
      %Ash.Resource.Validation{validation: {module, opts}} -> {module, opts[:attribute]}
      %Ash.Resource.Change{change: {module, opts}} -> {module, opts[:attribute]}
    end)
  end

  # Whether a resource-wide validation or change, by its `where`, applies to `action_name`.
  defp applies_to?(%{where: where}, action_name) do
    Enum.all?(where, fn
      {Ash.Resource.Validation.ActionIs, opts} ->
        action_name in List.wrap(opts[:action])

      {Ash.Resource.Validation.Negate, opts} ->
        case opts[:validation] do
          {Ash.Resource.Validation.ActionIs, inner} ->
            action_name not in List.wrap(inner[:action])

          _other ->
            true
        end

      _other ->
        true
    end)
  end

  defp global_steps(action_name) do
    validations =
      for %Ash.Resource.Validation{validation: {module, opts}} = v <-
            Ash.Resource.Info.validations(Subscription),
          :update in v.on,
          applies_to?(v, action_name),
          do: {module, opts[:attribute]}

    changes =
      for %Ash.Resource.Change{change: {module, opts}} = c <-
            Ash.Resource.Info.changes(Subscription),
          :update in c.on,
          applies_to?(c, action_name),
          do: {module, opts[:attribute]}

    validations ++ changes
  end

  describe "publish_granted is a person's own act" do
    test "it is human-only, beside the macro's own publish" do
      assert ActionReach.human_only?(Subscription, :publish_granted)
      refute ActionReach.human_only?(Subscription, :publish)
    end

    for name <- [:process, :seed] do
      test "the #{name} system actor is Forbidden", %{tenant: tenant} do
        draft = draft!(tenant, "nothing-published")

        assert {:error, %Ash.Error.Forbidden{}} =
                 Subscription.publish_granted(draft,
                   actor: apply(SystemActor, unquote(name), []),
                   tenant: tenant
                 )

        assert Ash.reload!(draft, authorize?: false).status == :draft
      end
    end

    test "an automation principal acting for a person who may publish is Forbidden", ctx do
      for name <- [:recipe_runner, :evidence_admitter] do
        assert {:error, %Ash.Error.Forbidden{}} =
                 ctx.tenant
                 |> draft!("nothing-published")
                 |> Subscription.publish_granted(
                   actor: acting_for(ctx.publisher, name),
                   tenant: ctx.tenant
                 )
      end
    end

    test "an engine-marked call is Forbidden, as a principal or as a system actor", ctx do
      for actor <- [acting_for(ctx.publisher, :recipe_runner), SystemActor.process()] do
        assert {:error, %Ash.Error.Forbidden{}} =
                 ctx.tenant
                 |> draft!("nothing-published")
                 |> engine_publish_granted(actor, ctx.tenant)
      end

      assert [] = Ash.read!(AgentStartGrant, authorize?: false, tenant: ctx.tenant)
    end

    # The macro has no option for extra actions, so publish_granted restates publish by
    # module name. A step the library adds to publish later must be added here too.
    test "it carries every step publish carries" do
      assert step_modules(:publish) -- step_modules(:publish_granted) == []

      # The resource-wide ones too, except the two that read the authority a draft brings
      # into publish and the refusal of a standing grant by publish itself.
      authority_specific = [
        {AshEnterprise.Bpmn.Subscription.Validations.HumanTasksOnly, nil},
        {AshEnterprise.Bpmn.Subscription.Validations.CausingPersonAllowlisted, nil},
        {Ash.Resource.Validation.AttributeDoesNotEqual, :authority}
      ]

      assert (global_steps(:publish) -- authority_specific) -- global_steps(:publish_granted) ==
               []
    end

    test "a diagram that names a legacy step is refused, grant_role included", ctx do
      for action <- ["reject_request", "grant_role", "start_agent_run"] do
        key = process!(ctx.tenant, String.replace(@legacy, "ACTION", action))
        draft = draft!(ctx.tenant, key)

        assert {:error, _} =
                 result =
                 Subscription.publish_granted(draft,
                   actor: ctx.publisher.actor,
                   tenant: ctx.tenant
                 )

        assert message(result) =~ "a standing grant cannot start #{key}"
        assert message(result) =~ "serviceTask Legacy (#{action}"
        assert Ash.reload!(draft, authorize?: false).status == :draft
      end
    end

    test "a process that is not published yet is refused: there is no diagram to see", ctx do
      draft = draft!(ctx.tenant, "nothing-published-#{unique()}")

      assert {:error, _} =
               result =
               Subscription.publish_granted(draft, actor: ctx.publisher.actor, tenant: ctx.tenant)

      assert message(result) =~ "a standing grant needs a published process to cover"
      assert Ash.reload!(draft, authorize?: false).status == :draft
    end

    test "a resource with no tenant is refused here too", ctx do
      draft =
        Subscription
        |> Ash.Changeset.for_create(
          :create,
          %{
            key: "standing.user.#{unique()}",
            match_resource: "AshEnterprise.Accounts.User",
            process_key: "nothing-published"
          },
          system(ctx.tenant)
        )
        |> Ash.create!()

      assert {:error, _} =
               result =
               Subscription.publish_granted(draft, actor: ctx.publisher.actor, tenant: ctx.tenant)

      assert message(result) =~ "it has no tenant"
    end
  end

  describe "a version's grant is its own" do
    test "v2 cannot inherit v1's grant", ctx do
      key = process!(ctx.tenant, @check_expiry)
      recipe = "standing.versions.#{unique()}"

      v1 = ctx.tenant |> draft!(key, recipe) |> publish_granted!(ctx.publisher)
      assert grant!(v1).principal_id == ctx.publisher.user.id

      # A second version, carried to published with the same authority and person past
      # publish_granted, so the only thing it lacks is a grant of its own.
      v2 = draft!(ctx.tenant, key, recipe)
      assert v2.version == v1.version + 1
      assert Authority.grant_key(v2) != Authority.grant_key(v1)
      Subscription.retire!(v1, system(ctx.tenant))

      Ash.Seed.update!(v2, %{
        status: :published,
        authority: :standing_grant,
        accountable_person_id: ctx.publisher.user.id
      })

      runner_role!(ctx.admin, [{Credential, :read, :global}])
      record_credential!(ctx)
      sweep!(ctx.tenant)

      {dispatch, instance} = started!(ctx.tenant)
      assert dispatch.subscription_id == v2.id

      assert RecipeAuthority.check(%{instance: instance, tenant: ctx.tenant}) ==
               {:error, {:no_authority, :no_start_grant}}

      assert_raise RuntimeError, ~r/\{:no_authority, :no_start_grant\}/, &advance!/0
      assert invocations(ctx.tenant) == []
    end

    test "publishing v2 as a standing grant writes v2's own grant", ctx do
      key = process!(ctx.tenant, @check_expiry)
      recipe = "standing.versions.#{unique()}"

      v1 = ctx.tenant |> draft!(key, recipe) |> publish_granted!(ctx.publisher)
      Subscription.retire!(v1, system(ctx.tenant))
      v2 = ctx.tenant |> draft!(key, recipe) |> publish_granted!(ctx.publisher)

      assert grant!(v1).id != grant!(v2).id
      assert grant!(v2).agent_key == "recipe:#{recipe}:#{v2.version}"
    end
  end

  describe "a step runs nothing" do
    test "when its publisher has been deactivated: no_authority, and no invocation", ctx do
      key = process!(ctx.tenant, @check_expiry)
      ctx.tenant |> draft!(key) |> publish_granted!(ctx.publisher)
      runner_role!(ctx.admin, [{Credential, :read, :global}])

      record_credential!(ctx)
      sweep!(ctx.tenant)
      DailyFixtures.deactivate!(ctx.publisher)

      {_dispatch, instance} = started!(ctx.tenant)

      assert RecipeAuthority.check(%{instance: instance, tenant: ctx.tenant}) ==
               {:error, {:no_authority, :inactive}}

      assert_raise RuntimeError, ~r/\{:no_authority, :inactive\}/, &advance!/0
      assert invocations(ctx.tenant) == []
      assert Ash.reload!(instance, authorize?: false).status != :completed
    end

    test "when its publisher has moved to another tenant", ctx do
      key = process!(ctx.tenant, @check_expiry)
      ctx.tenant |> draft!(key) |> publish_granted!(ctx.publisher)

      record_credential!(ctx)
      sweep!(ctx.tenant)
      Grants.move_to!(ctx.publisher, clinic!().admin)

      {_dispatch, instance} = started!(ctx.tenant)

      assert RecipeAuthority.check(%{instance: instance, tenant: ctx.tenant}) ==
               {:error, {:no_authority, :other_tenant}}
    end

    test "when the grant has lapsed or been revoked", ctx do
      key = process!(ctx.tenant, @check_expiry)
      subscription = ctx.tenant |> draft!(key) |> publish_granted!(ctx.publisher)
      grant = grant!(subscription)

      # Published with a review date a year ahead of it.
      assert Authority.grant_review_days() == 365
      assert DateTime.after?(grant.valid_until, DateTime.add(DateTime.utc_now(), 300, :day))

      record_credential!(ctx)
      sweep!(ctx.tenant)
      {_dispatch, instance} = started!(ctx.tenant)
      engine_ctx = %{instance: instance, tenant: ctx.tenant}

      assert {:ok, %{authority: :standing_grant}} = RecipeAuthority.check(engine_ctx)

      Ash.Seed.update!(grant, %{valid_until: DateTime.add(DateTime.utc_now(), -1, :second)})
      assert RecipeAuthority.check(engine_ctx) == {:error, {:no_authority, :no_start_grant}}

      Ash.destroy!(grant, authorize?: false, tenant: ctx.tenant)
      assert RecipeAuthority.check(engine_ctx) == {:error, {:no_authority, :no_start_grant}}

      assert_raise RuntimeError, ~r/\{:no_authority, :no_start_grant\}/, &advance!/0
      assert invocations(ctx.tenant) == []
    end

    test "when the job names a tenant that is not the instance's", ctx do
      key = process!(ctx.tenant, @check_expiry)
      ctx.tenant |> draft!(key) |> publish_granted!(ctx.publisher)

      record_credential!(ctx)
      sweep!(ctx.tenant)
      {_dispatch, instance} = started!(ctx.tenant)

      assert RecipeAuthority.check(%{instance: instance, tenant: clinic!().tenant}) ==
               {:error, {:no_authority, :other_tenant}}
    end

    test "when a row carries a standing grant with nobody accountable for it", ctx do
      # Published plainly over a key with nothing published yet, then given a process that
      # acts and a standing grant past publish_granted, so nobody was stamped.
      key = "standing-#{unique()}"
      subscription = ctx.tenant |> draft!(key) |> Subscription.publish!(system(ctx.tenant))
      process!(ctx.tenant, @check_expiry, key)
      Ash.Seed.update!(subscription, %{authority: :standing_grant})

      record_credential!(ctx)
      sweep!(ctx.tenant)
      {_dispatch, instance} = started!(ctx.tenant)

      assert RecipeAuthority.check(%{instance: instance, tenant: ctx.tenant}) ==
               {:error, {:no_authority, :requesterless}}
    end

    test "when its process later names a legacy step", ctx do
      key = process!(ctx.tenant, @check_expiry)
      ctx.tenant |> draft!(key) |> publish_granted!(ctx.publisher)

      # The diagram changes under the published recipe: a version its publisher never saw.
      process!(ctx.tenant, String.replace(@legacy, "ACTION", "reject_request"), key)

      record_credential!(ctx)
      sweep!(ctx.tenant)

      assert_raise RuntimeError, ~r/\{:no_authority, :definition_not_granted\}/, &advance!/0
      assert invocations(ctx.tenant) == []
    end

    test "when the publisher could not run the target, though the runner could", ctx do
      key = process!(ctx.tenant, @check_expiry)
      subscription = ctx.tenant |> draft!(key) |> publish_granted!(ctx.narrow)
      runner_role!(ctx.admin, [{Credential, :read, :global}])

      record_credential!(ctx)
      sweep!(ctx.tenant)

      assert_raise RuntimeError, ~r/invocation_failed/, &advance!/0

      assert [row] = invocations(ctx.tenant)
      # Refused as it is made, as the actor a claim would build: nobody is asked.
      assert {row.status, row.failure_class, row.error_code} ==
               {:rejected, :rejected, "not_permitted"}

      assert row.executing_principal == %{
               type: :automation,
               id: "recipe_runner",
               on_behalf_of: ctx.narrow.user.id,
               agent: Authority.grant_key(subscription)
             }
    end

    test "when the runner holds no role, whatever the publisher may do", ctx do
      key = process!(ctx.tenant, @check_expiry)
      ctx.tenant |> draft!(key) |> publish_granted!(ctx.publisher)

      record_credential!(ctx)
      sweep!(ctx.tenant)

      assert_raise RuntimeError, ~r/invocation_failed/, &advance!/0
      assert [row] = invocations(ctx.tenant)

      assert {row.status, row.failure_class, row.error_code} ==
               {:rejected, :rejected, "not_permitted"}
    end
  end

  describe "a person publishes a standing grant" do
    test "the step runs as the intersection, for the accountable person", ctx do
      key = process!(ctx.tenant, @check_expiry)
      subscription = ctx.tenant |> draft!(key) |> publish_granted!(ctx.publisher)

      assert {subscription.status, subscription.authority, subscription.accountable_person_id} ==
               {:published, :standing_grant, ctx.publisher.user.id}

      # The diagram its publisher saw, and only that one, is what its steps may run in.
      [definition] =
        AshEnterprise.Bpmn.Subscription.Validations.StandingGrantSteps.definitions(
          key,
          ctx.tenant
        )

      assert subscription.granted_definition_ids == [definition.id]

      grant = grant!(subscription)
      assert {grant.principal_id, grant.principal_type} == {ctx.publisher.user.id, :user}

      runner_role!(ctx.admin, [{Credential, :read, :global}])
      credential = record_credential!(ctx)
      sweep!(ctx.tenant)
      advance!()

      {dispatch, instance} = started!(ctx.tenant)
      assert Ash.reload!(instance, authorize?: false).status == :completed

      # The administrator caused the event; the cause is recorded and is not who ran it.
      assert dispatch.caused_by_id == ctx.admin.user.id
      assert instance.subject_id == credential.id

      assert [row] = invocations(ctx.tenant)
      assert row.status == :succeeded
      assert row.owner_id == ctx.publisher.user.id

      assert row.executing_principal == %{
               type: :automation,
               id: "recipe_runner",
               on_behalf_of: ctx.publisher.user.id,
               agent: Authority.grant_key(subscription)
             }

      # The actor a claim builds is the principal acting for the publisher, on the
      # intersection, and its audit entry names what it ran under.
      assert {:ok, %AutomationPrincipal{name: :recipe_runner} = actor} = Identity.actor_for(row)
      assert actor.id == ctx.publisher.user.id

      assert Map.take(Correlation.audit_metadata(actor), [
               "automation_principal",
               "on_behalf_of_id",
               "recipe_dispatch_id",
               "recipe_event_id",
               "recipe_grant_id"
             ]) == %{
               "automation_principal" => "recipe_runner",
               "on_behalf_of_id" => ctx.publisher.user.id,
               "recipe_dispatch_id" => dispatch.id,
               "recipe_event_id" => dispatch.event_id,
               "recipe_grant_id" => grant.id
             }
    end

    test "a call activity's child runs under the same grant", ctx do
      child = process!(ctx.tenant, @check_expiry)
      parent = process!(ctx.tenant, String.replace(@parent, "CHILD_KEY", child))
      subscription = ctx.tenant |> draft!(parent) |> publish_granted!(ctx.publisher)
      runner_role!(ctx.admin, [{Credential, :read, :global}])

      record_credential!(ctx)
      sweep!(ctx.tenant)
      advance!()

      {_dispatch, root} = started!(ctx.tenant)
      subscription = Ash.reload!(subscription, authorize?: false)
      assert length(subscription.granted_definition_ids) == 2

      assert [child_instance] =
               Instance
               |> Ash.Query.filter(parent_instance_id == ^root.id)
               |> Ash.read!(authorize?: false, tenant: ctx.tenant)

      assert [row] = invocations(ctx.tenant)
      assert row.process_instance_id == child_instance.id
      assert row.status == :succeeded

      assert row.executing_principal == %{
               type: :automation,
               id: "recipe_runner",
               on_behalf_of: ctx.publisher.user.id,
               agent: Authority.grant_key(subscription)
             }

      assert {:ok, %{authority: :standing_grant}} =
               RecipeAuthority.check(%{instance: child_instance, tenant: ctx.tenant})
    end
  end

  describe "the cause is never authority" do
    test "a legacy entry is refused under a standing grant whoever caused the event", ctx do
      key = process!(ctx.tenant, @check_expiry)
      ctx.tenant |> draft!(key) |> publish_granted!(ctx.publisher)

      record_credential!(ctx)
      sweep!(ctx.tenant)
      {_dispatch, instance} = started!(ctx.tenant)

      assert ActionInvoker.invoke("reject_request", %{instance: instance, tenant: ctx.tenant}) ==
               {:error, {:no_authority, :not_an_invocation_target}}

      assert ActionInvoker.invocation_target?("check_licence_expiry")
      refute ActionInvoker.invocation_target?("grant_role")
    end
  end

  # The rows a standing grant is decided from are written only by the engine and by
  # publish_granted. A person whose role reaches a resource's create may still not forge one.
  describe "the rows a standing grant is decided from cannot be forged" do
    setup ctx do
      key = process!(ctx.tenant, @check_expiry)
      subscription = ctx.tenant |> draft!(key) |> publish_granted!(ctx.publisher)
      runner_role!(ctx.admin, [{Credential, :read, :global}])

      # An instance of the same process, started by the administrator, with no recipe.
      definition =
        Definition
        |> Ash.Query.filter(key == ^key and status == :published)
        |> Ash.read_one!(authorize?: false, tenant: ctx.tenant)

      own =
        AshBpmn.start_instance!(AshEnterprise.Bpmn,
          definition: definition,
          subject: ctx.clinic.credential,
          actor: SystemActor.process(),
          started_by_id: ctx.admin.user.id,
          tenant: ctx.tenant
        )

      %{subscription: subscription, definition: definition, own: own}
    end

    test "a person may not write a dispatch naming their own instance, nor a system actor", ctx do
      assert ActionReach.engine_only?(Dispatch, :create)

      for actor <- [ctx.admin.actor, SystemActor.process(), SystemActor.oban()] do
        assert {:error, %Ash.Error.Forbidden{}} =
                 Dispatch.create(
                   %{
                     subscription_id: ctx.subscription.id,
                     event_id: Ash.UUID.generate(),
                     event_sequence: 1,
                     event_occurred_at: DateTime.utc_now(),
                     kind: :start,
                     status: :started,
                     instance_id: ctx.own.id
                   },
                   actor: actor,
                   tenant: ctx.tenant
                 )
      end

      assert RecipeAuthority.check(%{instance: ctx.own, tenant: ctx.tenant}) == :ok
    end

    test "a person may not start an instance under a recipe's instance", ctx do
      assert ActionReach.engine_only?(Instance, :create)

      record_credential!(ctx)
      sweep!(ctx.tenant)
      {_dispatch, root} = started!(ctx.tenant)

      assert {:error, %Ash.Error.Forbidden{}} =
               Instance.create(
                 %{
                   definition_id: ctx.definition.id,
                   subject_type: to_string(Credential),
                   subject_id: ctx.clinic.credential.id,
                   started_by_id: ctx.admin.user.id,
                   parent_instance_id: root.id
                 },
                 actor: ctx.admin.actor,
                 tenant: ctx.tenant
               )
    end

    test "nobody but publish_granted writes a recipe's start grant", ctx do
      grant = grant!(ctx.subscription)
      Ash.destroy!(grant, authorize?: false, tenant: ctx.tenant)
      team = team!(ctx.admin, ctx.publisher)

      for {principal_id, principal_type, actor} <- [
            {ctx.publisher.user.id, :user, ctx.admin.actor},
            {ctx.publisher.user.id, :user, ctx.publisher.actor},
            {team.id, :team, ctx.admin.actor}
          ] do
        assert {:error, _refused} =
                 AgentStartGrant.grant(
                   %{
                     agent_key: Authority.grant_key(ctx.subscription),
                     principal_id: principal_id,
                     principal_type: principal_type,
                     valid_until: nil
                   },
                   actor: actor,
                   tenant: ctx.tenant
                 )
      end

      assert [] = Ash.read!(AgentStartGrant, authorize?: false, tenant: ctx.tenant)
    end

    test "a recipe's start grant held through a team counts for nothing", ctx do
      grant = grant!(ctx.subscription)
      Ash.destroy!(grant, authorize?: false, tenant: ctx.tenant)
      team = team!(ctx.admin, ctx.publisher)

      Ash.Seed.seed!(AgentStartGrant, %{
        agent_key: Authority.grant_key(ctx.subscription),
        principal_id: team.id,
        principal_type: :team,
        organization_id: ctx.tenant
      })

      record_credential!(ctx)
      sweep!(ctx.tenant)
      {_dispatch, instance} = started!(ctx.tenant)

      assert RecipeAuthority.check(%{instance: instance, tenant: ctx.tenant}) ==
               {:error, {:no_authority, :no_start_grant}}
    end
  end

  # The publisher reviewed the diagrams publish_granted saw. Anything else runs nothing.
  describe "a standing grant runs only the diagrams its publisher saw" do
    test "a later version of the process runs nothing", ctx do
      key = process!(ctx.tenant, @check_expiry)
      ctx.tenant |> draft!(key) |> publish_granted!(ctx.publisher)
      runner_role!(ctx.admin, [{Credential, :read, :global}])

      # A new version under the key, naming another declared target.
      process!(
        ctx.tenant,
        String.replace(@check_expiry, "check_licence_expiry", "check_licence_documents"),
        key
      )

      record_credential!(ctx)
      sweep!(ctx.tenant)
      {_dispatch, instance} = started!(ctx.tenant)

      assert RecipeAuthority.check(%{instance: instance, tenant: ctx.tenant}) ==
               {:error, {:no_authority, :definition_not_granted}}

      assert_raise RuntimeError, ~r/\{:no_authority, :definition_not_granted\}/, &advance!/0
      assert invocations(ctx.tenant) == []
    end

    test "a later version of a call activity's child runs nothing", ctx do
      child = process!(ctx.tenant, @check_expiry)
      parent = process!(ctx.tenant, String.replace(@parent, "CHILD_KEY", child))
      ctx.tenant |> draft!(parent) |> publish_granted!(ctx.publisher)
      runner_role!(ctx.admin, [{Credential, :read, :global}])

      process!(
        ctx.tenant,
        String.replace(@check_expiry, "check_licence_expiry", "check_licence_documents"),
        child
      )

      record_credential!(ctx)
      sweep!(ctx.tenant)

      assert_raise RuntimeError, ~r/\{:no_authority, :definition_not_granted\}/, &advance!/0
      assert invocations(ctx.tenant) == []
    end

    test "a decision route is refused: a standing grant starts one named process", ctx do
      decision = "standing.route.#{unique()}"

      decision
      |> then(
        &AshEnterprise.Decisions.Definition.create!(
          %{key: &1, name: &1, xml: File.read!("priv/dmn/access_request_risk.dmn")},
          system(ctx.tenant)
        )
      )
      |> AshEnterprise.Decisions.Definition.publish!(system(ctx.tenant))

      draft =
        Subscription
        |> Ash.Changeset.for_create(
          :create,
          %{
            key: "standing.decision.#{unique()}",
            match_resource: "AshEnterprise.Credentialing.Credential",
            match_action: :record,
            match_action_type: :create,
            route_kind: :decision,
            decision_key: decision
          },
          system(ctx.tenant)
        )
        |> Ash.create!()

      assert {:error, _} =
               result =
               Subscription.publish_granted(draft, actor: ctx.publisher.actor, tenant: ctx.tenant)

      assert message(result) =~ "a standing grant starts one named process"
      assert Ash.reload!(draft, authorize?: false).status == :draft
    end
  end

  describe "the recipe runner" do
    test "is no agent version's authority, and with no role it holds nothing", ctx do
      authority = %{"type" => "automation", "name" => "recipe_runner"}
      version = %{model_profile: AshEnterprise.AI.Models.in_zone_profile_name()}

      assert AshEnterprise.Execution.Validations.Publishable.problems(version, authority) == [
               "recipe_runner runs only a recipe's standing grant, never an agent version"
             ]

      assert ActorContext.build_automation(:recipe_runner, ctx.tenant).grants == %{}
    end
  end
end
