defmodule AshEnterprise.Canonical.Projections.GmailTest do
  @moduledoc """
  The Gmail raw → canonical projection (epic E4): only the replay owner's own
  linked accounts, deny-by-default zone admission (ADR 0042), then
  Conversation/Message/Person derived from landed `gmail.messages` records,
  deterministically, with nothing mailbox-derived on organization-owned rows.

  Every landed record here is synthetic (`GmailSyntheticMailbox`), written to
  the sandboxed test database only.
  """

  use AshEnterprise.DataCase, async: false

  alias AshEnterprise.Canonical.{Conversation, Message, Person}
  alias AshEnterprise.Canonical.Projections.Gmail, as: Projection
  alias AshEnterprise.Ingestion.SourceObject
  alias AshEnterprise.Integration.Gmail.Sync
  alias AshEnterprise.Integration.LinkedAccount
  alias AshEnterprise.Security.ActorContext
  alias AshEnterprise.Test.GmailSyntheticMailbox

  @projection_env AshEnterprise.Canonical.Projections.Gmail

  defmodule AdmitAll do
    @moduledoc false
    @behaviour AshEnterprise.Canonical.Projections.ZoneGate
    @impl true
    def admit(_source, _context), do: :ok
  end

  defmodule AdmitTagged do
    @moduledoc false
    @behaviour AshEnterprise.Canonical.Projections.ZoneGate
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
    org = organization!("gmail-projection-#{unique}")
    owner = user!("owner-#{unique}")
    linked = link!(owner, org)

    box = start_supervised!(GmailSyntheticMailbox, id: :owner_box)
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
      land!(GmailSyntheticMailbox.message(box, id), linked, %{"residency" => residency(id, b1)})
    end

    %{org: org, owner: owner, linked: linked, unique: unique, a1: a1, a2: a2, b1: b1}
  end

  test "by default the zone gate admits nothing and nothing is projected", ctx do
    assert {:ok, counts} = Projection.replay(owner: ctx.owner, tenant: ctx.org)

    assert counts.source_objects == 3
    assert counts.foreign == 0
    assert counts.admitted == 0
    assert counts.denied == 3
    assert counts.messages == 0

    assert canonical(ctx) == %{conversations: [], messages: [], people: []}
  end

  test "admitted records project to conversations, messages and people", ctx do
    Application.put_env(:ash_enterprise, @projection_env, zone_gate: AdmitAll)

    assert {:ok, counts} = Projection.replay(owner: ctx.owner, tenant: ctx.org)
    assert counts.admitted == counts.source_objects

    thread_a = conversation!(ctx, ctx.linked, "thread-a-#{ctx.unique}")

    inbound = message!(ctx, ctx.linked, ctx.a1)
    reply = message!(ctx, ctx.linked, ctx.a2)

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
    assert sender.owner_id == ctx.owner.id

    bare = message!(ctx, ctx.linked, ctx.b1)
    bare_sender = Ash.get!(Person, bare.sender_id, tenant: ctx.org.id, authorize?: false)
    assert bare_sender.name == nil

    assert %{people: people} = canonical(ctx)

    assert people |> Enum.map(&to_string(&1.email)) |> Enum.sort() == [
             "bare@example.synthetic.test",
             "cc@example.synthetic.test",
             GmailSyntheticMailbox.owner(),
             "sender.one@example.synthetic.test"
           ]
  end

  test "projected identities carry the linked account (Gmail ids are per mailbox)", ctx do
    Application.put_env(:ash_enterprise, @projection_env, zone_gate: AdmitAll)
    assert {:ok, _counts} = Projection.replay(owner: ctx.owner, tenant: ctx.org)

    %{messages: messages, conversations: conversations} = canonical(ctx)

    assert Enum.map(messages, & &1.external_id) ==
             Enum.sort(Enum.map([ctx.a1, ctx.a2, ctx.b1], &Sync.external_id(ctx.linked.id, &1)))

    assert Enum.map(conversations, & &1.external_id) ==
             Enum.sort([
               Sync.external_id(ctx.linked.id, "thread-a-#{ctx.unique}"),
               Sync.external_id(ctx.linked.id, "thread-b-#{ctx.unique}")
             ])
  end

  test "the conversation is the owner's: subject and participants, sealed under the scope",
       ctx do
    Application.put_env(:ash_enterprise, @projection_env, zone_gate: AdmitAll)

    assert {:ok, _counts} = Projection.replay(owner: ctx.owner, tenant: ctx.org)

    thread_a = conversation!(ctx, ctx.linked, "thread-a-#{ctx.unique}")
    assert thread_a.owner_id == ctx.owner.id
    assert thread_a.subject == "SYNTHETIC-SUBJECT-A"

    assert thread_a.participants["emails"] ==
             Enum.sort([
               "cc@example.synthetic.test",
               GmailSyntheticMailbox.owner(),
               "sender.one@example.synthetic.test"
             ])

    assert length(thread_a.participants["person_ids"]) == 3

    scope = AshEnterprise.Erasure.scope_by_ref!(:connection, ctx.linked.id, authorize?: false)
    assert thread_a.erasure_scope_id == scope.id

    # Sealed at rest: the table holds ciphertext, never the subject.
    %{rows: [[ciphertext]]} =
      AshEnterprise.Repo.query!(
        "SELECT encrypted_subject FROM canonical_conversations WHERE id = $1::uuid",
        [Ecto.UUID.dump!(thread_a.id)]
      )

    assert is_binary(ciphertext)
    refute String.contains?(ciphertext, "SYNTHETIC-SUBJECT-A")
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
    assert message.external_id == Sync.external_id(ctx.linked.id, ctx.b1)
  end

  describe "whose records" do
    setup ctx do
      Application.put_env(:ash_enterprise, @projection_env, zone_gate: AdmitAll)

      # Carol: same tenant, her own linked account, and a message whose Gmail
      # id collides with the owner's a1 (Gmail ids are per mailbox).
      carol = user!("carol-#{ctx.unique}")
      carol_linked = link!(carol, ctx.org)
      carol_box = start_supervised!(GmailSyntheticMailbox, id: :carol_box)

      GmailSyntheticMailbox.add_message(carol_box,
        id: ctx.a1,
        thread_id: "thread-a-#{ctx.unique}",
        subject: "SYNTHETIC-SUBJECT-CAROL",
        body: "SYNTHETIC-BODY-CAROL"
      )

      land!(GmailSyntheticMailbox.message(carol_box, ctx.a1), carol_linked)

      # Bob: another tenant entirely.
      org_b = organization!("gmail-projection-b-#{ctx.unique}")
      bob = user!("bob-#{ctx.unique}")
      bob_linked = link!(bob, org_b)
      bob_box = start_supervised!(GmailSyntheticMailbox, id: :bob_box)
      bob_id = GmailSyntheticMailbox.add_message(bob_box, id: "msg-bob-#{ctx.unique}")
      land!(GmailSyntheticMailbox.message(bob_box, bob_id), bob_linked)

      # A record that names no linked account at all.
      orphan_box = start_supervised!(GmailSyntheticMailbox, id: :orphan_box)
      orphan_id = GmailSyntheticMailbox.add_message(orphan_box, id: "msg-orphan-#{ctx.unique}")
      land!(GmailSyntheticMailbox.message(orphan_box, orphan_id), nil)

      %{
        carol: carol,
        carol_linked: carol_linked,
        org_b: org_b,
        bob: bob,
        bob_linked: bob_linked,
        bob_id: bob_id
      }
    end

    test "a replay projects only the owner's own linked accounts in that tenant", ctx do
      assert {:ok, counts} = Projection.replay(owner: ctx.owner, tenant: ctx.org)

      assert counts.source_objects == 6
      assert counts.foreign == 3
      assert counts.admitted == 3

      messages = canonical(ctx).messages
      assert length(messages) == 3
      assert Enum.all?(messages, &(&1.owner_id == ctx.owner.id))
      refute Enum.any?(messages, &(&1.body in ["SYNTHETIC-BODY-CAROL"]))

      # Nothing of Bob's reached his own tenant either.
      assert Message.read!(tenant: ctx.org_b.id, authorize?: false) == []
    end

    test "naming another tenant does not reach the owner's mailbox", ctx do
      assert {:ok, counts} = Projection.replay(owner: ctx.owner, tenant: ctx.org_b)
      assert counts.admitted == 0
      assert counts.foreign == counts.source_objects

      assert Message.read!(tenant: ctx.org_b.id, authorize?: false) == []
    end

    test "colliding Gmail ids from two mailboxes stay two rows, each its owner's", ctx do
      assert {:ok, _} = Projection.replay(owner: ctx.owner, tenant: ctx.org)
      assert {:ok, _} = Projection.replay(owner: ctx.carol, tenant: ctx.org)
      assert {:ok, _} = Projection.replay(owner: ctx.bob, tenant: ctx.org_b)

      mine = message!(ctx, ctx.linked, ctx.a1)
      carols = message!(ctx, ctx.carol_linked, ctx.a1)

      assert mine.id != carols.id
      assert {mine.owner_id, mine.body} == {ctx.owner.id, "SYNTHETIC-BODY-1"}
      assert {carols.owner_id, carols.body} == {ctx.carol.id, "SYNTHETIC-BODY-CAROL"}
      assert mine.conversation_id != carols.conversation_id

      bobs =
        Message.by_external!("gmail", Sync.external_id(ctx.bob_linked.id, ctx.bob_id),
          tenant: ctx.org_b.id,
          authorize?: false
        )

      assert bobs.owner_id == ctx.bob.id
    end

    test "an unlinked account's records are no one's to project", ctx do
      LinkedAccount.unlink!(ctx.linked, tenant: ctx.org.id, authorize?: false)

      assert {:ok, counts} = Projection.replay(owner: ctx.owner, tenant: ctx.org)
      assert counts.admitted == 0
      assert canonical(ctx).messages == []
    end

    test "a Person another user owns is neither renamed nor linked", ctx do
      # Carol already has the sender as a Person, under her own name for them.
      carol_person =
        Person
        |> Ash.Changeset.for_create(
          :upsert_from_source,
          %{
            email: "sender.one@example.synthetic.test",
            name: "CAROLS-NAME-FOR-THEM",
            owner_id: ctx.carol.id,
            owner_type: :user,
            owning_user_id: ctx.carol.id
          },
          tenant: ctx.org.id,
          authorize?: false
        )
        |> Ash.create!(upsert?: true, upsert_identity: :unique_email, upsert_fields: [:name])

      assert {:ok, counts} = Projection.replay(owner: ctx.owner, tenant: ctx.org)

      reloaded = Ash.get!(Person, carol_person.id, tenant: ctx.org.id, authorize?: false)
      assert reloaded.name == "CAROLS-NAME-FOR-THEM"
      assert reloaded.owner_id == ctx.carol.id

      # The owner's message from that address is not linked to Carol's row;
      # the owner's other correspondents still are.
      assert message!(ctx, ctx.linked, ctx.a1).sender_id == nil
      assert message!(ctx, ctx.linked, ctx.b1).sender_id
      assert counts.people == 3
    end
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

  # Lands a synthetic record the way Sync lands one: identity namespaced by the
  # linked account, which is also named in the metadata. `nil` lands a record
  # that names no account.
  # Landed exactly as the scoped lander lands: sealed under the linked
  # account's erasure scope (ref = the account's uuid), or a stand-in scope for
  # a record that came through no account.
  defp land!(message, linked, metadata \\ %{}) do
    {external_id, account_metadata, scope_ref} =
      case linked do
        nil ->
          {"no-account:" <> message["id"], %{}, "gmail-test-no-account"}

        linked ->
          {Sync.external_id(linked.id, message["id"]), %{"linked_account_id" => linked.id},
           linked.id}
      end

    scope =
      AshEnterprise.Erasure.ensure_scope!(:connection, scope_ref, %{label: "gmail test"},
        actor: AshEnterprise.Platform.SystemActor.oban()
      )

    SourceObject.land_under!(
      scope.id,
      %{
        external_system: "gmail",
        external_id: external_id,
        raw_payload: message,
        source_metadata:
          %{"stream" => "gmail.messages", "thread_id" => message["threadId"]}
          |> Map.merge(account_metadata)
          |> Map.merge(metadata),
        cursor: %{"phase" => "backfill"},
        fetched_at: ~U[2026-10-12 09:00:00Z]
      },
      authorize?: false
    )
  end

  defp organization!(name) do
    AshEnterprise.Accounts.Organization
    |> Ash.Changeset.for_create(:create, %{name: name, unique_name: name}, authorize?: false)
    |> Ash.create!()
  end

  defp user!(local) do
    AshEnterprise.Accounts.User
    |> Ash.Changeset.for_create(
      :register_with_password,
      %{
        email: "#{local}@projection.test",
        password: "password1234",
        password_confirmation: "password1234"
      },
      authorize?: false
    )
    |> Ash.create!()
  end

  # `:link` makes the acting human the owner; policies are not under test here.
  defp link!(user, org) do
    actor =
      ActorContext.attach(user, %ActorContext{
        user_id: user.id,
        organization_id: org.id,
        principal_ids: [user.id]
      })

    LinkedAccount.link!(
      %{
        provider_config_key: "google-mail",
        connection_id: "conn-mail-synthetic-#{System.unique_integer([:positive])}"
      },
      actor: actor,
      tenant: org.id,
      authorize?: false
    )
  end

  defp message!(ctx, linked, gmail_id) do
    Message.by_external!("gmail", Sync.external_id(linked.id, gmail_id),
      tenant: ctx.org.id,
      authorize?: false
    )
  end

  defp conversation!(ctx, linked, thread_id) do
    Conversation.by_external!("gmail", Sync.external_id(linked.id, thread_id),
      tenant: ctx.org.id,
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
