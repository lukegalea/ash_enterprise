defmodule AshEnterprise.Provenance.DelegatedTest do
  @moduledoc """
  Delegated writes in the audit explainer (ADR 0078, section 2, agents mapped
  once): an impersonated write was associated with the subject, and the operator
  acted on their behalf; a recipe step ran as the `recipe_runner` principal for
  the version's accountable person, under a dispatch — named when the reader
  may read it, and one `:unreadable` gap when they may not. The person who
  caused the triggering event is never an agent of the step (ADR 0069).
  """

  use AshEnterprise.DataCase, async: false
  use Oban.Testing, repo: AshEnterprise.Repo

  import AshEnterprise.Test.DailyFixtures, only: [tenant!: 0, member!: 3]
  import AshEnterprise.Test.Process.EvidenceChecks, only: [clinic!: 0]

  require Ash.Query

  alias AshEnterprise.Audit.EventLog
  alias AshEnterprise.Bpmn.{Definition, Dispatch, Subscription}
  alias AshEnterprise.Bpmn.Subscription.Authority
  alias AshEnterprise.Canonical.Task
  alias AshEnterprise.Platform.AutomationPrincipal
  alias AshEnterprise.Provenance
  alias AshEnterprise.Security.{ActorContext, AgentStartGrant}
  alias AshEnterprise.Security.Impersonation

  @check_expiry """
  <?xml version="1.0" encoding="UTF-8"?>
  <bpmn2:definitions xmlns:bpmn2="http://www.omg.org/spec/BPMN/20100524/MODEL"
                     xmlns:ash="https://github.com/lukegalea/ash_bpmn/ns"
                     id="Definitions_provenance_check" targetNamespace="https://example.com/bpmn">
    <bpmn2:process id="Process_provenance_check" isExecutable="true">
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

  describe "impersonation" do
    setup do
      admin = tenant!()
      unique = System.unique_integer([:positive])

      subject = member!(admin, "Subject #{unique}", [])
      operator = member!(admin, "Operator #{unique}", [])

      # The subject's write, made while the operator held the keyboard.
      actor = Impersonation.acting_as(subject.actor, operator.user.id)

      task =
        Task.capture!("Cover the desk #{unique}", %{},
          actor: actor,
          tenant: admin.tenant,
          authorize?: false
        )

      %{
        admin: admin,
        subject: subject,
        operator: operator,
        task: task
      }
    end

    test "the activity names the subject, and the operator acted on their behalf", %{
      admin: admin,
      subject: subject,
      operator: operator,
      task: task
    } do
      reader =
        member!(admin, "Audit reader #{System.unique_integer([:positive])}", [
          {Task, :read, :global},
          {EventLog, :read, :global},
          {AshEnterprise.Accounts.User, :read, :global}
        ])

      {:ok, %{explanation: explanation}} = explain(reader, "task", task.id, "title")

      associated = step(explanation, :was_associated_with)
      assert associated.agent_label == subject.email

      assert [behalf] = Enum.filter(explanation.steps, &(&1.relation == :acted_on_behalf_of))
      assert behalf.agent_label == operator.email
      assert behalf.on_behalf_of == subject.email
    end

    test "a reader who may not read users learns only that persons acted", %{
      admin: admin,
      subject: subject,
      task: task
    } do
      reader =
        member!(admin, "Blind reader #{System.unique_integer([:positive])}", [
          {Task, :read, :global},
          {EventLog, :read, :global}
        ])

      {:ok, %{explanation: explanation}} = explain(reader, "task", task.id, "title")

      assert step(explanation, :was_associated_with).agent_label == "a person"

      assert [behalf] = Enum.filter(explanation.steps, &(&1.relation == :acted_on_behalf_of))
      assert behalf.agent_label == "a person"
      assert behalf.on_behalf_of == "a person"
      refute inspect(explanation) =~ subject.email
    end
  end

  describe "a recipe step" do
    setup do
      clinic = clinic!()
      admin = clinic.admin
      tenant = clinic.tenant
      unique = System.unique_integer([:positive])

      # The publisher is the version's accountable person; the administrator's
      # credential write is what caused the event, and is never authority.
      publisher =
        member!(admin, "Recipe publisher #{unique}", [
          {Subscription, :read, :global},
          {Subscription, :write, :global}
        ])

      key = "provenance-recipe-#{unique}"
      definition = Definition.create!(%{key: key, name: key, xml: @check_expiry}, system(tenant))
      assert definition.errors in [nil, []]
      Definition.publish!(definition, system(tenant))

      subscription =
        Subscription
        |> Ash.Changeset.for_create(
          :create,
          %{
            key: "provenance.recipe.#{unique}",
            match_resource: "AshEnterprise.Credentialing.Credential",
            match_action: :record,
            match_action_type: :create,
            process_key: key
          },
          system(tenant)
        )
        |> Ash.create!()
        |> Subscription.publish_granted!(actor: publisher.actor, tenant: tenant)

      # The triggering event, whose cause is the administrator.
      AshEnterprise.Credentialing.record_credential!(
        %{
          kind: :licence,
          number: "DEMO-RN-#{unique}",
          expires_on: Date.add(Date.utc_today(), 365),
          clinician_id: clinic.credential.clinician_id
        },
        actor: admin.actor,
        tenant: tenant
      )

      sweep!(tenant)

      assert [dispatch] =
               Dispatch
               |> Ash.Query.filter(status == :started)
               |> Ash.read!(authorize?: false, tenant: tenant)

      assert [grant] =
               AgentStartGrant
               |> Ash.Query.filter(agent_key == ^Authority.grant_key(subscription))
               |> Ash.read!(authorize?: false, tenant: tenant)

      # The write a recipe step makes: the runner principal, for the publisher,
      # under the dispatch and the grant it ran on.
      actor = recipe_actor(publisher, subscription, dispatch, grant, tenant)

      task =
        Task.capture!("Follow up the licence #{unique}", %{},
          actor: actor,
          tenant: tenant,
          authorize?: false
        )

      %{
        admin: admin,
        publisher: publisher,
        dispatch: dispatch,
        grant: grant,
        task: task
      }
    end

    test "a reader who may read the dispatch and the grant sees both", %{
      admin: admin,
      publisher: publisher,
      dispatch: dispatch,
      grant: grant,
      task: task
    } do
      reader =
        member!(admin, "Recipe reader #{System.unique_integer([:positive])}", [
          {Task, :read, :global},
          {EventLog, :read, :global},
          {Dispatch, :read, :global},
          {AgentStartGrant, :read, :global},
          {AshEnterprise.Accounts.User, :read, :global}
        ])

      {:ok, %{explanation: explanation}} = explain(reader, "task", task.id, "title")

      assert [behalf] = Enum.filter(explanation.steps, &(&1.relation == :acted_on_behalf_of))
      assert behalf.agent_label == "an automation principal (recipe_runner)"
      assert behalf.on_behalf_of == publisher.email
      assert behalf.activity == "dispatch:" <> to_string(dispatch.id)

      assert [used] = Enum.filter(explanation.steps, &(&1.relation == :used))
      assert used.entity.resource == "agent_start_grant"
      assert used.entity.id == grant.id
      assert used.activity == "dispatch:" <> to_string(dispatch.id)
      assert used.granularity == :record
      assert used.summary == "standing grant"

      # The person who caused the event is named nowhere (ADR 0069).
      refute inspect(explanation) =~ admin.email
      refute inspect(explanation) =~ admin.user.id
    end

    test "a reader who may read neither gets one unreadable gap and neither id", %{
      admin: admin,
      dispatch: dispatch,
      grant: grant,
      task: task
    } do
      reader =
        member!(admin, "Unreadable reader #{System.unique_integer([:positive])}", [
          {Task, :read, :global},
          {EventLog, :read, :global}
        ])

      result = explain(reader, "task", task.id, "title")
      assert {:ok, %{explanation: explanation}} = result

      assert [gap] = Enum.filter(explanation.gaps, &(&1.kind == :unreadable))
      assert gap.of.attribute == "title"

      # One gap, and no identifier of either row anywhere in the answer.
      assert Enum.count(explanation.gaps, &(&1.kind == :unreadable)) == 1
      refute inspect(result) =~ to_string(dispatch.id)
      refute inspect(result) =~ to_string(grant.id)

      assert Enum.filter(explanation.steps, &(&1.relation == :acted_on_behalf_of)) != []

      assert Enum.filter(explanation.steps, &(&1.relation == :used)) == []
    end
  end

  # -- Helpers -------------------------------------------------------------

  defp explain(ctx, type, id, attribute) do
    Provenance.explain("#{Provenance.base()}/#{type}/#{id}##{attribute}",
      actor: ctx.actor,
      tenant: ctx.tenant
    )
  end

  defp step(explanation, relation), do: Enum.find(explanation.steps, &(&1.relation == relation))

  defp system(tenant), do: [actor: AshEnterprise.Platform.SystemActor.process(), tenant: tenant]

  # The trigger sweep, inline, as `AshEnterprise.Process.StandingGrantTest` runs it.
  defp sweep!(tenant) do
    inline = Application.get_env(:ash_bpmn, :oban_testing)
    Application.put_env(:ash_bpmn, :oban_testing, nil)

    try do
      AshBpmn.Triggers.SweepWorker.perform(%Oban.Job{args: %{"tenant" => tenant}})
    after
      Application.put_env(:ash_bpmn, :oban_testing, inline)
    end
  end

  # The actor a claim builds for a standing grant's step (ADR 0069): the
  # principal acting for the accountable person, its provenance fields naming
  # the dispatch, the event and the grant.
  defp recipe_actor(publisher, subscription, dispatch, grant, tenant) do
    context =
      ActorContext.intersect(
        ActorContext.build(publisher.user, tenant: tenant),
        ActorContext.build_automation(:recipe_runner, tenant)
      )

    AutomationPrincipal.acting(
      AutomationPrincipal.recipe_runner(),
      publisher.user.id,
      Authority.grant_key(subscription),
      context
    )
    |> then(fn actor ->
      %{
        actor
        | recipe: %{dispatch_id: dispatch.id, event_id: dispatch.event_id, grant_id: grant.id}
      }
    end)
    |> ActorContext.attach(context)
  end
end
