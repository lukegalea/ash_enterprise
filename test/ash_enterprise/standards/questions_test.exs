defmodule AshEnterprise.Standards.QuestionsTest do
  @moduledoc """
  AST-138: the confirmed standards questions, declared, and the candidate
  rung that decides which code units each one is asked about.

  The twenty-three questions on `AshEnterprise.Standards.CodeUnit` are
  rendered by `QuestionProposal.to_dsl/2` from the entries Luke Galea
  confirms, each with its projection and that projection's shape:

    * the seventeen confirmed on 2026-10-21 (three dogfood records,
      `test/fixtures/standards/confirmed.json`), re-declared at version 2
      with a `state_shape` (`confirmed-v2.json`);
    * the six ADR 0038 questions at version 1 (`adr-0038-confirmed.json`).

  `confirmed-v2.json` and `adr-0038-confirmed.json` are the exports of
  the two records Luke confirmed in dogfood on 2026-10-29. No model is
  called here.
  """

  use ExUnit.Case, async: true

  alias AshAgentTools.CodeSubjects
  alias AshEnterprise.Standards
  alias AshEnterprise.Standards.{Candidates, CodeUnit, Questions}
  alias AshEnterprise.SystemOne.QuestionProposal
  alias AshEnterprise.SystemOne.QuestionProposal.Schema
  alias AshJudgments.Registry.Canonical
  alias AshJudgments.Registry.Info

  @fixtures Path.expand("../../fixtures/standards", __DIR__)
  @lock_file Path.expand("../../../priv/judgments/lock.json", __DIR__)
  @source Path.expand("../../../lib/ash_enterprise/standards/code_unit.ex", __DIR__)

  @v1_records %{
    "61a388e9-1f61-4bdd-913b-ab45f61590a6" => 2,
    "04d37ab9-e18b-401e-8b89-02473d5619ae" => 6,
    "dee2d586-d943-4c2f-8e01-bbb06866efe3" => 9
  }

  @v2_records %{"43864d09-edbc-4ba1-b3f1-48e0017c5409" => 17}
  @adr_records %{"9f91e62a-ce8c-4729-8e4b-0342fde5f26d" => 6}

  @adr_questions [
    :policy_check_calls_no_model,
    :actor_context_build_calls_no_model,
    :feel_or_dmn_evaluation_calls_no_model,
    :rules_evaluation_makes_no_live_model_call,
    :projector_calls_no_model,
    :calculation_calls_no_model
  ]

  # The entries of one fixture, after checking its records and their sizes.
  defp entries(file, records, status) do
    decoded = @fixtures |> Path.join(file) |> File.read!() |> Jason.decode!()

    assert Map.new(decoded, &{&1["id"], length(&1["proposals"])}) == records
    assert Enum.all?(decoded, &(&1["status"] == status))

    Enum.flat_map(decoded, & &1["proposals"])
  end

  defp v1, do: entries("confirmed.json", @v1_records, "confirmed")
  defp v2, do: entries("confirmed-v2.json", @v2_records, "confirmed")
  defp adr, do: entries("adr-0038-confirmed.json", @adr_records, "confirmed")

  # Every declared question with the entry it was rendered from.
  defp declared_with_entries do
    Enum.map(v2() ++ adr(), fn entry ->
      {Info.question(CodeUnit, String.to_existing_atom(entry["name"])), entry}
    end)
  end

  describe "the declared questions" do
    test "are the seventeen v2 entries and the six ADR 0038 entries, in clause order" do
      declared = Info.questions(CodeUnit)

      assert Enum.map(declared, &Atom.to_string(&1.name)) ==
               Enum.map(v2() ++ adr(), & &1["name"])

      assert Enum.map(declared, & &1.name) == Questions.names()
      assert Enum.take(Questions.names(), -6) == @adr_questions
    end

    test "the v2 entries are the 2026-10-21 entries with a state_shape and nothing else" do
      wording = fn entry -> Map.drop(entry, ["question_hash", "state_shape"]) end

      assert Enum.map(v2(), wording) == Enum.map(v1(), wording)

      for entry <- v2() ++ adr() do
        question = Questions.fetch!(String.to_existing_atom(entry["name"]))
        assert entry["state_shape"] == question.projection.shape(), entry["name"]
        assert entry["clause_ref"] == question.clause, entry["name"]
      end
    end

    test "each is to_dsl's rendering of its entry at its version, plus its projection and shape" do
      landed = @source |> File.read!() |> question_bodies()

      for {question, entry} <- declared_with_entries() do
        rendered =
          entry
          |> Map.put("profile", "winnow_gpu")
          |> QuestionProposal.to_dsl(CodeUnit)
          |> question_bodies()
          |> Map.fetch!(question.name)
          |> Enum.map(fn
            {:version, [], [1]} -> {:version, [], [question.version]}
            line -> line
          end)

        projection = Questions.fetch!(question.name).projection

        alias_ast =
          {:__aliases__, [], projection |> Module.split() |> Enum.map(&String.to_atom/1)}

        assert Map.fetch!(landed, question.name) ==
                 rendered ++
                   [
                     {:state_projection, [], [alias_ast]},
                     {:state_shape, [], [{{:., [], [alias_ast, :shape]}, [], []}]}
                   ],
               "#{question.name} is not to_dsl's rendering plus its projection and shape"

        assert question.instructions == entry["instructions"]
        assert stringify(question.criteria) == entry["criteria"]
        assert question.profile == :winnow_gpu
        assert Atom.to_string(question.family) == entry["family"]
        assert question.state_projection == projection
        assert question.state_contract == Canonical.state_contract(entry["state_shape"])

        if options = entry["options"] do
          assert Enum.map(question.constraints[:of], &Atom.to_string/1) == options
        end
      end

      assert Info.questions(CodeUnit) |> Enum.map(& &1.version) |> Enum.frequencies() ==
               %{1 => 6, 2 => 17}
    end

    test "hashes: normalise hashes at v1, and a declared hash differs from it only by version" do
      lock = @lock_file |> File.read!() |> Jason.decode!()

      for {question, entry} <- declared_with_entries() do
        {:ok, declaration} = Schema.normalise(entry)

        # The proposal mechanism's identity: always version 1.
        assert declaration.version == 1
        assert Schema.question_hash(declaration) == entry["question_hash"], entry["name"]

        # The declared identity is the same declaration at its version.
        assert question.question_hash ==
                 Schema.question_hash(%{declaration | version: question.version}),
               entry["name"]

        if question.version == 1 do
          assert question.question_hash == entry["question_hash"]
        else
          refute question.question_hash == entry["question_hash"]
        end

        assert lock[question.question_id] == %{
                 "hash" => question.question_hash,
                 "version" => question.version
               }
      end
    end

    test "the 2026-10-21 hashes are the v1 identities without a shape" do
      hashed = Enum.filter(v1(), & &1["question_hash"])
      assert length(hashed) == 9

      for entry <- hashed do
        {:ok, declaration} = Schema.normalise(entry)
        assert declaration.state_shape == nil
        assert Schema.question_hash(declaration) == entry["question_hash"]

        question = Info.question(CodeUnit, String.to_existing_atom(entry["name"]))
        refute question.question_hash == entry["question_hash"]
      end
    end

    test "each question sees its declared projection" do
      for question <- Questions.all() do
        assert Questions.declared(question.name).state_projection == question.projection
      end

      assert Questions.all() |> Enum.map(& &1.projection) |> Enum.uniq() |> length() == 4
    end

    test "violations read the admitted value, whatever the polarity" do
      assert Questions.violation?(:handle_event_authorizes, false)
      refute Questions.violation?(:handle_event_authorizes, true)
      assert Questions.violation?(:association_query_strategy, "joins_has_many")
      refute Questions.violation?(:association_query_strategy, "belongs_to_join")
      assert Questions.violation?(:hs9_interface_copy_languages, :not_done)
      refute Questions.violation?(:hs9_interface_copy_languages, "customer_facing_other")

      assert Questions.violating_status(:hs6_no_novelty_claims) == :out
      assert Questions.violating_status(:association_query_strategy) == :in
    end

    test "facts name the CodeUnit resource" do
      {:ok, [subject | _]} =
        CodeSubjects.from_source("defmodule M do\nend\n", "lib/m.ex", repository: "r")

      assert Standards.subject_term(subject) == %{
               "type" => "AshEnterprise.Standards.CodeUnit",
               "id" => "r:lib/m.ex#M"
             }
    end
  end

  describe "the ADR 0038 questions" do
    test "six yes/no questions in one family, true compliant, one per component" do
      for name <- @adr_questions do
        question = Questions.fetch!(name)
        declared = Questions.declared(name)

        assert declared.family == :model_call_location
        assert declared.type == AshAi.Evaluate.Noul
        assert declared.version == 1
        assert question.holds_value == true
        assert question.roll_up == :all
        assert Questions.violation?(name, false)
        refute Questions.violation?(name, true)
        assert question.source =~ "ADR 0038"
      end

      assert Candidates.component_questions() |> Map.keys() |> Enum.sort() ==
               Enum.sort(@adr_questions)

      assert Candidates.component_questions() |> Map.values() |> Enum.uniq() |> length() == 6
    end

    test "only the policy-check question sees the policies section" do
      for name <- @adr_questions do
        expected =
          if name == :policy_check_calls_no_model,
            do: Standards.Projections.PolicyView,
            else: Standards.Projections.ModuleHeader

        assert Questions.fetch!(name).projection == expected
      end
    end
  end

  describe "Candidates.component/1" do
    test "each structural kind: check, ActorContext build, projector, calculation" do
      check =
        units!("lib/demo/model_check.ex", """
        defmodule Demo.ModelCheck do
          use Ash.Policy.FilterCheck

          def filter(_actor, _authorizer, _opts), do: expr(true)
        end
        """)

      actor_context =
        units!("lib/demo/security/actor_context.ex", """
        defmodule Demo.Security.ActorContext do
          def build(user), do: %{user_id: user.id}
        end
        """)

      projector =
        units!("lib/demo/ledger_projector.ex", """
        defmodule Demo.LedgerProjector do
          use AshEvents.Projector

          def handle_event(event, state), do: Map.put(state, event.id, event)
        end
        """)

      calculation =
        units!("lib/demo/calculations/score.ex", """
        defmodule Demo.Calculations.Score do
          use Ash.Resource.Calculation

          def calculate(records, _opts, _context), do: Enum.map(records, & &1.score)
        end
        """)

      assert components(check) == %{"Demo.ModelCheck.filter/3" => :policy_check}

      assert components(actor_context) == %{
               "Demo.Security.ActorContext.build/1" => :actor_context_build
             }

      assert components(projector) == %{"Demo.LedgerProjector.handle_event/2" => :projector}
      assert components(calculation) == %{"Demo.Calculations.Score.calculate/3" => :calculation}
    end

    test "the call-site kinds: a DMN or FEEL evaluation, an ash_rules evaluation or fact builder" do
      units =
        units!("lib/demo/gate.ex", """
        defmodule Demo.Gate do
          def decide(inputs), do: AshDecisions.Evaluator.evaluate(:gate, inputs)
          def feel(expr, ctx), do: Feel.evaluate(expr, ctx)
          def rules(bundle, facts), do: AshRules.evaluate(bundle, facts)
          def facts(subject), do: Bridge.Rules.facts_for(subject, [])
          def plain(x), do: x
        end
        """)

      assert components(units) == %{
               "Demo.Gate.decide/1" => :feel_or_dmn_evaluation,
               "Demo.Gate.feel/2" => :feel_or_dmn_evaluation,
               "Demo.Gate.rules/2" => :rules_evaluation,
               "Demo.Gate.facts/1" => :rules_evaluation
             }

      rules_module =
        units!("lib/demo/bundle.ex", """
        defmodule Demo.Bundle do
          use AshRules

          def check(facts), do: facts
        end
        """)

      assert components(rules_module) == %{"Demo.Bundle.check/1" => :rules_evaluation}
    end

    test "a policy entity with an expr is a policy check; one without is not" do
      units =
        units!("lib/demo/post.ex", """
        defmodule Demo.Post do
          use Ash.Resource

          policies do
            policy action_type(:read) do
              authorize_if expr(owner_id == ^actor(:id))
            end

            policy action_type(:create) do
              authorize_if always()
            end
          end
        end
        """)

      assert components(units) == %{"Demo.Post/policies/policy[0]" => :policy_check}
    end

    test "structural kinds win over call sites, and a unit is asked one ADR question only" do
      units =
        units!("lib/demo/decision_projector.ex", """
        defmodule Demo.DecisionProjector do
          use AshEvents.Projector

          def handle_event(event, state), do: Decisions.evaluate(event.key, state)
        end
        """)

      assert components(units) == %{"Demo.DecisionProjector.handle_event/2" => :projector}

      [handler] = Enum.filter(units, &(&1.kind == :function))

      assert Enum.filter(@adr_questions, &Candidates.candidate?(&1, handler)) == [
               :projector_calls_no_model
             ]
    end

    test "an ordinary module is no component, and a vendored one is never a candidate" do
      plain = units!("lib/demo/plain.ex", "defmodule Demo.Plain do\n  def go(x), do: x\nend\n")
      assert components(plain) == %{}

      vendored =
        units!("deps/thing/lib/calc.ex", """
        defmodule Thing.Calc do
          use Ash.Resource.Calculation

          def calculate(records, _opts, _context), do: records
        end
        """)

      assert components(vendored) == %{"Thing.Calc.calculate/3" => :calculation}
      assert Enum.filter(vendored, &Candidates.candidate?(:calculation_calls_no_model, &1)) == []
    end
  end

  describe "the candidate rung" do
    test "a check module's functions are asked whether they query; other modules are not" do
      units =
        units!("lib/demo/team_check.ex", """
        defmodule Demo.TeamCheck do
          use Ash.Policy.SimpleCheck

          def describe(_), do: "member of the team"
          def match?(actor, _context, _opts), do: actor.context.team_id != nil
        end
        """)

      assert names(units, :policy_check_never_queries) == [
               "Demo.TeamCheck.describe/1",
               "Demo.TeamCheck.match?/3"
             ]

      assert names(
               units("lib/other.ex", "defmodule Other do\n  def match?(a), do: a\nend\n"),
               :policy_check_never_queries
             ) ==
               []
    end

    test "a forbid_if is a candidate in a policy entity, never in a field or an action" do
      units =
        units!("lib/demo/post.ex", """
        defmodule Demo.Post do
          use Ash.Resource

          policies do
            policy action_type(:read) do
              forbid_if expr(archived)
              authorize_if always()
            end
          end

          actions do
            read :read
          end
        end
        """)

      assert names(units, :no_forbid_if_for_row_access) == ["Demo.Post/policies/policy[0]"]
    end

    test "a LiveView's handle_event/3 and a template without gettext are candidates" do
      units =
        units!("lib/demo_web/live/page_live.ex", """
        defmodule DemoWeb.PageLive do
          use DemoWeb, :live_view

          def handle_event("save", params, socket), do: {:noreply, assign(socket, :p, params)}

          def render(assigns) do
            ~H"<p>Saved</p>"
          end
        end
        """)

      assert names(units, :handle_event_authorizes) == ["DemoWeb.PageLive.handle_event/3"]
      assert names(units, :hs9_interface_copy_languages) == ["DemoWeb.PageLive.render/1"]
    end

    test "comments, query loops, Oban enqueues and HTTP calls" do
      units =
        units!("lib/demo/worker.ex", """
        defmodule Demo.Worker do
          use Oban.Worker

          # Loads every post.
          # Then loads each author.
          # One query per post.
          def authors(posts), do: Enum.map(posts, &Repo.get(Author, &1.author_id))

          def enqueue(post), do: %{post: post} |> Demo.Worker.new() |> Oban.insert()

          def fetch(url), do: Req.get(url)

          def plain(x), do: x
        end
        """)

      assert names(units, :comments_are_durable_facts_only) == ["Demo.Worker.authors/1"]
      assert names(units, :association_query_strategy) == ["Demo.Worker.authors/1"]
      assert names(units, :oban_args_string_keyed) == ["Demo.Worker.enqueue/1"]
      assert names(units, :stores_ids_not_structs) == ["Demo.Worker.enqueue/1"]
      assert names(units, :third_party_api_wrapped) == ["Demo.Worker.fetch/1"]
    end

    test "doc paragraphs: the first one for HS-1, novelty words for HS-6, all for the rest" do
      units =
        units!("docs/guide.md", """
        # Guide

        This guide says how to run the standing job.

        It is a groundbreaking approach.

        - a list item
        """)

      assert names(units, :hs1_lead_with_outcome_or_ask) == ["Guide[0]"]
      assert names(units, :hs6_no_novelty_claims) == ["Guide[1]"]
      assert length(names(units, :hs3_use_plain_words)) == 3
    end

    test "a vendored path is never a candidate" do
      units = units!("priv/cdm/schema.md", "# Schema\n\nThe first ever schema.\n")
      assert names(units, :hs6_no_novelty_claims) == []
    end
  end

  defp units!(path, source) do
    {:ok, units} =
      CodeSubjects.from_source(source, path, repository: "demo", context: [:module_header])

    units
  end

  defp units(path, source), do: units!(path, source)

  defp names(units, question) do
    units |> Enum.filter(&Candidates.candidate?(question, &1)) |> Enum.map(& &1.name_path)
  end

  defp components(units) do
    for unit <- units, component = Candidates.component(unit), into: %{} do
      {unit.name_path, component}
    end
  end

  defp stringify(criteria), do: Map.new(criteria, fn {k, v} -> {to_string(k), v} end)

  # Every `question :name do ... end` in the source, as its body's
  # expressions with the position metadata removed, so the formatter's line
  # breaks do not count.
  defp question_bodies(source) do
    {_ast, found} =
      source
      |> Code.string_to_quoted!()
      |> Macro.prewalk(%{}, fn
        {:question, _, [name, [do: {:__block__, _, body}]]} = node, acc when is_atom(name) ->
          {node, Map.put(acc, name, Enum.map(body, &strip_meta/1))}

        node, acc ->
          {node, acc}
      end)

    found
  end

  defp strip_meta(ast), do: Macro.prewalk(ast, &Macro.update_meta(&1, fn _ -> [] end))
end
