defmodule AshEnterprise.Canonical.RelatedLabelsAuthorizationTest do
  @moduledoc """
  The calculations that name a related record on a row — `sender_label`,
  `organizer_label`, `next_event`, `latest_message` — read that record **as
  the reader**. A reader who may read the row but not the related record
  must get nothing from it: no name, no title, no body.

  Each test is phrased as what must not happen. The related record always
  belongs to the tenant's admin; the reader holds a grant on the row only.
  """

  use AshEnterprise.DataCase, async: false

  import AshEnterprise.Test.DailyFixtures, only: [tenant!: 0, member!: 3, person!: 3, scope!: 0]

  alias AshEnterprise.Canonical.{CalendarEvent, Conversation, Message, Person}

  setup do
    %{admin: tenant!()}
  end

  defp owner(user) do
    %{
      owner_id: user.id,
      owner_type: :user,
      owning_user_id: user.id,
      owning_business_unit_id: user.owning_business_unit_id
    }
  end

  defp event!(owner_ctx, title, organizer_id) do
    starts_at = DateTime.add(DateTime.utc_now(), 60, :minute)

    CalendarEvent
    |> Ash.Changeset.for_create(
      :upsert_from_source,
      Map.merge(owner(owner_ctx.user), %{
        title: title,
        starts_at: starts_at,
        ends_at: DateTime.add(starts_at, 30, :minute),
        status: :confirmed,
        external_system: "test",
        external_id: "evt-#{System.unique_integer([:positive])}",
        organizer_id: organizer_id,
        erasure_scope_id: scope!().id
      }),
      tenant: owner_ctx.tenant,
      authorize?: false
    )
    |> Ash.create!()
  end

  defp conversation!(owner_ctx) do
    Conversation
    |> Ash.Changeset.for_create(
      :upsert_from_source,
      Map.merge(owner(owner_ctx.user), %{
        subject: "Quarterly review",
        participants: %{},
        external_system: "gmail",
        external_id: "conv-#{System.unique_integer([:positive])}",
        erasure_scope_id: scope!().id
      }),
      tenant: owner_ctx.tenant,
      authorize?: false
    )
    |> Ash.create!()
  end

  defp message!(owner_ctx, conversation, sender, body) do
    Message
    |> Ash.Changeset.for_create(
      :upsert_from_source,
      Map.merge(owner(owner_ctx.user), %{
        body: body,
        sent_at: DateTime.utc_now(),
        direction: :inbound,
        external_system: "gmail",
        external_id: "msg-#{System.unique_integer([:positive])}",
        conversation_id: conversation.id,
        sender_id: sender.id,
        erasure_scope_id: scope!().id
      }),
      tenant: owner_ctx.tenant,
      authorize?: false
    )
    |> Ash.create!()
  end

  defp load!(record, calculation, :unauthorized) do
    record
    |> Ash.load!(calculation, authorize?: false, tenant: record.organization_id)
    |> Map.fetch!(calculation)
  end

  defp load!(record, calculation, person) do
    record
    |> Ash.load!(calculation, actor: person.actor, tenant: person.tenant)
    |> Map.fetch!(calculation)
  end

  test "next_event names no event the reader may not read", %{admin: admin} do
    reader = member!(admin, "People only", [{Person, :read, :basic}])
    mine = person!(reader, "me-#{System.unique_integer([:positive])}@example.test", "Me")

    # The admin's event, organized by the reader's own person.
    event!(admin, "Admin's private planning", mine.id)

    assert load!(mine, :next_event, :unauthorized) =~ "Admin's private planning"
    assert load!(mine, :next_event, reader) == nil
  end

  test "organizer_label names no organizer the reader may not read", %{admin: admin} do
    reader = member!(admin, "Events only", [{CalendarEvent, :read, :global}])
    organizer = person!(admin, "boss-#{System.unique_integer([:positive])}@example.test", "Boss")
    event = event!(admin, "Planning", organizer.id)

    assert load!(event, :organizer_label, :unauthorized) == "Boss"
    assert load!(event, :organizer_label, reader) == nil
  end

  test "latest_message shows no message the reader may not read", %{admin: admin} do
    reader = member!(admin, "Conversations only", [{Conversation, :read, :basic}])
    conversation = conversation!(reader)
    sender = person!(admin, "s-#{System.unique_integer([:positive])}@example.test", "Sender")

    # The admin's message in the reader's conversation.
    message!(admin, conversation, sender, "The admin's confidential body")

    assert load!(conversation, :latest_message, :unauthorized) =~ "confidential body"
    assert load!(conversation, :latest_message, reader) == nil
  end

  test "sender_label names no sender the reader may not read", %{admin: admin} do
    reader =
      member!(admin, "Mail only", [{Conversation, :read, :basic}, {Message, :read, :basic}])

    conversation = conversation!(reader)

    sender =
      person!(admin, "s-#{System.unique_integer([:positive])}@example.test", "Secret Sender")

    message = message!(reader, conversation, sender, "Hello")

    assert load!(message, :sender_label, :unauthorized) == "Secret Sender"
    assert load!(message, :sender_label, reader) == nil

    # …and not through latest_message, where the label is a nested load.
    line = load!(conversation, :latest_message, reader)
    assert line =~ "Hello"
    refute line =~ "Secret Sender"
  end
end
