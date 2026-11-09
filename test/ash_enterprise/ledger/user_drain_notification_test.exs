defmodule AshEnterprise.Ledger.UserDrainNotificationTest do
  @moduledoc """
  What the drain announces once it has ingested a legacy write.

  `Legacy.User` has `ledger?(true)`, so its trigger writes a durable ledger row and sends only
  `wake:<id>`; `AshStrangler.Listener` answers a wake by nudging the drain and never builds an
  `Ash.Notifier.Notification`. Left like that, nothing would ever reach the resource's PubSub
  notifier and `/app/legacy-users` would stop updating. The drain therefore dispatches one
  notification per drained event itself, with `AshStrangler.Listener.notify/2`, after its
  transaction has committed.

  The listener is off under test (`:legacy_listener?` is false), so every test here goes through
  the drain: raw SQL for the legacy write (no Ash action writes legacy rows), the ledger trigger
  for the event, `UserDrainWorker.drain/0` for the rest.

  The sandbox wraps each test in a transaction, so "after commit" cannot be observed as a commit.
  It is pinned by its consequence instead: a batch whose later event fails rolls back, and the
  earlier events of that batch must not have been announced.
  """

  use AshEnterprise.DataCase, async: false

  import ExUnit.CaptureLog

  alias AshEnterprise.Ledger.UserDrainWorker
  alias AshEnterprise.Repo

  @topics ~w(created updated destroyed)

  setup do
    seeded = AshEnterprise.Platform.Seeder.seed_legacy_estate()

    # Ingestion records the KYC events too, and refuses without an active bundle.
    {:ok, _bundle} = AshEnterprise.Compliance.Seeds.seed(seeded.organization.id)

    # The estate's own rows are legacy writes too. Drain them before listening so each test
    # sees only what it caused.
    {:ok, _} = UserDrainWorker.drain()

    for topic <- @topics,
        do: Phoenix.PubSub.subscribe(AshEnterprise.PubSub, "legacy_users:#{topic}")

    :ok
  end

  describe "the current schema" do
    test "has the ledger trigger and no longer has the payload trigger" do
      assert [[0]] = rows("SELECT count(*) FROM pg_proc WHERE proname = 'strangler_users_notify'")

      assert [[0]] =
               rows("SELECT count(*) FROM pg_trigger WHERE tgname = 'strangler_users_notify'")

      assert [[1]] =
               rows(
                 "SELECT count(*) FROM pg_trigger WHERE tgname = 'strangler_ledger_legacy_users'"
               )
    end

    test "Legacy.User notifies through PubSub only; nothing projects from a notification" do
      notifiers = Ash.Resource.Info.notifiers(AshEnterprise.Legacy.User)

      assert Ash.Notifier.PubSub in notifiers
      refute Enum.any?(notifiers, &(&1 |> inspect() |> String.contains?("Projection")))
    end
  end

  describe "a drained event" do
    test "announces an insert on legacy_users:created" do
      legacy_id = insert_legacy_user!("Ada", "Lovelace")

      assert {:ok, 1} = UserDrainWorker.drain()

      assert_receive %Phoenix.Socket.Broadcast{
                       topic: "legacy_users:created",
                       payload: %Ash.Notifier.Notification{} = notification
                     },
                     2_000

      assert notification.data.legacy_id == legacy_id
      assert notification.data.full_name == "Ada Lovelace"
      assert notification.metadata.ash_strangler.origin == :legacy
      assert notification.action.name == :legacy_write
    end

    test "announcing a healthy event logs no failure" do
      insert_legacy_user!("Quiet", "Path")

      log = capture_log(fn -> assert {:ok, 1} = UserDrainWorker.drain() end)

      refute log =~ "notification failed"
    end

    test "announces an update on legacy_users:updated" do
      legacy_id = insert_legacy_user!("Grace", "Hopper")
      {:ok, 1} = UserDrainWorker.drain()
      assert_receive %Phoenix.Socket.Broadcast{topic: "legacy_users:created"}, 2_000

      Repo.query!("UPDATE legacy.users SET last_name = 'Murray' WHERE id = $1", [legacy_id])

      assert {:ok, 1} = UserDrainWorker.drain()

      assert_receive %Phoenix.Socket.Broadcast{
                       topic: "legacy_users:updated",
                       payload: %{data: %{full_name: "Grace Murray"}}
                     },
                     2_000
    end

    test "announces one notification per event, so a batch of three is three broadcasts" do
      for n <- 1..3, do: insert_legacy_user!("Batch", "N#{n}")

      assert {:ok, 3} = UserDrainWorker.drain()

      for _ <- 1..3,
          do: assert_receive(%Phoenix.Socket.Broadcast{topic: "legacy_users:created"}, 2_000)

      refute_receive %Phoenix.Socket.Broadcast{}, 100
    end

    test "a hard delete announces legacy_users:destroyed and does not crash" do
      legacy_id = insert_legacy_user!("Gone", "Soon")
      {:ok, 1} = UserDrainWorker.drain()
      assert_receive %Phoenix.Socket.Broadcast{topic: "legacy_users:created"}, 2_000

      Repo.query!("DELETE FROM legacy.users WHERE id = $1", [legacy_id])

      log = capture_log(fn -> assert {:ok, 1} = UserDrainWorker.drain() end)
      refute log =~ "notification failed"

      # The row is gone, so the notification carries a record holding only the derived key.
      assert_receive %Phoenix.Socket.Broadcast{
                       topic: "legacy_users:destroyed",
                       payload: %{data: %AshEnterprise.Legacy.User{} = gone}
                     },
                     2_000

      assert gone.id == derived_id(legacy_id)
    end

    test "a replayed event is announced again and converges" do
      legacy_id = insert_legacy_user!("Replay", "Me")
      {:ok, 1} = UserDrainWorker.drain()
      assert_receive %Phoenix.Socket.Broadcast{topic: "legacy_users:created"}, 2_000

      Repo.query!(
        "UPDATE legacy_change_events SET processed_at = NULL WHERE id = (SELECT max(id) FROM legacy_change_events)"
      )

      assert {:ok, 1} = UserDrainWorker.drain()

      # At-least-once: the second announcement is a duplicate, and a consumer re-reads, so it is
      # harmless. What it must not be is a crash or a second row.
      assert_receive %Phoenix.Socket.Broadcast{
                       topic: "legacy_users:created",
                       payload: %{data: %{legacy_id: ^legacy_id}}
                     },
                     2_000
    end

    test "a replayed insert whose row has since been deleted announces only the delete" do
      legacy_id = insert_legacy_user!("Short", "Lived")
      Repo.query!("DELETE FROM legacy.users WHERE id = $1", [legacy_id])

      assert {:ok, 2} = UserDrainWorker.drain()

      # There is nothing left to re-read for the insert, so it is silent rather than an error.
      refute_receive %Phoenix.Socket.Broadcast{topic: "legacy_users:created"}, 100
      assert_receive %Phoenix.Socket.Broadcast{topic: "legacy_users:destroyed"}, 2_000
    end
  end

  describe "failure" do
    test "a notification that raises is logged and leaves the batch committed" do
      good_id = insert_legacy_user!("Still", "Committed")

      # A delete whose key is not a scalar: ingestion skips every delete, but deriving the id to
      # announce it raises.
      poison = insert_ledger_event!("delete", %{"id" => %{"not" => "scalar"}}, nil)

      log =
        capture_log(fn ->
          assert {:ok, 2} = UserDrainWorker.drain()
        end)

      assert log =~ "legacy user notification failed"
      assert log =~ "#{poison}"

      # The batch committed: nothing is left to drain, and the ingested row is there.
      assert [[0]] = rows("SELECT count(*) FROM legacy_change_events WHERE processed_at IS NULL")

      assert [[1]] =
               rows("SELECT count(*) FROM projected_users WHERE legacy_id = $1", [good_id])

      # The healthy event was announced despite its neighbour failing.
      assert_receive %Phoenix.Socket.Broadcast{topic: "legacy_users:created"}, 2_000
    end

    test "a rolled-back batch announces nothing, not even its healthy events" do
      good_id = insert_legacy_user!("Never", "Announced")

      # Sorts after the healthy event and cannot be ingested: an update with no row image.
      insert_ledger_event!("update", %{"id" => good_id + 1_000_000}, nil)

      assert {:error, {:ingest_failed, _event_id, :no_row_image}} = UserDrainWorker.drain()

      refute_receive %Phoenix.Socket.Broadcast{}, 200

      # Every row stays unprocessed and is retried: the at-least-once contract is unchanged.
      assert [[2]] = rows("SELECT count(*) FROM legacy_change_events WHERE processed_at IS NULL")
    end
  end

  defp rows(sql, params \\ []), do: Repo.query!(sql, params).rows

  defp derived_id(legacy_id) do
    AshStrangler.KeyDerivation.uuid_v5(
      "ce41843a-c056-4c3e-9c79-50e7e5f4887c",
      AshStrangler.KeyDerivation.name("legacy.users", legacy_id)
    )
  end

  defp insert_legacy_user!(first_name, last_name) do
    login = "drain-#{System.unique_integer([:positive])}"

    %{rows: [[id]]} =
      Repo.query!(
        """
        INSERT INTO legacy.users (login, email, first_name, last_name, state, created_at, updated_at)
        VALUES ($1, $2, $3, $4, 'active', now(), now())
        RETURNING id
        """,
        [login, "#{login}@corp.example", first_name, last_name]
      )

    id
  end

  defp insert_ledger_event!(operation, primary_key, new_row) do
    %{rows: [[id]]} =
      Repo.query!(
        """
        INSERT INTO legacy_change_events (source_schema, source_table, operation, primary_key, new_row)
        VALUES ('legacy', 'users', $1, $2, $3)
        RETURNING id
        """,
        [operation, primary_key, new_row]
      )

    id
  end
end
