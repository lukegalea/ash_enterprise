defmodule AshEnterprise.Standards.ChoiceQuestionsTest do
  @moduledoc """
  AST-138: the two standards questions that are a Choice, not a yes/no,
  judge through the real judge action and the host ledger.

  Both declare their options as a plain list on `of:`. The model is
  `FakeReqLLM` answering with a queued choice reply; the unit is a
  synthetic function.
  """

  use AshEnterprise.DataCase, async: false

  alias AshAgentTools.CodeSubjects
  alias AshEnterprise.Platform.Correlation
  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.Standards
  alias AshEnterprise.Standards.{CodeUnit, Questions}
  alias AshEnterprise.SystemOne
  alias AshEnterprise.SystemOne.Judgment
  alias AshEnterprise.SystemOne.TestSupport.FakeReqLLM

  @source """
  defmodule Demo.Orders do
    @moduledoc "Synthetic orders."
    import Ecto.Query

    def with_lines(order_ids) do
      from(o in "orders", where: o.id in ^order_ids, preload: [:lines])
    end
  end
  """

  setup do
    Correlation.start_new()
    System.put_env("S1_OLLAYA_GPU_BASE_URL", "http://127.0.0.1:11435")
    System.put_env("OLLAYA_API_KEY", "local-test-only")

    on_exit(fn ->
      FakeReqLLM.clear_replies()
      System.delete_env("S1_OLLAYA_GPU_BASE_URL")
      System.delete_env("OLLAYA_API_KEY")
    end)

    %{tenant: Ash.UUID.generate()}
  end

  for {name, choice} <- [
        association_query_strategy: "has_many_separate_queries",
        hs9_interface_copy_languages: "not_done"
      ] do
    test "#{name} is judged and recorded as a choice", %{tenant: tenant} do
      question = Questions.fetch!(unquote(name))
      unit = unit!(question)
      term = Standards.subject_term(unit)

      FakeReqLLM.queue_replies([
        %{
          "choice" => unquote(choice),
          "probabilities" => %{unquote(choice) => 0.8},
          "confidence" => 0.8
        }
      ])

      context =
        SystemOne.judge_context(
          tenant: tenant,
          judgments: %{req_llm: FakeReqLLM, subject: %{type: term["type"], id: term["id"]}}
        )

      answer =
        CodeUnit
        |> Ash.ActionInput.for_action(
          Questions.judge_action(question.name),
          %{"input" => unit},
          actor: SystemActor.system()
        )
        |> Ash.run_action!(context: context)

      assert %AshAi.Evaluate.Choice{value: unquote(choice)} = answer

      assert [recorded] =
               Judgment
               |> Ash.Query.for_read(:read, %{},
                 actor: SystemActor.system(),
                 tenant: tenant
               )
               |> Ash.read!()

      assert recorded.answer_kind == :choice
      assert recorded.value == unquote(choice)
      assert recorded.question_id =~ "#judgments/#{unquote(name)}"
    end
  end

  defp unit!(question) do
    {:ok, [unit | _]} =
      CodeSubjects.from_source(@source, "lib/demo/orders.ex",
        repository: "demo",
        kinds: question.kinds,
        context: question.projection
      )

    unit
  end
end
