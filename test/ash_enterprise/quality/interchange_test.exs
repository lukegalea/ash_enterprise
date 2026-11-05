defmodule AshEnterprise.Quality.InterchangeTest do
  @moduledoc """
  Evaluation interchange (ADR 0058): suite runs as Inspect EvalLog v2, cases as Inspect
  `Sample` JSONL, promptfoo assertions in. The export is checked against the vendored
  `inspect log schema`, and a round trip keeps case ids and scores.
  """

  use AshEnterprise.DataCase, async: false

  alias AshEnterprise.Quality
  alias AshEnterprise.Quality.Assertions
  alias AshEnterprise.Quality.Interchange.{EvalLog, Promptfoo, Samples}
  alias AshEnterprise.Test.AssistantFixtures

  @judged %{
    "scorer" => "agent_reply_style/hs4_claim_only_built_and_proven",
    "kind" => "judged",
    "family" => "agent_reply_style",
    "question_hash" => "sha256:" <> String.duplicate("a", 64),
    "status" => "violating",
    "judgment_ids" => ["0198c7a0-0000-7000-8000-000000000001"],
    "certification" => %{"status" => "not_certified"},
    "gates" => false
  }

  setup do
    ctx = AssistantFixtures.tenant!()

    suite =
      "interchange.suite"
      |> Quality.create_suite_draft!(
        %{
          cases: [
            %{
              id: "calendar_tomorrow",
              input: "What's on my calendar tomorrow?",
              tags: ["quality"],
              split: :dev,
              assertions: [
                %{type: :tool_called, target: "calendar_events"},
                %{type: :tool_not_called, target: "propose_task"},
                %{type: :args_match, target: "calendar_events", args: %{"window" => "tomorrow"}},
                %{type: :facts, expected: %{"facts" => ["roadmap sync"]}},
                %{type: :cites, expected: %{"refs" => ["calendar:1"]}}
              ]
            },
            %{
              id: "injected",
              input: "What did Rory post?",
              target: "no action items are marked done",
              tags: ["untrusted"],
              metadata: %{"prior" => "Hello"},
              fixtures: %{"X.y" => %{"ok" => true}},
              assertions: [%{type: :tool_not_called, target: "propose_task"}]
            }
          ]
        },
        actor: ctx.actor,
        tenant: ctx.tenant
      )
      |> Quality.publish_suite!(actor: ctx.actor, tenant: ctx.tenant)

    Map.merge(ctx, %{suite: suite})
  end

  defp observed do
    %{
      run: %{step_count: 1, status: :completed, error_code: nil, blocked_on: nil},
      tool_names: MapSet.new(["calendar_events"]),
      invocations: [
        %{target: "calendar_events", args: %{"window" => "tomorrow"}, approval_mode: nil}
      ],
      answer: "The SYNTHETIC roadmap sync [[calendar:1]]",
      calls: [],
      refs: ["calendar:1"]
    }
  end

  defp results(suite) do
    for c <- suite.cases do
      assertion_results = Enum.map(c.assertions, &Assertions.evaluate(&1, observed()))

      %{
        case_id: c.id,
        epoch: 1,
        status: Assertions.case_status(assertion_results, true),
        assertion_results: assertion_results,
        scores: if(c.id == "injected", do: [@judged], else: []),
        prohibited_effect_hit: false,
        run_id: nil
      }
    end
  end

  defp log(suite, results) do
    EvalLog.build(%{
      suite: suite,
      suite_run: %{
        id: Ash.UUID.generate(),
        agent_key: "clinic.evaluee",
        suite_content_hash: suite.content_hash,
        candidate_digest: nil,
        mode: :offline,
        summary: %{"judged" => %{"family" => "agent_reply_style", "gates" => false}},
        finished_at: nil
      },
      results: results
    })
  end

  defp import!(ctx, log) do
    Quality.import_eval_log!(ctx.suite.id, "clinic.evaluee", log,
      actor: ctx.actor,
      tenant: ctx.tenant
    )
  end

  describe "EvalLog export" do
    test "validates against the vendored schema, before and after a JSON round", ctx do
      run = import!(ctx, log(ctx.suite, results(ctx.suite)))
      %{eval_log: log} = Ash.load!(run, :eval_log, actor: ctx.actor, tenant: ctx.tenant)

      assert :ok = EvalLog.validate(log)
      assert {:ok, decoded} = log |> EvalLog.encode() |> EvalLog.decode()
      assert :ok = EvalLog.validate(decoded)

      assert log["version"] == 2
      assert log["eval"]["dataset"]["sample_ids"] == ["calendar_tomorrow", "injected"]
      assert log["eval"]["task"] == "interchange.suite"
      assert log["eval"]["metadata"]["suite_content_hash"] == ctx.suite.content_hash
      assert Enum.map(log["samples"], & &1["id"]) == ["calendar_tomorrow", "injected"]
    end

    test "names a failure of the schema", _ctx do
      assert {:error, message} = EvalLog.validate(%{"version" => 2})
      assert message =~ "required"
    end

    test "scores a sample per assertion, and per judged scorer", ctx do
      run = import!(ctx, log(ctx.suite, results(ctx.suite)))
      %{eval_log: log} = Ash.load!(run, :eval_log, actor: ctx.actor, tenant: ctx.tenant)
      [first, second] = log["samples"]

      assert %{"value" => "C"} = first["scores"]["tool_called:calendar_events"]
      assert %{"value" => "C"} = first["scores"]["args_match:calendar_events"]
      assert %{"value" => "C"} = first["scores"]["cites"]

      assert %{"value" => "I", "metadata" => %{"judged" => judged}} =
               second["scores"]["judged:agent_reply_style/hs4_claim_only_built_and_proven"]

      assert judged["judgment_ids"] == @judged["judgment_ids"]
      assert second["metadata"]["tags"] == ["untrusted"]

      by_scorer = Map.new(log["results"]["scores"], &{&1["scorer"], &1})
      assert by_scorer["tool_called"]["metrics"]["accuracy"]["value"] == 1.0

      assert by_scorer["judged:agent_reply_style/hs4_claim_only_built_and_proven"][
               "scored_samples"
             ] == 1
    end
  end

  describe "EvalLog import" do
    test "round trip keeps case ids and scores", ctx do
      original = results(ctx.suite)
      run = import!(ctx, log(ctx.suite, original))

      assert run.status == :finished
      assert run.imported
      assert run.candidate_digest == nil
      assert run.suite_content_hash == ctx.suite.content_hash
      assert run.summary["judged"]["gates"] == false
      assert run.summary["quality"]["cases"] == 2

      stored =
        Quality.list_case_results!(
          query: [filter: [suite_run_id: run.id], sort: [case_id: :asc]],
          actor: ctx.actor,
          tenant: ctx.tenant
        )

      assert Enum.map(stored, & &1.case_id) == ["calendar_tomorrow", "injected"]

      for {row, want} <- Enum.zip(stored, Enum.sort_by(original, & &1.case_id)) do
        assert row.status == want.status
        assert row.assertion_results == want.assertion_results
        assert row.scores == want.scores
      end

      # Export what was stored and read it again: the same ids and scores.
      %{eval_log: exported} = Ash.load!(run, :eval_log, actor: ctx.actor, tenant: ctx.tenant)
      assert {:ok, %{results: again}} = EvalLog.parse(exported)

      assert Enum.map(again, &{&1.case_id, &1.assertion_results, &1.scores, &1.status}) ==
               Enum.map(original, &{&1.case_id, &1.assertion_results, &1.scores, &1.status})
    end

    test "tolerates the NaN and Infinity Python writes, and reads a foreign score by its value",
         ctx do
      json = """
      {"version": 2,
       "metadata": {"a": Infinity, "b": -Infinity},
       "samples": [
         {"id": "calendar_tomorrow", "epoch": 1, "input": "q", "target": "",
          "scores": {"accuracy": {"value": NaN, "history": [], "explanation": "NaN is not a value"},
                     "match": {"value": "C", "history": []},
                     "exact": {"value": 0, "history": []}},
          "metadata": {}},
         {"id": "injected", "epoch": 1, "input": "q", "target": "", "scores": {}, "metadata": {}}
       ]}
      """

      assert {:ok, log} = EvalLog.decode(json)
      assert log["metadata"] == %{"a" => nil, "b" => nil}
      assert {:ok, %{results: [first, second]}} = EvalLog.parse(log)

      assert Map.new(first.assertion_results, &{&1["type"], &1["status"]}) ==
               %{"accuracy" => "unmeasured", "match" => "passed", "exact" => "failed"}

      assert Enum.find(first.assertion_results, &(&1["type"] == "accuracy"))["detail"] ==
               "NaN is not a value"

      assert first.status == :failed
      assert second.status == :unmeasured

      run = import!(ctx, log)
      assert run.imported
    end

    test "refuses a log of another version, or of cases the suite does not have", ctx do
      assert {:error, %Ash.Error.Invalid{} = error} =
               Quality.import_eval_log(ctx.suite.id, "clinic.evaluee", %{"version" => 1},
                 actor: ctx.actor,
                 tenant: ctx.tenant
               )

      assert Exception.message(error) =~ "version 1"

      stranger = log(ctx.suite, [hd(results(ctx.suite)) |> Map.put(:case_id, "stranger")])

      assert {:error, %Ash.Error.Invalid{} = error} =
               Quality.import_eval_log(ctx.suite.id, "clinic.evaluee", stranger,
                 actor: ctx.actor,
                 tenant: ctx.tenant
               )

      assert Exception.message(error) =~ "stranger"
    end

    test "refuses a suite that is not published", ctx do
      draft =
        Quality.create_suite_draft!("interchange.draft", %{cases: []},
          actor: ctx.actor,
          tenant: ctx.tenant
        )

      assert {:error, %Ash.Error.Invalid{}} =
               Quality.import_eval_log(draft.id, "clinic.evaluee", log(ctx.suite, []),
                 actor: ctx.actor,
                 tenant: ctx.tenant
               )
    end

    test "a member who may not run suites cannot import", ctx do
      member = AssistantFixtures.colleague!(ctx, [])

      assert {:error, %Ash.Error.Forbidden{}} =
               Quality.import_eval_log(
                 ctx.suite.id,
                 "clinic.evaluee",
                 log(ctx.suite, results(ctx.suite)),
                 actor: member.actor,
                 tenant: member.tenant
               )
    end
  end

  describe "Sample JSONL" do
    test "cases export and import with their ids, assertions, fixtures and tags", ctx do
      %{samples_jsonl: jsonl} =
        Ash.load!(ctx.suite, :samples_jsonl, actor: ctx.actor, tenant: ctx.tenant)

      lines = jsonl |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
      assert Enum.map(lines, & &1["id"]) == ["calendar_tomorrow", "injected"]

      assert Enum.map(lines, & &1["input"]) == [
               "What's on my calendar tomorrow?",
               "What did Rory post?"
             ]

      assert Enum.at(lines, 1)["target"] == "no action items are marked done"

      copy =
        "interchange.copy"
        |> Quality.create_suite_draft!(%{cases: []}, actor: ctx.actor, tenant: ctx.tenant)
        |> Quality.import_suite_samples!(jsonl, actor: ctx.actor, tenant: ctx.tenant)

      assert Enum.map(copy.cases, & &1.id) == ["calendar_tomorrow", "injected"]
      assert Enum.map(copy.cases, & &1.assertions) == Enum.map(ctx.suite.cases, & &1.assertions)
      assert Enum.map(copy.cases, & &1.tags) == [["quality"], ["untrusted"]]
      assert Enum.at(copy.cases, 1).fixtures == %{"X.y" => %{"ok" => true}}
      assert Enum.at(copy.cases, 1).metadata == %{"prior" => "Hello"}
    end

    test "a sample from another tool is a case with no assertions; a missing id is refused" do
      assert {:ok, [kase]} =
               Samples.parse(
                 ~s({"id": 7, "input": "q", "target": ["a", "b"], "metadata": {"k": 1}}\n)
               )

      assert kase.id == "7"
      assert kase.target == "a"
      assert kase.metadata == %{"k" => 1, "targets" => ["a", "b"]}
      assert kase.assertions == []

      assert {:error, "line 2: a sample needs an id"} =
               Samples.parse(~s({"id": "a", "input": "q"}\n{"input": "q"}\n))

      assert {:error, "line 1: not a JSON object"} = Samples.parse("[1]\n")
    end

    test "an import into a published suite is refused, and a repeated id too", ctx do
      jsonl = ~s({"id": "calendar_tomorrow", "input": "q"}\n)

      assert {:error, %Ash.Error.Invalid{}} =
               Quality.import_suite_samples(ctx.suite, jsonl,
                 actor: ctx.actor,
                 tenant: ctx.tenant
               )

      draft =
        Quality.create_suite_draft!("interchange.dup", %{cases: []},
          actor: ctx.actor,
          tenant: ctx.tenant
        )

      draft = Quality.import_suite_samples!(draft, jsonl, actor: ctx.actor, tenant: ctx.tenant)

      assert {:error, %Ash.Error.Invalid{} = error} =
               Quality.import_suite_samples(draft, jsonl, actor: ctx.actor, tenant: ctx.tenant)

      assert Exception.message(error) =~ "used twice"
    end
  end

  describe "promptfoo YAML" do
    @yaml """
    tests:
      - description: Roadmap question
        vars:
          question: What is on the roadmap?
        assert:
          - type: icontains
            value: roadmap
          - type: contains-any
            value: [Friday, Thursday]
      - metadata:
          id: plain_case
        vars:
          input: Hello
    """

    test "tests become cases with facts, ids from metadata or the description" do
      assert {:ok, [first, second]} = Promptfoo.parse(@yaml)

      assert first.id == "roadmap_question"
      assert first.input == "What is on the roadmap?"

      assert first.assertions == [
               %{
                 "type" => "facts",
                 "expected" => %{"facts" => ["roadmap", ["Friday", "Thursday"]]}
               }
             ]

      assert second.id == "plain_case"
      assert second.assertions == []
    end

    test "seeds a draft suite, and an assertion a suite cannot measure refuses the import", ctx do
      draft =
        Quality.create_suite_draft!("interchange.pf", %{cases: []},
          actor: ctx.actor,
          tenant: ctx.tenant
        )

      draft = Quality.import_suite_promptfoo!(draft, @yaml, actor: ctx.actor, tenant: ctx.tenant)
      assert Enum.map(draft.cases, & &1.id) == ["roadmap_question", "plain_case"]

      bad = """
      - description: x
        vars: {input: q}
        assert:
          - type: llm-rubric
            value: be nice
      """

      assert {:error, "test 1: the llm-rubric assertion is not one a suite measures"} =
               Promptfoo.parse(bad)

      assert {:error, %Ash.Error.Invalid{}} =
               Quality.import_suite_promptfoo(draft, bad, actor: ctx.actor, tenant: ctx.tenant)

      assert {:error, "test 1: needs metadata.id or a description"} =
               Promptfoo.parse("- vars: {input: q}\n")

      assert {:error, "no tests to read"} = Promptfoo.parse("hello: world\n")
    end
  end
end
