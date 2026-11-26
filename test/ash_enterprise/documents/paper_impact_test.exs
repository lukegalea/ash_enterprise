defmodule AshEnterprise.Documents.PaperImpactTest do
  @moduledoc """
  R4: a clause version or a clause table version shows what it would do to
  documents already issued before a second person admits or publishes it.
  SYNTHETIC rows only, seeded the way the other paper tests seed them. Every errored, missing, stale or failed report refuses the decision;
  a run that cannot be baselined is never counted unchanged.
  """

  use AshEnterprise.DataCase, async: true

  import AshEnterprise.Test.DailyFixtures, only: [tenant!: 0, member!: 3]
  import ExUnit.CaptureIO

  alias AshEnterprise.Decisions
  alias AshEnterprise.Decisions.{Definition, Evaluation}
  alias AshEnterprise.Documents
  alias AshEnterprise.Documents.Paper
  alias AshEnterprise.Documents.Paper.Impact
  alias AshEnterprise.Documents.PaperClause
  alias AshEnterprise.Erasure
  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.Test.Paper.ClauseTables
  alias AshEnterprise.Test.{PaperEntries, PaperFacts, PaperSamples}

  @moduletag :evidence

  @title "Activity summary 2025"
  @key "hazard_note"
  @decision_key "paper.clause." <> @key
  @block "clause:" <> @key

  @original "Hazard follow-up explained."
  @revised "Revised hazard follow-up wording."

  @checker_grants [
    {PaperClause, :create, :global},
    {PaperClause, :read, :global},
    {PaperClause, :write, :global}
  ]

  # Three documents' rows: two Hazard years with different amounts, one without.
  @hazard_40 2025
  @hazard_75 2024
  @groceries 2023

  setup do
    admin = tenant!()

    PaperEntries.seed!(admin, [
      {"a", "2025-01-02", "-20", "Groceries"},
      {"b", "2025-07-15", "-40", "Hazard"},
      {"c", "2024-01-02", "-20", "Groceries"},
      {"d", "2024-07-15", "-75", "Hazard"},
      {"e", "2023-01-02", "-20", "Groceries"},
      {"f", "2023-03-04", "-5.50", "Groceries"}
    ])

    admit_clause(admin)
    bind(admin)
    {:ok, admin: admin}
  end

  describe "a clause text candidate" do
    test "changes exactly the clause block of the runs that carry it, and the checker admits",
         %{admin: admin} do
      run_a = issue!(admin, @hazard_40)
      run_b = issue!(admin, @hazard_75)
      _no_clause = issue!(admin, @groceries)

      checker = checker!(admin)
      draft = draft_clause(admin, revised_runs())
      measured = measure!(draft, checker, admin)
      report = measured.impact_report

      assert report["error"] == nil

      assert report["counts"] == %{
               "changed" => 2,
               "unchanged" => 0,
               "unreproducible" => 0,
               "failed" => 0
             }

      assert report["collateral"] == 0
      assert report["sample"] == %{"taken" => 2, "cap" => 50, "truncated" => false}
      assert report["candidate"]["content_hash"] == draft.content_hash

      assert Enum.sort(Enum.map(report["cases"], & &1["run_id"])) ==
               Enum.sort([run_a.id, run_b.id])

      for c <- report["cases"] do
        assert c["outcome"] == "changed"
        assert c["collateral"] == []
        assert [%{"block" => @block, "page_before" => 1, "page_after" => 1}] = c["blocks"]
        assert %{"blocks" => [[@original, @revised]], "title" => @title} = Impact.opened(c)
      end

      # The stored report keeps no document text in the clear.
      refute inspect(report) =~ @revised

      # The surface's rows: the changed block, before and after.
      rows = Documents.paper_clause_impact_changes!(actor: checker.actor, tenant: admin.tenant)
      assert length(rows) == 2

      assert Enum.all?(rows, &match?(%{block: @block, before: @original, after: @revised}, &1))

      assert {:ok, admitted} =
               Documents.admit_paper_clause(measured, actor: checker.actor, tenant: admin.tenant)

      assert admitted.status == :admitted
    end

    test "zero affected runs is a measured report, and admits", %{admin: admin} do
      checker = checker!(admin)
      measured = admin |> draft_clause(revised_runs()) |> measure!(checker, admin)

      assert measured.impact_report["cases"] == []
      assert measured.impact_report["counts"]["changed"] == 0
      assert {:ok, _admitted} = admit(measured, checker, admin)
    end
  end

  describe "the admit gate refuses" do
    test "with no report", %{admin: admin} do
      checker = checker!(admin)
      draft = draft_clause(admin, revised_runs())

      assert refusal(admit(draft, checker, admin)) =~ "no impact report"
    end

    test "with a report measured for an older candidate hash", %{admin: admin} do
      issue!(admin, @hazard_40)
      checker = checker!(admin)
      older = admin |> draft_clause(revised_runs()) |> measure!(checker, admin)

      newer = draft_clause(admin, [%{"kind" => "text", "value" => "Newer wording again."}])

      # The older version's report, carried onto the newer one.
      carried =
        newer
        |> Ash.Changeset.for_update(:measure_impact, %{},
          actor: checker.actor,
          tenant: admin.tenant
        )
        |> Ash.Changeset.force_change_attribute(:impact_report, older.impact_report)
        |> Ash.update!(authorize?: false)

      assert carried.impact_report["candidate"]["content_hash"] != carried.content_hash
      assert refusal(admit(carried, checker, admin)) =~ "measured for another version"
    end

    test "with a failed case", %{admin: admin} do
      issue!(admin, @hazard_40)
      checker = checker!(admin)

      unfillable = [
        %{"kind" => "text", "value" => "Claimed under "},
        %{"kind" => "hole", "value" => "no_such_field"}
      ]

      measured = admin |> draft_clause(unfillable) |> measure!(checker, admin)

      assert measured.impact_report["counts"]["failed"] == 1

      assert [%{"outcome" => "failed", "reason_kind" => "clause_unresolved"}] =
               measured.impact_report["cases"]

      assert refusal(admit(measured, checker, admin)) =~ "failed to render or read back"
    end

    test "with an errored report", %{admin: admin} do
      checker = checker!(admin)
      draft = draft_clause(admin, revised_runs())

      errored =
        draft
        |> Ash.Changeset.for_update(:measure_impact, %{},
          actor: checker.actor,
          tenant: admin.tenant
        )
        |> Ash.Changeset.force_change_attribute(:impact_report, %{
          "error" => "the renderer was unavailable",
          "candidate" => %{"content_hash" => draft.content_hash},
          "cases" => [],
          "counts" => %{}
        })
        |> Ash.update!(authorize?: false)

      assert refusal(admit(errored, checker, admin)) =~ "errored"
    end

    test "the maker, even with a clean report", %{admin: admin} do
      issue!(admin, @hazard_40)
      checker = checker!(admin)
      measured = admin |> draft_clause(revised_runs()) |> measure!(checker, admin)

      assert :ok = Impact.gate(measured.impact_report, measured.content_hash)

      message = refusal(admit(measured, %{actor: admin.actor}, admin))
      assert message =~ "may not admit"
      refute message =~ "impact"
    end
  end

  describe "what cannot be measured is never unchanged" do
    test "a run whose frozen payload was erased is unreproducible", %{admin: admin} do
      run = issue!(admin, @hazard_40)

      scope = Erasure.get_scope!(run.erasure_scope_id, authorize?: false)
      Erasure.shred_scope!(scope, scope.ref, "SYNTHETIC impact test", authorize?: false)

      checker = checker!(admin)
      measured = admin |> draft_clause(revised_runs()) |> measure!(checker, admin)

      assert measured.impact_report["counts"] == %{
               "changed" => 0,
               "unchanged" => 0,
               "unreproducible" => 1,
               "failed" => 0
             }

      assert [%{"run_id" => run_id, "outcome" => "unreproducible", "reason_kind" => "erased"}] =
               measured.impact_report["cases"]

      assert run_id == run.id
    end

    test "a cap smaller than the sample is said", %{admin: admin} do
      issue!(admin, @hazard_40)
      issue!(admin, @hazard_75)
      draft = draft_clause(admin, revised_runs())

      report = Impact.measure(draft, admin.tenant, cap: 1)

      assert report.sample == %{taken: 1, cap: 1, truncated: true}
      assert length(report.cases) == 1
      assert Impact.summary(Impact.stored(report), draft.content_hash) =~ "the cap cut the sample"
    end
  end

  describe "a clause table candidate" do
    test "a version that drops the clause for a category flips exactly the matching runs",
         %{admin: admin} do
      run_a = issue!(admin, @hazard_40)
      run_b = issue!(admin, @hazard_75)
      run_c = issue!(admin, @groceries)

      measured = admin |> draft_table(drops_hazard_xml()) |> measure_table!(admin.actor, admin)
      report = measured.impact_report

      assert report["error"] == nil

      assert report["counts"] == %{
               "gains" => 0,
               "loses" => 2,
               "reason_changed" => 0,
               "unchanged" => 1,
               "unreproducible" => 0,
               "failed" => 0
             }

      by_outcome = Enum.group_by(report["cases"], & &1["outcome"], & &1["run_id"])
      assert Enum.sort(by_outcome["loses"]) == Enum.sort([run_a.id, run_b.id])
      assert by_outcome["unchanged"] == [run_c.id]

      rows = Decisions.clause_table_impact_changes!(actor: admin.actor, tenant: admin.tenant)
      assert length(rows) == 2
      assert Enum.all?(rows, &(&1.outcome == "Loses the clause"))

      assert %Definition{status: :published} = Definition.publish!(measured, system(admin))
    end

    test "publishing refuses with no report, and with a stale one", %{admin: admin} do
      draft = draft_table(admin, drops_hazard_xml())

      assert_raise Ash.Error.Invalid, ~r/no impact report/, fn ->
        Definition.publish!(draft, system(admin))
      end

      measured = measure_table!(draft, admin.actor, admin)

      edited =
        Definition.save_xml!(
          measured,
          drops_hazard_xml("edited after measuring"),
          system(admin)
        )

      assert_raise Ash.Error.Invalid, ~r/measured for another version/, fn ->
        Definition.publish!(edited, system(admin))
      end
    end

    test "a reader without access to the tenant's evaluations replays nothing", %{admin: admin} do
      issue!(admin, @hazard_40)

      reader =
        member!(admin, "table-reader-#{System.unique_integer([:positive])}", [
          {Definition, :read, :global},
          {Definition, :write, :global}
        ])

      assert [] =
               AshDecisions.Replay.recorded(Definition, Evaluation, @decision_key,
                 actor: reader.actor,
                 tenant: admin.tenant
               )

      measured = admin |> draft_table(drops_hazard_xml()) |> measure_table!(reader.actor, admin)

      assert measured.impact_report["cases"] == []
      assert measured.impact_report["error"] =~ "may not read every recorded evaluation"

      assert_raise Ash.Error.Invalid, ~r/impact: the impact report errored/, fn ->
        Definition.publish!(measured, system(admin))
      end
    end
  end

  describe "a layout candidate (mix paper.impact)" do
    test "the host's own layout changes nothing in the fixtures" do
      report = layout_report(Paper.layout())

      # Fixtures record no digest: compared, never counted changed or unchanged.
      assert report.counts == %{
               changed: 0,
               unchanged: 0,
               unrecorded: 3,
               unreproducible: 0,
               failed: 0
             }

      assert Enum.all?(report.cases, &(&1.outcome == :unchanged and &1.baseline == :unrecorded))
    end

    test "the letter before it printed clauses fails exactly the fixtures that carry one" do
      source = String.replace(letter_source(), "#paper-clauses()\n", "")
      older = AshPaper.Layout.compile!(:letter, 1, source)
      report = layout_report(older)

      # A clause the document carries but the layout does not print fails the
      # read-back: a document that could not be issued, never "unchanged".
      assert report.counts == %{
               changed: 0,
               unchanged: 0,
               unrecorded: 1,
               unreproducible: 0,
               failed: 2
             }

      failed = for %{outcome: :failed} = c <- report.cases, do: c.id
      assert Enum.sort(failed) == ["hazard-carlito", "many-rows-maplestone"]
      assert Enum.all?(report.cases, &(&1.outcome != :failed or elem(&1.reason, 0) == :read_back))
    end

    test "the task prints the report for a layout module" do
      output =
        capture_io(fn ->
          Mix.Tasks.Paper.Impact.run(["--layout", "AshEnterprise.Documents.Paper.Letter"])
        end)

      assert output =~ "paper.impact: layout letter"
      assert output =~ "changed 0, unchanged 0, unrecorded 3, unreproducible 0, failed 0"
    end
  end

  defp layout_report(layout) do
    {:ok, report} =
      AshPaper.Compare.report(
        PaperSamples.samples(),
        [layout: layout],
        [allow_unrecorded: true] ++ PaperSamples.limits()
      )

    report
  end

  # ── fixtures and helpers ────────────────────────────────────────────────

  @doc false
  def __probe_setup__(admin),
    do:
      (
        admit_clause(admin)
        bind(admin)
      )

  @doc false
  def __probe_issue__(admin), do: issue!(admin, @hazard_40)

  defp letter_source, do: Paper.layout().__paper_layout__().source

  defp checker!(admin),
    do: member!(admin, "paper-clerk-#{System.unique_integer([:positive])}", @checker_grants)

  defp system(admin), do: [actor: SystemActor.process(), tenant: admin.tenant]

  defp admit_clause(admin) do
    checker = checker!(admin)

    admin
    |> draft_clause([%{"kind" => "text", "value" => @original}])
    |> measure!(checker, admin)
    |> admit(checker, admin)
    |> then(fn {:ok, admitted} -> admitted end)
  end

  defp draft_clause(admin, runs) do
    Documents.draft_paper_clause!(@key, :en, %{runs: runs},
      actor: admin.actor,
      tenant: admin.tenant
    )
  end

  defp measure!(clause, checker, admin),
    do: Documents.measure_paper_clause_impact!(clause, actor: checker.actor, tenant: admin.tenant)

  defp admit(clause, who, admin),
    do: Documents.admit_paper_clause(clause, actor: who.actor, tenant: admin.tenant)

  defp refusal({:error, %Ash.Error.Invalid{errors: errors}}),
    do: Enum.map_join(errors, "; ", &Map.get(&1, :message, ""))

  defp revised_runs, do: [%{"kind" => "text", "value" => @revised}]

  defp draft_table(admin, xml) do
    Definition
    |> Ash.Changeset.for_create(
      :create,
      %{key: @decision_key, name: @key, xml: xml},
      system(admin)
    )
    |> Ash.create!()
  end

  defp measure_table!(definition, actor, admin),
    do: Decisions.measure_definition_impact!(definition, actor: actor, tenant: admin.tenant)

  # The tenant's table with the Hazard rule answering out: the clause leaves
  # every Hazard document, and the rest keep their answer.
  defp drops_hazard_xml(why \\ "the note no longer goes in") do
    ClauseTables.xml(@key)
    |> String.replace(
      ~s(<outputEntry id="oe_hazard"><text>true</text></outputEntry>),
      ~s(<outputEntry id="oe_hazard"><text>false</text></outputEntry>)
    )
    |> String.replace(
      "Hazard entries this year: the hazard note explains the follow-up.",
      "Hazard entries this year: #{why}."
    )
  end

  defp bind(admin) do
    ClauseTables.publish!(admin.tenant, @key)
    {:ok, schema, _layout, _theme} = Paper.definition("activity_summary")

    Documents.bind_paper!(
      "activity_summary",
      Paper.binding_purpose(),
      %{
        selection: Paper.selection(schema, Paper.layout(), Paper.theme("carlito"), admin.tenant),
        backend_profile_hash: AshPaper.Binding.backend_profile_hash(%{"typst" => "pinned"})
      },
      actor: admin.actor,
      tenant: admin.tenant
    )
  end

  defp issue!(admin, year) do
    subject = PaperEntries.subject(year)
    PaperFacts.answer_all!(admin, "activity_summary", subject, @title)

    assert {:ok, run} =
             Documents.issue_paper_run("activity_summary", subject, @title,
               actor: admin.actor,
               tenant: admin.tenant
             )

    assert run.read_back_status == :passed
    run
  end
end
