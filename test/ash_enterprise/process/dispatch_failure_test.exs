defmodule AshEnterprise.Process.DispatchFailureTest do
  @moduledoc """
  A funnel that raised is recorded, and can be driven again, through the engine-only
  dispatch create.

  `AshEnterprise.Bpmn.Dispatch.create` is `engine_only` (ADR 0069): no role grant and no
  system actor writes a dispatch. The two writes ash_bpmn makes outside an ordinary
  dispatch both go through it, engine-marked: the sweep's `:failed` row with reason
  `:funnel_error` when the funnel raised (`AshBpmn.Triggers.Correlator.record_aborted/4`),
  and the start a re-drive of that failure makes
  (`AshBpmn.Triggers.Correlator.dispatch_event/4` with `redrive: true`). Were the host's
  narrowing to refuse either, the failure would be lost (the sweep raises rather than pass
  an event that left no row) or could never be retried.
  """

  use AshEnterprise.DataCase, async: false

  require Ash.Query

  alias AshBpmn.Triggers.{Correlator, SweepWorker}
  alias AshEnterprise.Audit.EventLog
  alias AshEnterprise.Bpmn.{Dispatch, Instance, Subscription}
  alias AshEnterprise.Platform.{Seeder, SystemActor}
  alias AshEnterprise.Process.Resolver
  alias AshEnterprise.Security.{AccessRequest, Role}

  setup do
    platform = Seeder.seed_platform_organization()
    publish_baseline(platform.id)

    %{organization: organization, user: admin, business_unit: unit} =
      Seeder.seed_tenant(
        unique_name: "funnel-#{System.unique_integer([:positive])}",
        email: "funnel-#{System.unique_integer([:positive])}@example.com"
      )

    on_exit(&Resolver.forget_platform_tenant/0)

    opts = [actor: SystemActor.process(), tenant: organization.id]

    {:ok, draft} = Resolver.fork(:process, "access_request.grant", organization.id, nil)
    AshEnterprise.Bpmn.Definition.publish!(draft, opts)

    recipe =
      Subscription.create!(
        %{
          key: "access_request.submitted",
          match_resource: "AshEnterprise.Security.AccessRequest",
          process_key: "access_request.grant",
          guard_feel: ~s(event.action = "submit")
        },
        opts
      )
      |> Subscription.set_authority!(:causing_person, opts)
      |> Subscription.publish!(opts)

    role =
      Role
      |> Ash.Changeset.for_create(:create, %{name: "Funnel Reader"},
        actor: SystemActor.seed(),
        tenant: organization.id
      )
      |> Ash.create!()

    request =
      AccessRequest.submit!(
        %{
          justification: "I need this to run the quarterly compliance report for my region.",
          requested_role_tier: :privileged,
          requested_role_id: role.id,
          scoping_business_unit_id: unit.id
        },
        actor: admin,
        tenant: organization.id
      )

    %{tenant: organization.id, recipe: recipe, request: request}
  end

  test "a funnel error is a :failed row and a re-drive turns it into one start", ctx do
    event = submitted_event(ctx)
    sweep = SweepWorker.context(AshEnterprise.Bpmn, ctx.tenant)

    # What the sweep does when the funnel raised: a row in a transaction of its own.
    {:ok, :ok} =
      AshEnterprise.Repo.transaction(fn ->
        Correlator.record_aborted(event, [ctx.recipe], sweep, "boom")
      end)

    assert [failed] = dispatches(ctx.tenant)
    assert failed.status == :failed
    assert failed.reason == :funnel_error
    assert failed.error == "boom"
    assert failed.subscription_id == ctx.recipe.id
    assert failed.instance_id == nil
    assert instances(ctx.tenant, ctx.request.id) == []

    # An ordinary dispatch counts the failure as the record and starts nothing.
    redrive!(event, ctx.recipe, sweep, false)
    assert length(dispatches(ctx.tenant)) == 1

    # A re-drive starts the process once, beside the failure it answers.
    redrive!(event, ctx.recipe, sweep, true)

    assert [started] = Enum.filter(dispatches(ctx.tenant), &(&1.status == :started))
    assert started.event_id == failed.event_id
    assert [instance] = instances(ctx.tenant, ctx.request.id)
    assert started.instance_id == instance.id

    # And a second re-drive finds the start and makes no other.
    redrive!(event, ctx.recipe, sweep, true)
    assert length(dispatches(ctx.tenant)) == 2
    assert length(instances(ctx.tenant, ctx.request.id)) == 1
  end

  test "nothing but the engine writes a dispatch, the system actor included", ctx do
    event = submitted_event(ctx)

    assert {:error, %Ash.Error.Forbidden{}} =
             Dispatch
             |> Ash.Changeset.for_create(
               :create,
               %{
                 subscription_id: ctx.recipe.id,
                 event_id: event.id,
                 event_sequence: event.sequence,
                 event_occurred_at: DateTime.utc_now(),
                 kind: :start,
                 status: :failed,
                 reason: :funnel_error
               },
               actor: SystemActor.process(),
               tenant: ctx.tenant
             )
             |> Ash.create()
  end

  defp submitted_event(ctx) do
    EventLog
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(
      resource == ^AccessRequest and record_id == ^ctx.request.id and action == :submit
    )
    |> Ash.read_one!(actor: SystemActor.process(), tenant: ctx.tenant)
  end

  defp redrive!(event, subscription, sweep, redrive?) do
    {:ok, :ok} =
      AshEnterprise.Repo.transaction(fn ->
        Correlator.dispatch_event(event, [subscription], sweep, redrive: redrive?)
      end)
  end

  defp dispatches(tenant) do
    Dispatch
    |> Ash.Query.for_read(:read)
    |> Ash.read!(actor: SystemActor.process(), tenant: tenant)
  end

  defp instances(tenant, subject_id) do
    Instance
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(subject_id == ^subject_id)
    |> Ash.read!(actor: SystemActor.process(), tenant: tenant)
  end

  defp publish_baseline(platform) do
    opts = [actor: SystemActor.process(), tenant: platform]

    for {glob, resource} <- [
          {"priv/dmn/*.dmn", AshEnterprise.Decisions.Definition},
          {"priv/bpmn/*.bpmn", AshEnterprise.Bpmn.Definition}
        ],
        path <- Path.wildcard(glob) do
      key_for = path |> Path.basename() |> Path.rootname() |> dotted()

      unless resource
             |> Ash.Query.for_read(:read)
             |> Ash.Query.filter(key == ^key_for and status == :published)
             |> Ash.read!(opts)
             |> Enum.any?() do
        definition = resource.create!(%{key: key_for, name: key_for, xml: File.read!(path)}, opts)
        resource.publish!(definition, opts)
      end
    end
  end

  defp dotted(name) do
    parts = String.split(name, "_")
    Enum.join(Enum.drop(parts, -1), "_") <> "." <> List.last(parts)
  end
end
