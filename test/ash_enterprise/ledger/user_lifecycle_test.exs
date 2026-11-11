defmodule AshEnterprise.Ledger.UserLifecycleTest do
  @moduledoc """
  The two paths into `projected_users` agree about `lifecycle_status`.

  A legacy write reaches `projected_users` through the change ledger's drain
  (`AshEnterprise.Ledger.UserIngestion`), and the backfill projects the rows the ledger never saw
  (`AshEnterprise.Legacy.UserBackfill.project_row/1`). The legacy application's five states map
  onto the platform's two through the platform's own state machine, and a suspended or passive
  user must not read as active because of which path wrote the row last.

  The oracle is the backfill: for each legacy state, the drain's result is compared with what
  `project_row/1` gives for the same legacy row projected from nothing. The fixed expectation
  beside it keeps the comparison from passing because both paths are wrong the same way.
  """

  use AshEnterprise.DataCase, async: false

  alias AshEnterprise.Accounts.ProjectedUser
  alias AshEnterprise.Ledger.UserDrainWorker
  alias AshEnterprise.Legacy.Estate
  alias AshEnterprise.Legacy.UserBackfill
  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.Repo

  @states ~w(active passive pending suspended deleted)

  # Only `active` is active; the other four are the platform's inactive.
  @expected %{
    "active" => :active,
    "passive" => :inactive,
    "pending" => :inactive,
    "suspended" => :inactive,
    "deleted" => :inactive
  }

  setup do
    seeded = AshEnterprise.Platform.Seeder.seed_legacy_estate()

    # Ingestion records the KYC events too, and refuses without an active bundle.
    {:ok, _bundle} = AshEnterprise.Compliance.Seeds.seed(seeded.organization.id)

    # The estate's own rows are legacy writes too. Drain them so each test sees only its own.
    {:ok, _} = UserDrainWorker.drain()

    :ok
  end

  describe "an insert in each legacy state" do
    for state <- @states do
      test "#{state}: the drain leaves what project_row/1 leaves" do
        state = unquote(state)
        legacy_id = insert_legacy_user!(state)

        assert {:ok, 1} = UserDrainWorker.drain()
        drained = lifecycle!(legacy_id)

        assert drained == backfilled_lifecycle!(legacy_id)
        assert drained == Map.fetch!(@expected, state)
      end
    end
  end

  describe "an update into each legacy state" do
    for state <- @states do
      test "active -> #{state}: the drain leaves what project_row/1 leaves" do
        state = unquote(state)
        legacy_id = insert_legacy_user!("active")
        {:ok, 1} = UserDrainWorker.drain()
        assert lifecycle!(legacy_id) == :active

        set_state!(legacy_id, state)
        assert {:ok, 1} = UserDrainWorker.drain()
        drained = lifecycle!(legacy_id)

        assert drained == backfilled_lifecycle!(legacy_id)
        assert drained == Map.fetch!(@expected, state)
      end
    end

    for state <- @states -- ["active"] do
      test "#{state} -> active: the drain reactivates, as project_row/1 does" do
        state = unquote(state)
        legacy_id = insert_legacy_user!(state)
        {:ok, 1} = UserDrainWorker.drain()
        assert lifecycle!(legacy_id) == :inactive

        set_state!(legacy_id, "active")
        assert {:ok, 1} = UserDrainWorker.drain()
        drained = lifecycle!(legacy_id)

        assert drained == backfilled_lifecycle!(legacy_id)
        assert drained == :active
      end
    end
  end

  # What `project_row/1` leaves for this legacy row projected from nothing: the projected row is
  # removed first, so the answer does not depend on what the drain wrote.
  defp backfilled_lifecycle!(legacy_id) do
    Repo.query!("DELETE FROM projected_users WHERE legacy_id = $1", [legacy_id])

    row =
      AshEnterprise.Legacy.User
      |> Ash.Query.for_read(:read, %{}, opts())
      |> Ash.read!(opts())
      |> Enum.find(&(&1.legacy_id == legacy_id))

    assert row, "the legacy read model should show legacy user #{legacy_id}"
    assert :ok = UserBackfill.project_row(row)
    lifecycle!(legacy_id)
  end

  defp lifecycle!(legacy_id) do
    ProjectedUser
    |> Ash.Query.for_read(:read, %{}, opts())
    |> Ash.read!(opts())
    |> Enum.find(&(&1.legacy_id == legacy_id))
    |> Map.fetch!(:lifecycle_status)
  end

  defp opts,
    do: [actor: SystemActor.projection(), tenant: Estate.organization_id(), authorize?: false]

  defp set_state!(legacy_id, state) do
    Repo.query!("UPDATE legacy.users SET state = $2, updated_at = now() WHERE id = $1", [
      legacy_id,
      state
    ])
  end

  defp insert_legacy_user!(state) do
    login = "lifecycle-#{System.unique_integer([:positive])}"

    %{rows: [[id]]} =
      Repo.query!(
        """
        INSERT INTO legacy.users (login, email, first_name, last_name, state, created_at, updated_at)
        VALUES ($1, $2, 'Life', 'Cycle', $3, now(), now())
        RETURNING id
        """,
        [login, "#{login}@corp.example", state]
      )

    id
  end
end
