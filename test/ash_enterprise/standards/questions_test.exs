defmodule AshEnterprise.Standards.QuestionsTest do
  @moduledoc """
  AST-138: the confirmed standards questions, declared, and the candidate
  rung that decides which code units each one is asked about.

  The seventeen questions on `AshEnterprise.Standards.CodeUnit` are the
  entries Luke Galea confirmed on 2026-10-21 (three dogfood records,
  `test/fixtures/standards/confirmed.json`), rendered by
  `QuestionProposal.to_dsl/2` and landed at version 1. No model is called
  here.
  """

  use ExUnit.Case, async: true

  alias AshAgentTools.CodeSubjects
  alias AshEnterprise.Standards
  alias AshEnterprise.Standards.{Candidates, CodeUnit, Questions}
  alias AshEnterprise.SystemOne.QuestionProposal
  alias AshJudgments.Registry.Info

  @fixture Path.expand("../../fixtures/standards/confirmed.json", __DIR__)
  @lock_file Path.expand("../../../priv/judgments/lock.json", __DIR__)
  @source Path.expand("../../../lib/ash_enterprise/standards/code_unit.ex", __DIR__)

  @records %{
    "61a388e9-1f61-4bdd-913b-ab45f61590a6" => 2,
    "04d37ab9-e18b-401e-8b89-02473d5619ae" => 6,
    "dee2d586-d943-4c2f-8e01-bbb06866efe3" => 9
  }

  defp confirmed do
    records = @fixture |> File.read!() |> Jason.decode!()

    assert Map.new(records, &{&1["id"], length(&1["proposals"])}) == @records
    assert Enum.all?(records, &(&1["status"] == "confirmed"))

    Enum.flat_map(records, & &1["proposals"])
  end

  describe "the declared questions" do
    test "are the seventeen confirmed entries, rendered verbatim, at version 1 on winnow_gpu" do
      entries = confirmed()
      declared = Info.questions(CodeUnit)
      landed = @source |> File.read!() |> question_bodies()

      assert Enum.map(declared, &Atom.to_string(&1.name)) == Enum.map(entries, & &1["name"])
      assert Enum.map(declared, & &1.name) == Questions.names()

      for entry <- entries do
        question = Info.question(CodeUnit, String.to_existing_atom(entry["name"]))

        # The declaration is to_dsl's rendering of the confirmed entry, as
        # code; the one addition is the projection, the block's last line.
        rendered =
          entry
          |> Map.put("profile", "winnow_gpu")
          |> QuestionProposal.to_dsl(CodeUnit)
          |> question_bodies()

        [projection | body] = Enum.reverse(Map.fetch!(landed, question.name))

        assert Enum.reverse(body) == Map.fetch!(rendered, question.name),
               "#{entry["name"]} is not to_dsl's rendering"

        assert {:state_projection, _, [_module]} = projection

        assert question.instructions == entry["instructions"]
        assert stringify(question.criteria) == entry["criteria"]
        assert question.version == 1
        assert question.profile == :winnow_gpu
        assert Atom.to_string(question.family) == entry["family"]

        if options = entry["options"] do
          assert Enum.map(question.constraints[:of], &Atom.to_string/1) == options
        end
      end
    end

    test "the house-style hashes equal the confirmed hashes, and the lock holds every question" do
      entries = Map.new(confirmed(), &{&1["name"], &1})
      lock = @lock_file |> File.read!() |> Jason.decode!()

      for question <- Info.questions(CodeUnit) do
        entry = Map.fetch!(entries, Atom.to_string(question.name))

        if hash = entry["question_hash"] do
          assert question.question_hash == hash
        end

        assert question.state_contract == nil
        assert lock[question.question_id] == %{"hash" => question.question_hash, "version" => 1}
      end

      assert Enum.count(entries, fn {_name, entry} -> entry["question_hash"] end) == 9
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
