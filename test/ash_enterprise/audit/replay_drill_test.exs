defmodule AshEnterprise.Audit.ReplayDrillTest do
  @moduledoc """
  Rebuilding state by replaying the audit log (q11): the clear list is configured, guarded,
  and refuses every replay it could not complete, and a replay over a log it covers puts
  back exactly the rows that were there.

  The refusals come first, and each asserts that nothing was deleted.
  """

  use AshEnterprise.DataCase, async: false

  alias AshEnterprise.Accounts.BusinessUnit
  alias AshEnterprise.Audit.{ClearRecordsForReplay, EventLog}
  alias AshEnterprise.Platform.{Correlation, SystemActor}
  alias AshEnterprise.Repo

  setup do
    Correlation.start_new()
    previous = Application.get_env(:ash_enterprise, ClearRecordsForReplay)
    on_exit(fn -> Application.put_env(:ash_enterprise, ClearRecordsForReplay, previous) end)
    %{org: Ash.UUID.generate()}
  end

  defp configure(config), do: Application.put_env(:ash_enterprise, ClearRecordsForReplay, config)

  defp create_bu!(name, org, attrs \\ %{}) do
    BusinessUnit
    |> Ash.Changeset.for_create(:create, Map.put(attrs, :name, name),
      authorize?: false,
      tenant: org,
      actor: SystemActor.seed()
    )
    |> Ash.create!()
  end

  defp replay do
    EventLog
    |> Ash.ActionInput.for_action(:replay, %{}, actor: SystemActor.replay(), authorize?: false)
    |> Ash.run_action()
  end

  # The refusal is raised inside the replay action, which reports it as an Ash error.
  defp assert_refused(pattern) do
    assert_raise Ash.Error.Unknown, pattern, fn -> replay() end
  end

  # Every business unit row, archived ones included, as the database holds it.
  defp units do
    Repo.query!(
      "SELECT id, name, parent_business_unit_id, organization_id, archived_at IS NOT NULL " <>
        "FROM business_units ORDER BY id"
    ).rows
  end

  defp seeded_units(org) do
    root = create_bu!("Root", org)
    sales = create_bu!("Sales", org, %{parent_business_unit_id: root.id})
    create_bu!("Support", org, %{parent_business_unit_id: root.id})

    sales
    |> Ash.Changeset.for_update(:update, %{name: "Field Sales"},
      authorize?: false,
      actor: SystemActor.seed()
    )
    |> Ash.update!()

    units()
  end

  describe "replay refuses" do
    test "where clearing is not allowed, as in production", ctx do
      before = seeded_units(ctx.org)
      configure(allow?: false, resources: [BusinessUnit])

      assert_refused(~r/not allowed here/)
      assert units() == before
    end

    test "when the log holds events for a resource the list does not name", ctx do
      before = seeded_units(ctx.org)
      configure(allow?: true, resources: [])

      assert_refused(~r/BusinessUnit/)
      assert units() == before
    end

    test "when events have moved to the archive", ctx do
      before = seeded_units(ctx.org)
      configure(allow?: true, resources: [BusinessUnit])

      Repo.query!("""
      INSERT INTO audit_event_archive
        (id, sequence, organization_id, record_id, version, occurred_at, resource, action,
         action_type, user_id, data, changed_attributes, metadata, previous_hash, hash, archived_at)
      SELECT id, sequence, organization_id, record_id, version, occurred_at, resource, action,
             action_type, user_id, data, changed_attributes, metadata, previous_hash, hash, now()
      FROM audit_events ORDER BY sequence LIMIT 1
      """)

      assert_refused(~r/archive/)
      assert units() == before
    end

    test "a list that names the audit log itself", ctx do
      before = seeded_units(ctx.org)
      configure(allow?: true, resources: [EventLog])

      assert_refused(~r/replay's input/)
      assert units() == before
    end

    test "a list that names a resource with no events" do
      configure(allow?: true, resources: [AshEnterprise.Lineage.Run])

      assert_refused(~r/not audited/)
    end
  end

  describe "replay rebuilds" do
    test "the listed resources, row for row", ctx do
      before = seeded_units(ctx.org)
      assert length(before) == 3
      events_before = Repo.query!("SELECT count(*) FROM audit_events").rows

      configure(allow?: true, resources: [BusinessUnit])

      assert :ok = replay()

      # The same rows, ids, names (the update included), hierarchy and tenant.
      assert units() == before
      # A replay re-runs what was recorded; it records nothing new.
      assert Repo.query!("SELECT count(*) FROM audit_events").rows == events_before
    end
  end
end
