defmodule AshEnterprise.CanonicalTest do
  @moduledoc """
  Epic E4 acceptance: the deterministic core.

  * the fixture calendar tap lands SourceObjects end-to-end (TapWorker →
    FixtureTap → land),
  * `Projection.replay/2` turns them into CalendarEvents that match the
    fixture,
  * replay is deterministic: delete every canonical row, replay again, and the
    result is byte-identical,
  * re-landing the same fixture (upsert-refresh) and re-replaying produces zero
    diffs,
  * external-id lookups work on both SourceObject and the canonical rows,
  * the replay context resolves from config and refuses to guess.
  """

  use AshEnterprise.DataCase, async: false

  alias AshEnterprise.Canonical.{CalendarEvent, Person, Projection}
  alias AshEnterprise.Ingestion.SourceObject
  alias AshEnterprise.Ingestion.TapWorker

  require Ash.Query

  @opts [authorize?: false]

  # What the fixture tap emits, as the projector must see it (keep in sync with
  # AshEnterprise.Ingestion.FixtureTap).
  @fixture [
    %{
      "id" => "evt_cal_001",
      "iCalUID" => "evt_cal_001@fixture.local",
      "title" => "Weekly plan review",
      "starts_at" => ~U[2026-10-05 09:00:00Z],
      "ends_at" => ~U[2026-10-05 09:30:00Z],
      "location" => "War room",
      "organizer_email" => "admin@example.com"
    },
    %{
      "id" => "evt_cal_002",
      "iCalUID" => "evt_cal_002@fixture.local",
      "title" => "Design review with Alice",
      "starts_at" => ~U[2026-10-06 14:00:00Z],
      "ends_at" => ~U[2026-10-06 15:00:00Z],
      "location" => nil,
      "organizer_email" => "alice@example.com"
    },
    %{
      "id" => "evt_cal_003",
      "iCalUID" => "evt_cal_003@fixture.local",
      "title" => "Dentist",
      "starts_at" => ~U[2026-10-07 10:30:00Z],
      "ends_at" => ~U[2026-10-07 11:15:00Z],
      "location" => "Dr. Molnar",
      "organizer_email" => "admin@example.com"
    }
  ]

  setup do
    org =
      AshEnterprise.Accounts.Organization
      |> Ash.Changeset.for_create(
        :create,
        %{name: "Canonical Test", unique_name: "canonical-test"},
        @opts
      )
      |> Ash.create!()

    user =
      AshEnterprise.Accounts.User
      |> Ash.Changeset.for_create(
        :register_with_password,
        %{
          email: "operator@canonical.test",
          password: "password1234",
          password_confirmation: "password1234"
        },
        @opts
      )
      |> Ash.create!()

    context = [owner: user, tenant: org.id]

    %{org: org, user: user, context: context}
  end

  describe "fixture tap end-to-end" do
    test "calendar_dev lands SourceObjects and replay projects them to CalendarEvents", %{
      context: context
    } do
      assert {:ok, %{records: 3, external_system: "calendar"}} =
               TapWorker.perform(%Oban.Job{args: %{"pipeline" => "calendar_dev"}})

      assert length(landed_external_ids()) == 3

      assert {:ok, %{calendar: %{source_objects: 3, calendar_events: 3, people: 2}}} =
               Projection.replay(:calendar, context)

      assert projected_events(context) == expected_events()

      # People are keyed by email — the v1 linkage — with names from the
      # fixture's displayName fields.
      assert %Person{name: "Operator"} = person_by_email("admin@example.com", context)
      assert %Person{name: "Alice Chen"} = person_by_email("alice@example.com", context)
    end

    test "the operator (no displayName) does not get blanked by a name-less pass", %{
      context: context
    } do
      run_fixture_pipeline()
      Projection.replay(:calendar, context)

      # evt_cal_003's organizer has an email but no displayName: the replay's
      # final Person upsert must conflict-and-change-nothing.
      assert %Person{name: "Operator"} = person_by_email("admin@example.com", context)
    end
  end

  describe "replay determinism" do
    test "delete every canonical row, replay again: byte-identical", %{context: context} do
      run_fixture_pipeline()

      Projection.replay(:calendar, context)
      first = calendar_snapshot(context)

      purge_canonical_rows()

      assert {:ok, %{calendar: %{calendar_events: 3, people: 2}}} =
               Projection.replay(:calendar, context)

      assert calendar_snapshot(context) == first
    end

    test "re-landing the same fixture and re-replaying produces zero diffs", %{context: context} do
      run_fixture_pipeline()
      Projection.replay(:calendar, context)
      first = calendar_snapshot(context)

      # Landing is upsert-refresh, not append-only: the identical fixture
      # refreshes the same rows in place.
      assert {:ok, %{records: 3}} = run_fixture_pipeline()
      assert length(landed_external_ids()) == 3

      assert {:ok, %{calendar: %{calendar_events: 3, people: 2}}} =
               Projection.replay(:calendar, context)

      assert calendar_snapshot(context) == first
    end
  end

  describe "external-id lookup" do
    test "SourceObject.by_external returns the raw row" do
      run_fixture_pipeline()

      source = SourceObject.by_external!("calendar", "evt_cal_002", @opts)
      assert %SourceObject{external_id: "evt_cal_002", external_system: "calendar"} = source
      assert source.source_metadata["stream"] == "events"
    end

    test "CalendarEvent.by_external returns the canonical row", %{context: context} do
      run_fixture_pipeline()
      Projection.replay(:calendar, context)

      tenant = context[:tenant]

      assert {:ok, %{external_id: "evt_cal_001"}} =
               CalendarEvent.by_external("calendar", "evt_cal_001",
                 authorize?: false,
                 tenant: tenant
               )

      assert {:ok, nil} =
               CalendarEvent.by_external("calendar", "evt_missing",
                 authorize?: false,
                 tenant: tenant
               )
    end
  end

  describe "replay context" do
    test "zero-arg replay resolves owner and tenant from config", %{org: org, user: user} do
      Application.put_env(:ash_enterprise, AshEnterprise.Canonical,
        replay_owner_email: to_string(user.email),
        replay_tenant_unique_name: org.unique_name
      )

      on_exit(fn -> Application.delete_env(:ash_enterprise, AshEnterprise.Canonical) end)

      run_fixture_pipeline()

      assert {:ok, %{calendar: %{calendar_events: 3}}} = Projection.replay(:calendar)

      assert projected_events(owner: user, tenant: org.id) == expected_events()
    end

    test "an unresolvable context raises instead of guessing" do
      # The sandbox has no seeded "example" tenant or admin@example.com user,
      # so the default resolution must refuse — loudly.
      assert_raise ArgumentError, ~r/cannot resolve the operator/, fn ->
        Projection.replay(:calendar)
      end
    end

    test "a system without a projector raises instead of silently no-oping", %{context: context} do
      assert_raise ArgumentError, ~r/no projector for :gmail/, fn ->
        Projection.replay(:gmail, context)
      end
    end
  end

  # --- helpers -----------------------------------------------------------------

  defp run_fixture_pipeline do
    TapWorker.perform(%Oban.Job{args: %{"pipeline" => "calendar_dev"}})
  end

  defp landed_external_ids do
    SourceObject
    |> Ash.Query.filter(external_system == "calendar")
    |> Ash.read!(@opts)
    |> Enum.map(& &1.external_id)
    |> Enum.sort()
  end

  defp person_by_email(email, context) do
    AshEnterprise.Canonical.Person
    |> Ash.Query.filter(email == ^email)
    |> Ash.read_one!(authorize?: false, tenant: context[:tenant])
  end

  # The projected rows as a plain map, with volatile columns (ids, timestamps)
  # and the tenant/owner context excluded — exactly what determinism says must
  # be a pure function of the raw payloads. The organizer is compared by email,
  # the v1 linkage, because a fresh replay mints new Person ids.
  defp calendar_snapshot(context) do
    context
    |> projected_events()
    |> Enum.sort_by(& &1["external_id"])
  end

  defp projected_events(context) do
    tenant = context[:tenant]

    CalendarEvent
    |> Ash.Query.sort(:external_id)
    |> Ash.read!(authorize?: false, tenant: tenant)
    |> Ash.load!(:organizer, authorize?: false, tenant: tenant)
    |> Enum.map(fn event ->
      # Truncate to the second: the fixture carries whole seconds, the read
      # back carries microsecond precision, and DateTime equality includes
      # that precision.
      %{
        "external_id" => event.external_id,
        "external_system" => event.external_system,
        "external_uid" => event.external_uid,
        "title" => event.title,
        "starts_at" => DateTime.truncate(event.starts_at, :second),
        "ends_at" => DateTime.truncate(event.ends_at, :second),
        "location" => event.location,
        "organizer_email" => event.organizer && to_string(event.organizer.email)
      }
    end)
  end

  defp expected_events do
    @fixture
    |> Enum.map(fn event ->
      %{
        "external_id" => event["id"],
        "external_system" => "calendar",
        "external_uid" => event["iCalUID"],
        "title" => event["title"],
        "starts_at" => event["starts_at"],
        "ends_at" => event["ends_at"],
        "location" => event["location"],
        "organizer_email" => event["organizer_email"]
      }
    end)
    |> Enum.sort_by(& &1["external_id"])
  end

  # The determinism proof needs empty tables, not archived ghosts — and these
  # resources deliberately have no soft delete, so this is a plain truncate of
  # the two tables the calendar projection writes, in FK order.
  defp purge_canonical_rows do
    AshEnterprise.Repo.delete_all("canonical_calendar_events")
    AshEnterprise.Repo.delete_all("canonical_people")
  end
end
