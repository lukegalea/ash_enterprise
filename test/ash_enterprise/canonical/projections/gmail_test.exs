defmodule AshEnterprise.Canonical.Projections.GmailTest do
  @moduledoc """
  The Gmail raw → canonical projection (epic E4): deny-by-default zone
  admission (ADR 0042), then Conversation/Message/Person derived from landed
  `gmail.messages` records, deterministically.

  Every landed record here is synthetic (`GmailSyntheticMailbox`), written to
  the sandboxed test database only.
  """

  use AshEnterprise.DataCase, async: false

  alias AshEnterprise.Canonical.{Conversation, Message, Person}
  alias AshEnterprise.Canonical.Projections.Gmail, as: Projection
  alias AshEnterprise.Ingestion.SourceObject
  alias AshEnterprise.Test.GmailSyntheticMailbox

  @projection_env AshEnterprise.Canonical.Projections.Gmail

  defmodule AdmitAll do
    @moduledoc false
    @behaviour AshEnterprise.Canonical.Projections.Gmail.ZoneGate
    @impl true
    def admit(_source, _context), do: :ok
  end

  defmodule AdmitTagged do
    @moduledoc false
    @behaviour AshEnterprise.Canonical.Projections.Gmail.ZoneGate
    @impl true
    def admit(%{source_metadata: %{"residency" => "admissible"}}, _context), do: :ok
    def admit(_source, _context), do: {:deny, :untagged}
  end

  setup do
    previous = Application.get_env(:ash_enterprise, @projection_env)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:ash_enterprise, @projection_env, previous),
        else: Application.delete_env(:ash_enterprise, @projection_env)
    end)

    Application.delete_env(:ash_enterprise, @projection_env)

    unique = System.unique_integer([:positive])

    org =
      AshEnterprise.Accounts.Organization
      |> Ash.Changeset.for_create(
        :create,
        %{name: "gmail-projection-#{unique}", unique_name: "gmail-projection-#{unique}"},
        authorize?: false
      )
      |> Ash.create!()

    owner =
      AshEnterprise.Accounts.User
      |> Ash.Changeset.for_create(
        :register_with_password,
        %{
          email: "owner-#{unique}@projection.test",
          password: "password1234",
          password_confirmation: "password1234"
        },
        authorize?: false
      )
      |> Ash.create!()

    box = start_supervised!(GmailSyntheticMailbox)
    owner_address = GmailSyntheticMailbox.owner()

    # Thread A: an inbound message and the operator's reply.
    a1 =
      GmailSyntheticMailbox.add_message(box,
        id: "msg-a1-#{unique}",
        thread_id: "thread-a-#{unique}",
        subject: "SYNTHETIC-SUBJECT-A",
        from: "\"Synthetic, Sender\" <Sender.One@Example.Synthetic.Test>",
        cc: "cc@example.synthetic.test"
      )

    a2 =
      GmailSyntheticMailbox.add_message(box,
        id: "msg-a2-#{unique}",
        thread_id: "thread-a-#{unique}",
        subject: "Re: SYNTHETIC-SUBJECT-A",
        from: owner_address,
        to: "sender.one@example.synthetic.test",
        labels: ["SENT"]
      )

    # Thread B: one message, no display name on the sender.
    b1 =
      GmailSyntheticMailbox.add_message(box,
        id: "msg-b1-#{unique}",
        thread_id: "thread-b-#{unique}",
        subject: "SYNTHETIC-SUBJECT-B",
        from: "bare@example.synthetic.test"
      )

    for id <- [a1, a2, b1] do
      land!(GmailSyntheticMailbox.message(box, id), %{"residency" => residency(id, b1)})
    end

    %{org: org, owner: owner, unique: unique, a1: a1, a2: a2, b1: b1}
  end

  test "by default the zone gate admits nothing and nothing is projected", ctx do
    assert {:ok, counts} = Projection.replay(owner: ctx.owner, tenant: ctx.org)

    assert counts.source_objects >= 3
    assert counts.admitted == 0
    assert counts.denied == counts.source_objects
    assert counts.messages == 0

    assert canonical(ctx) == %{conversations: [], messages: [], people: []}
  end

  test "admitted records project to conversations, messages and people", ctx do
    Application.put_env(:ash_enterprise, @projection_env, zone_gate: AdmitAll)

    assert {:ok, counts} = Projection.replay(owner: ctx.owner, tenant: ctx.org)
    assert counts.admitted == counts.source_objects

    thread_a =
      Conversation.by_external!("gmail", "thread-a-#{ctx.unique}",
        tenant: ctx.org.id,
        authorize?: false
      )

    assert thread_a.subject == "SYNTHETIC-SUBJECT-A"

    assert thread_a.participants["emails"] == [
             "cc@example.synthetic.test",
             GmailSyntheticMailbox.owner(),
             "sender.one@example.synthetic.test"
           ]

    assert length(thread_a.participants["person_ids"]) == 3

    inbound = Message.by_external!("gmail", ctx.a1, tenant: ctx.org.id, authorize?: false)
    reply = Message.by_external!("gmail", ctx.a2, tenant: ctx.org.id, authorize?: false)

    assert inbound.direction == :inbound
    assert reply.direction == :outbound
    assert inbound.conversation_id == thread_a.id
    assert reply.conversation_id == thread_a.id
    assert inbound.body == "SYNTHETIC-BODY-1"
    assert inbound.owner_id == ctx.owner.id
    assert DateTime.compare(inbound.sent_at, reply.sent_at) == :lt

    sender = Ash.get!(Person, inbound.sender_id, tenant: ctx.org.id, authorize?: false)
    assert to_string(sender.email) == "sender.one@example.synthetic.test"
    assert sender.name == "Synthetic, Sender"

    bare = Message.by_external!("gmail", ctx.b1, tenant: ctx.org.id, authorize?: false)
    bare_sender = Ash.get!(Person, bare.sender_id, tenant: ctx.org.id, authorize?: false)
    assert bare_sender.name == nil
  end

  test "replay is deterministic: a second pass converges on the same rows", ctx do
    Application.put_env(:ash_enterprise, @projection_env, zone_gate: AdmitAll)

    assert {:ok, first_counts} = Projection.replay(owner: ctx.owner, tenant: ctx.org)
    first = canonical(ctx)

    assert {:ok, second_counts} = Projection.replay(owner: ctx.owner, tenant: ctx.org)
    assert second_counts == first_counts
    assert canonical(ctx) == first

    assert length(first.conversations) == 2
    assert length(first.messages) == 3
  end

  test "admission is per record", ctx do
    Application.put_env(:ash_enterprise, @projection_env, zone_gate: AdmitTagged)

    assert {:ok, counts} = Projection.replay(owner: ctx.owner, tenant: ctx.org)
    assert counts.admitted == 1

    assert %{messages: [message], conversations: [_one]} = canonical(ctx)
    assert message.external_id == ctx.b1
  end

  test "address lists: quoted commas, display names, bare addresses, junk" do
    assert Projection.addresses(
             ~s("Doe, Jane" <Jane@Example.test>, bob@example.test, Carol <c@x.test>, not-an-address)
           ) ==
             [
               %{email: "jane@example.test", name: "Doe, Jane"},
               %{email: "bob@example.test", name: nil},
               %{email: "c@x.test", name: "Carol"}
             ]

    assert Projection.addresses(nil) == []
  end

  # --- helpers -----------------------------------------------------------------

  # Only thread B's message carries an admissible residency tag.
  defp residency(id, id), do: "admissible"
  defp residency(_id, _admissible), do: nil

  defp land!(message, metadata) do
    SourceObject.land!(
      %{
        external_system: "gmail",
        external_id: message["id"],
        raw_payload: message,
        source_metadata:
          Map.merge(%{"stream" => "gmail.messages", "thread_id" => message["threadId"]}, metadata),
        cursor: %{"phase" => "backfill"},
        fetched_at: ~U[2026-10-12 09:00:00Z]
      },
      authorize?: false
    )
  end

  # The projected rows, minus timestamps and audit columns, keyed by their
  # source identities so two replays compare equal.
  defp canonical(ctx) do
    opts = [tenant: ctx.org.id, authorize?: false]

    %{
      conversations:
        Conversation.read!(opts)
        |> Enum.map(&Map.take(&1, [:id, :external_id, :subject, :participants]))
        |> Enum.sort_by(& &1.external_id),
      messages:
        Message.read!(opts)
        |> Enum.map(
          &Map.take(&1, [
            :id,
            :external_id,
            :body,
            :sent_at,
            :direction,
            :conversation_id,
            :sender_id,
            :owner_id
          ])
        )
        |> Enum.sort_by(& &1.external_id),
      people:
        Person
        |> Ash.read!(opts)
        |> Enum.map(&Map.take(&1, [:id, :email, :name]))
        |> Enum.sort_by(&to_string(&1.email))
    }
  end
end
