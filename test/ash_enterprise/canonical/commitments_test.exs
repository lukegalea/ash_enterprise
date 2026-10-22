defmodule AshEnterprise.Canonical.CommitmentsTest do
  @moduledoc """
  Commitments proposed from what the person sent and the meetings they had
  (PROD-18, ADR 0047): the in-zone model reads a sent message and its
  promise becomes a *proposal* on the person's board — sealed under the
  message's erasure scope, read once, never accepted by the proposer.
  Accept puts it on their list; Dismiss ends it. With no in-zone model,
  nothing is sent and nothing is read. A shred of the source leaves
  `[shredded]` where the words were, in the row and in the audit log alike.
  """

  use AshEnterprise.DataCase, async: false

  import AshEnterprise.Test.DailyFixtures, only: [tenant!: 1]
  import AshEnterprise.Test.CommitmentFixtures

  require Ash.Query

  alias AshEnterprise.Audit.EventLog
  alias AshEnterprise.Canonical.{Commitments, CommitmentScan, Task}
  alias AshEnterprise.Erasure
  alias AshEnterprise.Erasure.Shredded
  alias AshEnterprise.Platform.{LocalTime, SystemActor}
  alias AshEnterprise.Test.AssistantFixtures

  @promise "Thanks Dana — I'll send you the Q3 deck by Friday.\n\nOn Mon, Dana wrote:\n> can you share it?"

  setup do
    ctx = tenant!(operator?: true)
    %{ctx: ctx, opts: [actor: ctx.actor, tenant: ctx.tenant, authorize?: true]}
  end

  defp proposals(ctx) do
    Task.mine!(
      actor: ctx.actor,
      tenant: ctx.tenant,
      query: [filter: [status: :proposed]],
      load: [:label, :lane, :origin_ref]
    )
  end

  defp scans(source_id, tenant) do
    CommitmentScan
    |> Ash.Query.filter(source_id == ^source_id)
    |> Ash.read!(tenant: tenant, authorize?: false)
  end

  describe "with the in-zone model" do
    setup do
      AssistantFixtures.in_zone!()
      scripted_model!()
    end

    test "a sent promise is proposed on the person's board, sealed, and read once", %{ctx: ctx} do
      %{message: message, conversation: conversation} = sent!(ctx, "gmail", @promise)

      result = Commitments.sweep()
      assert result.messages == 1
      assert result.proposed == 1

      # The model read only what the person wrote, not what they replied to.
      assert_received {:extractor_prompt, prompt, _opts}
      assert prompt =~ "I'll send you the Q3 deck by Friday"
      refute prompt =~ "can you share it?"

      assert [proposal] = proposals(ctx)
      assert proposal.lane == :proposed
      assert proposal.label == "Send Dana the Q3 deck"
      assert proposal.evidence == "I'll send you the Q3 deck by Friday"
      assert proposal.source == "gmail"
      assert proposal.origin_ref == "inbox:#{conversation.id}"
      assert proposal.erasure_scope_id == message.erasure_scope_id
      assert proposal.instrument =~ AssistantFixtures.zone()
      assert LocalTime.to_local(proposal.due_at).hour == 17
      assert DateTime.to_date(LocalTime.to_local(proposal.due_at)) == ~D[2026-10-23]
      # The plain title is structural; the words are sealed.
      refute proposal.title =~ "Q3"

      # Not on any list until accepted.
      assert {:ok, []} = Task.due_today(actor: ctx.actor, tenant: ctx.tenant)

      assert [%CommitmentScan{found: 1, proposer: "message_commitments/1"}] =
               scans(message.id, ctx.tenant)

      # Read once: the next sweep sends nothing and proposes nothing more.
      assert %{messages: 0, proposed: 0} = Commitments.sweep()
      refute_received {:extractor_prompt, _, _}
      assert [_one] = proposals(ctx)
    end

    test "a message with no promise is scanned with nothing found; received mail is not read",
         %{ctx: ctx} do
      %{message: plain} = sent!(ctx, "slack", "Sounds good, see you there")
      %{message: inbound} = sent!(ctx, "gmail", @promise, direction: :inbound)

      assert %{messages: 1, proposed: 0} = Commitments.sweep()
      assert [%CommitmentScan{found: 0}] = scans(plain.id, ctx.tenant)
      assert scans(inbound.id, ctx.tenant) == []
      assert proposals(ctx) == []
    end

    test "Accept puts a proposal in the Inbox; Dismiss ends one; the proposer decides nothing",
         %{ctx: ctx, opts: opts} do
      sent!(ctx, "gmail", @promise)
      meeting!(ctx, "Synthetic vendor review")
      Commitments.sweep()

      assert [_, _] = found = proposals(ctx)
      promise = Enum.find(found, &(&1.source == "gmail"))
      follow_up = Enum.find(found, &(&1.source == "calendar"))
      assert follow_up.label == "Follow up on Synthetic vendor review"
      assert follow_up.origin_ref == "calendar:#{follow_up.origin_id}"

      # The proposer cannot accept what it proposed.
      assert {:error, _} =
               promise
               |> Ash.Changeset.for_update(:accept, %{},
                 actor: SystemActor.proposer(),
                 tenant: ctx.tenant
               )
               |> Ash.update(authorize?: false)

      assert {:ok, %Task{status: :open, plan: :inbox}} = Task.accept_mine(promise.id, opts)
      assert {:ok, [accepted]} = Task.mine(Keyword.put(opts, :query, filter: [id: promise.id]))
      assert Ash.load!(accepted, :lane, opts).lane == :inbox

      assert {:ok, %Task{status: :cancelled}} = Task.dismiss_mine(follow_up.id, opts)
      assert proposals(ctx) == []

      # Accepting twice, or accepting a dismissed one, is refused.
      assert {:error, %Ash.Error.Invalid{}} = Task.accept_mine(promise.id, opts)
      assert {:error, %Ash.Error.Invalid{}} = Task.accept_mine(follow_up.id, opts)
    end

    test "a shred of the source leaves [shredded] in the row and nothing in the audit log",
         %{ctx: ctx} do
      %{scope: scope} = sent!(ctx, "gmail", @promise)
      Commitments.sweep()
      assert [proposal] = proposals(ctx)

      Erasure.shred_scope!(scope, scope.ref, "test shred", actor: ctx.actor)

      [after_shred] =
        Task
        |> Ash.Query.filter(id == ^proposal.id)
        |> Ash.Query.load([:label])
        |> Ash.read!(tenant: ctx.tenant, authorize?: false)

      assert %Shredded{} = after_shred.commitment
      assert %Shredded{} = after_shred.evidence
      assert after_shred.label == Shredded.rendered()

      for event <- Ash.read!(EventLog, authorize?: false) do
        text = Jason.encode!(%{d: event.data, c: event.changed_attributes, m: event.metadata})

        refute text =~ "Q3 deck",
               "audit event #{event.id} (#{event.resource}) spells the commitment"
      end
    end
  end

  test "with no in-zone model nothing is sent and no message is read; meetings still are",
       %{ctx: ctx} do
    scripted_model!()
    %{message: message} = sent!(ctx, "gmail", @promise)
    meeting!(ctx, "Synthetic planning")

    result = Commitments.sweep()
    assert result.skipped in [:outside_zone, :no_model_target, :zone_mismatch]
    assert result.messages == 0
    assert result.meetings == 1
    refute_received {:extractor_prompt, _, _}
    assert scans(message.id, ctx.tenant) == []
    assert [%Task{source: "calendar"}] = proposals(ctx)
  end
end
