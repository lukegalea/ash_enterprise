defmodule AshEnterprise.Canonical.DerivedJoinsTest do
  @moduledoc """
  The derived facts (`AshEnterprise.Canonical.Derive`): an event's attendees
  and a conversation's participants become first-class joins inside their
  parent's upsert — reconciled on every re-projection, left alone by a write
  that does not say — and a shred deletes them, because they hold ids rather
  than sealed values. Also the relationships the surfaces link through.
  SYNTHETIC data only.
  """

  use AshEnterprise.DataCase, async: false

  require Ash.Query

  import AshEnterprise.Test.DailyFixtures

  alias AshEnterprise.Agents.MorningBrief

  alias AshEnterprise.Canonical.{
    CalendarEvent,
    Conversation,
    ConversationParticipant,
    EventAttendee,
    Person
  }

  alias AshEnterprise.Erasure.Scope
  alias AshEnterprise.Integration.{Landing, LinkedAccount}

  defp opts(ctx), do: [actor: ctx.actor, tenant: ctx.tenant]
  defp system(ctx), do: [tenant: ctx.tenant, authorize?: false]

  defp owner(ctx) do
    %{
      owner_id: ctx.user.id,
      owner_type: :user,
      owning_user_id: ctx.user.id,
      owning_business_unit_id: ctx.user.owning_business_unit_id
    }
  end

  defp upsert_event!(ctx, external_id, scope, attrs) do
    CalendarEvent.upsert_from_source!(
      ctx
      |> owner()
      |> Map.merge(%{
        external_system: "google_calendar",
        external_id: external_id,
        title: "Synthetic sync",
        starts_at: ~U[2026-10-13 15:00:00.000000Z],
        ends_at: ~U[2026-10-13 15:30:00.000000Z],
        erasure_scope_id: scope.id
      })
      |> Map.merge(attrs),
      system(ctx)
    )
  end

  defp upsert_conversation!(ctx, external_id, scope, person_ids) do
    Conversation.upsert_from_source!(
      Map.merge(owner(ctx), %{
        external_system: "gmail",
        external_id: external_id,
        subject: "Synthetic thread",
        participants: %{"emails" => [], "person_ids" => person_ids},
        erasure_scope_id: scope.id
      }),
      system(ctx)
    )
  end

  defp attendees(event, ctx) do
    EventAttendee
    |> Ash.Query.filter(event_id == ^event.id)
    |> Ash.read!(system(ctx))
    |> Map.new(&{&1.person_id, &1.response_status})
  end

  defp participants(conversation, ctx) do
    ConversationParticipant
    |> Ash.Query.filter(conversation_id == ^conversation.id)
    |> Ash.read!(system(ctx))
    |> MapSet.new(& &1.person_id)
  end

  describe "event attendees" do
    test "an event's upsert derives its attendees, with their answers, and reconciles them" do
      ctx = tenant!()
      scope = scope!()
      ada = person!(ctx, "ada@example.test", "Ada Park")
      bo = person!(ctx, "bo@example.test", "Bo Lee")

      event =
        upsert_event!(ctx, "evt-1", scope, %{
          attendees: [
            %{person_id: ada.id, response_status: "accepted"},
            %{person_id: bo.id, response_status: "needsAction"}
          ]
        })

      assert attendees(event, ctx) == %{ada.id => :accepted, bo.id => :needs_action}

      # Re-projected: Bo dropped off the invite, Ada changed her mind.
      upsert_event!(ctx, "evt-1", scope, %{
        attendees: [%{person_id: ada.id, response_status: "declined"}]
      })

      assert attendees(event, ctx) == %{ada.id => :declined}

      # A write that does not say who is invited (a bare cancellation) keeps them.
      upsert_event!(ctx, "evt-1", scope, %{status: :cancelled})
      assert attendees(event, ctx) == %{ada.id => :declined}

      # The owner reads the joins and both sides of them.
      [loaded] =
        CalendarEvent
        |> Ash.Query.filter(id == ^event.id)
        |> Ash.Query.load([:attendee_count, people: [:label], attendees: [:response_label]])
        |> Ash.read!(opts(ctx))

      assert loaded.attendee_count == 1
      assert [%{label: "Ada Park"}] = loaded.people
      assert [%{response_label: "Declined"}] = loaded.attendees

      [ada] =
        Person
        |> Ash.Query.filter(id == ^ada.id)
        |> Ash.Query.load(:attended_events)
        |> Ash.read!(opts(ctx))

      assert Enum.map(ada.attended_events, & &1.id) == [event.id]
    end
  end

  describe "conversation participants" do
    test "a conversation's upsert derives its participants and reconciles them" do
      ctx = tenant!()
      scope = scope!()
      ada = person!(ctx, "ada@example.test", "Ada Park")
      bo = person!(ctx, "bo@example.test", "Bo Lee")

      conversation = upsert_conversation!(ctx, "thread-1", scope, [ada.id, bo.id, "not-a-uuid"])
      assert participants(conversation, ctx) == MapSet.new([ada.id, bo.id])

      upsert_conversation!(ctx, "thread-1", scope, [bo.id])
      assert participants(conversation, ctx) == MapSet.new([bo.id])

      [bo] =
        Person
        |> Ash.Query.filter(id == ^bo.id)
        |> Ash.Query.load([:conversation_count, :conversations])
        |> Ash.read!(opts(ctx))

      assert bo.conversation_count == 1
      assert Enum.map(bo.conversations, & &1.id) == [conversation.id]
    end

    test "a sender's messages are a relationship of the person" do
      ctx = tenant!()
      conversation = conversation!(ctx, "gmail", "Quarterly review", "Thursday works.")

      [message] =
        Ash.load!(conversation, [messages: [:sender, :preview, :sent]], opts(ctx)).messages

      assert message.preview == "Thursday works."
      assert is_binary(message.sent)

      [sender] =
        Person
        |> Ash.Query.filter(id == ^message.sender.id)
        |> Ash.Query.load([:sent_messages, :sent_message_count])
        |> Ash.read!(opts(ctx))

      assert sender.sent_message_count == 1
      assert Enum.map(sender.sent_messages, & &1.id) == [message.id]
    end
  end

  describe "shred" do
    test "shredding a scope deletes the joins of everything sealed under it, and only those" do
      ctx = tenant!(operator?: true)
      shredded = scope!()
      kept = scope!()
      ada = person!(ctx, "ada@example.test", "Ada Park")

      gone_event =
        upsert_event!(ctx, "evt-gone", shredded, %{attendees: [%{person_id: ada.id}]})

      kept_event = upsert_event!(ctx, "evt-kept", kept, %{attendees: [%{person_id: ada.id}]})
      gone_thread = upsert_conversation!(ctx, "thread-gone", shredded, [ada.id])
      kept_thread = upsert_conversation!(ctx, "thread-kept", kept, [ada.id])

      shredded
      |> Ash.Changeset.for_update(
        :shred,
        %{confirm: shredded.ref, reason: "synthetic erasure test"},
        actor: ctx.actor
      )
      |> Ash.update!()

      assert attendees(gone_event, ctx) == %{}
      assert participants(gone_thread, ctx) == MapSet.new()
      assert attendees(kept_event, ctx) == %{ada.id => nil}
      assert participants(kept_thread, ctx) == MapSet.new([ada.id])
    end
  end

  describe "links between the operator's records" do
    test "a linked account and its erasure scope name each other" do
      ctx = tenant!(operator?: true)
      account = linked_account!(ctx, "google-mail")
      {:ok, scope} = Landing.open(account)

      [loaded] =
        LinkedAccount
        |> Ash.Query.filter(id == ^account.id)
        |> Ash.Query.load(:erasure_scope)
        |> Ash.read!(opts(ctx))

      assert loaded.erasure_scope.id == scope.id

      [scope] =
        Scope
        |> Ash.Query.filter(id == ^scope.id)
        |> Ash.Query.load([:linked_account, :conversation_count])
        |> Ash.read!(opts(ctx))

      assert scope.linked_account.id == account.id
      assert scope.conversation_count == 0
    end

    test "a morning brief reaches its events and its approval task" do
      ctx = tenant!()
      event = event!(ctx, "Design review", 5, 30)
      brief = brief!(ctx)

      [brief] =
        MorningBrief
        |> Ash.Query.filter(id == ^brief.id)
        |> Ash.Query.load([:events, approval_task: [:subject_ref]])
        |> Ash.read!(opts(ctx))

      assert Enum.map(brief.events, & &1.id) == [event.id]
      assert brief.approval_task.subject_ref == "today:#{brief.id}"
    end
  end
end
