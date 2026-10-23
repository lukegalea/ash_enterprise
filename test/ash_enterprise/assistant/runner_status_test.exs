defmodule AshEnterprise.Assistant.RunnerStatusTest do
  @moduledoc """
  The runner reads how `AshAi.ToolLoop` ended (`Result.status`) instead of
  taking every finished loop for an answer. Only `:complete` is an answer; a
  loop that stopped with tool calls unrun is recorded as failed, with the
  reason and the held calls on the answer. Scripted model, synthetic data;
  nothing reaches a network.
  """

  use AshEnterprise.DataCase, async: false

  alias AshAi.ToolLoop.Result
  alias AshEnterprise.Assistant.{Runner, Thread, Turn}
  alias AshEnterprise.Test.AssistantFixtures, as: F
  alias AshEnterprise.Test.AssistantFixtures.ScriptedModel
  alias AshEnterpriseWeb.AssistantLive

  setup do
    F.in_zone!()
    ctx = F.tenant!()
    {:ok, thread} = Thread.start("SYNTHETIC thread", actor: ctx.actor, tenant: ctx.tenant)
    Map.put(ctx, :thread, thread)
  end

  defp run(ctx, opts) do
    Runner.run([thread: ctx.thread, actor: ctx.actor, tenant: ctx.tenant] ++ opts)
  end

  defp events do
    receive do
      {:assistant, _ref, event} -> [event | events()]
    after
      0 -> []
    end
  end

  describe "status_reason/1" do
    test "only a complete loop is an answer" do
      assert Runner.status_reason(%Result{status: :complete}) == nil
      assert Runner.status_reason(%Result{status: :awaiting_approval}) == :awaiting_approval
      assert Runner.status_reason(%Result{status: :paused}) == :tool_paused
      assert Runner.status_reason(%Result{status: :something_new}) == :internal
    end

    test "every reason it can give has its own page copy" do
      generic = AssistantLive.reason_message("SYNTHETIC-unknown")

      for reason <- ["awaiting_approval", "tool_paused"] do
        refute AssistantLive.reason_message(reason) == generic
      end
    end
  end

  describe "a run whose loop stops before answering" do
    test "a call held for approval ends the answer as awaiting_approval", ctx do
      ScriptedModel.script!([
        {:tools, [{"pending_approvals", %{"input" => %{}}}]},
        {:text, "SYNTHETIC: never asked for"}
      ])

      hold_all = fn _call, _context -> :ask end

      assert {:error, :awaiting_approval, %Turn{} = answer} =
               run(ctx, question: "SYNTHETIC: approvals?", approve_tool_call: hold_all)

      assert answer.status == :failed
      assert answer.error_class == "awaiting_approval"
      # Nothing was answered: the text before the call was narration.
      assert (answer.content || "") == ""

      # The call is recorded, unrun and marked as held.
      assert [%{"name" => "pending_approvals", "ok" => nil, "held" => "awaiting_approval"}] =
               answer.tool_calls["calls"]

      # One model call: the loop stopped instead of going round again.
      assert ScriptedModel.remaining() == [{:text, "SYNTHETIC: never asked for"}]

      evs = events()
      assert Enum.any?(evs, &match?({:held, %{ids: [_], reason: :awaiting_approval}}, &1))
      assert Enum.any?(evs, &match?({:failed, :awaiting_approval, %Turn{}}, &1))
      refute Enum.any?(evs, &match?({:tool_result, _}, &1))
    end

    test "a denied call goes back to the model, which still answers", ctx do
      ScriptedModel.script!([
        {:tools, [{"pending_approvals", %{"input" => %{}}}]},
        {:text, "SYNTHETIC: that lookup was not allowed."}
      ])

      deny_all = fn _call, _context -> {:deny, "SYNTHETIC policy"} end

      assert {:ok, %Turn{status: :complete} = answer} =
               run(ctx, question: "SYNTHETIC: approvals?", approve_tool_call: deny_all)

      assert answer.content == "SYNTHETIC: that lookup was not allowed."
      assert [%{"name" => "pending_approvals", "ok" => false} = call] = answer.tool_calls["calls"]
      refute Map.has_key?(call, "held")
    end

    test "with no gate every call runs, as before", ctx do
      ScriptedModel.script!([
        {:tools, [{"pending_approvals", %{"input" => %{}}}]},
        {:text, "SYNTHETIC: nothing is waiting."}
      ])

      assert {:ok, %Turn{status: :complete} = answer} =
               run(ctx, question: "SYNTHETIC: approvals?")

      assert [%{"name" => "pending_approvals", "ok" => true} = call] = answer.tool_calls["calls"]
      refute Map.has_key?(call, "held")
      refute Enum.any?(events(), &match?({:held, _}, &1))
    end
  end
end
