defmodule AshEnterprise.Quality.AgentReplyTest do
  @moduledoc """
  S1-91: an assistant answer read as a reply subject. The text is decrypted
  from the turn as the actor, and only for an actor the turn's policies let
  read it; the subject term and the state digest are the same every time
  the same turn is read. Synthetic threads and text only; no model is
  called.
  """

  use AshEnterprise.DataCase, async: false

  alias AshEnterprise.Assistant.{Thread, Turn}
  alias AshEnterprise.Erasure
  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.Quality
  alias AshEnterprise.Quality.{AgentReply, Questions}
  alias AshEnterprise.Test.AssistantFixtures, as: F

  @answer "The SYNTHETIC launch checklist is due on Friday.\r\nQuinn asked for it. "

  setup do
    ctx = F.tenant!()
    {:ok, thread} = Thread.start("SYNTHETIC thread", actor: ctx.actor, tenant: ctx.tenant)

    question = append!(ctx, thread, %{role: :user, content: "SYNTHETIC: what is due?"})
    answer = append!(ctx, thread, %{role: :assistant, content: @answer})

    Map.merge(ctx, %{thread: thread, question: question, answer: answer})
  end

  defp append!(ctx, thread, attrs) do
    attrs |> Map.put(:thread_id, thread.id) |> Turn.append!(actor: ctx.actor, tenant: ctx.tenant)
  end

  defp read(ctx, turn_id, actor, extra \\ %{}) do
    Quality.reply_from_turn(turn_id, extra, actor: actor, tenant: ctx.tenant)
  end

  describe "a reply drawn from an assistant turn" do
    test "decrypts as the person whose thread it is", ctx do
      assert {:ok, %AgentReply{} = reply} = read(ctx, ctx.answer.id, ctx.actor)

      assert reply.id == "assistant_turn:#{ctx.answer.id}"
      assert reply.text == "The SYNTHETIC launch checklist is due on Friday.\nQuinn asked for it."
      assert reply.turn_id == ctx.answer.id
      assert reply.thread_id == ctx.thread.id
      assert reply.erasure_scope_id == ctx.answer.erasure_scope_id
      assert reply.status == :complete
      refute reply.used_tools
    end

    test "is not decrypted for anyone else in the tenant, even an administrator", ctx do
      for colleague <- [F.colleague!(ctx), F.colleague!(ctx, admin?: true)] do
        assert {:error, %Ash.Error.Invalid{} = error} = read(ctx, ctx.answer.id, colleague.actor)
        assert Exception.message(error) =~ "not found"
        refute Exception.message(error) =~ "SYNTHETIC launch checklist"
      end
    end

    test "the administrator is refused by the turn, not by the reply's own policies", ctx do
      admin = F.colleague!(ctx, admin?: true)
      {:ok, thread} = Thread.start("SYNTHETIC own thread", actor: admin.actor, tenant: ctx.tenant)
      own = append!(admin, thread, %{role: :assistant, content: "SYNTHETIC own answer."})

      assert {:ok, %AgentReply{text: "SYNTHETIC own answer."}} = read(ctx, own.id, admin.actor)
      assert {:error, %Ash.Error.Invalid{}} = read(ctx, ctx.answer.id, admin.actor)
    end

    test "is not read without an actor, nor from another tenant", ctx do
      assert {:error, _} = read(ctx, ctx.answer.id, nil)

      other = F.tenant!()

      assert {:error, _} =
               Quality.reply_from_turn(ctx.answer.id, actor: other.actor, tenant: other.tenant)
    end

    test "a system actor reads it as itself", ctx do
      assert {:ok, reply} = read(ctx, ctx.answer.id, SystemActor.oban())
      assert reply.text =~ "SYNTHETIC launch checklist"
    end

    test "a question turn is not a reply", ctx do
      assert {:error, %Ash.Error.Invalid{}} = read(ctx, ctx.question.id, ctx.actor)
    end

    test "a turn whose scope is shredded has no text left, so it is no reply", ctx do
      scope = Erasure.get_scope!(ctx.answer.erasure_scope_id, authorize?: false)
      Erasure.shred_scope!(scope, scope.ref, "SYNTHETIC test shred", authorize?: false)

      assert {:error, %Ash.Error.Invalid{}} = read(ctx, ctx.answer.id, ctx.actor)
    end
  end

  describe "the subject term and the state digest" do
    test "are the same across reads of the same turn", ctx do
      {:ok, first} = read(ctx, ctx.answer.id, ctx.actor)
      {:ok, second} = read(ctx, ctx.answer.id, SystemActor.oban())

      assert Quality.subject_term(first) == %{
               "type" => "AshEnterprise.Quality.AgentReply",
               "id" => "assistant_turn:#{ctx.answer.id}"
             }

      assert Quality.subject_term(second) == Quality.subject_term(first)
      assert Quality.digest(second) == Quality.digest(first)

      assert Quality.current_digests([first]) == %{
               Quality.subject_term(first) => Quality.digest(first)
             }
    end

    test "the digest is the text's, after normalisation, and nothing else", ctx do
      {:ok, reply} = read(ctx, ctx.answer.id, ctx.actor)

      same = %AgentReply{
        id: "assistant_turn:#{Ash.UUID.generate()}",
        text: "The SYNTHETIC launch checklist is due on Friday.\nQuinn asked for it.",
        used_tools: true
      }

      different = %{same | text: "The SYNTHETIC launch checklist is due on Monday."}

      assert Quality.digest(same) == Quality.digest(reply)
      refute Quality.digest(different) == Quality.digest(reply)

      # The judge records this same digest as the judgment's state_digest.
      for name <- Questions.names() do
        assert AshEnterprise.SystemOne.JudgedState.digest(Questions.judged_state(name, reply)) ==
                 Quality.digest(reply)
      end
    end

    test "an evaluation case names its subject by run, case and epoch", ctx do
      named = %{run_id: "SYNTHETIC-run", case_id: "due_today"}

      {:ok, first} = read(ctx, ctx.answer.id, ctx.actor, Map.put(named, :epoch, 1))
      {:ok, again} = read(ctx, ctx.answer.id, ctx.actor, Map.put(named, :epoch, 1))
      {:ok, rerun} = read(ctx, ctx.answer.id, ctx.actor, Map.put(named, :epoch, 2))

      assert first.id == "agent_reply:SYNTHETIC-run/due_today/1"
      assert Quality.subject_term(again) == Quality.subject_term(first)
      assert rerun.id == "agent_reply:SYNTHETIC-run/due_today/2"
      refute Quality.subject_term(rerun) == Quality.subject_term(first)
      assert Quality.digest(rerun) == Quality.digest(first)
    end

    test "run, case and epoch are given together or not at all", ctx do
      assert {:error, %Ash.Error.Invalid{} = error} =
               read(ctx, ctx.answer.id, ctx.actor, %{run_id: "SYNTHETIC-run"})

      assert Exception.message(error) =~ "give all three or none"
    end
  end

  describe "a reply that used tools" do
    test "cited records: hs4 and hs7 are not asked of it", ctx do
      turn =
        append!(ctx, ctx.thread, %{
          role: :assistant,
          content: "Rory asked about it [[conversation:SYNTHETIC]].",
          refs: ["conversation:SYNTHETIC"]
        })

      {:ok, reply} = read(ctx, turn.id, ctx.actor)

      assert reply.used_tools

      refute :hs4_claim_only_built_and_proven in Questions.for_reply(reply)
      refute :hs7_never_invent_name_feature_or_date in Questions.for_reply(reply)
      assert length(Questions.for_reply(reply)) == 6
    end

    test "tool calls with no citation: still a reply that used tools", ctx do
      turn =
        append!(ctx, ctx.thread, %{
          role: :assistant,
          content: "Nothing is due today.",
          tool_calls: %{"calls" => [%{"name" => "my_tasks", "ok" => true, "count" => 0}]}
        })

      {:ok, reply} = read(ctx, turn.id, ctx.actor)

      assert reply.used_tools
      assert length(Questions.for_reply(reply)) == 6
    end

    test "a reply with no tools is asked all eight", ctx do
      {:ok, reply} = read(ctx, ctx.answer.id, ctx.actor)
      assert Questions.for_reply(reply) == Questions.names()
    end
  end
end
