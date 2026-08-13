defmodule AshEnterprise.Platform.LifecycleTest do
  @moduledoc """
  The CDM lifecycle, as a guarded state machine.

  Two properties are worth testing and neither is obvious from reading the DSL:

    * **Illegal transitions are rejected.** That is the difference between a
      state machine and an enum, and it is the reason for the whole exercise.
    * **`state_code` and `status_code` are derived, not stored.** They cannot
      drift from the status, because there is nothing to drift -- the Dataverse
      pair is reconstructed on read from a single source.
  """

  use AshEnterprise.DataCase, async: false

  alias AshEnterprise.Accounts.BusinessUnit
  alias AshEnterprise.Platform.Lifecycle

  setup do
    org = Ash.UUID.generate()

    bu =
      BusinessUnit
      |> Ash.Changeset.for_create(:create, %{name: "Root"}, authorize?: false, tenant: org)
      |> Ash.create!()

    %{org: org, bu: bu}
  end

  describe "the canonical lifecycle" do
    test "records start active" do
      assert Lifecycle.default_status() == :active
    end

    test "each status belongs to exactly one state" do
      # This total function is why state_code need not be stored.
      for status <- Lifecycle.statuses() do
        assert Lifecycle.state_for(status) in [:active, :inactive]
      end
    end

    test "integer codes match the scraped Dataverse option sets" do
      # Pinned to the values a real Dataverse instance uses. If these change,
      # imports and exports silently mean something different.
      assert Lifecycle.status_code(:active) == 1
      assert Lifecycle.status_code(:inactive) == 2
      assert Lifecycle.state_code(:active) == 0
      assert Lifecycle.state_code(:inactive) == 1
    end
  end

  describe "transitions" do
    test "a new record is active", ctx do
      assert ctx.bu.lifecycle_status == :active
    end

    test "deactivate moves an active record to inactive", ctx do
      updated =
        ctx.bu
        |> Ash.Changeset.for_update(:deactivate, %{}, authorize?: false, tenant: ctx.org)
        |> Ash.update!()

      assert updated.lifecycle_status == :inactive
    end

    test "activate moves it back", ctx do
      inactive =
        ctx.bu
        |> Ash.Changeset.for_update(:deactivate, %{}, authorize?: false, tenant: ctx.org)
        |> Ash.update!()

      active =
        inactive
        |> Ash.Changeset.for_update(:activate, %{}, authorize?: false, tenant: ctx.org)
        |> Ash.update!()

      assert active.lifecycle_status == :active
    end

    test "an illegal transition is rejected", ctx do
      # Already active. Activating again is not a legal transition -- the state
      # machine declares `activate` as inactive -> active only. An enum would
      # have accepted this silently.
      assert {:error, _} =
               ctx.bu
               |> Ash.Changeset.for_update(:activate, %{}, authorize?: false, tenant: ctx.org)
               |> Ash.update()
    end
  end

  describe "the Dataverse pair is derived" do
    test "state_code and status_code follow the status", ctx do
      loaded = load_codes(ctx.bu, ctx.org)

      assert loaded.lifecycle_status == :active
      assert loaded.status_code == 1
      assert loaded.state_code == 0

      inactive =
        ctx.bu
        |> Ash.Changeset.for_update(:deactivate, %{}, authorize?: false, tenant: ctx.org)
        |> Ash.update!()
        |> load_codes(ctx.org)

      assert inactive.lifecycle_status == :inactive
      assert inactive.status_code == 2
      assert inactive.state_code == 1
    end

    test "neither is a stored column, so the pair cannot disagree" do
      attribute_names =
        BusinessUnit
        |> Ash.Resource.Info.attributes()
        |> Enum.map(& &1.name)

      refute :state_code in attribute_names
      refute :status_code in attribute_names
      assert :lifecycle_status in attribute_names

      calculation_names =
        BusinessUnit
        |> Ash.Resource.Info.calculations()
        |> Enum.map(& &1.name)

      assert :state_code in calculation_names
      assert :status_code in calculation_names
    end
  end

  describe "the lifecycle is introspectable" do
    test "the state machine is declared on the resource, so it can be diagrammed" do
      # This is what clarity and ash_diagram render. A lifecycle expressed as
      # scattered set_attribute calls is knowledge only its author has.
      assert AshStateMachine in Spark.extensions(BusinessUnit)

      assert AshStateMachine.Info.state_machine_state_attribute!(BusinessUnit) ==
               :lifecycle_status
    end
  end

  defp load_codes(record, tenant) do
    Ash.load!(record, [:state_code, :status_code], authorize?: false, tenant: tenant)
  end
end
