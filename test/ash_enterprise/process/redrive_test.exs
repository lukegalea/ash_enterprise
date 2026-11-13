defmodule AshEnterprise.Process.RedriveTest do
  @moduledoc """
  A person re-drives a tenant's failed trigger dispatches (`AshEnterprise.Bpmn.Redrive`),
  each under the subscription version on its row, with that version's standing grant checked
  again now (ADR 0069). The failure is the one the sweep records when the funnel raised
  (`AshBpmn.Triggers.Correlator.record_aborted/4`); the recipe is a standing grant, so the
  grant check is the one that matters.

  The person who re-drives (an operator managing the tenant's recipes) is deliberately not
  the recipe's publisher: the re-drive needs the operator's grant to act, and the publisher's
  to start anything. SYNTHETIC data only.
  """

  use AshEnterprise.DataCase, async: false

  import AshEnterprise.Test.Process.EvidenceChecks, only: [clinic!: 0]

  require Ash.Query

  alias AshBpmn.Triggers.{Correlator, SweepWorker}
  alias AshEnterprise.Audit.{EventLog, EventSource}
  alias AshEnterprise.Bpmn.{Definition, Dispatch, Instance, Redrive, Subscription}
  alias AshEnterprise.Bpmn.Subscription.Authority
  alias AshEnterprise.Credentialing
  alias AshEnterprise.Credentialing.Credential
  alias AshEnterprise.Platform.{AutomationPrincipal, SystemActor}
  alias AshEnterprise.Security.{ActorContext, AgentStartGrant}
  alias AshEnterprise.Test.DailyFixtures

  @check_expiry """
  <?xml version="1.0" encoding="UTF-8"?>
  <bpmn2:definitions xmlns:bpmn2="http://www.omg.org/spec/BPMN/20100524/MODEL"
                     xmlns:ash="https://github.com/lukegalea/ash_bpmn/ns"
                     id="Definitions_redrive_check" targetNamespace="https://example.com/bpmn">
    <bpmn2:process id="Process_redrive_check" isExecutable="true">
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

  @recipe_grants [{Subscription, :read, :global}, {Subscription, :write, :global}]

  setup do
    tenant!()
  end

  defp tenant! do
    clinic = clinic!()
    admin = clinic.admin

    publisher =
      DailyFixtures.member!(
        admin,
        "Recipe publisher #{unique()}",
        @recipe_grants ++ [{Credential, :read, :global}]
      )

    operator = DailyFixtures.member!(admin, "Recipe operator #{unique()}", @recipe_grants)

    reader =
      DailyFixtures.member!(admin, "Recipe reader #{unique()}", [{Subscription, :read, :global}])

    key = process!(clinic.tenant)

    recipe =
      Subscription
      |> Ash.Changeset.for_create(
        :create,
        %{
          key: "redrive.recipe.#{unique()}",
          match_resource: "AshEnterprise.Credentialing.Credential",
          match_action: :record,
          match_action_type: :create,
          process_key: key
        },
        system(clinic.tenant)
      )
      |> Ash.create!()
      |> Subscription.publish_granted!(actor: publisher.actor, tenant: clinic.tenant)

    %{
      clinic: clinic,
      admin: admin,
      tenant: clinic.tenant,
      publisher: publisher,
      operator: operator,
      reader: reader,
      recipe: recipe
    }
  end

  defp unique, do: System.unique_integer([:positive])
  defp system(tenant), do: [actor: SystemActor.process(), tenant: tenant]

  defp process!(tenant) do
    key = "redrive-#{unique()}"
    definition = Definition.create!(%{key: key, name: key, xml: @check_expiry}, system(tenant))
    Definition.publish!(definition, system(tenant))
    key
  end

  # The event, then the row the sweep writes when the funnel raised on it.
  defp failure!(ctx) do
    credential =
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

    event =
      EventLog
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(
        resource == ^Credential and record_id == ^credential.id and action == :record
      )
      |> Ash.read_one!(actor: SystemActor.process(), tenant: ctx.tenant)

    {:ok, :ok} =
      AshEnterprise.Repo.transaction(fn ->
        Correlator.record_aborted(
          event,
          [ctx.recipe],
          SweepWorker.context(AshEnterprise.Bpmn, ctx.tenant),
          "boom"
        )
      end)

    event
  end

  # As production runs it: a started process's first advance is a job, not run inline here.
  defp without_inline_jobs(fun) do
    inline = Application.get_env(:ash_bpmn, :oban_testing)
    Application.put_env(:ash_bpmn, :oban_testing, nil)

    try do
      fun.()
    after
      Application.put_env(:ash_bpmn, :oban_testing, inline)
    end
  end

  defp redrive(event, actor, tenant) do
    without_inline_jobs(fn ->
      Redrive.redrive_failed(
        %{from_sequence: event.sequence, to_sequence: event.sequence},
        actor: actor,
        tenant: tenant
      )
    end)
  end

  defp started(tenant) do
    Dispatch
    |> Ash.Query.filter(status == :started)
    |> Ash.read!(authorize?: false, tenant: tenant)
  end

  defp instances(tenant), do: Ash.read!(Instance, authorize?: false, tenant: tenant)
  defp redrives(tenant), do: Ash.read!(Redrive, authorize?: false, tenant: tenant)

  defp grant!(subscription) do
    AgentStartGrant
    |> Ash.Query.filter(agent_key == ^Authority.grant_key(subscription))
    |> Ash.read_one!(authorize?: false, tenant: subscription.organization_id)
  end

  describe "a re-drive under the version on the row" do
    test "a successful re-drive starts once", ctx do
      event = failure!(ctx)
      assert started(ctx.tenant) == []

      assert {:ok, [redrive]} = redrive(event, ctx.operator.actor, ctx.tenant)

      assert redrive.outcome == :started
      assert redrive.reason == nil
      assert redrive.subscription_id == ctx.recipe.id
      assert redrive.event_id == event.id
      assert redrive.created_by_id == ctx.operator.user.id

      assert [dispatch] = started(ctx.tenant)
      assert dispatch.id == redrive.dispatch_id
      assert dispatch.subscription_id == ctx.recipe.id
      assert [instance] = instances(ctx.tenant)
      assert dispatch.instance_id == instance.id
    end

    test "a second re-drive does not start twice", ctx do
      event = failure!(ctx)

      assert {:ok, [%{outcome: :started} = first]} =
               redrive(event, ctx.operator.actor, ctx.tenant)

      assert {:ok, [second]} = redrive(event, ctx.operator.actor, ctx.tenant)
      assert second.outcome == :already_started
      assert second.dispatch_id == first.dispatch_id

      assert [_one] = started(ctx.tenant)
      assert [_one] = instances(ctx.tenant)
      assert length(redrives(ctx.tenant)) == 2
    end

    test "re-drive re-checks the grant now: revoked after the failure, no start and no_authority",
         ctx do
      event = failure!(ctx)
      Ash.destroy!(grant!(ctx.recipe), authorize?: false, tenant: ctx.tenant)

      assert {:ok, [redrive]} = redrive(event, ctx.operator.actor, ctx.tenant)
      assert redrive.outcome == :no_authority
      assert redrive.reason == "no_start_grant"
      assert redrive.dispatch_id == nil

      assert started(ctx.tenant) == []
      assert instances(ctx.tenant) == []
    end

    test "a lapsed grant or a deactivated publisher starts nothing either", ctx do
      lapsed = failure!(ctx)
      grant = grant!(ctx.recipe)
      Ash.Seed.update!(grant, %{valid_until: DateTime.add(DateTime.utc_now(), -1, :second)})

      assert {:ok, [%{outcome: :no_authority, reason: "no_start_grant"}]} =
               redrive(lapsed, ctx.operator.actor, ctx.tenant)

      Ash.Seed.update!(grant, %{valid_until: DateTime.add(DateTime.utc_now(), 30, :day)})
      DailyFixtures.deactivate!(ctx.publisher)
      gone = failure!(ctx)

      assert {:ok, [%{outcome: :no_authority, reason: "inactive"}]} =
               redrive(gone, ctx.operator.actor, ctx.tenant)

      assert started(ctx.tenant) == []
      assert instances(ctx.tenant) == []
    end

    test "a disabled version is not driven", ctx do
      event = failure!(ctx)
      Subscription.disable!(ctx.recipe, system(ctx.tenant))

      assert {:ok, [%{outcome: :not_started, reason: "disabled"}]} =
               redrive(event, ctx.operator.actor, ctx.tenant)

      assert started(ctx.tenant) == []
    end

    test "other-tenant dispatches are not touched", ctx do
      other = tenant!()
      ours = failure!(ctx)
      theirs = failure!(other)

      # Every sequence there is, in our tenant: only our failure is ours to drive.
      assert {:ok, [redrive]} =
               without_inline_jobs(fn ->
                 Redrive.redrive_failed(%{from_sequence: 0},
                   actor: ctx.operator.actor,
                   tenant: ctx.tenant
                 )
               end)

      assert redrive.event_id == ours.id
      assert redrives(other.tenant) == []
      assert started(other.tenant) == []

      assert [%{status: :failed, event_id: event_id}] =
               Ash.read!(Dispatch, authorize?: false, tenant: other.tenant)

      assert event_id == theirs.id

      # Nor may our operator re-drive in their tenant.
      assert {:error, %Ash.Error.Forbidden{}} = redrive(theirs, ctx.operator.actor, other.tenant)
      assert started(other.tenant) == []
    end

    test "the re-drive is ash_bpmn's, fetching the one event from this tenant's log", ctx do
      assert Redrive.ash_bpmn_kind() == :redrive

      event = failure!(ctx)
      assert {:ok, %EventLog{id: id}} = EventSource.event(ctx.tenant, event.id)
      assert id == event.id
      assert {:error, :not_found} = EventSource.event(Ecto.UUID.generate(), event.id)

      assert {:ok, [redrive]} = redrive(event, ctx.operator.actor, ctx.tenant)
      assert redrive.outcome == :started
      assert %DateTime{} = redrive.inserted_at
    end

    test "a range is required", ctx do
      assert {:error, error} =
               Redrive.redrive_failed(%{}, actor: ctx.operator.actor, tenant: ctx.tenant)

      assert Exception.message(error) =~ "give a range"
    end
  end

  describe "a re-drive is a person's act" do
    test "a person who may only read recipes is Forbidden", ctx do
      event = failure!(ctx)
      assert {:error, %Ash.Error.Forbidden{}} = redrive(event, ctx.reader.actor, ctx.tenant)
      assert redrives(ctx.tenant) == []
    end

    test "no system actor and no automation principal may re-drive", ctx do
      event = failure!(ctx)

      principal =
        AutomationPrincipal.acting(
          AutomationPrincipal.recipe_runner(),
          ctx.operator.user.id,
          "redrive-test",
          ActorContext.intersect(
            ActorContext.build(ctx.operator.user, tenant: ctx.tenant),
            ActorContext.build_automation(:recipe_runner, ctx.tenant)
          )
        )

      for actor <- [SystemActor.process(), SystemActor.oban(), principal] do
        assert {:error, %Ash.Error.Forbidden{}} = redrive(event, actor, ctx.tenant)
      end

      assert redrives(ctx.tenant) == []
      assert started(ctx.tenant) == []
    end
  end

  describe "the task" do
    test "re-drives a range as the named person, and starts nothing twice", ctx do
      event = failure!(ctx)
      Mix.shell(Mix.Shell.Process)
      on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

      args = [
        "--tenant",
        ctx.tenant,
        "--as",
        to_string(ctx.operator.user.email),
        "--from-sequence",
        to_string(event.sequence),
        "--to-sequence",
        to_string(event.sequence)
      ]

      without_inline_jobs(fn -> Mix.Tasks.AshEnterprise.Bpmn.Redrive.run(args) end)
      assert_received {:mix_shell, :info, [_tenant_line]}
      assert_received {:mix_shell, :info, [line]}
      assert line =~ "event #{event.sequence} (#{event.id}): started"

      without_inline_jobs(fn -> Mix.Tasks.AshEnterprise.Bpmn.Redrive.run(args) end)
      assert_received {:mix_shell, :info, [_tenant_line]}
      assert_received {:mix_shell, :info, [line]}
      assert line =~ "already_started"

      assert [_one] = started(ctx.tenant)
    end

    test "refuses without a range" do
      assert_raise Mix.Error, ~r/give a range/, fn ->
        Mix.Tasks.AshEnterprise.Bpmn.Redrive.run(["--tenant", "x", "--as", "y"])
      end
    end
  end

  describe "lag telemetry" do
    setup do
      test_pid = self()
      handler = "redrive-test-#{unique()}"

      :telemetry.attach_many(
        handler,
        [[:ash_enterprise, :bpmn, :sweep], [:ash_enterprise, :bpmn, :dispatch, :start]],
        fn event, measurements, metadata, _ ->
          send(test_pid, {event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)
    end

    test "the sweep reports how far behind the tenant's log it is", ctx do
      without_inline_jobs(fn ->
        SweepWorker.perform(%Oban.Job{args: %{"tenant" => ctx.tenant}})
      end)

      tenant = ctx.tenant
      assert_received {[:ash_enterprise, :bpmn, :sweep], %{lag: 0}, %{tenant: ^tenant}}

      # A cursor three events behind the newest reports three.
      newest = AshEnterprise.Audit.EventSource.latest_sequence(tenant)

      AshEnterprise.Bpmn.Telemetry.handle_sweep(
        [:ash_bpmn, :triggers, :sweep],
        %{},
        %{tenant: tenant, last_sequence: newest - 3},
        nil
      )

      assert_received {[:ash_enterprise, :bpmn, :sweep], %{lag: 3}, %{tenant: ^tenant}}
    end

    test "a dispatch that starts a process reports how long its event waited", ctx do
      event = failure!(ctx)
      assert {:ok, [%{outcome: :started}]} = redrive(event, ctx.operator.actor, ctx.tenant)

      tenant = ctx.tenant

      assert_received {[:ash_enterprise, :bpmn, :dispatch, :start], %{latency: latency},
                       %{tenant: ^tenant, kind: :start}}

      waited = DateTime.diff(DateTime.utc_now(), event.occurred_at, :microsecond)
      assert latency >= 0
      assert System.convert_time_unit(latency, :native, :microsecond) <= waited
    end
  end
end
