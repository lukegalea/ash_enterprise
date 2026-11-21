defmodule AshEnterprise.Assistant.DailyQuestionsTest do
  @moduledoc """
  The two daily questions the read tools answer in one call (PROD-41): "who am I
  waiting on" (`find_conversations` with `waiting_on_others`) and "which meetings
  tomorrow need prep" (`meeting_prep`). Each is run as the person, as a run's step
  runs it: what it returns to its owner, that the person themself is never one of
  the people named, and that nobody else's mail or calendar reaches it. Synthetic
  data only.
  """

  use AshEnterprise.DataCase, async: false

  alias AshEnterprise.Canonical.Task
  alias AshEnterprise.Test.AssistantFixtures, as: F
  alias AshEnterprise.Test.DailyFixtures, as: D

  setup do
    F.in_zone!()
    alice = F.tenant!()

    # Alice herself, as her mail and calendar know her.
    me = D.person!(alice, to_string(alice.user.email), "Alice Synthetic")
    quinn = D.person!(alice, "quinn@example.test", "Quinn Synthetic")
    rory = D.person!(alice, "rory@example.test", "Rory Example")
    robin = D.person!(alice, "robin@example.test", "Robin Newcomer")

    %{alice: alice, me: me, quinn: quinn, rory: rory, robin: robin}
  end

  describe "find_conversations waiting_on_others" do
    test "threads the person wrote last in, longest wait first, with who they wait on",
         %{alice: alice, me: me, quinn: quinn, rory: rory} do
      contract =
        D.thread!(alice, "gmail", "SYNTHETIC contract redlines", [me, quinn], [
          {:inbound, quinn, "SYNTHETIC: redlines attached.", 3 * 24 * 60},
          {:outbound, me, "SYNTHETIC: can you confirm clause 4?", 2 * 24 * 60}
        ])

      dm =
        D.thread!(
          alice,
          "slack",
          "SYNTHETIC DM",
          [me, rory],
          [{:outbound, me, "SYNTHETIC: did the deploy finish?", 60}],
          kind: :dm
        )

      # A channel post waits on nobody in particular; a thread Rory answered is not waiting.
      D.thread!(
        alice,
        "slack",
        "SYNTHETIC #general",
        [me, rory],
        [{:outbound, me, "SYNTHETIC: lunch is here.", 30}],
        kind: :public_channel
      )

      D.thread!(alice, "gmail", "SYNTHETIC answered", [me, rory], [
        {:outbound, me, "SYNTHETIC: question?", 120},
        {:inbound, rory, "SYNTHETIC: answer.", 90}
      ])

      assert [first, second] =
               F.tool!(alice, :find_conversations, %{waiting_on_others: true})

      assert first["ref"] == "inbox:#{contract.id}"
      assert first["waiting_on"] == ["Quinn Synthetic"]
      assert first["last_from"] == "me"
      assert is_binary(first["waiting_since"])

      assert second["ref"] == "slack:#{dm.id}"
      assert second["waiting_on"] == ["Rory Example"]

      # Without the flag the rows carry no waiting fields.
      refute Enum.any?(F.tool!(alice, :find_conversations, %{}), &Map.has_key?(&1, "waiting_on"))
    end

    test "a thread older than the window is not waited on", %{alice: alice, me: me, quinn: quinn} do
      D.thread!(alice, "gmail", "SYNTHETIC long ago", [me, quinn], [
        {:outbound, me, "SYNTHETIC: any news?", 45 * 24 * 60}
      ])

      assert [] = F.tool!(alice, :find_conversations, %{waiting_on_others: true})

      assert [%{"waiting_on" => ["Quinn Synthetic"]}] =
               F.tool!(alice, :find_conversations, %{
                 waiting_on_others: true,
                 window: "last_90_days"
               })
    end

    test "another person's threads are not theirs to wait on", %{
      alice: alice,
      me: me,
      quinn: quinn
    } do
      D.thread!(alice, "gmail", "SYNTHETIC-ALICE-WAITING", [me, quinn], [
        {:outbound, me, "SYNTHETIC-ALICE-BODY", 60}
      ])

      bob = F.colleague!(alice, admin?: true)

      assert [] = F.tool!(bob, :find_conversations, %{waiting_on_others: true})
    end
  end

  describe "meeting_prep" do
    setup %{alice: alice, me: me, quinn: quinn, rory: rory, robin: robin} do
      review = D.event!(alice, "SYNTHETIC design review", 0, 30, starts_at: tomorrow(10))
      Enum.each([me, quinn], &D.attendee!(alice, review, &1))

      intro = D.event!(alice, "SYNTHETIC intro call", 0, 30, starts_at: tomorrow(14))
      Enum.each([me, robin], &D.attendee!(alice, intro, &1))

      standup = D.event!(alice, "SYNTHETIC standup", 0, 15, starts_at: tomorrow(9))
      Enum.each([me, rory], &D.attendee!(alice, standup, &1))

      cancelled =
        D.event!(alice, "SYNTHETIC cancelled sync", 0, 30,
          starts_at: tomorrow(16),
          status: :cancelled
        )

      D.attendee!(alice, cancelled, quinn)

      # Rory and Alice have met and talked, but nothing between them is recent enough
      # to be open.
      D.thread!(alice, "slack", "SYNTHETIC DM with Rory", [me, rory], [
        {:inbound, rory, "SYNTHETIC: any time.", 120 * 24 * 60}
      ])

      past = D.event!(alice, "SYNTHETIC last week's standup", -7 * 24 * 60, 15)
      D.attendee!(alice, past, rory)

      # Quinn is owed a reply, and Alice holds an action item from this meeting.
      owed =
        D.thread!(alice, "gmail", "SYNTHETIC redlines", [me, quinn], [
          {:inbound, quinn, "SYNTHETIC: can you look at clause 4 before we meet?", 120}
        ])

      item = action_item_from!(alice, review, "SYNTHETIC bring the signed NDA")

      %{review: review, intro: intro, standup: standup, owed: owed, item: item}
    end

    test "tomorrow's meetings, each with what to prepare and the refs to cite", ctx do
      %{alice: alice, review: review, intro: intro, standup: standup, owed: owed, item: item} =
        ctx

      rows = F.tool!(alice, :meeting_prep, %{})

      # In time order; the cancelled one is gone.
      assert Enum.map(rows, & &1["ref"]) ==
               ["calendar:#{standup.id}", "calendar:#{review.id}", "calendar:#{intro.id}"]

      [standup_row, review_row, intro_row] = rows

      assert review_row["prep"] == true
      assert review_row["attendees"] == ["Quinn Synthetic"]

      assert [%{ref: owed_ref, from: "Quinn Synthetic", subject: "SYNTHETIC redlines"}] =
               review_row["replies_owed"]

      assert owed_ref == "inbox:#{owed.id}"
      assert [%{ref: "action_items:" <> item_id}] = review_row["open_items"]
      assert item_id == item.id

      assert Enum.any?(review_row["reasons"], &(&1 =~ "owe Quinn Synthetic a reply"))
      assert Enum.any?(review_row["reasons"], &(&1 =~ "bring the signed NDA"))

      assert intro_row["prep"] == true
      assert intro_row["not_met_before"] == ["Robin Newcomer"]

      # Nothing open with Rory, whom Alice has met: nothing to prepare.
      assert standup_row["prep"] == false
      refute Map.has_key?(standup_row, "reasons")

      # Alice is never one of the people she meets.
      refute Enum.any?(rows, &("Alice Synthetic" in (&1["attendees"] || [])))
    end

    test "narrowed by title and window", %{alice: alice, review: review} do
      assert [%{"ref" => ref}] = F.tool!(alice, :meeting_prep, %{text: "contract"})
      assert ref == "calendar:#{review.id}"

      assert [] = F.tool!(alice, :meeting_prep, %{window: "yesterday", text: "contract"})
      assert F.refusal(alice, :meeting_prep, %{window: "SYNTHETIC-BAD"}) =~ "not a window"
    end

    test "nobody else's mail reaches it, and a member with no grants gets nothing", %{
      alice: alice
    } do
      carol = F.colleague!(alice)
      assert [] = F.tool!(carol, :meeting_prep, %{})

      # An Administrator's role reaches the tenant's calendar events and action items
      # (neither is owner-only), but mail, Slack, contacts and attendee lists are the
      # owner's alone: nothing derived from them is in another person's answer.
      bob = F.colleague!(alice, admin?: true)

      for row <- F.tool!(bob, :meeting_prep, %{}) do
        refute Map.has_key?(row, "replies_owed")
        refute Map.has_key?(row, "waiting_on_them")
        refute Map.has_key?(row, "not_met_before")
        refute Map.has_key?(row, "attendees")
      end
    end

    test "only a run on the in-zone model gets an answer", %{alice: alice} do
      assert "Refused: " <> _ = F.refusal(alice, :meeting_prep, %{}, run?: false)

      F.in_zone!(profile_zone: "SYNTHETIC-OTHER-ZONE")
      message = F.refusal(alice, :meeting_prep, %{})
      assert "Refused: " <> _ = message
      refute message =~ "SYNTHETIC"
    end
  end

  defp tomorrow(hour), do: D.tomorrow_at(Time.new!(hour, 0, 0))

  # An action item the person accepted from a proposal that came from `origin`.
  defp action_item_from!(ctx, origin, commitment) do
    proposal =
      Task
      |> Ash.Changeset.for_create(
        :propose,
        %{
          commitment: commitment,
          evidence: commitment,
          source: "calendar",
          origin_type: to_string(origin.__struct__),
          origin_id: origin.id,
          erasure_scope_id: origin.erasure_scope_id,
          proposer: "test",
          instrument: "deterministic",
          owner_id: ctx.user.id,
          owning_user_id: ctx.user.id,
          owning_business_unit_id: ctx.user.owning_business_unit_id
        },
        tenant: ctx.tenant,
        authorize?: false
      )
      |> Ash.create!()

    {:ok, task} = Task.accept_mine(proposal.id, actor: ctx.actor, tenant: ctx.tenant)
    task
  end
end
