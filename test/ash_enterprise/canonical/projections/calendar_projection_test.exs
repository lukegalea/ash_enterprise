defmodule AshEnterprise.Canonical.Projections.CalendarTest do
  @moduledoc """
  The Google Calendar projector on its own: the pure payload mapping, and
  deterministic replay over synthetic sources (no landing, no network).
  """

  use AshEnterprise.DataCase, async: true

  alias AshEnterprise.Canonical.{CalendarEvent, Person}
  alias AshEnterprise.Canonical.Projections.Calendar, as: Projector
  alias AshEnterprise.Test.CalendarFixtures, as: F

  describe "event_attributes/1 (pure)" do
    test "timed events convert their offset to UTC; the room is not a person" do
      assert {:ok, attrs} = Projector.event_attributes(F.planning_event())

      assert attrs.status == :confirmed
      assert attrs.title == "#{F.marker()} planning block"
      assert attrs.starts_at == ~U[2026-10-13 13:00:00Z]
      assert attrs.ends_at == ~U[2026-10-13 13:30:00Z]
      assert attrs.organizer == %{email: "ada@example.test", name: "Ada #{F.marker()}"}

      assert Enum.map(attrs.attendees, & &1.email) == ["ada@example.test", F.primary_calendar()]
    end

    test "all-day events start and end at midnight UTC; tentative is kept" do
      assert {:ok, attrs} = Projector.event_attributes(F.offsite_event())
      assert attrs.status == :tentative
      assert attrs.starts_at == ~U[2026-10-16 00:00:00Z]
      assert attrs.ends_at == ~U[2026-10-17 00:00:00Z]
      assert attrs.location == nil
    end

    test "an untitled event gets a placeholder title rather than failing" do
      payload = Map.delete(F.review_event(), "summary")
      assert {:ok, %{title: "(no title)"}} = Projector.event_attributes(payload)
    end

    test "a bare deletion is recognised as a cancellation with nothing else to project" do
      assert {:bare, :cancelled} = Projector.event_attributes(F.bare_cancellation("synthev0002"))
    end

    test "an unknown status is read as confirmed, never turned into an atom" do
      payload = Map.put(F.review_event(), "status", "something-new")
      assert {:ok, %{status: :confirmed}} = Projector.event_attributes(payload)
    end
  end

  describe "calendar_key/2" do
    test "depends only on the linked account and the calendar, and carries no calendar id" do
      account = Ecto.UUID.generate()
      key = Projector.calendar_key(account, F.primary_calendar())

      assert key == Projector.calendar_key(account, F.primary_calendar())
      assert key != Projector.calendar_key(account, F.team_calendar())
      assert key != Projector.calendar_key(Ecto.UUID.generate(), F.primary_calendar())
      assert "gcal:" <> hex = key
      assert byte_size(hex) == 64
      refute key =~ "example.test"
    end
  end

  describe "external_id/2" do
    test "is the calendar key plus the event id" do
      assert Projector.external_id("cursor-key", "synthev0001") == "cursor-key/synthev0001"
    end

    test "an over-long event id is digested so the identity still fits" do
      id = Projector.external_id("cursor-key", String.duplicate("a", 600))
      assert byte_size(id) <= 512
      assert String.starts_with?(id, "cursor-key/sha256:")
      assert id == Projector.external_id("cursor-key", String.duplicate("a", 600))
    end
  end

  describe "replay/2" do
    setup do
      unique = "projection-#{System.unique_integer([:positive])}"

      org =
        AshEnterprise.Accounts.Organization
        |> Ash.Changeset.for_create(:create, %{name: unique, unique_name: unique},
          authorize?: false
        )
        |> Ash.create!()

      owner =
        AshEnterprise.Accounts.User
        |> Ash.Changeset.for_create(
          :register_with_password,
          %{
            email: "owner-#{System.unique_integer([:positive])}@projection.test",
            password: "password1234",
            password_confirmation: "password1234"
          },
          authorize?: false
        )
        |> Ash.create!()

      sources =
        for payload <- [F.planning_event(), F.review_event(), F.offsite_event()] do
          %{
            external_system: Projector.external_system(),
            external_id: Projector.external_id("cal-key-synthetic", payload["id"]),
            raw_payload: payload
          }
        end

      scope =
        AshEnterprise.Erasure.ensure_scope!(
          :connection,
          "projection-test-#{System.unique_integer([:positive])}",
          %{label: "projection test"},
          actor: AshEnterprise.Platform.SystemActor.oban()
        )

      context = %{owner_id: owner.id, tenant_id: org.id, erasure_scope_id: scope.id}

      %{org: org, owner: owner, context: context, sources: sources}
    end

    test "a deleted event with its full payload is recorded as cancelled", ctx do
      source = %{
        external_system: Projector.external_system(),
        external_id: Projector.external_id("cal-key-synthetic", "synthev0004"),
        raw_payload: F.deleted_event()
      }

      assert {:ok, %{cancelled: 1}} = Projector.replay([source], ctx.context)
      assert [event] = CalendarEvent |> Ash.read!(tenant: ctx.org.id, authorize?: false)
      assert event.status == :cancelled
      assert event.erasure_scope_id == ctx.context.erasure_scope_id
    end

    test "a deleted event that already has a row keeps the row, cancelled", ctx do
      live = %{
        external_system: Projector.external_system(),
        external_id: Projector.external_id("cal-key-synthetic", "synthev0004"),
        raw_payload: Map.put(F.deleted_event(), "status", "confirmed")
      }

      assert {:ok, %{projected: 1}} = Projector.replay([live], ctx.context)
      [row] = CalendarEvent |> Ash.read!(tenant: ctx.org.id, authorize?: false)

      assert row.status == :confirmed

      bare = %{live | raw_payload: F.bare_cancellation("synthev0004")}
      assert {:ok, %{projected: 0, cancelled: 1}} = Projector.replay([bare], ctx.context)

      assert [kept] = CalendarEvent |> Ash.read!(tenant: ctx.org.id, authorize?: false)
      assert kept.id == row.id
      assert kept.title == row.title
      assert kept.status == :cancelled
    end

    test "a projection without an erasure scope writes nothing", ctx do
      assert {:error, :erasure_scope_required} =
               Projector.replay(ctx.sources, Map.delete(ctx.context, :erasure_scope_id))

      assert CalendarEvent |> Ash.read!(tenant: ctx.org.id, authorize?: false) == []
      assert Person |> Ash.read!(tenant: ctx.org.id, authorize?: false) == []
    end

    test "is deterministic: delete everything, replay, and the rows come back the same", ctx do
      assert {:ok, %{projected: 3, people: 4}} = Projector.replay(ctx.sources, ctx.context)
      first = rows(ctx.org)

      assert {:ok, %{projected: 3}} = Projector.replay(ctx.sources, ctx.context)
      assert rows(ctx.org) == first

      truncate_tenant("canonical_calendar_events", ctx.org.id)
      truncate_tenant("canonical_people", ctx.org.id)

      assert {:ok, %{projected: 3}} = Projector.replay(ctx.sources, ctx.context)
      assert strip_ids(rows(ctx.org)) == strip_ids(first)
    end

    test "a bare cancellation of an unseen event is skipped, not invented", ctx do
      source = %{
        external_system: Projector.external_system(),
        external_id: Projector.external_id("cal-key-synthetic", "never-seen"),
        raw_payload: F.bare_cancellation("never-seen")
      }

      assert {:ok, %{skipped: 1, projected: 0}} = Projector.replay([source], ctx.context)
      assert CalendarEvent |> Ash.read!(tenant: ctx.org.id, authorize?: false) == []
    end
  end

  defp rows(org) do
    events =
      CalendarEvent
      |> Ash.Query.sort(:external_id)
      |> Ash.read!(tenant: org.id, authorize?: false)
      |> Enum.map(fn e ->
        organizer =
          e.organizer_id && Ash.get!(Person, e.organizer_id, tenant: org.id, authorize?: false)

        {e.id, e.external_id, e.title, e.starts_at, e.ends_at, e.location,
         organizer && to_string(organizer.email)}
      end)

    people =
      Person
      |> Ash.Query.sort(:email)
      |> Ash.read!(tenant: org.id, authorize?: false)
      |> Enum.map(&{&1.id, to_string(&1.email), &1.name})

    {events, people}
  end

  defp strip_ids({events, people}) do
    {Enum.map(events, &Tuple.delete_at(&1, 0)), Enum.map(people, &Tuple.delete_at(&1, 0))}
  end

  # Test-only raw delete, the same one `AshEnterprise.CanonicalTest` uses: the
  # projected resources have no destroy action on purpose (replay
  # reconstructs; nothing deletes a projection), and "delete every canonical
  # row" is exactly what the determinism proof needs. Scoped to this test's
  # tenant inside the sandbox transaction.
  defp truncate_tenant(table, organization_id) do
    import Ecto.Query, only: [from: 2]

    {:ok, uuid} = Ecto.UUID.dump(organization_id)
    AshEnterprise.Repo.delete_all(from(row in table, where: row.organization_id == ^uuid))
  end
end
