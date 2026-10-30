defmodule AshEnterprise.Standards.StandingTest do
  @moduledoc """
  AST-138: the standards standing job (assess, judge, admit) and the
  advisory review comment, over a synthetic checkout.

  The judge path is the real one (generated judge action, host judge
  context, ledger recorder, banding step, facts materialiser) with the
  model replaced by `FakeReqLLM` and the band table by a stub resolver, so
  the test makes no model call and needs no published band table. The
  checkout's code and prose are synthetic.
  """

  use AshEnterprise.DataCase, async: false

  import ExUnit.CaptureIO

  require Ash.Query

  alias AshAgentTools.Laws
  alias AshEnterprise.Platform.Correlation
  alias AshEnterprise.Standards.{Review, Standing}
  alias AshEnterprise.SystemOne.Fact
  alias AshEnterprise.SystemOne.Judgment
  alias AshEnterprise.SystemOne.TestSupport.FakeReqLLM

  @questions [:policy_check_never_queries, :handle_event_authorizes, :hs6_no_novelty_claims]

  setup do
    Correlation.start_new()
    System.put_env("S1_OLLAYA_GPU_BASE_URL", "http://127.0.0.1:11435")
    System.put_env("OLLAYA_API_KEY", "local-test-only")
    FakeReqLLM.reset_calls()

    on_exit(fn ->
      System.delete_env("S1_OLLAYA_GPU_BASE_URL")
      System.delete_env("OLLAYA_API_KEY")
    end)

    root = checkout!()
    repository = "standards-#{System.unique_integer([:positive])}"

    %{
      root: root,
      tenant: Ash.UUID.generate(),
      opts: [repository: repository, questions: @questions, paths: ["lib", "docs"]]
    }
  end

  describe "the standing job" do
    test "assess finds every candidate without a fact, and nothing else", %{
      root: root,
      opts: opts
    } do
      assert pending_names(Standing.assess(root, opts)) == %{
               policy_check_never_queries: [
                 "Demo.TeamCheck.describe/1",
                 "Demo.TeamCheck.match?/3"
               ],
               handle_event_authorizes: ["DemoWeb.PageLive.handle_event/3"],
               hs6_no_novelty_claims: ["Guide[1]"]
             }

      assert FakeReqLLM.calls() == 0
    end

    test "run judges, records and admits each candidate; a re-run finds nothing to do", %{
      root: root,
      tenant: tenant,
      opts: opts
    } do
      results = Standing.run(root, run_opts(opts, tenant))

      assert length(results) == 4
      assert Enum.all?(results, &match?({:ok, %{band: :admit}}, &1.result))
      assert FakeReqLLM.calls() == 4

      # Each answer is a ledger row under the code unit's subject term.
      rows = Ash.read!(Judgment, tenant: tenant, authorize?: false)
      assert length(rows) == 4
      assert Enum.all?(rows, &(&1.subject_type == "AshEnterprise.Standards.CodeUnit"))

      assert MapSet.new(rows, & &1.id) == MapSet.new(results, & &1.observation_id)

      # Each admitted fact carries the unit's digest, so it reads as current.
      [handler] = Enum.filter(results, &(&1.question == :handle_event_authorizes))
      [fact] = facts(handler.subject_id)
      assert fact.subject_type == "AshEnterprise.Standards.CodeUnit"
      assert fact.value == false
      assert fact.holds == false

      assert pending_names(Standing.assess(root, opts)) == %{
               policy_check_never_queries: [],
               handle_event_authorizes: [],
               hs6_no_novelty_claims: []
             }

      # Editing a unit makes its fact stale; only that unit is judged again.
      write!(root, "lib/demo/team_check.ex", team_check("actor.context.team_ids != []"))

      assert %{policy_check_never_queries: [{subject, :stale}]} = Standing.assess(root, opts)
      assert subject.name_path == "Demo.TeamCheck.match?/3"
    end

    test "the filters: statuses per unit, and the units that break their standard", %{
      root: root,
      tenant: tenant,
      opts: opts
    } do
      Standing.run(root, run_opts(opts, tenant))

      assert root
             |> Standing.statuses(:handle_event_authorizes, opts)
             |> Enum.map(fn {unit, status} -> {unit.name_path, status} end) == [
               {"DemoWeb.PageLive.handle_event/3", :out}
             ]

      assert root
             |> Standing.violations(opts)
             |> Enum.map(&{&1.question, &1.subject.location}) == [
               {:handle_event_authorizes, "lib/demo_web/live/page_live.ex:4"}
             ]
    end

    test "a candidate is found however many other units sort before it", %{
      root: root,
      opts: opts
    } do
      # More units than the facts query's default cap (100), all sorting
      # before the check module and none of them candidates.
      filler = Enum.map_join(1..150, "\n", &"  def f#{&1}(x), do: x")
      write!(root, "lib/aaa/filler.ex", "defmodule Aaa.Filler do\n#{filler}\nend\n")

      assert %{policy_check_never_queries: pending} =
               Standing.assess(root, Keyword.put(opts, :questions, [:policy_check_never_queries]))

      assert pending |> Enum.map(fn {s, _} -> s.name_path end) |> Enum.sort() == [
               "Demo.TeamCheck.describe/1",
               "Demo.TeamCheck.match?/3"
             ]
    end

    test "a family with no published band table admits nothing", %{
      root: root,
      tenant: tenant,
      opts: opts
    } do
      opts = Keyword.put(opts, :questions, [:hs6_no_novelty_claims])

      [result] =
        Standing.run(root,
          repository: opts[:repository],
          questions: opts[:questions],
          paths: opts[:paths],
          tenant: tenant,
          judgments: %{req_llm: FakeReqLLM}
        )

      assert {:error, _reason} = result.result
      assert facts(result.subject_id) == []
      assert [{_unit, {:unknown, _}}] = Standing.statuses(root, :hs6_no_novelty_claims, opts)
    end
  end

  describe "units too large to judge" do
    test "are reported as :context_too_large, never judged, and read unknown", %{
      root: root,
      tenant: tenant,
      opts: opts
    } do
      write!(root, "lib/demo_web/live/big_live.ex", big_live())

      pending = Standing.assess(root, opts)

      assert {big, :context_too_large} =
               Enum.find(pending.handle_event_authorizes, fn {s, _} ->
                 s.path == "lib/demo_web/live/big_live.ex"
               end)

      assert big.name_path == "DemoWeb.BigLive.handle_event/3"
      refute big.id =~ "~chunk"

      # :limit counts judgeable units only.
      limited = Standing.assess(root, Keyword.put(opts, :limit, 1))

      assert limited.handle_event_authorizes
             |> Enum.map(fn {s, reason} -> {s.name_path, reason} end)
             |> Enum.sort() == [
               {"DemoWeb.BigLive.handle_event/3", :context_too_large},
               {"DemoWeb.PageLive.handle_event/3", :no_fact}
             ]

      results = Standing.run(root, run_opts(opts, tenant))

      assert [skipped] = Enum.filter(results, &(&1.subject_id == big.id))
      assert skipped.result == {:skipped, :context_too_large}
      assert skipped.reason == :context_too_large
      assert skipped.observation_id == nil

      # The four judgeable units are judged; the oversized one is not.
      assert length(results) == 5
      assert FakeReqLLM.calls() == 4

      rows = Ash.read!(Judgment, tenant: tenant, authorize?: false)
      assert length(rows) == 4
      assert facts(big.id) == []

      assert {_unit, {:unknown, [:context_too_large]}} =
               root
               |> Standing.statuses(:handle_event_authorizes, opts)
               |> Enum.find(fn {unit, _} -> unit.id == big.id end)
    end

    test "standing --dry-run lists them with their reason", %{root: root, opts: opts} do
      write!(root, "lib/demo_web/live/big_live.ex", big_live())

      output =
        capture_io(fn ->
          Mix.Tasks.AshEnterprise.Standards.Standing.run([
            root,
            "--dry-run",
            "--repository",
            opts[:repository],
            "--question",
            "handle_event_authorizes"
          ])
        end)

      assert %{"pending" => %{"handle_event_authorizes" => pending}} = Jason.decode!(output)
      assert pending["count"] == 2

      assert %{
               "location" => "lib/demo_web/live/big_live.ex:" <> _,
               "reason" => "context_too_large"
             } =
               Enum.find(pending["units"], &(&1["reason"] == "context_too_large"))

      assert FakeReqLLM.calls() == 0
    end

    test "the review reports a touched one as unknown, never judged or admitted", %{
      root: root,
      opts: opts
    } do
      source = big_live()
      write!(root, "lib/demo_web/live/big_live.ex", source)

      diff = added_diff("lib/demo_web/live/big_live.ex", source)
      review = Review.review(root, diff, Keyword.take(opts, [:repository, :questions]))

      assert [finding] = review.advisory
      assert finding.standard == "std-law-11-authorize-handle-event"
      assert finding.location =~ "lib/demo_web/live/big_live.ex:"
      assert finding.status == {:unknown, :context_too_large}
      refute finding.admitted?

      assert review.markdown =~
               "std-law-11-authorize-handle-event: unknown (:context_too_large)"

      assert FakeReqLLM.calls() == 0
    end
  end

  describe "this checkout" do
    # One question per code projection, two of them ADR 0038's. Each takes
    # about 5 s over this checkout; a question asked about every doc
    # paragraph or every commented function takes over 15 s, so the full
    # run belongs to `standing --dry-run`.
    @self_questions [
      :policy_check_calls_no_model,
      :actor_context_build_calls_no_model,
      :third_party_api_wrapped
    ]

    @tag timeout: 120_000
    test "assess over the real code completes, with no model call" do
      root = Path.expand("../../..", __DIR__)
      repository = "standards-self-#{System.unique_integer([:positive])}"

      pending = Standing.assess(root, repository: repository, questions: @self_questions)

      assert pending |> Map.keys() |> Enum.sort() == Enum.sort(@self_questions)

      for {_name, units} <- pending, {_subject, reason} <- units do
        assert reason in [:no_fact, :context_too_large]
      end

      assert pending.policy_check_calls_no_model != []
      assert pending.actor_context_build_calls_no_model != []
      assert FakeReqLLM.calls() == 0
    end
  end

  describe "the advisory review" do
    test "carries the laws judge's report unchanged and each touched candidate's fact", %{
      root: root,
      tenant: tenant,
      opts: opts
    } do
      Standing.run(root, run_opts(opts, tenant))

      diff =
        added_diff(
          "lib/demo_web/live/page_live.ex",
          File.read!(Path.join(root, "lib/demo_web/live/page_live.ex"))
        )

      review = Review.review(root, diff, Keyword.take(opts, [:repository, :questions]))

      assert Jason.encode!(review.laws) == Jason.encode!(Laws.judge(diff, diff?: true))

      assert [finding] = review.advisory
      assert finding.standard == "std-law-11-authorize-handle-event"
      assert finding.location == "lib/demo_web/live/page_live.ex:4"
      assert finding.admitted?
      assert {:out, _fact} = finding.status
      assert finding.rung == :system_one

      assert review.markdown =~ "### Standards (System One, advisory: not a gate)"

      assert review.markdown =~
               "- `lib/demo_web/live/page_live.ex:4` std-law-11-authorize-handle-event: admitted fact, out"

      # Without findings, the deterministic section is byte-identical.
      without = Review.review(root, diff, repository: "nothing-judged", questions: @questions)
      assert deterministic(without.markdown) == deterministic(review.markdown)
    end

    test "a unit the change edits reads unknown until the standing job judges it", %{
      root: root,
      tenant: tenant,
      opts: opts
    } do
      Standing.run(root, run_opts(opts, tenant))
      write!(root, "docs/guide.md", guide("It is a groundbreaking, first ever approach."))

      diff = added_diff("docs/guide.md", File.read!(Path.join(root, "docs/guide.md")))
      review = Review.review(root, diff, Keyword.take(opts, [:repository, :questions]))

      assert [%{standard: "std-hs-6", admitted?: false, status: {:unknown, :stale}}] =
               review.advisory
    end
  end

  describe "the Mix tasks" do
    test "standing --dry-run prints the pending units as JSON, with no model call", %{
      root: root,
      opts: opts
    } do
      output =
        capture_io(fn ->
          Mix.Tasks.AshEnterprise.Standards.Standing.run([
            root,
            "--dry-run",
            "--repository",
            opts[:repository],
            "--question",
            "handle_event_authorizes"
          ])
        end)

      assert %{"pending" => %{"handle_event_authorizes" => pending}} = Jason.decode!(output)

      assert pending == %{
               "count" => 1,
               "units" => [
                 %{"location" => "lib/demo_web/live/page_live.ex:4", "reason" => "no_fact"}
               ]
             }

      assert FakeReqLLM.calls() == 0
    end

    test "standing refuses an unknown question name", %{root: root} do
      assert_raise Mix.Error, ~r/unknown question "everything"/, fn ->
        Mix.Tasks.AshEnterprise.Standards.Standing.run([
          root,
          "--dry-run",
          "--question",
          "everything"
        ])
      end
    end

    test "review prints the comment for the change between a base and HEAD", %{root: root} do
      git!(root, ["init", "--quiet"])
      commit!(root, "base")
      write!(root, "docs/guide.md", guide("It is the first ever approach."))
      commit!(root, "change")

      output =
        capture_io(fn ->
          Mix.Tasks.AshEnterprise.Standards.Review.run([root, "--base", "HEAD~1"])
        end)

      assert output =~ "### Iron laws (deterministic)"
      assert output =~ "- `docs/guide.md:5` std-hs-6: unknown (:no_fact)"
    end
  end

  # -- helpers ------------------------------------------------------------------

  defp commit!(root, message) do
    git!(root, ["add", "-A"])

    git!(root, [
      "-c",
      "user.name=t",
      "-c",
      "user.email=t@example.test",
      "commit",
      "--quiet",
      "-m",
      message
    ])
  end

  defp git!(root, args) do
    {output, 0} = System.cmd("git", ["-C", root | args], stderr_to_stdout: true)
    output
  end

  defp run_opts(opts, tenant) do
    Keyword.merge(opts,
      tenant: tenant,
      judgments: %{req_llm: FakeReqLLM},
      resolver: &band_table/3
    )
  end

  # The stub band table: admits every answer, with the value the test wants
  # per family, so one unit (the event handler) is a violation.
  defp band_table("authorization", _tenant, _inputs), do: admit(false)
  defp band_table(_family, _tenant, _inputs), do: admit(true)

  defp admit(value) do
    {:ok,
     %{
       band_table: %{
         "definition_key" => "judgments_band_standards",
         "definition_version" => "1",
         "content_hash" => "sha256:" <> String.duplicate("c", 64),
         "definition_id" => Ash.UUID.generate(),
         "tenant_fork" => nil
       },
       outputs: %{"band" => "admit", "fact_value" => value},
       matched_rule_ids: ["DecisionRule_1"],
       decision_evaluation_id: Ash.UUID.generate()
     }}
  end

  defp facts(subject_id) do
    Fact
    |> Ash.Query.filter(subject_id == ^subject_id)
    |> Ash.read!(authorize?: false)
  end

  defp pending_names(by_question) do
    Map.new(by_question, fn {name, pending} ->
      {name, pending |> Enum.map(fn {subject, _reason} -> subject.name_path end) |> Enum.sort()}
    end)
  end

  defp deterministic(markdown), do: markdown |> String.split("### Standards") |> hd()

  defp added_diff(path, source) do
    lines = String.split(source, "\n")

    "--- /dev/null\n+++ b/#{path}\n@@ -0,0 +1,#{length(lines)} @@\n" <>
      Enum.map_join(lines, "\n", &("+" <> &1))
  end

  defp checkout! do
    root = Path.join(System.tmp_dir!(), "standards_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)

    write!(root, "lib/demo/team_check.ex", team_check("actor.context.team_id != nil"))

    write!(root, "lib/demo_web/live/page_live.ex", """
    defmodule DemoWeb.PageLive do
      use DemoWeb, :live_view

      def handle_event("save", params, socket), do: {:noreply, assign(socket, :p, params)}
    end
    """)

    write!(root, "docs/guide.md", guide("It is a groundbreaking approach."))
    root
  end

  # A LiveView whose module header alone (its alias lines) is larger than
  # the default 7,168-token budget: its handle_event/3 cannot be chunked.
  defp big_live do
    aliases =
      Enum.map_join(1..600, "\n", fn n ->
        "  alias DemoWeb.Components.Generated.Widget#{n}.Implementation, as: W#{n}"
      end)

    """
    defmodule DemoWeb.BigLive do
      use DemoWeb, :live_view
    #{aliases}

      def handle_event("go", _params, socket), do: {:noreply, socket}
    end
    """
  end

  defp team_check(body) do
    """
    defmodule Demo.TeamCheck do
      use Ash.Policy.SimpleCheck

      def describe(_), do: "member of the team"
      def match?(actor, _context, _opts), do: #{body}
    end
    """
  end

  defp guide(second) do
    "# Guide\n\nThis guide says how to run the standing job.\n\n#{second}\n"
  end

  defp write!(root, path, content) do
    full = Path.join(root, path)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, content)
  end
end
