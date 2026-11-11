defmodule AshEnterprise.Durability.LedgerAnnouncementTest do
  @moduledoc """
  The drain announces a legacy write only after the batch that ingested it has committed.

  `AshEnterprise.Ledger.UserDrainWorker` claims, ingests and marks a batch in one transaction and
  announces its events afterwards. The sandboxed notification test cannot see that order: the
  sandbox never commits, so "a rolled-back batch announces nothing" passes whether the broadcast
  sits after the commit or inside the transaction in front of anything that could undo it. Here
  every drain commits for real, and the test reads the ledger from a second connection at the
  moment the announcement arrives.

  Two things make the order observable rather than a race.

    * A deferred constraint trigger on `legacy_change_events` sleeps while the drain's transaction
      commits. Postgres runs it at COMMIT, after the transaction's own statements, so an
      announcement sent from inside the transaction is received a clear 400ms before the rows are
      visible; one sent after the commit cannot be.
    * A second deferred constraint trigger refuses the commit of one named event, so the batch is
      rolled back by the commit itself, after every statement of it has run, the announcement
      included if it had been sent from inside. Nothing earlier in the transaction fails, which is
      what a broadcast placed before the commit would have to survive to be harmless.

  Cleanup: the triggers and functions above and each test's legacy user, ledger events and
  projection are removed in `on_exit`. What stays is append-only by design (the compliance and
  audit events the ingestion recorded) or a fixture (the legacy estate and its compliance
  program, seeded once for the module); the suite drops the whole database when it ends, and each
  row is keyed by a login made for the test.
  """

  use AshEnterprise.DurabilityCase, async: false

  import ExUnit.CaptureLog

  alias AshEnterprise.Ledger.UserDrainWorker

  @topics ~w(created updated destroyed)
  @commit_delay_ms 400

  setup_all do
    AshEnterprise.Platform.Seeder.seed_legacy_estate()

    # Ingestion records the KYC events too, and refuses without an active bundle.
    {:ok, _bundle} =
      AshEnterprise.Compliance.Seeds.seed(AshEnterprise.Legacy.Estate.organization_id())

    # The estate's own rows are legacy writes too. Drain them now, so each test sees its own.
    {:ok, _} = UserDrainWorker.drain()

    :ok
  end

  setup do
    suffix = System.unique_integer([:positive])
    delay = "ledger_announcement_delay_#{suffix}"
    refuse = "ledger_announcement_refuse_#{suffix}"

    Repo.query!("""
    CREATE FUNCTION #{delay}() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN PERFORM pg_sleep(#{@commit_delay_ms / 1000}); RETURN NULL; END $$
    """)

    Repo.query!("""
    CREATE CONSTRAINT TRIGGER #{delay} AFTER UPDATE ON legacy_change_events
      DEFERRABLE INITIALLY DEFERRED FOR EACH ROW
      WHEN (OLD.processed_at IS NULL AND NEW.processed_at IS NOT NULL)
      EXECUTE FUNCTION #{delay}()
    """)

    Repo.query!("""
    CREATE FUNCTION #{refuse}() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN RAISE EXCEPTION 'commit refused for event %', NEW.id USING ERRCODE = 'check_violation';
    END $$
    """)

    on_exit(fn ->
      Repo.query!("DROP TRIGGER IF EXISTS #{delay} ON legacy_change_events")
      Repo.query!("DROP TRIGGER IF EXISTS #{refuse} ON legacy_change_events")
      Repo.query!("DROP FUNCTION IF EXISTS #{delay}()")
      Repo.query!("DROP FUNCTION IF EXISTS #{refuse}()")
    end)

    for topic <- @topics,
        do: Phoenix.PubSub.subscribe(AshEnterprise.PubSub, "legacy_users:#{topic}")

    %{refuse: refuse}
  end

  test "an announcement arrives only after the batch is visible as processed elsewhere" do
    login = unique_login()
    legacy_id = insert_legacy_user!(login)
    on_exit(fn -> clean_up!(login) end)

    drain = Task.async(&UserDrainWorker.drain/0)

    assert_receive %Phoenix.Socket.Broadcast{
                     topic: "legacy_users:created",
                     payload: %{data: %{legacy_id: ^legacy_id}}
                   },
                   10_000

    # This process has a connection of its own, and the drain's transaction has either committed
    # or it has not. What it reads now is what any other session sees.
    assert [[true]] =
             rows(
               "SELECT processed_at IS NOT NULL FROM legacy_change_events WHERE primary_key = $1",
               [%{"id" => legacy_id}]
             )

    assert [["Life Cycle"]] =
             rows("SELECT full_name FROM projected_users WHERE legacy_id = $1", [legacy_id])

    assert {:ok, 1} = Task.await(drain, 10_000)
  end

  test "a batch refused at commit announces nothing and leaves nothing behind", %{refuse: refuse} do
    login = unique_login()
    legacy_id = insert_legacy_user!(login)
    on_exit(fn -> clean_up!(login) end)

    [[event_id]] =
      rows("SELECT id FROM legacy_change_events WHERE primary_key = $1", [%{"id" => legacy_id}])

    Repo.query!("""
    CREATE CONSTRAINT TRIGGER #{refuse} AFTER UPDATE ON legacy_change_events
      DEFERRABLE INITIALLY DEFERRED FOR EACH ROW
      WHEN (NEW.id = #{event_id} AND NEW.processed_at IS NOT NULL)
      EXECUTE FUNCTION #{refuse}()
    """)

    # Postgrex logs the failed commit as a disconnect; that is the expected noise of this test.
    capture_log(fn ->
      assert_raise Postgrex.Error, ~r/commit refused/, &UserDrainWorker.drain/0
    end)

    refute_receive %Phoenix.Socket.Broadcast{}, 1_000

    # Rolled back as seen from a connection that was not in the transaction: the event is still
    # to be drained and the projection it would have written is not there.
    assert [[nil]] =
             rows("SELECT processed_at FROM legacy_change_events WHERE id = $1", [event_id])

    assert [[0]] = rows("SELECT count(*) FROM projected_users WHERE legacy_id = $1", [legacy_id])
  end

  test "a batch with a poison event announces nothing, not even its healthy events" do
    login = unique_login()
    legacy_id = insert_legacy_user!(login)
    on_exit(fn -> clean_up!(login) end)

    [[event_id]] =
      rows("SELECT id FROM legacy_change_events WHERE primary_key = $1", [%{"id" => legacy_id}])

    # Sorts after the healthy event and cannot be ingested: an update with no row image.
    [[poison_id]] =
      rows("""
      INSERT INTO legacy_change_events (source_schema, source_table, operation, primary_key)
      VALUES ('legacy', 'users', 'update', '{"id": #{legacy_id + 1_000_000}}')
      RETURNING id
      """)

    on_exit(fn -> Repo.query!("DELETE FROM legacy_change_events WHERE id = $1", [poison_id]) end)

    assert {:error, {:ingest_failed, ^poison_id, :no_row_image}} = UserDrainWorker.drain()

    refute_receive %Phoenix.Socket.Broadcast{}, 1_000

    assert [[2]] =
             rows(
               "SELECT count(*) FROM legacy_change_events WHERE processed_at IS NULL AND id = ANY($1)",
               [[event_id, poison_id]]
             )

    assert [[0]] = rows("SELECT count(*) FROM projected_users WHERE legacy_id = $1", [legacy_id])
  end

  defp rows(sql, params \\ []), do: Repo.query!(sql, params).rows

  defp unique_login, do: "announce-#{System.unique_integer([:positive])}"

  defp insert_legacy_user!(login) do
    [[id]] =
      rows(
        """
        INSERT INTO legacy.users (login, email, first_name, last_name, state, created_at, updated_at)
        VALUES ($1, $2, 'Life', 'Cycle', 'active', now(), now())
        RETURNING id
        """,
        [login, "#{login}@corp.example"]
      )

    id
  end

  # Removes what the test committed: the legacy row, the ledger events it caused (the delete
  # writes one more, so the events go last), and the projection.
  defp clean_up!(login) do
    ids = rows("SELECT id FROM legacy.users WHERE login = $1", [login]) |> List.flatten()

    Repo.query!("DELETE FROM legacy.users WHERE login = $1", [login])

    Repo.query!("DELETE FROM legacy_change_events WHERE (primary_key->>'id')::bigint = ANY($1)", [
      ids
    ])

    Repo.query!("DELETE FROM projected_users WHERE legacy_id = ANY($1)", [ids])
  end
end
