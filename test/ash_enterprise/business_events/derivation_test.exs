defmodule AshEnterprise.BusinessEvents.DerivationTest do
  @moduledoc """
  The canonical-row → business-fact mapping (ADR 0051), as pure functions:
  which kind a write implies, what a fact carries (ids and clear structure,
  nothing sealed), and the delivery keys that make re-deriving a no-op.
  """

  use ExUnit.Case, async: true

  alias AshEnterprise.BusinessEvents.Derivation

  @carried_by_calendar ~w(calendar_event_id erasure_scope_id starts_at ends_at status organizer_id changed)
  @carried_by_message ~w(message_id conversation_id sender_id direction erasure_scope_id)
  @carried_by_conversation ~w(conversation_id first_message_id kind erasure_scope_id)

  defp calendar_event(overrides \\ %{}) do
    Map.merge(
      %{
        id: Ash.UUID.generate(),
        external_system: "google_calendar",
        external_id: "gcal:abc/evt-1",
        title: "SEALED TITLE",
        location: "SEALED LOCATION",
        starts_at: ~U[2026-10-13 14:00:00.000000Z],
        ends_at: ~U[2026-10-13 14:30:00.000000Z],
        status: :confirmed,
        organizer_id: Ash.UUID.generate(),
        erasure_scope_id: Ash.UUID.generate(),
        updated_at: ~U[2026-10-12 09:00:00.000000Z]
      },
      overrides
    )
  end

  defp message(overrides \\ %{}) do
    Map.merge(
      %{
        id: Ash.UUID.generate(),
        external_system: "gmail",
        external_id: "msg-1",
        body: "SEALED BODY",
        sent_at: ~U[2026-10-12 08:15:00.000000Z],
        direction: :inbound,
        conversation_id: Ash.UUID.generate(),
        sender_id: Ash.UUID.generate(),
        erasure_scope_id: Ash.UUID.generate()
      },
      overrides
    )
  end

  defp conversation(message) do
    %{
      id: message.conversation_id,
      external_system: "gmail",
      external_id: "thread-1",
      subject: "SEALED SUBJECT",
      kind: nil,
      erasure_scope_id: message.erasure_scope_id
    }
  end

  defp recorded(fact), do: %{id: Ash.UUID.generate(), data: fact.data}

  # A conversation's current start, as the recorder reads it back.
  defp started(fact), do: %{id: Ash.UUID.generate(), occurred_at: fact.occurred_at}

  describe "calendar events" do
    test "first sight of a live event is scheduled; the state is carried, the content is not" do
      event = calendar_event()
      assert [fact] = Derivation.calendar_event(event, nil)

      assert fact.event_kind == :"calendar_event.scheduled"
      assert fact.subject_type == "calendar_event"
      assert fact.subject_stream == :google_calendar
      assert fact.subject_external_id == event.external_id
      assert fact.occurred_at == event.updated_at

      assert fact.data == %{
               "calendar_event_id" => event.id,
               "erasure_scope_id" => event.erasure_scope_id,
               "starts_at" => "2026-10-13T14:00:00.000000Z",
               "ends_at" => "2026-10-13T14:30:00.000000Z",
               "status" => "confirmed",
               "organizer_id" => event.organizer_id
             }

      assert fact.provenance["mapping_name"] == "ash_enterprise.canonical.calendar_event"
      assert fact.provenance["mapping_version_hash"] == Derivation.version_hash()
      assert fact.provenance["source_record_id"] == event.id
      refute inspect(fact) =~ "SEALED"
    end

    test "the same state again derives nothing" do
      event = calendar_event()
      [first] = Derivation.calendar_event(event, nil)

      assert Derivation.calendar_event(%{event | updated_at: DateTime.utc_now()}, recorded(first)) ==
               []
    end

    test "a moved event is changed, naming what changed" do
      event = calendar_event()
      [first] = Derivation.calendar_event(event, nil)
      moved = %{event | starts_at: ~U[2026-10-13 15:00:00.000000Z]}

      assert [fact] = Derivation.calendar_event(moved, recorded(first))
      assert fact.event_kind == :"calendar_event.changed"
      assert fact.data["changed"] == ["starts_at"]
      assert fact.data["starts_at"] == "2026-10-13T15:00:00.000000Z"
    end

    test "cancelling is cancelled; reinstating is scheduled again" do
      event = calendar_event()
      [first] = Derivation.calendar_event(event, nil)

      [cancelled] = Derivation.calendar_event(%{event | status: :cancelled}, recorded(first))
      assert cancelled.event_kind == :"calendar_event.cancelled"

      assert [reinstated] = Derivation.calendar_event(event, recorded(cancelled))
      assert reinstated.event_kind == :"calendar_event.scheduled"
    end

    test "an event first seen cancelled is cancelled" do
      assert [%{event_kind: :"calendar_event.cancelled"}] =
               Derivation.calendar_event(calendar_event(%{status: :cancelled}), nil)
    end

    test "a change derived twice from one predecessor has one delivery key; a change back does not reuse an old one" do
      event = calendar_event()
      [first] = Derivation.calendar_event(event, nil)
      moved = %{event | starts_at: ~U[2026-10-13 15:00:00.000000Z]}
      first_recorded = recorded(first)

      [a] = Derivation.calendar_event(moved, first_recorded)
      [b] = Derivation.calendar_event(moved, first_recorded)
      assert a.delivery_key == b.delivery_key

      [back] = Derivation.calendar_event(event, recorded(a))
      assert back.event_kind == :"calendar_event.changed"
      refute back.delivery_key in [first.delivery_key, a.delivery_key]
      assert byte_size(back.delivery_key) <= 512
    end

    test "a native row, or one from an unknown system, derives nothing" do
      assert Derivation.calendar_event(calendar_event(%{external_id: nil}), nil) == []
      assert Derivation.calendar_event(calendar_event(%{external_system: "outlook"}), nil) == []
    end
  end

  describe "messages and conversations" do
    test "an inbound message is received, an outbound one sent, and its conversation starts" do
      inbound = message()
      assert [received, started] = Derivation.message(inbound, conversation(inbound))

      assert received.event_kind == :"message.received"
      assert received.occurred_at == inbound.sent_at
      assert received.actor_type == "canonical.person"
      assert received.actor_external_id == inbound.sender_id
      assert Map.keys(received.data) -- @carried_by_message == []

      assert started.event_kind == :"conversation.started"
      assert started.subject_type == "conversation"
      assert started.subject_external_id == "thread-1"
      assert started.occurred_at == inbound.sent_at
      assert started.data["first_message_id"] == inbound.id
      assert Map.keys(started.data) -- @carried_by_conversation == []

      outbound = message(%{direction: :outbound, external_id: "msg-2"})

      assert [%{event_kind: :"message.sent"}, _] =
               Derivation.message(outbound, conversation(outbound))

      refute inspect(Derivation.message(inbound, conversation(inbound))) =~ "SEALED"
    end

    test "every message of a conversation derives the same start, so it collapses to one" do
      first = message()
      second = message(%{id: Ash.UUID.generate(), external_id: "msg-2"})

      [_, started_a] = Derivation.message(first, conversation(first))
      [_, started_b] = Derivation.message(second, conversation(first))
      assert started_a.delivery_key == started_b.delivery_key
    end

    test "a message with no conversation yet derives only itself" do
      assert [%{event_kind: :"message.received"}] = Derivation.message(message(), nil)
    end
  end

  describe "a conversation's start, corrected (BIZEV-9)" do
    test "a message sent before the current start supersedes it" do
      later = message(%{sent_at: ~U[2026-10-12 09:00:00.000000Z]})
      [_, start] = Derivation.message(later, conversation(later), nil)
      current = started(start)

      earlier =
        message(%{
          id: Ash.UUID.generate(),
          external_id: "msg-0",
          sent_at: ~U[2026-10-12 07:00:00.000000Z],
          conversation_id: later.conversation_id
        })

      assert [_, correction] = Derivation.message(earlier, conversation(later), current)

      assert correction.event_kind == :"conversation.started"
      assert correction.supersedes_event_id == current.id
      assert correction.occurred_at == earlier.sent_at
      assert correction.data["first_message_id"] == earlier.id
      assert correction.subject_external_id == start.subject_external_id
      assert Map.keys(correction.data) -- @carried_by_conversation == []

      # A new fact, not the first start again; derived twice, one key.
      refute correction.delivery_key == start.delivery_key
      assert [_, again] = Derivation.message(earlier, conversation(later), current)
      assert again.delivery_key == correction.delivery_key
    end

    test "a message sent at or after the current start derives no conversation fact" do
      first = message()
      [_, start] = Derivation.message(first, conversation(first), nil)

      for sent_at <- [first.sent_at, DateTime.add(first.sent_at, 60)] do
        later = message(%{id: Ash.UUID.generate(), external_id: "msg-2", sent_at: sent_at})

        assert [%{event_kind: :"message.received"}] =
                 Derivation.message(later, conversation(first), started(start))
      end
    end

    test "the first start keeps the key it had before corrections existed" do
      first = message()
      [_, start] = Derivation.message(first, conversation(first), nil)
      refute Map.has_key?(start, :supersedes_event_id)
      assert [_, ^start] = Derivation.message(first, conversation(first))
    end
  end

  describe "a shred's tombstone" do
    test "names the scope and counts the owner's facts; nothing else" do
      scope = %{
        id: Ash.UUID.generate(),
        kind: :connection,
        ref: "SECRET-CONNECTION-REF",
        label: "SECRET LABEL",
        shredded_at: ~U[2026-10-18 12:00:00.000000Z]
      }

      owner = %{organization_id: Ash.UUID.generate(), owner_id: Ash.UUID.generate()}
      tombstone = Derivation.shredded(scope, owner, 4, :ca)

      assert tombstone.subject_external_id == scope.id
      assert tombstone.occurred_at == scope.shredded_at

      assert tombstone.data == %{
               "subject" => scope.id,
               "region" => "ca",
               "erasure_scope_id" => scope.id,
               "scope_kind" => "connection",
               "facts" => 4
             }

      refute inspect(tombstone) =~ "SECRET"

      other_owner = %{owner | owner_id: Ash.UUID.generate()}

      refute Derivation.shredded(scope, other_owner, 4, :ca).delivery_key ==
               tombstone.delivery_key

      assert Derivation.shredded(scope, owner, 5, :ca).delivery_key == tombstone.delivery_key
    end
  end

  test "a calendar fact carries nothing but ids and clear structure" do
    event = calendar_event()
    [first] = Derivation.calendar_event(event, nil)
    [changed] = Derivation.calendar_event(%{event | ends_at: DateTime.utc_now()}, recorded(first))

    for fact <- [first, changed] do
      assert Map.keys(fact.data) -- @carried_by_calendar == []
      assert fact.actor_type == nil
    end
  end
end
