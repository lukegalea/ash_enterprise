defmodule AshEnterprise.Process.TriggerTest do
  @moduledoc """
  The invariants the trigger design rests on, as assertions.

  `docs/plans/event-triggered-processes.md` argues them; this is where they are checked. The
  two that matter most are the ones that would fail silently: a trigger that feeds itself, and
  a cursor that skips an event.
  """

  use AshEnterprise.DataCase, async: false

  require Ash.Query

  alias AshEnterprise.Platform.{Seeder, SystemActor}
  alias AshEnterprise.Process.{Trigger, TriggerCursor, TriggerDispatch}

  setup do
    %{organization: organization} =
      Seeder.seed_tenant(
        unique_name: "trig-#{System.unique_integer([:positive])}",
        email: "trig-#{System.unique_integer([:positive])}@example.com"
      )

    %{tenant: organization.id}
  end

  defp opts(tenant), do: [actor: SystemActor.process(), tenant: tenant]

  defp trigger!(tenant, attrs) do
    defaults = %{
      key: "t-#{System.unique_integer([:positive])}",
      match_resource: "AshEnterprise.Accounts.Team",
      process_key: "some_process"
    }

    Trigger.create!(Map.merge(defaults, attrs), opts(tenant))
  end

  describe "a trigger may not feed itself" do
    # The invariant that was nearly left to luck. Some process and decision resources carry the
    # audit hook -- a definition published, a task decided -- so a process started by a trigger
    # writes audit events, and those are trigger inputs.
    for resource <- [
          "AshEnterprise.Bpmn.Definition",
          "AshEnterprise.Bpmn.HumanTask",
          "AshEnterprise.Decisions.Definition",
          "AshEnterprise.Process.TriggerDispatch"
        ] do
      test "refuses to match #{resource}", %{tenant: tenant} do
        assert {:error, error} =
                 Trigger.create(
                   %{
                     key: "self-#{System.unique_integer([:positive])}",
                     match_resource: unquote(resource),
                     process_key: "p"
                   },
                   opts(tenant)
                 )

        assert Exception.message(error) =~ "may not match"
      end
    end

    test "an ordinary application resource is fine", %{tenant: tenant} do
      assert %Trigger{} = trigger!(tenant, %{match_resource: "AshEnterprise.Accounts.User"})
    end
  end

  describe "a trigger needs somewhere to send an event" do
    test "neither a process nor a decision is refused", %{tenant: tenant} do
      assert {:error, error} =
               Trigger.create(
                 %{key: "nowhere", match_resource: "AshEnterprise.Accounts.Team"},
                 opts(tenant)
               )

      assert Exception.message(error) =~ "process_key or a decision_key"
    end

    test "a decision alone is enough", %{tenant: tenant} do
      assert %Trigger{} =
               Trigger.create!(
                 %{
                   key: "by-decision",
                   match_resource: "AshEnterprise.Accounts.Team",
                   decision_key: "routing"
                 },
                 opts(tenant)
               )
    end
  end

  describe "versioning" do
    test "versions are per key and per tenant", %{tenant: tenant} do
      a =
        Trigger.create!(
          %{key: "shared", match_resource: "AshEnterprise.Accounts.Team", process_key: "p"},
          opts(tenant)
        )

      b =
        Trigger.create!(
          %{key: "shared", match_resource: "AshEnterprise.Accounts.Team", process_key: "p"},
          opts(tenant)
        )

      assert a.version == 1
      assert b.version == 2
    end

    test "another tenant's versions are independent", %{tenant: tenant} do
      %{organization: other} =
        Seeder.seed_tenant(
          unique_name: "trig-other-#{System.unique_integer([:positive])}",
          email: "trig-other-#{System.unique_integer([:positive])}@example.com"
        )

      a =
        Trigger.create!(
          %{key: "same", match_resource: "AshEnterprise.Accounts.Team", process_key: "p"},
          opts(tenant)
        )

      b =
        Trigger.create!(
          %{key: "same", match_resource: "AshEnterprise.Accounts.Team", process_key: "p"},
          opts(other.id)
        )

      assert a.version == 1
      assert b.version == 1
    end
  end

  describe "enabled is an operational switch, not a deployment act" do
    test "it can be flipped on a published trigger without publishing again", %{tenant: tenant} do
      trigger = tenant |> trigger!(%{}) |> Trigger.publish!(opts(tenant))
      assert trigger.status == :published

      off = Trigger.set_enabled!(trigger, false, opts(tenant))
      assert off.enabled == false
      assert off.status == :published, "disabling must not retire it"
      assert off.version == trigger.version, "disabling must not create a version"
    end

    test "only published *and* enabled triggers are read for dispatch", %{tenant: tenant} do
      enabled = tenant |> trigger!(%{}) |> Trigger.publish!(opts(tenant))
      disabled = tenant |> trigger!(%{}) |> Trigger.publish!(opts(tenant))
      Trigger.set_enabled!(disabled, false, opts(tenant))
      _draft = trigger!(tenant, %{})

      keys = Trigger.published!(opts(tenant)) |> Enum.map(& &1.key)

      assert enabled.key in keys
      refute disabled.key in keys
    end
  end

  describe "the cursor" do
    test "there can be only one per tenant", %{tenant: tenant} do
      first = TriggerCursor.create!(%{last_sequence: 0}, opts(tenant))
      # `upsert?` on the identity, so a second create returns the same row rather than a
      # constraint error -- the sweeper does not have to remember whether it has run before.
      second = TriggerCursor.create!(%{last_sequence: 5}, opts(tenant))

      assert first.id == second.id
      assert second.last_sequence == 5
    end

    test "advancing stamps when it happened", %{tenant: tenant} do
      cursor = TriggerCursor.create!(%{last_sequence: 0}, opts(tenant))
      assert is_nil(cursor.last_dispatched_at)

      advanced = TriggerCursor.advance!(cursor, 42, opts(tenant))

      assert advanced.last_sequence == 42
      assert %DateTime{} = advanced.last_dispatched_at
    end
  end

  describe "the dispatch ledger" do
    setup %{tenant: tenant} do
      %{trigger: tenant |> trigger!(%{}) |> Trigger.publish!(opts(tenant))}
    end

    # What makes a replayed batch idempotent after a sweep crashes mid-way.
    test "the same trigger cannot record twice for one event", %{tenant: tenant, trigger: trigger} do
      event_id = Ash.UUID.generate()

      assert {:ok, _} =
               TriggerDispatch.create(
                 %{
                   trigger_id: trigger.id,
                   event_id: event_id,
                   event_sequence: 1,
                   status: :started
                 },
                 opts(tenant)
               )

      assert {:error, _} =
               TriggerDispatch.create(
                 %{
                   trigger_id: trigger.id,
                   event_id: event_id,
                   event_sequence: 1,
                   status: :started
                 },
                 opts(tenant)
               )
    end

    # A skip is as much a fact as a start: it answers "why did nothing happen", which is the
    # harder of the two questions.
    test "a skipped dispatch is recorded with its reason", %{tenant: tenant, trigger: trigger} do
      {:ok, dispatch} =
        TriggerDispatch.create(
          %{
            trigger_id: trigger.id,
            event_id: Ash.UUID.generate(),
            event_sequence: 2,
            status: :skipped,
            reason: :guard_false
          },
          opts(tenant)
        )

      assert dispatch.status == :skipped
      assert dispatch.reason == :guard_false
    end

    test "depth is carried so an indirect cycle is bounded rather than improbable", %{
      tenant: tenant,
      trigger: trigger
    } do
      {:ok, dispatch} =
        TriggerDispatch.create(
          %{
            trigger_id: trigger.id,
            event_id: Ash.UUID.generate(),
            event_sequence: 3,
            status: :started,
            depth: 2
          },
          opts(tenant)
        )

      assert dispatch.depth == 2
    end
  end
end
