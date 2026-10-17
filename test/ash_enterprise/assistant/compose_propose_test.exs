defmodule AshEnterprise.Assistant.ComposeProposeTest do
  @moduledoc """
  The assistant's composer and proposal tools (E10.3, E10.4) on synthetic
  data: what a composed spec may name, that its rows are read as the person,
  that a proposal resolves names as the person and changes nothing until it
  is executed with them as the actor, and that pinned apps and drafts are
  their owner's alone.
  """

  use AshEnterprise.DataCase, async: false

  alias AshEnterprise.AI.Proposal
  alias AshEnterprise.Assistant.{Composer, PinnedApp, ReplyDraft}
  alias AshEnterprise.Canonical.Task
  alias AshEnterprise.Test.AssistantFixtures, as: F
  alias AshEnterprise.Test.DailyFixtures, as: D

  setup do
    F.in_zone!()
    F.tenant!()
  end

  defp tool!(ctx, resource, name, input) do
    resource
    |> Ash.ActionInput.for_action(name, input,
      actor: ctx.actor,
      tenant: ctx.tenant,
      context: %{AshEnterprise.Assistant.ZoneGate.key() => F.target()},
      authorize?: true
    )
    |> Ash.run_action!()
  end

  defp encoded(surface, ctx),
    do:
      surface
      |> AshA2ui.Dynamic.build_surface(actor: ctx.actor, tenant: ctx.tenant)
      |> Jason.encode!()

  describe "the composer" do
    test "writes a verified table, calendar and board for every source it offers", ctx do
      for show <- Composer.sources(), display <- ~w(table calendar board) do
        case {show, display, Composer.compose(%{show: show, display: display})} do
          {_, _, {:ok, composed}} ->
            assert %AshA2ui.Dynamic.Surface{} = composed.surface
            assert composed.spec["resource"] == show
            refute Enum.any?(composed.spec["components"], &Map.has_key?(&1, "row_actions"))
            # ...and it builds, as the person, without a row action anywhere.
            assert [_ | _] =
                     AshA2ui.Dynamic.build_surface(composed.surface,
                       actor: ctx.actor,
                       tenant: ctx.tenant
                     )

          {show, display, {:error, [reason | _]}} ->
            # Only the combinations the catalogue cannot place are refused,
            # with a reason the model can act on.
            assert display in ~w(calendar board), "#{show} #{display}: #{reason}"
            assert reason =~ "use a table"
        end
      end
    end

    test "refuses what it cannot show with short reasons, and notes what it ignored" do
      assert {:error, [reason]} = Composer.compose(%{show: "secrets"})
      assert reason =~ "show must be one of"

      assert {:error, [reason]} =
               Composer.compose(%{show: "tasks", display: "board", group_by: "title"})

      assert reason =~ "splits by status"

      assert {:ok, composed} =
               Composer.compose(%{
                 show: "tasks",
                 columns: ["title", "SYNTHETIC-nope"],
                 status: :open
               })

      assert [note] = composed.notes
      assert note =~ "SYNTHETIC-nope"
      assert composed.spec["components"] |> hd() |> Map.fetch!("fields") == ["title"]
    end

    test "builds as the person: their rows, and nobody else's", ctx do
      bob = F.colleague!(ctx, admin?: true)
      D.conversation!(ctx, "gmail", "SYNTHETIC alice standup", "hi")

      D.conversation!(
        %{user: bob.user, tenant: ctx.tenant},
        "gmail",
        "SYNTHETIC bob private",
        "hi"
      )

      # Conversations are owner-only: even the tenant's Administrator (alice)
      # reads only her own.
      {:ok, composed} = Composer.compose(%{show: "conversations", channel: "gmail"})
      json = encoded(composed.surface, ctx)

      assert json =~ "SYNTHETIC alice standup"
      refute json =~ "SYNTHETIC bob private"
    end

    test "the compose tool answers the model without rows, and is zone-gated", ctx do
      D.event!(ctx, "SYNTHETIC tool row", 60, 30)

      result =
        tool!(ctx, AshEnterprise.Assistant.Compose, :compose_surface, %{
          show: :events,
          display: :calendar
        })

      assert result["surface"]["show"] == "events"
      assert result["shown"] =~ "Calendar events"
      refute Jason.encode!(result) =~ "SYNTHETIC tool row"

      refused =
        AshEnterprise.Assistant.Compose
        |> Ash.ActionInput.for_action(:compose_surface, %{show: :events},
          actor: ctx.actor,
          tenant: ctx.tenant,
          authorize?: true
        )
        |> Ash.run_action!()

      assert refused["error"] =~ "ADR 0042"
    end
  end

  describe "proposals" do
    test "add and finish an action item: nothing until executed, then as the person", ctx do
      result =
        tool!(ctx, AshEnterprise.Assistant.Propose, :propose_task, %{
          change: :add,
          title: "SYNTHETIC send the deck",
          due: "tomorrow"
        })

      assert result["proposed"] =~ "SYNTHETIC send the deck"
      assert result["proposal"]["kind"] == "create_task"
      assert Task.mine!(actor: ctx.actor, tenant: ctx.tenant) == []

      {:ok, proposal} = Proposal.from_wire(result["proposal"], ctx.actor, ctx.tenant)
      assert {:ok, %Task{} = task} = Proposal.execute(proposal, ctx.actor, ctx.tenant)
      assert task.owner_id == ctx.user.id
      assert task.source == "assistant"
      assert task.status == :open
      assert task.due_at

      done =
        tool!(ctx, AshEnterprise.Assistant.Propose, :propose_task, %{
          change: :done,
          title: "send the DECK"
        })

      assert done["proposal"] == %{"kind" => "complete_task", "task_id" => task.id}

      {:ok, proposal} = Proposal.from_wire(done["proposal"], ctx.actor, ctx.tenant)
      assert {:ok, %Task{status: :done}} = Proposal.execute(proposal, ctx.actor, ctx.tenant)

      # Done once: rebuilding the same proposal now refuses, rather than re-running.
      assert {:error, message} = Proposal.from_wire(done["proposal"], ctx.actor, ctx.tenant)
      assert message =~ "already done"
    end

    test "another person's task or conversation does not resolve", ctx do
      bob = F.colleague!(ctx, admin?: true)

      {:ok, bobs} =
        Task.capture("SYNTHETIC bob's item", %{}, actor: bob.actor, tenant: ctx.tenant)

      refused =
        tool!(ctx, AshEnterprise.Assistant.Propose, :propose_task, %{
          change: :done,
          title: bobs.id
        })

      assert refused["error"] =~ "No open action item of yours"

      # The self-service completion itself does not reach it either.
      assert {:error, _} = Task.complete_mine(bobs.id, actor: ctx.actor, tenant: ctx.tenant)

      conversation =
        D.conversation!(
          %{user: bob.user, tenant: ctx.tenant},
          "gmail",
          "SYNTHETIC bob mail",
          "hi"
        )

      refused =
        tool!(ctx, AshEnterprise.Assistant.Propose, :propose_reply, %{
          conversation: "inbox:#{conversation.id}",
          text: "SYNTHETIC reply"
        })

      assert refused["error"] =~ "No conversation of yours"
    end

    test "a reply draft is stored, sealed and owner-only, never sent", ctx do
      conversation = D.conversation!(ctx, "gmail", "SYNTHETIC launch", "Can you confirm?")

      result =
        tool!(ctx, AshEnterprise.Assistant.Propose, :propose_reply, %{
          conversation: "inbox:#{conversation.id}",
          text: "SYNTHETIC: confirmed for Friday."
        })

      assert result["proposed"] =~ "SYNTHETIC launch"
      assert ReplyDraft.mine!(actor: ctx.actor, tenant: ctx.tenant) == []

      {:ok, proposal} = Proposal.from_wire(result["proposal"], ctx.actor, ctx.tenant)
      assert proposal.details[:sent] =~ "never"
      assert {:ok, draft} = Proposal.execute(proposal, ctx.actor, ctx.tenant)
      assert draft.erasure_scope_id == conversation.erasure_scope_id

      [mine] = ReplyDraft.mine!(actor: ctx.actor, tenant: ctx.tenant)
      assert mine.body == "SYNTHETIC: confirmed for Friday."

      # Ciphertext at rest, and nobody else's to read.
      [%{encrypted_body: ciphertext}] =
        Ash.read!(ReplyDraft, authorize?: false, tenant: ctx.tenant)

      refute ciphertext =~ "confirmed for Friday"

      bob = F.colleague!(ctx, admin?: true)
      assert ReplyDraft.mine!(actor: bob.actor, tenant: ctx.tenant) == []
      assert Ash.read!(ReplyDraft, actor: bob.actor, tenant: ctx.tenant) == []
    end

    test "sync needs a linked account, and decisions are refused at their seam", ctx do
      refused = tool!(ctx, AshEnterprise.Assistant.Propose, :propose_sync, %{})
      assert refused["error"] =~ "no active linked accounts"

      for kind <- Proposal.decision_kinds() do
        assert {:error, message} = Proposal.decision(kind, ctx.actor, ctx.tenant, nil)
        assert message =~ "not proposed from the chat"
      end
    end
  end

  describe "pinned apps" do
    test "pin, re-verify on load, owner-only, unpin", ctx do
      {:ok, composed} = Composer.compose(%{show: "tasks", display: "board"})
      spec = AshA2ui.Dynamic.serialize(composed.surface)

      {:ok, app} =
        PinnedApp.pin(
          %{
            title: Composer.structural_title(composed.request),
            display: :board,
            source: "tasks",
            spec: spec
          },
          actor: ctx.actor,
          tenant: ctx.tenant
        )

      assert app.title == "Tasks · board"
      assert {:ok, %AshA2ui.Dynamic.Surface{}} = Composer.reload(app.spec)
      assert {:error, [_ | _]} = Composer.reload(String.replace(spec, "\"tasks\"", "\"secrets\""))

      bob = F.colleague!(ctx, admin?: true)
      assert PinnedApp.mine!(actor: bob.actor, tenant: ctx.tenant) == []
      assert {:error, _} = PinnedApp.get(app.id, actor: bob.actor, tenant: ctx.tenant)
      assert {:error, _} = PinnedApp.unpin(app.id, actor: bob.actor, tenant: ctx.tenant)

      assert :ok = PinnedApp.unpin(app.id, actor: ctx.actor, tenant: ctx.tenant)
      assert PinnedApp.mine!(actor: ctx.actor, tenant: ctx.tenant) == []
    end
  end
end
