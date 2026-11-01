defmodule AshEnterprise.Quality.QuestionsTest do
  @moduledoc """
  S1-91: the eight `agent_reply_style` questions on
  `AshEnterprise.Quality.AgentReply`, their lock, and which of them are
  asked of a reply. No model is called and nothing is stored.
  """

  use ExUnit.Case, async: true

  alias AshEnterprise.Quality
  alias AshEnterprise.Quality.{AgentReply, Questions}
  alias AshEnterprise.Quality.Projections.ReplyText
  alias AshEnterprise.Standards.CodeUnit
  alias AshEnterprise.SystemOne.JudgedState
  alias AshJudgments.Registry.Canonical
  alias AshJudgments.Registry.Info
  alias AshJudgments.Registry.Verifiers.VerifyLock
  alias Spark.Dsl.Transformer

  @lock_file Path.expand("../../../priv/judgments/lock.json", __DIR__)

  @names [
    :hs1_lead_with_outcome_or_ask,
    :hs2_keep_it_short,
    :hs3_use_plain_words,
    :hs4_claim_only_built_and_proven,
    :hs5_promise_only_agreed_to,
    :hs6_no_novelty_claims,
    :hs7_never_invent_name_feature_or_date,
    :hs8_no_internal_shorthand_for_outside
  ]

  defp reply(text, used_tools \\ false),
    do: %AgentReply{
      id: "assistant_turn:#{Ash.UUID.generate()}",
      text: text,
      used_tools: used_tools
    }

  describe "the declared questions" do
    test "are hs1 to hs8, yes/no, version 1, in the agent_reply_style family, seeing ReplyText" do
      declared = Info.questions(AgentReply)

      assert Enum.map(declared, & &1.name) == @names
      assert Questions.names() == @names

      for question <- declared do
        assert question.type == AshAi.Evaluate.Noul
        assert question.version == 1
        assert question.family == :agent_reply_style
        assert question.profile == :winnow_gpu_12b
        assert question.state_projection == ReplyText
        assert question.state_contract == Canonical.state_contract(%{"reply" => "string"})
      end

      assert Questions.family() == :agent_reply_style
    end

    test "are the code-unit house-style wording with the document read as the reply" do
      for name <- @names do
        reply_question = Info.question(AgentReply, name)
        code_question = Info.question(CodeUnit, name)

        assert reply_question.instructions == as_reply(code_question.instructions), inspect(name)

        assert reply_question.criteria == Map.new(code_question.criteria, &as_reply/1),
               inspect(name)

        refute reply_question.instructions =~ "document"
        refute reply_question.question_id == code_question.question_id
        refute reply_question.question_hash == code_question.question_hash
      end
    end

    test "the lock holds each at version 1" do
      lock = @lock_file |> File.read!() |> Jason.decode!()

      for question <- Info.questions(AgentReply) do
        assert lock[question.question_id] == %{
                 "hash" => question.question_hash,
                 "version" => 1
               }
      end
    end

    test "the family is configured to admit a confident no, like house_style" do
      families = Application.fetch_env!(:ash_judgments, :families)
      assert families[:agent_reply_style] == families[:house_style]
      assert families[:agent_reply_style] == %{low_band: :admit_no}
    end

    test "score inputs are the family's own, so they never collide with house_style's" do
      assert Questions.score_inputs() == Enum.map(@names, &"#{&1}__p_true")

      assert Enum.all?(Info.questions(AgentReply), &(&1.family != :house_style))
    end
  end

  describe "the lock" do
    test "a state-shape change without a version bump fails the lock" do
      dsl = AgentReply.spark_dsl_config()
      assert VerifyLock.verify(dsl) == :ok

      changed = redeclare(dsl, shape: %{"reply" => "string", "question" => "string"})
      assert {:error, errors} = VerifyLock.verify(changed)
      assert length(errors) == 8

      for error <- errors do
        assert Exception.message(error) =~ "changed without a version bump"
      end
    end

    test "the same change at version 2 passes, as the lock task then records it" do
      changed =
        AgentReply.spark_dsl_config()
        |> redeclare(shape: %{"reply" => "string", "question" => "string"}, version: 2)

      assert VerifyLock.verify(changed) == :ok
    end

    test "a question's hash is its declaration's, so the recomputation is the lock's" do
      for question <- Info.questions(AgentReply) do
        assert hash(question, ReplyText.shape(), question.version) == question.question_hash
      end
    end
  end

  describe "which questions are asked of a reply" do
    test "all eight of a reply that used no tools" do
      assert Questions.for_reply(reply("The report is filed.")) == @names
    end

    test "hs4 and hs7 are not asked of a reply that used tools" do
      asked = Questions.for_reply(reply("The SYNTHETIC review is on 2026-11-02.", true))

      assert asked ==
               @names --
                 [:hs4_claim_only_built_and_proven, :hs7_never_invent_name_feature_or_date]

      refute Questions.asked?(:hs4_claim_only_built_and_proven, reply("x", true))
      refute Questions.asked?(:hs7_never_invent_name_feature_or_date, reply("x", true))
      assert Questions.asked?(:hs5_promise_only_agreed_to, reply("x", true))
    end

    test "a reply that does not say whether it used tools is refused, not assumed" do
      assert_raise FunctionClauseError, fn ->
        Questions.asked?(:hs4_claim_only_built_and_proven, %{id: "x", text: "y"})
      end
    end

    test "violations read the admitted value: false is a violation, true is not" do
      for name <- @names do
        assert Questions.violation?(name, false)
        assert Questions.violation?(name, "false")
        refute Questions.violation?(name, true)
        assert Questions.violating_status(name) == :out
      end
    end
  end

  describe "the judged state" do
    test "is the reply text alone, and its digest is the reply's digest" do
      reply = reply("  The SYNTHETIC report is filed.\r\nNothing else is due.  ")

      for name <- @names do
        state = Questions.judged_state(name, reply)

        assert state == %{"reply" => "The SYNTHETIC report is filed.\nNothing else is due."}
        assert JudgedState.digest(state) == Quality.digest(reply)
      end
    end
  end

  defp as_reply({key, text}), do: {key, as_reply(text)}

  defp as_reply(text) when is_binary(text) do
    text
    |> String.replace("the document's", "the reply's")
    |> String.replace("The document's", "The reply's")
    |> String.replace("the document", "the reply")
    |> String.replace("The document", "The reply")
  end

  # The resource's DSL state with every question redeclared under another
  # state shape (and, optionally, version), its identity derived the way
  # the registry derives it.
  defp redeclare(dsl, opts) do
    shape = Keyword.fetch!(opts, :shape)

    dsl
    |> Transformer.get_entities([:judgments])
    |> Enum.reduce(dsl, fn question, acc ->
      version = Keyword.get(opts, :version, question.version)

      changed = %{
        question
        | state_shape: shape,
          state_contract: Canonical.state_contract(shape),
          version: version,
          question_hash: hash(question, shape, version)
      }

      Transformer.replace_entity(acc, [:judgments], changed, &(&1.name == question.name))
    end)
  end

  defp hash(question, shape, version) do
    Canonical.question_hash(%{
      answer_type: question.type,
      criteria: question.criteria,
      instructions: question.instructions,
      options: question.options,
      state_contract: Canonical.state_contract(shape),
      version: version
    })
  end
end
