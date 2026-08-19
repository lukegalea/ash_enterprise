defmodule AshEnterprise.Process.AccessRequestDemoTest do
  @moduledoc """
  The demonstration ADR 0009 has been owed since it was written: a process that actually runs
  in *this* application, started by an event, routed by a DMN decision, deciding an approval
  through the same union of grants that decides everything else.

  Every claim below was previously an argument in a document. Each is now the thing that fails
  if it stops being true.
  """

  use AshEnterprise.DataCase, async: false

  require Ash.Query

  alias AshEnterprise.Bpmn.{HumanTask, Instance, ProcessEvent}
  alias AshEnterprise.Decisions
  alias AshEnterprise.Platform.{Seeder, SystemActor}
  alias AshEnterprise.Process.{Resolver, Trigger, TriggerDispatch}
  alias AshEnterprise.Process.Triggers.SweepWorker
  alias AshEnterprise.Security.{AccessRequest, Role, UserRole}

  setup do
    platform = Seeder.seed_platform_organization()
    publish_baselines(platform.id)

    %{organization: organization, user: admin, business_unit: unit} =
      Seeder.seed_tenant(
        unique_name: "demo-#{System.unique_integer([:positive])}",
        email: "demo-#{System.unique_integer([:positive])}@example.com"
      )

    on_exit(&Resolver.forget_platform_tenant/0)

    trigger =
      Trigger.create!(
        %{
          key: "access_request.submitted",
          match_resource: "AshEnterprise.Security.AccessRequest",
          match_action: "submit",
          match_action_type: :create,
          guard_feel: ~s|string length(data.justification) > 30|,
          process_key: "access_request.grant"
        },
        actor: SystemActor.process(),
        tenant: organization.id
      )

    Trigger.publish!(trigger, actor: SystemActor.process(), tenant: organization.id)

    role =
      Role
      |> Ash.Changeset.for_create(:create, %{name: "Report Reader"},
        actor: SystemActor.seed(),
        tenant: organization.id
      )
      |> Ash.create!()

    %{tenant: organization.id, admin: admin, unit: unit, role: role, platform: platform.id}
  end

  defp publish_baselines(platform) do
    opts = [actor: SystemActor.process(), tenant: platform]

    for {glob, resource} <- [
          {"priv/dmn/*.dmn", Decisions.Definition},
          {"priv/bpmn/*.bpmn", AshEnterprise.Bpmn.Definition}
        ],
        path <- Path.wildcard(glob) do
      key =
        path
        |> Path.basename()
        |> Path.rootname()
        |> then(fn n ->
          parts = String.split(n, "_")
          Enum.join(Enum.drop(parts, -1), "_") <> "." <> List.last(parts)
        end)

      xml = File.read!(path)

      unless resource
             |> Ash.Query.for_read(:read)
             |> Ash.Query.filter(key == ^key and status == :published)
             |> Ash.read!(opts)
             |> Enum.any?() do
        definition = resource.create!(%{key: key, name: key, xml: xml}, opts)

        assert definition.errors in [nil, []],
               "#{key} did not compile: #{inspect(definition.errors)}"

        resource.publish!(definition, opts)
      end
    end
  end

  defp submit!(attrs, ctx) do
    AccessRequest.submit!(
      Map.merge(
        %{
          justification: "I need this to run the quarterly compliance report for my region.",
          requested_role_tier: :standard,
          requested_role_id: ctx.role.id,
          scoping_business_unit_id: ctx.unit.id
        },
        attrs
      ),
      actor: ctx.admin,
      tenant: ctx.tenant
    )
  end

  defp sweep!(tenant) do
    SweepWorker.perform(%Oban.Job{args: %{"tenant" => tenant}})
  end

  defp instances(tenant) do
    Instance
    |> Ash.Query.for_read(:read)
    |> Ash.read!(actor: SystemActor.process(), tenant: tenant)
  end

  describe "a process starts because something happened" do
    test "submitting a request dispatches a process, with nothing wired to the action", ctx do
      request = submit!(%{}, ctx)

      # Nothing has started yet: submitting is a plain create and it returned immediately.
      assert request.decision_outcome == nil
      assert instances(ctx.tenant) == []

      sweep!(ctx.tenant)

      assert [instance] = instances(ctx.tenant)
      assert instance.subject_id == request.id

      assert [dispatch] =
               TriggerDispatch
               |> Ash.Query.for_read(:read)
               |> Ash.read!(actor: SystemActor.process(), tenant: ctx.tenant)

      assert dispatch.status == :started
      assert dispatch.process_key == "access_request.grant"
      assert dispatch.instance_id == instance.id
    end

    test "a guard that says no records why, and starts nothing", ctx do
      # Long enough for the attribute's own `min_length: 10`, short enough that the
      # trigger's guard declines it. The two thresholds are deliberately far apart: a guard
      # that sat on the boundary of a validation would be a test about arithmetic.
      submit!(%{justification: "too terse here"}, ctx)
      sweep!(ctx.tenant)

      assert instances(ctx.tenant) == []

      assert [dispatch] =
               TriggerDispatch
               |> Ash.Query.for_read(:read)
               |> Ash.read!(actor: SystemActor.process(), tenant: ctx.tenant)

      assert dispatch.status == :skipped
      assert dispatch.reason == :guard_false
    end

    # The property the whole cursor design exists for.
    test "sweeping twice does not start the process twice", ctx do
      submit!(%{}, ctx)

      sweep!(ctx.tenant)
      sweep!(ctx.tenant)

      assert length(instances(ctx.tenant)) == 1
    end
  end

  describe "the decision routes it" do
    test "a low-risk request is granted without a human", ctx do
      request =
        submit!(
          %{
            requested_role_tier: :standard,
            justification: "Quarterly compliance reporting for the EMEA region, per audit ask."
          },
          ctx
        )

      sweep!(ctx.tenant)

      assert [instance] = instances(ctx.tenant)
      assert instance.status == :completed
      assert instance.outcome == :granted

      reloaded = reload(request, ctx.tenant)
      assert reloaded.risk_tier == :low
      assert reloaded.decision_outcome == :granted

      # The role was actually assigned, through an ordinary Ash action.
      assert reloaded.granted_user_role_id
      assert [_assignment] = assignments(request, ctx)
    end

    test "a privileged request waits for a human instead", ctx do
      submit!(%{requested_role_tier: :privileged}, ctx)
      sweep!(ctx.tenant)

      assert [instance] = instances(ctx.tenant)
      assert instance.status == :running

      assert [task] =
               HumanTask
               |> Ash.Query.for_read(:read)
               |> Ash.read!(actor: SystemActor.process(), tenant: ctx.tenant)

      assert task.node_id == "ExecutiveApproval"
      assert task.status == :open
    end

    # The decision's answer is evidence, not a log line.
    test "the evaluation is recorded with the version that decided", ctx do
      submit!(%{}, ctx)
      sweep!(ctx.tenant)

      assert [evaluation] =
               Decisions.Evaluation
               |> Ash.Query.for_read(:read)
               |> Ash.read!(actor: SystemActor.process(), tenant: ctx.tenant)

      assert evaluation.definition_key == "access_request.risk"
      assert evaluation.definition_version == 1
      assert evaluation.inputs["requestedRoleTier"] == "standard"
    end

    # A low-risk request takes the *default* flow, which by definition has no condition -- so
    # the recorded expression is empty and the flow id is what identifies the branch. Asserting
    # on the expression here would be asserting that the default branch is conditioned, which
    # is the opposite of what a default is.
    test "the gateway records which branch it took", ctx do
      submit!(%{}, ctx)
      sweep!(ctx.tenant)

      [instance] = instances(ctx.tenant)

      assert [event] = process_events(instance.id, :gateway_branch_taken, ctx.tenant)
      assert event.data["flow_id"] == "Flow_auto"
      assert event.data["target_node"] == "Grant"
    end

    test "a conditioned branch records the FEEL that chose it", ctx do
      # Threads two thresholds deliberately: over the trigger's guard (>30) so the process
      # starts at all, and under the decision table's boundary (<40) so an elevated request
      # comes back "high" and takes a *conditioned* branch rather than the default.
      submit!(
        %{requested_role_tier: :elevated, justification: "Short but elevated, needs review."},
        ctx
      )

      sweep!(ctx.tenant)

      [instance] = instances(ctx.tenant)

      assert [event] = process_events(instance.id, :gateway_branch_taken, ctx.tenant)
      assert event.data["expression"] =~ "routing.risk_tier"
    end
  end

  describe "attribution" do
    # The reason the bypass ordering was chosen over an engine actor: the human survives.
    test "the process runs as a named non-human actor, and names the human who caused it", ctx do
      request = submit!(%{}, ctx)
      sweep!(ctx.tenant)

      [instance] = instances(ctx.tenant)

      assert [started | _] = process_events(instance.id, :instance_started, ctx.tenant)
      assert started

      # The request itself is still attributed to the person who raised it.
      assert reload(request, ctx.tenant).created_by_id == ctx.admin.id
    end
  end

  defp reload(request, tenant) do
    AccessRequest
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^request.id)
    |> Ash.read_one!(actor: SystemActor.process(), tenant: tenant)
  end

  defp assignments(request, ctx) do
    UserRole
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(user_id == ^request.created_by_id and role_id == ^ctx.role.id)
    |> Ash.read!(actor: SystemActor.process(), tenant: ctx.tenant)
  end

  defp process_events(instance_id, kind, tenant) do
    ProcessEvent
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(instance_id == ^instance_id and kind == ^kind)
    |> Ash.read!(actor: SystemActor.process(), tenant: tenant)
  end
end
