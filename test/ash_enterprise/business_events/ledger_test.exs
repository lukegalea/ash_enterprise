defmodule AshEnterprise.BusinessEvents.LedgerTest do
  @moduledoc """
  The business-event ledger end to end (ADR 0051): canonical writes record
  their facts in the same transaction, as the row's owner and in its tenant;
  re-deriving records nothing new; a later-arriving earlier message corrects
  its conversation's start; `backfill/0` derives what was written before the
  ledger existed; only the owner reads their facts; a shred leaves every
  chain verifiable, nothing readable, and a tombstone; and the simulation
  twin stands on the same base as the ledger.
  """

  use AshEnterprise.DataCase, async: false

  require Ash.Query

  alias AshDiscreteBusinessEvents.Ledger.VerifyChains
  alias AshEnterprise.Accounts.User
  alias AshEnterprise.BusinessEvents
  alias AshEnterprise.BusinessEvents.Ledger
  alias AshEnterprise.BusinessEvents.Ledger.SimulationEvent
  alias AshEnterprise.BusinessEvents.Recorder
  alias AshEnterprise.Canonical.{CalendarEvent, Conversation, Message}
  alias AshEnterprise.Erasure
  alias AshEnterprise.Erasure.Shredded
  alias AshEnterprise.Integration.{Landing, LinkedAccount}
  alias AshEnterprise.Platform.Seeder
  alias AshEnterprise.Security
  alias AshEnterprise.Security.ActorContext

  @content ~w(SYNTHETIC-LEDGER-TITLE SYNTHETIC-LEDGER-LOCATION SYNTHETIC-LEDGER-BODY
              SYNTHETIC-LEDGER-SUBJECT)

  setup do
    previous = Application.get_env(:ash_enterprise, BusinessEvents)
    Application.put_env(:ash_enterprise, BusinessEvents, region: :test, residency_tag: "test")
    on_exit(fn -> Application.put_env(:ash_enterprise, BusinessEvents, previous) end)

    unique = System.unique_integer([:positive])

    seeded =
      Seeder.seed_tenant(
        name: "Ledger #{unique}",
        unique_name: "ledger-#{unique}",
        email: "alice-#{unique}@ledger.synthetic.test"
      )

    org = seeded.organization
    alice = seeded.user
    bob = administrator!(seeded, "bob-#{unique}@ledger.synthetic.test")

    account =
      LinkedAccount.link!(
        %{provider_config_key: "google-mail", connection_id: "conn-ledger-#{unique}"},
        actor: actor(alice, org.id),
        tenant: org.id
      )

    {:ok, scope} = Landing.open(account)

    %{
      org: org,
      alice: alice,
      bob: bob,
      seeded: seeded,
      scope: scope,
      unique: unique,
      owner: %{
        owner_id: alice.id,
        owner_type: :user,
        owning_user_id: alice.id,
        owning_business_unit_id: seeded.business_unit.id
      }
    }
  end

  describe "a calendar event's facts" do
    test "scheduled, unchanged, moved, cancelled — one fact per change, as the owner", ctx do
      upsert_event!(ctx, %{})
      upsert_event!(ctx, %{})
      upsert_event!(ctx, %{starts_at: ~U[2026-10-13 15:00:00.000000Z]})
      upsert_event!(ctx, %{starts_at: ~U[2026-10-13 15:00:00.000000Z], status: :cancelled})

      facts = facts(ctx)

      assert Enum.map(facts, & &1.action) == [
               :"calendar_event.scheduled",
               :"calendar_event.changed",
               :"calendar_event.cancelled"
             ]

      assert Enum.all?(facts, &(&1.owner_id == ctx.alice.id))
      assert Enum.all?(facts, &(&1.organization_id == ctx.org.id))
      assert Enum.all?(facts, &(&1.owning_business_unit_id == ctx.seeded.business_unit.id))
      assert Enum.all?(facts, &(&1.region == :test and &1.residency_tag == "test"))
      assert Enum.all?(facts, &(&1.subject_stream == :google_calendar))
      assert Enum.at(facts, 1).data["changed"] == ["starts_at"]

      [first | _] = facts
      assert first.context["owner"]["user_id"] == ctx.alice.id
      assert first.context["organization_id"] == ctx.org.id
      assert first.provenance["source_record_id"] == event_row(ctx).id

      assert_chain_clean()
    end

    test "a write that fails to record its facts writes nothing", ctx do
      Application.put_env(:ash_enterprise, BusinessEvents, region: :test, residency_tag: nil)

      assert {:error, _} =
               CalendarEvent
               |> Ash.Changeset.for_create(:upsert_from_source, event_attrs(ctx, %{}),
                 tenant: ctx.org.id,
                 authorize?: false
               )
               |> Ash.create()

      assert CalendarEvent.read!(tenant: ctx.org.id, authorize?: false) == []
    end
  end

  describe "a message's facts" do
    test "received once, and its conversation started once", ctx do
      conversation = upsert_conversation!(ctx)
      upsert_message!(ctx, conversation, "msg-1", ~U[2026-10-12 08:00:00.000000Z], :inbound)
      upsert_message!(ctx, conversation, "msg-1", ~U[2026-10-12 08:00:00.000000Z], :inbound)
      upsert_message!(ctx, conversation, "msg-2", ~U[2026-10-12 09:00:00.000000Z], :outbound)

      facts = facts(ctx)

      assert Enum.map(facts, & &1.action) == [
               :"message.received",
               :"conversation.started",
               :"message.sent"
             ]

      started = Enum.find(facts, &(&1.action == :"conversation.started"))
      assert started.occurred_at == ~U[2026-10-12 08:00:00.000000Z]
      assert started.data["conversation_id"] == conversation.id
      assert_chain_clean()
    end

    test "a later-arriving earlier message corrects the start; the first start stays", ctx do
      conversation = upsert_conversation!(ctx)
      upsert_message!(ctx, conversation, "msg-9", ~U[2026-10-12 09:00:00.000000Z], :inbound)
      [original] = starts(ctx)
      assert original.occurred_at == ~U[2026-10-12 09:00:00.000000Z]

      # Sent earlier, observed later: a correction superseding the first start.
      upsert_message!(ctx, conversation, "msg-7", ~U[2026-10-12 07:00:00.000000Z], :inbound)
      # Re-projected: nothing new. Sent between the two: not the start.
      upsert_message!(ctx, conversation, "msg-7", ~U[2026-10-12 07:00:00.000000Z], :inbound)
      upsert_message!(ctx, conversation, "msg-8", ~U[2026-10-12 08:00:00.000000Z], :inbound)

      assert [^original, correction] = starts(ctx)
      assert correction.supersedes_event_id == original.id
      assert correction.occurred_at == ~U[2026-10-12 07:00:00.000000Z]
      assert correction.data["first_message_id"] == message_row(ctx, "msg-7").id
      assert correction.owner_id == ctx.alice.id

      # An even earlier one supersedes the correction: each is the new present.
      upsert_message!(ctx, conversation, "msg-6", ~U[2026-10-12 06:00:00.000000Z], :outbound)
      assert [^original, ^correction, second] = starts(ctx)
      assert second.supersedes_event_id == correction.id

      assert Enum.count(facts(ctx), &(&1.subject_type == "message")) == 4
      assert_chain_clean()

      # Backfill re-derives every message in send order and records nothing.
      assert {:ok, %{recorded: 0}} = BusinessEvents.backfill()
    end
  end

  describe "backfill/0" do
    test "derives what was written before the ledger, and is a no-op the second time", ctx do
      Application.put_env(:ash_enterprise, BusinessEvents,
        region: :test,
        residency_tag: "test",
        emit?: false
      )

      upsert_event!(ctx, %{})
      conversation = upsert_conversation!(ctx)
      upsert_message!(ctx, conversation, "msg-late", ~U[2026-10-12 10:00:00.000000Z], :inbound)
      upsert_message!(ctx, conversation, "msg-early", ~U[2026-10-12 07:00:00.000000Z], :inbound)
      assert facts(ctx) == []

      Application.put_env(:ash_enterprise, BusinessEvents, region: :test, residency_tag: "test")

      assert {:ok, %{recorded: 4}} = BusinessEvents.backfill()
      assert {:ok, %{recorded: 0}} = BusinessEvents.backfill()

      started = Enum.find(facts(ctx), &(&1.action == :"conversation.started"))
      # Messages are backfilled in send order: the earliest starts it.
      assert started.occurred_at == ~U[2026-10-12 07:00:00.000000Z]
      assert_chain_clean()
    end
  end

  describe "owner-only" do
    test "the owner reads their facts; another Administrator of the tenant reads none", ctx do
      upsert_event!(ctx, %{})

      assert [_fact] =
               Ledger.by_region!(:test, actor: actor(ctx.alice, ctx.org.id), tenant: ctx.org.id)

      assert Ledger.by_region!(:test, actor: actor(ctx.bob, ctx.org.id), tenant: ctx.org.id) == []
    end

    test "a user cannot record a fact directly; recording is the projection's", ctx do
      fact = %{
        event_kind: :"calendar_event.scheduled",
        region: :test,
        residency_tag: "test",
        subject_type: "calendar_event",
        subject_external_id: "forged-#{ctx.unique}",
        occurred_at: DateTime.utc_now(),
        provenance: %{"mapping_name" => "forged"},
        context: %{
          "owner" => %{"user_id" => ctx.alice.id},
          "organization_id" => ctx.org.id
        }
      }

      # Forbidden: a generic action has no row for a depth to reach, so only a
      # :global grant authorizes one, and :basic is the only depth the ledger
      # can be granted at (ADR 0051, "Does it consume ActorContext?").
      assert {:error, %Ash.Error.Forbidden{}} =
               Ledger.record(fact, actor: actor(ctx.alice, ctx.org.id), tenant: ctx.org.id)

      assert facts(ctx) == []
    end

    test "no role can be granted wider than :basic on the ledger or its twin" do
      names = [inspect(Ledger), inspect(SimulationEvent)]

      privileges =
        Security.Privilege
        |> Ash.Query.filter(resource_name in ^names)
        |> Ash.read!(authorize?: false)

      assert privileges |> Enum.map(& &1.resource_name) |> Enum.uniq() |> Enum.sort() == names

      for privilege <- privileges do
        assert privilege.can_be_basic
        refute privilege.can_be_global or privilege.can_be_deep or privilege.can_be_local
      end
    end
  end

  # `cross_region_read` stays closed until its owner rule is designed (ADR 0051,
  # Known gaps). These pin both halves of "closed", so the door cannot start
  # working, or start writing ownerless disclosure rows, by accident.
  describe "cross_region_read is closed" do
    test "no user can run it, not even an Administrator", ctx do
      input =
        Ash.ActionInput.for_action(
          Ledger,
          :cross_region_read,
          %{regions: [:test, :other], purpose: "pinned by test"},
          actor: actor(ctx.bob, ctx.org.id),
          tenant: ctx.org.id
        )

      # A generic action needs a :global grant, and the ledger cannot be granted
      # wider than :basic (the test above), so no role can ever reach it.
      assert {:error, %Ash.Error.Forbidden{}} = Ash.run_action(input)
      assert disclosures(ctx) == []
    end

    test "machinery that reaches it writes no disclosure row", ctx do
      input =
        Ash.ActionInput.for_action(
          Ledger,
          :cross_region_read,
          %{regions: [:test, :other], purpose: "pinned by test"},
          actor: AshEnterprise.Platform.SystemActor.system(),
          tenant: ctx.org.id
        )

      # The system actor bypasses the grants, so the action runs, and its
      # ownerless disclosure rows are refused by StampOwner. The transaction
      # rolls back: nothing lands.
      result =
        try do
          Ash.run_action(input)
        rescue
          error -> {:raised, error}
        end

      refute match?({:ok, _}, result)
      assert disclosures(ctx) == []
    end
  end

  defp disclosures(ctx) do
    for region <- [:test, :other],
        event <- Ledger.by_region!(region, tenant: ctx.org.id, authorize?: false),
        event.event_kind == :"region.disclosure",
        do: event
  end

  describe "a shred" do
    test "leaves the chain verifiable, the facts in place, and nothing readable", ctx do
      upsert_event!(ctx, %{})
      upsert_event!(ctx, %{ends_at: ~U[2026-10-13 15:00:00.000000Z]})
      conversation = upsert_conversation!(ctx)
      upsert_message!(ctx, conversation, "msg-1", ~U[2026-10-12 08:00:00.000000Z], :inbound)

      before = facts(ctx)
      assert length(before) == 4
      assert Enum.all?(before, &(&1.data["erasure_scope_id"] == ctx.scope.id))
      refute_ledger_spells(@content)

      Seeder.grant_platform_operator(ctx.alice)
      operator = actor(ctx.alice, ctx.org.id)
      shredded = Erasure.shred_scope!(ctx.scope, ctx.scope.ref, "ledger test", actor: operator)

      assert %Shredded{} = event_row(ctx).title

      # The facts stay as they were, and one tombstone follows them, in the
      # owner's stream, naming the scope and counting the facts it covers.
      assert [_ | _] = after_shred = facts(ctx)
      {kept, [tombstone]} = Enum.split(after_shred, length(before))
      assert kept == before

      assert tombstone.action == :"retention.subject_erased"
      assert tombstone.subject_type == "retention"
      assert tombstone.subject_external_id == ctx.scope.id
      assert tombstone.occurred_at == shredded.shredded_at
      assert tombstone.owner_id == ctx.alice.id
      assert tombstone.organization_id == ctx.org.id

      assert tombstone.data == %{
               "subject" => ctx.scope.id,
               "region" => "test",
               "erasure_scope_id" => ctx.scope.id,
               "scope_kind" => "connection",
               "facts" => 4
             }

      refute_ledger_spells([ctx.scope.ref | @content])
      assert_chain_clean()

      # Recording the shred again collapses onto the tombstone, and
      # re-projecting the shredded row's structure records nothing new.
      assert {:ok, [^tombstone]} = Recorder.shredded(shredded)
      assert {:ok, %{recorded: 0}} = BusinessEvents.backfill()
      assert facts(ctx) == after_shred
    end

    test "a scope nothing was derived from leaves no tombstone", ctx do
      Seeder.grant_platform_operator(ctx.alice)
      operator = actor(ctx.alice, ctx.org.id)
      Erasure.shred_scope!(ctx.scope, ctx.scope.ref, "ledger test", actor: operator)

      assert facts(ctx) == []
    end
  end

  describe "the simulation twin" do
    test "stands on the platform base: tenant-scoped, owner-stamped, owner-only", ctx do
      run = "ledger-sim-#{ctx.unique}"

      simulated =
        SimulationEvent.record!(sim_fact(ctx, run, %{"user_id" => ctx.alice.id}),
          tenant: ctx.org.id,
          authorize?: false
        )

      assert simulated.simulated
      assert simulated.simulation_run == run
      assert simulated.organization_id == ctx.org.id
      assert simulated.owner_id == ctx.alice.id
      assert simulated.owning_business_unit_id == ctx.seeded.business_unit.id

      # An unowned simulated event is refused, as an unowned real one is.
      assert {:error, _} =
               SimulationEvent.record(sim_fact(ctx, run, nil),
                 tenant: ctx.org.id,
                 authorize?: false
               )

      # Owner-only: the owner reads it; another Administrator reads nothing.
      assert [%{id: id}] =
               SimulationEvent.by_region!(:test,
                 actor: actor(ctx.alice, ctx.org.id),
                 tenant: ctx.org.id
               )

      assert id == simulated.id

      assert SimulationEvent.by_region!(:test,
               actor: actor(ctx.bob, ctx.org.id),
               tenant: ctx.org.id
             ) == []

      # A user cannot record a simulated event directly.
      assert {:error, %Ash.Error.Forbidden{}} =
               SimulationEvent.record(sim_fact(ctx, run, %{"user_id" => ctx.alice.id}),
                 actor: actor(ctx.alice, ctx.org.id),
                 tenant: ctx.org.id
               )

      # The labeling read, per tenant; and nothing reached the real ledger.
      assert [%{simulation_run: ^run, events: 1}] =
               AshDiscreteBusinessEvents.simulation_runs(Ledger, tenant: ctx.org.id)

      assert facts(ctx) == []

      result = VerifyChains.verify(SimulationEvent, :test)
      assert result.findings == []
    end
  end

  # --- helpers ---------------------------------------------------------------------

  defp event_attrs(ctx, overrides) do
    Map.merge(
      Map.merge(ctx.owner, %{
        external_system: "google_calendar",
        external_id: "gcal:ledger-#{ctx.unique}/evt-1",
        title: "SYNTHETIC-LEDGER-TITLE",
        location: "SYNTHETIC-LEDGER-LOCATION",
        starts_at: ~U[2026-10-13 14:00:00.000000Z],
        ends_at: ~U[2026-10-13 14:30:00.000000Z],
        status: :confirmed,
        erasure_scope_id: ctx.scope.id
      }),
      overrides
    )
  end

  defp upsert_event!(ctx, overrides) do
    CalendarEvent.upsert_from_source!(event_attrs(ctx, overrides),
      tenant: ctx.org.id,
      authorize?: false
    )
  end

  defp event_row(ctx) do
    [row] = CalendarEvent.read!(tenant: ctx.org.id, authorize?: false)
    row
  end

  defp upsert_conversation!(ctx) do
    Conversation.upsert_from_source!(
      Map.merge(ctx.owner, %{
        external_system: "gmail",
        external_id: "ledger-thread-#{ctx.unique}",
        subject: "SYNTHETIC-LEDGER-SUBJECT",
        participants: %{"person_ids" => []},
        erasure_scope_id: ctx.scope.id
      }),
      tenant: ctx.org.id,
      authorize?: false
    )
  end

  defp upsert_message!(ctx, conversation, id, sent_at, direction) do
    Message.upsert_from_source!(
      Map.merge(ctx.owner, %{
        external_system: "gmail",
        external_id: "ledger-#{id}-#{ctx.unique}",
        body: "SYNTHETIC-LEDGER-BODY",
        sent_at: sent_at,
        direction: direction,
        conversation_id: conversation.id,
        erasure_scope_id: ctx.scope.id
      }),
      tenant: ctx.org.id,
      authorize?: false
    )
  end

  defp sim_fact(ctx, run, owner) do
    %{
      event_kind: :"calendar_event.scheduled",
      region: :test,
      residency_tag: "test",
      subject_type: "calendar_event",
      subject_external_id: "sim-#{ctx.unique}",
      occurred_at: ~U[2026-10-13 14:00:00.000000Z],
      provenance: %{"mapping_name" => "simulation"},
      simulation_run: run,
      context:
        Map.merge(
          %{"organization_id" => ctx.org.id},
          if(owner,
            do: %{"owner" => Map.put(owner, "business_unit_id", ctx.seeded.business_unit.id)},
            else: %{}
          )
        )
    }
  end

  defp starts(ctx), do: Enum.filter(facts(ctx), &(&1.action == :"conversation.started"))

  defp message_row(ctx, id) do
    external_id = "ledger-#{id}-#{ctx.unique}"

    Message
    |> Ash.Query.filter(external_id == ^external_id)
    |> Ash.read_one!(tenant: ctx.org.id, authorize?: false)
  end

  defp facts(ctx) do
    :test
    |> Ledger.by_region!(tenant: ctx.org.id, authorize?: false)
    |> Enum.sort_by(& &1.sequence)
  end

  defp assert_chain_clean do
    result = VerifyChains.verify(Ledger, :test)
    assert result.findings == []
    assert result.checked > 0
  end

  # Every column of every ledger row, as stored.
  defp refute_ledger_spells(strings) do
    %{rows: rows} = Repo.query!("SELECT row_to_json(e)::text FROM business_events e")
    text = rows |> List.flatten() |> Enum.join("\n")

    for string <- strings do
      refute String.contains?(text, string), "business_events spells #{inspect(string)}"
    end
  end

  defp actor(user, org_id),
    do: ActorContext.attach(user, ActorContext.build(user, tenant: org_id))

  defp administrator!(seeded, email) do
    user =
      User
      |> Ash.Changeset.for_create(
        :register_with_password,
        %{email: email, password: "password1234", password_confirmation: "password1234"},
        authorize?: false
      )
      |> Ash.create!()
      |> Ash.Changeset.for_update(
        :assign_to_business_unit,
        %{owning_business_unit_id: seeded.business_unit.id},
        authorize?: false
      )
      |> Ash.update!()

    Security.UserRole
    |> Ash.Changeset.for_create(
      :assign,
      %{
        user_id: user.id,
        role_id: seeded.role.id,
        scoping_business_unit_id: seeded.business_unit.id
      },
      tenant: seeded.organization.id,
      authorize?: false
    )
    |> Ash.create!()

    user
  end
end
