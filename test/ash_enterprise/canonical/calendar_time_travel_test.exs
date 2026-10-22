defmodule AshEnterprise.Canonical.CalendarTimeTravelTest do
  @moduledoc """
  `CalendarEvent` is temporal (ADR 0049, PROD-47): a re-projection that
  moves an event keeps the old version, so the calendar reads as it was
  known at any instant. Proves the upsert splits rather than overwrites, a
  write that changes nothing opens no version, the agenda windows cut
  around the read's instant, the week's reschedules come back as marks, a
  shred reaches every version, another person cannot read any of it, and
  the table carries the temporal key and the period-aware identities.
  SYNTHETIC data only.
  """

  use AshEnterprise.DataCase, async: false

  require Ash.Query

  import AshEnterprise.Test.DailyFixtures

  alias AshEnterprise.Canonical.{CalendarEvent, CalendarHistory, EventAttendee}
  alias AshEnterprise.Erasure
  alias AshEnterprise.Erasure.{Keyring, Shredded}
  alias AshEnterprise.Platform.LocalTime
  alias AshEnterprise.Repo

  defp opts(ctx), do: [actor: ctx.actor, tenant: ctx.tenant]
  defp as_of(ctx, at), do: opts(ctx) ++ [as_of: at]

  defp read_at(ctx, event, at) do
    CalendarEvent
    |> Ash.Query.for_read(:read, %{}, if(at, do: as_of(ctx, at), else: opts(ctx)))
    |> Ash.Query.filter(id == ^event.id)
    |> Ash.read_one!()
  end

  defp versions(event) do
    {:ok, %{rows: rows}} =
      Repo.query(
        "SELECT lower(valid_at), upper(valid_at), starts_at, encrypted_title " <>
          "FROM canonical_calendar_events WHERE id = $1 ORDER BY lower(valid_at)",
        [Ecto.UUID.dump!(event.id)]
      )

    rows
  end

  # The event first seen three days ago at 10:00 on the 19th, moved a day
  # ago to 14:00 on the 20th.
  defp rescheduled!(ctx) do
    known = DateTime.add(DateTime.utc_now(), -3, :day)
    moved = DateTime.add(DateTime.utc_now(), -1, :day)
    starts_at = ~U[2030-03-19 10:00:00.000000Z]

    event =
      event!(ctx, "SYNTHETIC design review", 0, 30,
        starts_at: starts_at,
        location: "SYNTHETIC room 4",
        as_of: known
      )

    moved_event =
      reproject_event!(
        ctx,
        event,
        %{starts_at: ~U[2030-03-20 14:00:00.000000Z], ends_at: ~U[2030-03-20 14:30:00.000000Z]},
        as_of: moved
      )

    %{event: moved_event, known: known, moved: moved, original: event}
  end

  setup do
    %{ctx: tenant!(operator?: true)}
  end

  describe "a reschedule" do
    test "keeps the old version: before it, the old time; after it, the new one", %{ctx: ctx} do
      %{event: event, known: known, moved: moved} = rescheduled!(ctx)

      before_move = read_at(ctx, event, DateTime.add(moved, -1, :minute))
      assert before_move.starts_at == ~U[2030-03-19 10:00:00.000000Z]
      assert before_move.title == "SYNTHETIC design review"

      assert read_at(ctx, event, DateTime.add(moved, 1, :minute)).starts_at ==
               ~U[2030-03-20 14:00:00.000000Z]

      now = read_at(ctx, event, nil)
      assert now.starts_at == ~U[2030-03-20 14:00:00.000000Z]
      assert now.location == "SYNTHETIC room 4"

      # Before it was first projected, it was not on the calendar at all.
      assert read_at(ctx, event, DateTime.add(known, -1, :minute)) == nil

      # One record, two versions: split at the reschedule, nothing overwritten.
      assert [[_k, ^moved, old_start, _], [^moved, nil, new_start, _]] =
               versions(event)

      assert old_start == ~N[2030-03-19 10:00:00.000000]
      assert new_start == ~N[2030-03-20 14:00:00.000000]

      # The version's write time is the reschedule's, not the first write's.
      assert DateTime.compare(now.updated_at, moved) == :eq
      assert DateTime.compare(now.inserted_at, known) == :eq
    end

    test "a write that changes nothing opens no version, and still reconciles attendees",
         %{ctx: ctx} do
      %{event: event} = rescheduled!(ctx)
      quinn = person!(ctx, "quinn@example.test", "SYNTHETIC Quinn")

      same = reproject_event!(ctx, event, %{attendees: [%{person_id: quinn.id}]})

      assert same.id == event.id
      assert length(versions(event)) == 2
      assert [%{person_id: person_id}] = Ash.read!(EventAttendee, opts(ctx))
      assert person_id == quinn.id

      # A changed title is a change.
      reproject_event!(ctx, event, %{title: "SYNTHETIC design review (moved)"})
      assert length(versions(event)) == 3
    end

    test "the agenda windows cut around the read's instant, not the wall clock", %{ctx: ctx} do
      day = LocalTime.today()
      at = fn date, time -> local(date, time) end
      known = DateTime.add(DateTime.utc_now(), -11, :day)

      # On the calendar since eleven days ago, for a slot ten days ago.
      past = Date.add(day, -10)

      event!(ctx, "SYNTHETIC retro", 0, 30, starts_at: at.(past, ~T[15:00:00]), as_of: known)

      noon_then = at.(past, ~T[12:00:00])

      today_then =
        CalendarEvent
        |> Ash.Query.for_read(:today, %{}, as_of(ctx, noon_then))
        |> Ash.read!()

      assert Enum.map(today_then, & &1.title) == ["SYNTHETIC retro"]

      # Read now, "today" is today, which the retro is not on.
      assert CalendarEvent.today!(opts(ctx)) == []
    end
  end

  describe "the week's history" do
    test "comes back as marks: moved, cancelled, back on", %{ctx: ctx} do
      %{event: event, moved: moved} = rescheduled!(ctx)
      cancelled_at = DateTime.add(DateTime.utc_now(), -2, :hour)
      reproject_event!(ctx, event, %{status: :cancelled}, as_of: cancelled_at)

      monday = CalendarHistory.week_start(~D[2030-03-20])
      history = CalendarHistory.history(monday, opts(ctx))

      assert [%{kind: :rescheduled, at: ^moved} = move, %{kind: :cancelled, at: ^cancelled_at}] =
               history.marks

      assert move.label == "Moved: SYNTHETIC design review"
      assert move.description =~ "→"
      assert length(history.versions[to_string(event.id)]) == 3

      # As of before the move, the week of the 18th held the event on the 19th.
      before = DateTime.add(moved, -1, :minute)

      assert [%{starts_at: ~U[2030-03-19 10:00:00.000000Z]}] =
               CalendarHistory.week(monday, before, opts(ctx))
    end
  end

  describe "erasure" do
    test "a shred reaches every version of an event", %{ctx: ctx} do
      scope = scope!()
      known = DateTime.add(DateTime.utc_now(), -3, :day)

      event =
        event!(ctx, "SYNTHETIC-SECRET offsite", 0, 60,
          starts_at: ~U[2030-03-19 10:00:00.000000Z],
          location: "SYNTHETIC-SECRET harbour",
          scope: scope,
          as_of: known
        )

      quinn = person!(ctx, "quinn@example.test", "SYNTHETIC Quinn")

      reproject_event!(
        ctx,
        event,
        %{starts_at: ~U[2030-03-21 10:00:00.000000Z], ends_at: ~U[2030-03-21 11:00:00.000000Z]},
        as_of: DateTime.add(known, 1, :day)
      )

      reproject_event!(
        ctx,
        event,
        %{title: "SYNTHETIC-SECRET offsite, new venue", attendees: [%{person_id: quinn.id}]},
        as_of: DateTime.add(known, 2, :day)
      )

      rows = versions(event)
      assert length(rows) == 3
      assert Enum.all?(rows, fn [_, _, _, sealed] -> match?({:ok, _}, open(sealed)) end)

      Erasure.shred_scope!(scope, scope.ref, "SYNTHETIC test shred", actor: ctx.actor)

      # Every version's ciphertext is sealed under the one scope key, which is gone.
      assert length(versions(event)) == 3

      assert Enum.all?(versions(event), fn [_, _, _, sealed] ->
               match?({:shredded, %Shredded{}}, open(sealed))
             end)

      # Read at each version's instant, the content is shredded and the times remain.
      for at <- [DateTime.add(known, 1, :hour), DateTime.add(known, 25, :hour), nil] do
        version = read_at(ctx, event, at)
        assert %Shredded{} = version.title
        assert %Shredded{} = version.location
        assert %DateTime{} = version.starts_at
      end

      assert Ash.read!(EventAttendee, opts(ctx)) == []

      {:ok, %{rows: [[raw]]}} =
        Repo.query(
          "SELECT string_agg(encrypted_title || coalesce(encrypted_location, ''), '') " <>
            "FROM canonical_calendar_events WHERE id = $1",
          [Ecto.UUID.dump!(event.id)]
        )

      refute raw =~ "SYNTHETIC-SECRET"
    end
  end

  describe "another person" do
    test "cannot read your calendar at any instant, nor its history", %{ctx: ctx} do
      %{event: event, moved: moved} = rescheduled!(ctx)
      other = member!(ctx, "SYNTHETIC no grants", [])
      monday = CalendarHistory.week_start(~D[2030-03-20])

      for at <- [nil, DateTime.add(moved, -1, :minute), DateTime.add(moved, 1, :minute)] do
        assert read_at(other, event, at) == nil
        assert CalendarHistory.week(monday, at, opts(other)) == []
      end

      assert CalendarHistory.history(
               monday,
               opts(other) ++ [at: DateTime.add(moved, -1, :minute)]
             ) ==
               %{versions: %{}, marks: []}
    end
  end

  describe "the table" do
    test "is keyed (id, valid_at WITHOUT OVERLAPS), with period-aware identities and its foreign keys" do
      {:ok, %{rows: constraints}} =
        Repo.query("""
        SELECT conname, contype::text, conperiod
        FROM pg_constraint WHERE conrelid = to_regclass('canonical_calendar_events')
        ORDER BY conname
        """)

      by_name = Map.new(constraints, fn [name, type, period] -> {name, {type, period}} end)

      assert by_name["canonical_calendar_events_pkey"] == {"p", true}
      assert by_name["canonical_calendar_events_unique_external_index"] == {"x", false}
      assert by_name["canonical_calendar_events_unique_provider_uid_index"] == {"x", false}
      assert {"f", false} = by_name["canonical_calendar_events_erasure_scope_id_fkey"]
      assert {"f", false} = by_name["canonical_calendar_events_organizer_id_fkey"]

      {:ok, %{rows: indexes}} =
        Repo.query(
          "SELECT indexname FROM pg_indexes WHERE tablename = 'canonical_calendar_events' " <>
            "AND indexdef LIKE 'CREATE UNIQUE INDEX%' AND indexname LIKE '%unique%'"
        )

      # No plain unique index left to refuse an event's second version.
      assert indexes == []
    end
  end

  defp open(sealed) do
    sealed |> Base.decode64!() |> Keyring.open!()
  end

  defp local(date, time) do
    date
    |> DateTime.new!(time, LocalTime.zone(), Tz.TimeZoneDatabase)
    |> DateTime.shift_zone!("Etc/UTC", Tz.TimeZoneDatabase)
  end
end
