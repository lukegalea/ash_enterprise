defmodule AshEnterprise.Assistant.EvalTest do
  @moduledoc """
  The assistant's eval set (PROD-46), driven by a scripted oracle instead of
  the in-zone model: CI's proof that every case is answerable with the tools
  as they are (the oracle's calls are accepted, its surfaces resolve, its
  proposals resolve as the person) and that the harness scores what it
  should — a perfect run scores perfectly, a wrong one shows its misses.
  `mix ash_enterprise.assistant.eval` runs the same set against the real model.
  """

  use AshEnterprise.DataCase, async: false

  alias AshEnterprise.Test.AssistantEval, as: Eval
  alias AshEnterprise.Test.AssistantFixtures, as: F
  alias AshEnterprise.Test.AssistantFixtures.ScriptedModel

  @moduletag timeout: 300_000

  setup do
    F.in_zone!()
    ctx = F.tenant!()
    %{ctx: ctx, fixture: Eval.seed!(ctx)}
  end

  test "the oracle answers every case and scores perfectly", %{ctx: ctx, fixture: fixture} do
    cases = Eval.cases(fixture)
    assert length(cases) >= 15

    results = Eval.run(ctx, cases, before_case: &ScriptedModel.script!(Eval.oracle(&1)))
    card = Eval.scorecard(results)

    assert card.misses == []
    assert card.complete == card.cases
    assert {n, n} = card.tool_choice
    assert {a, a} = card.args_expected
    assert card.calls_accepted == card.calls
    assert {c, c} = card.citations
    assert c > 0
    assert {f, f} = card.facts
    assert {3, 3} = card.surfaces
    assert {4, 4} = card.proposals
    assert card.latency_p95_ms >= card.latency_p50_ms
  end

  test "a wrong answer shows up as its misses", %{ctx: ctx, fixture: fixture} do
    by_id = Map.new(Eval.cases(fixture), &{&1.id, &1})

    wrong = %{
      # Answers from memory: no tool, no citation.
      "calendar_tomorrow" => [{:text, "SYNTHETIC: you have a roadmap sync."}],
      # Lists the tasks instead of composing the board.
      "board_tasks" => [
        {:tools, [{"my_tasks", %{"input" => %{}}}]},
        {:text, "SYNTHETIC: two open tasks."}
      ],
      # Claims to approve: a decision it may not make, with a write tool.
      "no_decisions" => [
        {:tools,
         [{"propose_task", %{"input" => %{"change" => "add", "title" => "approve brief"}}}]},
        {:text, "SYNTHETIC: done, approved."}
      ]
    }

    cases = Enum.map(Map.keys(wrong), &Map.fetch!(by_id, &1))
    results = Eval.run(ctx, cases, before_case: &ScriptedModel.script!(Map.fetch!(wrong, &1.id)))
    card = Eval.scorecard(results)
    misses = Map.new(card.misses)

    assert "tools" in misses["calendar_tomorrow"]
    assert {0, 2} = card.citations
    assert "surface" in misses["board_tasks"]
    assert "tools" in misses["no_decisions"]
    assert "facts" in misses["no_decisions"]

    # The scorecard is counts and rates: no answer text, no arguments.
    printed = Enum.join(Eval.lines(card), "\n")
    refute printed =~ "SYNTHETIC"
    refute printed =~ "approve brief"
  end
end
