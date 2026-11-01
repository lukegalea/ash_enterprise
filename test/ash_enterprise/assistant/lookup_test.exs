defmodule AshEnterprise.Assistant.LookupTest do
  @moduledoc """
  The assistant's read tools (E10.2), each a computed read run as a person, as
  a run's step runs it: what they return to their owner, that another person's mail, Slack, contacts and calendar
  are not in it (owner-only, ADR 0042), and that content reaches only an
  in-zone model in the canonical store's zone — and never content the zone
  gate refused at projection. Synthetic data only.
  """

  use AshEnterprise.DataCase, async: false

  alias AshEnterprise.Canonical.Projections.Gmail, as: GmailProjection
  alias AshEnterprise.Ingestion.SourceObject
  alias AshEnterprise.Integration.Gmail.Sync
  alias AshEnterprise.Integration.LinkedAccount
  alias AshEnterprise.Test.AssistantFixtures, as: F
  alias AshEnterprise.Test.DailyFixtures, as: D
  alias AshEnterprise.Test.GmailSyntheticMailbox

  @tools [
    {:calendar_events, %{}},
    {:find_conversations, %{}},
    {:read_messages, %{}},
    {:find_people, %{query: "example"}},
    {:my_tasks, %{status: :any}},
    {:morning_briefs, %{}},
    {:pending_approvals, %{}},
    {:steward_queue, %{}},
    {:count_activity, %{metric: :messages, group_by: :person}}
  ]

  setup do
    F.in_zone!()
    alice = F.tenant!()

    D.event!(alice, "SYNTHETIC-ALICE-STANDUP", 60, 30)
    D.person!(alice, "zed@example.test", "Zed Example")
    thread = D.conversation!(alice, "gmail", "SYNTHETIC-ALICE-SUBJECT", "SYNTHETIC-ALICE-BODY")
    slack = D.conversation!(alice, "slack", "SYNTHETIC-ALICE-CHANNEL", "SYNTHETIC-ALICE-SLACK")

    %{alice: alice, thread: thread, slack: slack}
  end

  describe "for their owner" do
    test "calendar_events: the window's events, with refs", %{alice: alice} do
      # At noon today, not relative to now: an hour from now is tomorrow after 23:00.
      D.event!(alice, "SYNTHETIC-ALICE-REVIEW", 0, 30, starts_at: D.today_at(~T[12:00:00]))

      assert [event] = F.tool!(alice, :calendar_events, %{window: "today", text: "review"})
      assert event["title"] == "SYNTHETIC-ALICE-REVIEW"
      assert "calendar:" <> _ = event["ref"]

      assert [] =
               F.tool!(alice, :calendar_events, %{window: "last_7_days", text: "nothing-like-it"})

      assert F.refusal(alice, :calendar_events, %{window: "SYNTHETIC-BAD"}) =~ "not a window"
    end

    test "calendar_events as_of: the day as it was known then, and what has moved since",
         %{alice: alice} do
      known = DateTime.add(DateTime.utc_now(), -3, :day)
      moved = DateTime.add(DateTime.utc_now(), -1, :day)

      event =
        D.event!(alice, "SYNTHETIC-ALICE-PLANNING", 0, 30,
          starts_at: ~U[2030-03-19 10:00:00.000000Z],
          as_of: known
        )

      D.reproject_event!(
        alice,
        event,
        %{starts_at: ~U[2030-03-19 15:00:00.000000Z], ends_at: ~U[2030-03-19 15:30:00.000000Z]},
        as_of: moved
      )

      before_move = DateTime.add(moved, -1, :hour) |> DateTime.to_iso8601()

      assert [then] =
               F.tool!(alice, :calendar_events, %{window: "2030-03-19", as_of: before_move})

      assert then["title"] == "SYNTHETIC-ALICE-PLANNING"
      assert then["when"] =~ "10:00"
      assert then["now"] =~ "15:00"

      assert [now] = F.tool!(alice, :calendar_events, %{window: "2030-03-19"})

      assert now["when"] =~ "15:00"
      refute Map.has_key?(now, "now")

      # Before it was on the calendar at all.
      long_ago = known |> DateTime.add(-1, :day) |> DateTime.to_iso8601()

      assert [] = F.tool!(alice, :calendar_events, %{window: "2030-03-19", as_of: long_ago})

      assert F.refusal(alice, :calendar_events, %{window: "2030-03-19", as_of: "last friday"}) =~
               "as_of"

      # Nobody else's past either.
      carol = F.colleague!(alice)

      assert [] = F.tool!(carol, :calendar_events, %{window: "2030-03-19", as_of: before_move})
    end

    test "find_conversations and read_messages: decrypted for the owner, cited by thread",
         %{alice: alice, thread: thread, slack: slack} do
      assert [_, _] = F.tool!(alice, :find_conversations, %{})

      assert [found] = F.tool!(alice, :find_conversations, %{source: :gmail, text: "alice-body"})

      assert found["subject"] == "SYNTHETIC-ALICE-SUBJECT"
      assert found["ref"] == "inbox:#{thread.id}"
      assert found["needs_reply"] == true

      assert [%{"ref" => ref}] = F.tool!(alice, :find_conversations, %{source: :slack})

      assert ref == "slack:#{slack.id}"

      assert [message] = F.tool!(alice, :read_messages, %{conversation: "inbox:#{thread.id}"})

      assert message["text"] == "SYNTHETIC-ALICE-BODY"
      assert message["ref"] == "inbox:#{thread.id}"
      assert message["from"] == "Sender"
    end

    test "find_people, count_activity", %{alice: alice} do
      assert [%{"name" => "Zed Example", "ref" => "people:" <> _}] =
               F.tool!(alice, :find_people, %{query: "zed"})

      # The total first, then the groups.
      assert [%{"key" => "all", "count" => 2, "window" => _} | groups] =
               F.tool!(alice, :count_activity, %{metric: :messages, group_by: :source})

      assert Enum.sort(Enum.map(groups, & &1["key"])) == ["gmail", "slack"]

      assert [%{"key" => "all", "count" => 1} | _groups] =
               F.tool!(alice, :count_activity, %{
                 metric: :events,
                 group_by: :day,
                 window: "next_7_days"
               })
    end

    test "find_people as_of: the records a person was split across then", %{alice: alice} do
      system = [tenant: alice.tenant, authorize?: false]
      month_ago = DateTime.add(DateTime.utc_now(), -30, :day)
      work = D.person!(alice, "yan@example.test", "Yan Example")
      home = D.person!(alice, "yan.home@example.test", "Yan Home")

      for {golden, external_id} <- [{work, "slack:U-yan"}, {home, "gmail:yan.home"}] do
        AshEnterprise.Mdm.SourceIdentity
        |> Ash.Changeset.for_create(
          :open,
          %{
            source: :slack,
            stream: :users,
            external_id: external_id,
            golden_resource: "AshEnterprise.Canonical.Person",
            golden_id: golden.id,
            asserted_by: :mapping
          },
          system ++ [as_of: month_ago]
        )
        |> Ash.create!()
      end

      home
      |> Ash.Changeset.for_update(:mdm_merge_into, %{survivor_id: work.id}, system)
      |> Ash.update!()

      # Now: the merged record answers through its survivor.
      assert [%{"name" => "Yan Example"} = now] = F.tool!(alice, :find_people, %{query: "yan"})

      refute Map.has_key?(now, "records_then")

      # A week ago: Yan was two records.
      week_ago = Date.add(Date.utc_today(), -7) |> Date.to_iso8601()

      people = F.tool!(alice, :find_people, %{query: "yan", as_of: week_ago})

      yan = Enum.find(people, &(&1["name"] == "Yan Example"))

      assert [%{"name" => "Yan Example", "identities" => 1}, %{"name" => "Yan Home"}] =
               yan["records_then"]

      assert F.refusal(alice, :find_people, %{query: "yan", as_of: "last friday"}) =~ "as_of"
    end

    test "pending_approvals and morning_briefs: the brief waiting on its owner", %{alice: alice} do
      D.brief!(alice)

      assert [%{"ref" => "today:" <> _}] = F.tool!(alice, :morning_briefs, %{})

      assert [_ | _] = approvals = F.tool!(alice, :pending_approvals, %{})
      assert Enum.all?(approvals, &match?(%{"ref" => "approvals:" <> _}, &1))
    end
  end

  describe "for anybody else" do
    test "another Administrator of the tenant gets none of the owner's mail, Slack or people",
         %{alice: alice} do
      bob = F.colleague!(alice, admin?: true)

      assert [] = F.tool!(bob, :find_conversations, %{})
      assert [] = F.tool!(bob, :read_messages, %{window: "last_90_days"})
      assert [] = F.tool!(bob, :find_people, %{query: "example"})

      assert [%{"key" => "all", "count" => 0}] =
               F.tool!(bob, :count_activity, %{metric: :messages, group_by: :person})

      assert [%{"key" => "all", "count" => 0}] =
               F.tool!(bob, :count_activity, %{metric: :conversations, group_by: :person})

      refute inspect(Enum.map(@tools, fn {name, input} -> F.tool!(bob, name, input) end)) =~
               "SYNTHETIC-ALICE-SUBJECT"
    end

    test "a member with no grants gets nothing from any tool", %{alice: alice} do
      carol = F.colleague!(alice)

      for {name, input} <- @tools do
        result = F.tool!(carol, name, input)
        refute inspect(result) =~ "SYNTHETIC-ALICE", "#{name} leaked the owner's content"
      end
    end

    test "naming the owner's conversation by ref does not open it", %{
      alice: alice,
      thread: thread
    } do
      bob = F.colleague!(alice, admin?: true)

      assert [] = F.tool!(bob, :read_messages, %{conversation: "inbox:#{thread.id}"})
    end
  end

  describe "the zone gate" do
    test "a caller with no run, or a run whose model is outside the zone, gets a refusal",
         %{alice: alice} do
      for {name, input} <- @tools do
        assert "Refused: " <> _ = F.refusal(alice, name, input, run?: false)
      end

      # The run's model is the in-zone profile: outside the canonical store's zone, or
      # not configured at all, nothing is returned to it.
      for setup <- [
            fn -> F.in_zone!(profile_zone: "SYNTHETIC-OTHER-ZONE") end,
            fn -> Application.put_env(:ash_enterprise, :ai, []) end
          ] do
        setup.()

        for {name, input} <- @tools do
          message = F.refusal(alice, name, input)
          assert "Refused: " <> _ = message
          refute message =~ "SYNTHETIC-ALICE"
        end
      end
    end

    test "content the zone gate refused at projection is never there to return" do
      Application.put_env(:ash_enterprise, GmailProjection, zone_gate: __MODULE__.AdmitTagged)
      on_exit(fn -> Application.delete_env(:ash_enterprise, GmailProjection) end)

      owner = F.tenant!()
      linked = link!(owner)
      box = start_supervised!(GmailSyntheticMailbox)

      admitted =
        GmailSyntheticMailbox.add_message(box,
          id: "msg-in-#{System.unique_integer([:positive])}",
          subject: "SYNTHETIC-ADMITTED",
          from: "in@example.test"
        )

      refused =
        GmailSyntheticMailbox.add_message(box,
          id: "msg-out-#{System.unique_integer([:positive])}",
          subject: "SYNTHETIC-REFUSED",
          from: "out@example.test"
        )

      land!(GmailSyntheticMailbox.message(box, admitted), linked, "admissible")
      land!(GmailSyntheticMailbox.message(box, refused), linked, "restricted")

      assert {:ok, %{admitted: 1}} =
               GmailProjection.replay(owner: owner.user, tenant: owner.organization)

      found = F.tool!(owner, :find_conversations, %{})
      assert [%{"subject" => "SYNTHETIC-ADMITTED"}] = found

      messages = F.tool!(owner, :read_messages, %{window: "last_90_days"})
      refute inspect(messages) =~ "SYNTHETIC-REFUSED"
      refute inspect(F.tool!(owner, :find_people, %{query: "out@"})) =~ "out@example.test"
    end
  end

  defmodule AdmitTagged do
    @moduledoc false
    @behaviour AshEnterprise.Canonical.Projections.ZoneGate
    @impl true
    def admit(%{source_metadata: %{"residency" => "admissible"}}, _context), do: :ok
    def admit(_source, _context), do: {:deny, :inadmissible_restriction}
  end

  defp link!(owner) do
    LinkedAccount.link!(
      %{
        provider_config_key: "google-mail",
        connection_id: "conn-assistant-#{System.unique_integer([:positive])}"
      },
      actor: owner.actor,
      tenant: owner.tenant
    )
  end

  defp land!(message, linked, residency) do
    scope =
      AshEnterprise.Erasure.ensure_scope!(:connection, linked.id, %{label: "assistant test"},
        actor: AshEnterprise.Platform.SystemActor.oban()
      )

    SourceObject.land_under!(
      scope.id,
      %{
        external_system: "gmail",
        external_id: Sync.external_id(linked.id, message["id"]),
        raw_payload: message,
        source_metadata: %{
          "stream" => "gmail.messages",
          "thread_id" => message["threadId"],
          "linked_account_id" => linked.id,
          "residency" => residency
        },
        cursor: %{"phase" => "backfill"},
        fetched_at: DateTime.utc_now()
      },
      authorize?: false
    )
  end
end
