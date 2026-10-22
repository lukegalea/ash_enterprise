defmodule AshEnterprise.Assistant.LookupTest do
  @moduledoc """
  The assistant's read tools (E10.2), each run as a person: what they return
  to their owner, that another person's mail, Slack, contacts and calendar
  are not in it (owner-only, ADR 0042), and that content reaches only an
  in-zone model in the canonical store's zone — and never content the zone
  gate refused at projection. Synthetic data only.
  """

  use AshEnterprise.DataCase, async: false

  alias AshEnterprise.AI.Models
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

      result = F.tool!(alice, :calendar_events, %{window: "today", text: "review"})
      assert %{"count" => 1, "events" => [event]} = result
      assert event["title"] == "SYNTHETIC-ALICE-REVIEW"
      assert "calendar:" <> _ = event["ref"]

      assert %{"count" => 0} =
               F.tool!(alice, :calendar_events, %{window: "last_7_days", text: "nothing-like-it"})

      assert %{"error" => error} = F.tool!(alice, :calendar_events, %{window: "SYNTHETIC-BAD"})
      assert error =~ "not a window"
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

      assert %{"as_of" => _, "count" => 1, "events" => [then]} =
               F.tool!(alice, :calendar_events, %{window: "2030-03-19", as_of: before_move})

      assert then["title"] == "SYNTHETIC-ALICE-PLANNING"
      assert then["when"] =~ "10:00"
      assert then["now"] =~ "15:00"

      assert %{"count" => 1, "events" => [now]} =
               F.tool!(alice, :calendar_events, %{window: "2030-03-19"})

      assert now["when"] =~ "15:00"
      refute Map.has_key?(now, "now")

      # Before it was on the calendar at all.
      long_ago = known |> DateTime.add(-1, :day) |> DateTime.to_iso8601()

      assert %{"count" => 0} =
               F.tool!(alice, :calendar_events, %{window: "2030-03-19", as_of: long_ago})

      assert %{"error" => error} =
               F.tool!(alice, :calendar_events, %{window: "2030-03-19", as_of: "last friday"})

      assert error =~ "as_of"

      # Nobody else's past either.
      carol = F.colleague!(alice)

      assert %{"count" => 0} =
               F.tool!(carol, :calendar_events, %{window: "2030-03-19", as_of: before_move})
    end

    test "find_conversations and read_messages: decrypted for the owner, cited by thread",
         %{alice: alice, thread: thread, slack: slack} do
      assert %{"count" => 2} = F.tool!(alice, :find_conversations, %{})

      assert %{"count" => 1, "conversations" => [found]} =
               F.tool!(alice, :find_conversations, %{source: :gmail, text: "alice-body"})

      assert found["subject"] == "SYNTHETIC-ALICE-SUBJECT"
      assert found["ref"] == "inbox:#{thread.id}"
      assert found["needs_reply"] == true

      assert %{"conversations" => [%{"ref" => ref}]} =
               F.tool!(alice, :find_conversations, %{source: :slack})

      assert ref == "slack:#{slack.id}"

      assert %{"count" => 1, "messages" => [message]} =
               F.tool!(alice, :read_messages, %{conversation: "inbox:#{thread.id}"})

      assert message["text"] == "SYNTHETIC-ALICE-BODY"
      assert message["ref"] == "inbox:#{thread.id}"
      assert message["from"] == "Sender"
    end

    test "find_people, count_activity", %{alice: alice} do
      assert %{"people" => [%{"name" => "Zed Example", "ref" => "people:" <> _}]} =
               F.tool!(alice, :find_people, %{query: "zed"})

      assert %{"total" => 2, "groups" => groups} =
               F.tool!(alice, :count_activity, %{metric: :messages, group_by: :source})

      assert Enum.sort(Enum.map(groups, & &1["key"])) == ["gmail", "slack"]

      assert %{"total" => 1} =
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
      assert %{"people" => [%{"name" => "Yan Example"} = now]} =
               F.tool!(alice, :find_people, %{query: "yan"})

      refute Map.has_key?(now, "records_then")

      # A week ago: Yan was two records.
      week_ago = Date.add(Date.utc_today(), -7) |> Date.to_iso8601()

      assert %{"as_of" => _, "people" => people} =
               F.tool!(alice, :find_people, %{query: "yan", as_of: week_ago})

      yan = Enum.find(people, &(&1["name"] == "Yan Example"))

      assert [%{"name" => "Yan Example", "identities" => 1}, %{"name" => "Yan Home"}] =
               yan["records_then"]

      assert %{"error" => _} = F.tool!(alice, :find_people, %{query: "yan", as_of: "last friday"})
    end

    test "pending_approvals and morning_briefs: the brief waiting on its owner", %{alice: alice} do
      D.brief!(alice)

      assert %{"count" => 1, "briefs" => [%{"ref" => "today:" <> _}]} =
               F.tool!(alice, :morning_briefs, %{})

      assert %{"count" => count, "approvals" => approvals} =
               F.tool!(alice, :pending_approvals, %{})

      assert count >= 1
      assert Enum.all?(approvals, &match?(%{"ref" => "approvals:" <> _}, &1))
    end
  end

  describe "for anybody else" do
    test "another Administrator of the tenant gets none of the owner's mail, Slack or people",
         %{alice: alice} do
      bob = F.colleague!(alice, admin?: true)

      assert %{"count" => 0} = F.tool!(bob, :find_conversations, %{})
      assert %{"count" => 0} = F.tool!(bob, :read_messages, %{window: "last_90_days"})
      assert %{"count" => 0} = F.tool!(bob, :find_people, %{query: "example"})

      assert %{"total" => 0} =
               F.tool!(bob, :count_activity, %{metric: :messages, group_by: :person})

      assert %{"total" => 0} =
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

      assert %{"count" => 0} =
               F.tool!(bob, :read_messages, %{conversation: "inbox:#{thread.id}"})
    end
  end

  describe "the zone gate" do
    test "no model target, or one outside the zone, gets a refusal and no content",
         %{alice: alice} do
      hosted = Models.resolve("anthropic:claude-haiku-4-5-20251001")
      other_zone = %{F.target() | zone: "SYNTHETIC-OTHER-ZONE"}

      for target <- [nil, hosted, other_zone], {name, input} <- @tools do
        result = F.tool!(alice, name, input, target)
        assert %{"error" => "Refused: " <> _, "count" => 0} = result
        refute inspect(result) =~ "SYNTHETIC-ALICE"
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
      assert %{"count" => 1, "conversations" => [%{"subject" => "SYNTHETIC-ADMITTED"}]} = found

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
