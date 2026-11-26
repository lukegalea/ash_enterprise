defmodule AshEnterprise.Documents.PaperClauseTest do
  @moduledoc """
  The clauses lane: wording is tenant data, a DMN table says whether each
  candidate clause is in an issued document and why, the binding pins the
  admitted version, and the run records the rule's own words. SYNTHETIC
  content only — the person's rows are seeded entries the `activity_summary`
  kind reads back, the way `AshEnterprise.Documents.PaperTest` does. Every refusal is visible on the
  run, never a pass.
  """

  use AshEnterprise.DataCase, async: true

  require Ash.Query

  import AshEnterprise.Test.DailyFixtures, only: [tenant!: 0, member!: 3]

  alias AshEnterprise.Decisions.{Definition, Evaluation}
  alias AshEnterprise.Documents
  alias AshEnterprise.Documents.Paper
  alias AshEnterprise.Documents.PaperClause
  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.Process.{Binding, Resolver}
  alias AshEnterprise.Test.Paper.ClauseTables
  alias AshEnterprise.Test.{PaperEntries, PaperFacts}

  @moduletag :evidence

  @title "Activity summary 2025"
  @key "hazard_note"
  @decision_key "paper.clause." <> @key
  @hazard_reason "Hazard entries this year: the hazard note explains the follow-up."

  # Maker-checker's second pair of eyes: a member granted on clauses alone.
  # The role name is unique per call — a role belongs to the tenant's root
  # unit and two members cannot share one name.
  @checker_grants [
    {PaperClause, :create, :global},
    {PaperClause, :read, :global},
    {PaperClause, :write, :global}
  ]

  defp checker_role_name, do: "paper-clerk-#{System.unique_integer([:positive])}"

  # The years the seeded rows are about: one with a Hazard entry, one without.
  @hazard_year 2025
  @groceries_year 2023

  setup do
    admin = tenant!()

    PaperEntries.seed!(admin, [
      {"a", "2025-01-02", "-20", "Groceries"},
      {"b", "2025-07-15", "-40", "Hazard"},
      {"c", "2023-01-02", "-20", "Groceries"},
      {"d", "2023-03-04", "-5.50", "Groceries"}
    ])

    {:ok, admin: admin}
  end

  describe "selection at issue" do
    test "a Hazard year issues with the clause, and the run carries the rule's words", %{
      admin: admin
    } do
      clause = admit_clause(admin)
      bind(admin)

      run = issue!(admin, @hazard_year)

      assert run.render_status == :rendered
      assert run.read_back_status == :passed
      assert run.problems == []

      assert [%{"key" => @key} = reason] = run.clause_reasons

      assert %{
               "locale" => "en",
               "version" => version,
               "content_hash" => content_hash,
               "decision_key" => @decision_key,
               "decision_version" => 1,
               "rule_id" => "rule_hazard_expenses",
               "reason" => @hazard_reason
             } = reason

      assert version == clause.version
      assert content_hash == clause.content_hash

      # The snapshot pins the same wording and the decision that put it there:
      # one read of the run answers "why is this clause here".
      snapshot = run.snapshot["snapshot"]

      assert %{"kind" => "clause", "key" => "#{@key}/en"} =
               pinned = definition_of(snapshot, "clause")

      assert pinned["content_hash"] == clause.content_hash

      assert %{"kind" => "dmn", "key" => @decision_key, "version" => "1"} =
               definition_of(snapshot, "dmn")

      assert %{
               "key" => @decision_key,
               "role" => "decision",
               "status" => "value",
               "source" => %{"id" => evaluation_id}
             } = input_of(snapshot)

      # The input is the evaluation row the decision wrote, correlated with
      # this run: what the table saw and which rule answered.
      evaluation = evaluation!(admin, evaluation_id)
      assert evaluation.correlation_id == run.id
      assert evaluation.matched_rule_ids == ["rule_hazard_expenses"]
      assert evaluation.outputs == %{"value" => true}
    end

    test "a year without Hazard issues without the clause: an explicit rule says exclude", %{
      admin: admin
    } do
      admit_clause(admin)
      bind(admin)

      run = issue!(admin, @groceries_year)

      assert run.render_status == :rendered
      assert run.read_back_status == :passed
      assert run.clause_reasons == []

      # The exclusion is still evidence: the decision ran, and the snapshot
      # says the table was consulted and answered out.
      snapshot = run.snapshot["snapshot"]
      assert %{"kind" => "dmn", "key" => @decision_key} = definition_of(snapshot, "dmn")
      refute definition_of(snapshot, "clause")

      assert %{"key" => @decision_key, "source" => %{"id" => evaluation_id}} = input_of(snapshot)
      evaluation = evaluation!(admin, evaluation_id)
      assert evaluation.correlation_id == run.id
      assert evaluation.matched_rule_ids == ["rule_no_hazard_expenses"]
      assert evaluation.outputs == %{"value" => false}
    end

    test "the same inputs twice issue the same bytes and the same reasons", %{admin: admin} do
      admit_clause(admin)
      bind(admin)

      run_a = issue!(admin, @hazard_year)
      run_b = issue!(admin, @hazard_year)

      assert run_a.output_digest == run_b.output_digest
      assert run_a.clause_reasons == run_b.clause_reasons
    end
  end

  describe "a document carries only the clauses its binding activated" do
    test "a tenant with no admitted clause and no clause table issues a Hazard year", %{
      admin: admin
    } do
      bind(admin, publish_table?: false)

      # Nothing is published for the key in this tenant: the table is absent.
      assert {:error, _unpublished} = Resolver.resolve(:decision, @decision_key, admin.tenant)

      run = issue!(admin, @hazard_year)

      assert run.render_status == :rendered
      assert run.read_back_status == :passed
      assert run.problems == []
      assert run.clause_reasons == []

      # No table was consulted: the binding pinned no clause, so no decision ran.
      snapshot = run.snapshot["snapshot"]
      refute definition_of(snapshot, "dmn")
      refute definition_of(snapshot, "clause")
      refute input_of(snapshot)
    end

    test "draft wording is never pinned, so the binding activates no clause", %{admin: admin} do
      draft_clause(admin)
      bind(admin)

      run = issue!(admin, @hazard_year)

      assert run.render_status == :rendered
      assert run.read_back_status == :passed
      assert run.clause_reasons == []
      refute definition_of(run.snapshot["snapshot"], "dmn")
    end

    test "a tenant that bound before admitting is stale after admitting", %{admin: admin} do
      bind(admin, publish_table?: false)
      admit_clause(admin)

      assert %Paper.Error{reason: {:binding_stale, _selection}} =
               unwrap(issue(admin, @hazard_year))

      assert [%{"kind" => "binding_stale"}] = failed_run(admin).problems

      # Rebound, the binding pins the clause and its table is required: with
      # none published the clause is undecided, never silently out.
      rebind(admin)

      assert %Paper.Error{reason: {:clause_undecided, @key}} =
               unwrap(issue(admin, @hazard_year))

      # With the table published the rebound tenant carries the clause.
      ClauseTables.publish!(admin.tenant, @key)

      run = issue!(admin, @hazard_year)
      assert run.read_back_status == :passed
      assert [%{"key" => @key, "reason" => @hazard_reason}] = run.clause_reasons
    end
  end

  describe "refusals, each one recorded on the run" do
    test "a missing decision input blocks the issue", %{admin: admin} do
      admit_clause(admin)
      bind(admin)
      publish_variant(admin.tenant, table_with_extra_input_xml())

      assert %Paper.Error{reason: {:missing_decision_input, @key, "region"}} =
               unwrap(issue(admin, @hazard_year))

      assert [%{"kind" => "missing_decision_input", "key" => @key, "detail" => "region"}] =
               failed_run(admin).problems
    end

    test "no matching rule leaves the clause undecided, and the issue blocked", %{admin: admin} do
      admit_clause(admin)
      bind(admin)
      publish_variant(admin.tenant, include_only_xml())

      assert %Paper.Error{reason: {:clause_undecided, @key}} =
               unwrap(issue(admin, @groceries_year))

      assert [%{"kind" => "clause_undecided", "key" => @key}] = failed_run(admin).problems
    end

    test "a UNIQUE violation blocks the issue", %{admin: admin} do
      admit_clause(admin)
      bind(admin)
      publish_variant(admin.tenant, overlapping_xml())

      assert %Paper.Error{reason: {:clause_decision_failed, @key, reason}} =
               unwrap(issue(admin, @hazard_year))

      assert inspect(reason) =~ ~r/unique/i

      run = failed_run(admin)

      assert [%{"kind" => "clause_decision_failed", "key" => @key} = problem] =
               Enum.filter(run.problems, &(&1["kind"] == "clause_decision_failed"))

      assert problem["detail"] =~ ~r/unique/i
    end

    test "a new admitted version makes the binding stale", %{admin: admin} do
      admit_clause(admin)
      bind(admin)

      checker = member!(admin, checker_role_name(), @checker_grants)
      admit_clause(admin, drafter: checker.actor, runs: revised_runs())

      assert %Paper.Error{reason: {:binding_stale, _selection}} =
               unwrap(issue(admin, @hazard_year))

      assert [%{"kind" => "binding_stale"}] = failed_run(admin).problems
    end

    test "a clause with no variant in the payload's locale blocks the issue", %{admin: admin} do
      admit_clause(admin, locale: :fr)
      bind(admin)

      assert %Paper.Error{reason: {:clause_not_pinned, @key, :en}} =
               unwrap(issue(admin, @hazard_year))

      assert [%{"kind" => "clause_not_pinned", "key" => @key, "detail" => "en"}] =
               failed_run(admin).problems
    end

    test "a hole the payload cannot fill blocks the issue", %{admin: admin} do
      admit_clause(admin,
        runs: [
          %{"kind" => "text", "value" => "Claimed under "},
          %{"kind" => "hole", "value" => "no_such_field"}
        ]
      )

      bind(admin)

      assert %Paper.Error{
               reason: {:clause_selection, [{:unfilled_holes, @key, ["no_such_field"]}]}
             } =
               unwrap(issue(admin, @hazard_year))

      assert [%{"kind" => "unfilled_holes", "key" => @key}] = failed_run(admin).problems
    end

    test "retiring the pinned version makes the binding stale", %{admin: admin} do
      clause = admit_clause(admin)
      bind(admin)

      Documents.retire_paper_clause!(clause, actor: admin.actor, tenant: admin.tenant)

      assert %Paper.Error{reason: {:binding_stale, _selection}} =
               unwrap(issue(admin, @hazard_year))

      assert [%{"kind" => "binding_stale"}] = failed_run(admin).problems
    end
  end

  describe "maker-checker" do
    test "the drafter may not admit their own clause", %{admin: admin} do
      clause = draft_clause(admin)

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Documents.admit_paper_clause(clause, actor: admin.actor, tenant: admin.tenant)

      assert Enum.any?(errors, fn error ->
               is_map(error) and Map.get(error, :message, "") =~ "may not admit"
             end)

      # A second pair of eyes can, once what it would change is measured.
      checker = member!(admin, checker_role_name(), @checker_grants)

      clause =
        Documents.measure_paper_clause_impact!(clause, actor: checker.actor, tenant: admin.tenant)

      assert {:ok, admitted} =
               Documents.admit_paper_clause(clause, actor: checker.actor, tenant: admin.tenant)

      assert admitted.status == :admitted
      assert admitted.admitted_by_id == checker.user.id
    end
  end

  describe "the publish gate" do
    test "a rule without a description is refused at publish", %{admin: admin} do
      assert publish_refused(admin.tenant, undescribed_rule_xml(), ~r/rule_description_missing/)
    end

    test "a non-UNIQUE table is refused at publish", %{admin: admin} do
      assert publish_refused(admin.tenant, any_hit_xml(), ~r/not_unique/)
    end
  end

  # ── fixtures and helpers ────────────────────────────────────────────────

  defp note_runs, do: [%{"kind" => "text", "value" => "Hazard follow-up explained."}]
  defp revised_runs, do: [%{"kind" => "text", "value" => "Revised hazard follow-up wording."}]

  # `admin` drafts; a member admits — maker-checker, exercised through the
  # grant model, not bypassed. `:drafter` flips who drafts (a new version by
  # the checker), and the admittance still needs a fresh second pair of eyes.
  defp admit_clause(admin, opts \\ []) do
    locale = Keyword.get(opts, :locale, :en)
    drafter = Keyword.get(opts, :drafter, admin.actor)
    runs = Keyword.get(opts, :runs, note_runs())
    checker = member!(admin, checker_role_name(), @checker_grants)

    clause =
      Documents.draft_paper_clause!(@key, locale, %{runs: runs},
        actor: drafter,
        tenant: admin.tenant
      )

    assert %PaperClause{status: :draft} = clause

    clause
    |> Documents.measure_paper_clause_impact!(actor: checker.actor, tenant: admin.tenant)
    |> Documents.admit_paper_clause!(actor: checker.actor, tenant: admin.tenant)
  end

  defp draft_clause(admin) do
    Documents.draft_paper_clause!(@key, :en, %{runs: note_runs()},
      actor: admin.actor,
      tenant: admin.tenant
    )
  end

  # Publishes the clause table too, unless `publish_table?: false`: a tenant
  # that never chose any wording has none.
  defp bind(admin, opts \\ []) do
    if Keyword.get(opts, :publish_table?, true), do: ClauseTables.publish!(admin.tenant, @key)

    Documents.bind_paper!(
      "activity_summary",
      Paper.binding_purpose(),
      %{selection: selection(admin, "carlito"), backend_profile_hash: profile_hash()},
      actor: admin.actor,
      tenant: admin.tenant
    )
  end

  defp rebind(admin) do
    binding =
      Documents.get_paper_binding_by_selector!(Paper.binding_selector("activity_summary"),
        actor: admin.actor,
        tenant: admin.tenant
      )

    Documents.rebind_paper!(
      binding,
      %{selection: selection(admin, "carlito"), backend_profile_hash: profile_hash()},
      actor: admin.actor,
      tenant: admin.tenant
    )
  end

  defp selection(admin, theme_name) do
    {:ok, schema, _layout, _theme} = Paper.definition("activity_summary")
    Paper.selection(schema, Paper.layout(), Paper.theme(theme_name), admin.tenant)
  end

  defp profile_hash, do: AshPaper.Binding.backend_profile_hash(%{"typst" => "pinned"})

  # A Hazard entry makes the requirement ask whether it was followed up; these
  # tests are about clauses, so it is answered first.
  defp issue(admin, year) do
    subject = PaperEntries.subject(year)
    PaperFacts.answer_all!(admin, "activity_summary", subject, @title)

    Documents.issue_paper_run("activity_summary", subject, @title,
      actor: admin.actor,
      tenant: admin.tenant
    )
  end

  defp issue!(admin, year) do
    assert {:ok, run} = issue(admin, year)
    run
  end

  defp unwrap({:error, %Paper.Error{} = error}), do: error

  defp unwrap({:error, class}) do
    assert [inner] = Enum.filter(class.errors, &match?(%Paper.Error{}, &1))
    inner
  end

  # The blocked issue's failed run, read back through the actor's own list.
  defp failed_run(admin) do
    assert {:ok, [run]} = Documents.my_paper_runs(actor: admin.actor, tenant: admin.tenant)
    assert run.render_status == :failed
    run
  end

  defp evaluation!(admin, id) do
    Evaluation
    |> Ash.Query.filter(id == ^id)
    |> Ash.read_one!(tenant: admin.tenant, authorize?: false)
  end

  defp definition_of(snapshot, kind),
    do: Enum.find(snapshot["definitions"], &(&1["kind"] == kind))

  defp input_of(snapshot),
    do: Enum.find(snapshot["inputs"], &(&1["key"] == @decision_key))

  # A variant table published as the next version of the same key and bound:
  # resolution reads what the tenant is bound to, which `bind` moves onto the
  # newest publish.
  defp publish_variant(tenant, xml) do
    opts = [actor: SystemActor.process(), tenant: tenant]

    definition =
      Definition
      |> Ash.Changeset.for_create(:create, %{key: @decision_key, name: @key, xml: xml}, opts)
      |> Ash.create!(opts)

    # Publishing rests on what the version would change (R4): measured first.
    published =
      definition
      |> AshEnterprise.Decisions.measure_definition_impact!(opts)
      |> Definition.publish!(opts)

    Binding.bind!(
      %{
        kind: :decision,
        key: @decision_key,
        source: :tenant,
        target_id: published.id,
        bound_version: published.version
      },
      opts
    )

    published
  end

  defp publish_refused(tenant, xml, expected) do
    opts = [actor: SystemActor.process(), tenant: tenant]

    definition =
      Definition
      |> Ash.Changeset.for_create(:create, %{key: @decision_key, name: @key, xml: xml}, opts)
      |> Ash.create!(opts)

    assert_raise Ash.Error.Invalid, expected, fn ->
      Definition.publish!(definition, opts)
    end
  end

  # ── variant tables ──────────────────────────────────────────────────────

  @year_requirement """
  <informationRequirement id="req_year">
    <requiredInput href="#input_year"/>
  </informationRequirement>
  """

  @categories_requirement """
  <informationRequirement id="req_categories">
    <requiredInput href="#input_categories"/>
  </informationRequirement>
  """

  # The canonical shape plus an input whose expression reads `region`, a name
  # `Paper.decision_inputs/2` never produces: the issue must refuse, naming it.
  defp table_with_extra_input_xml do
    requirements = @year_requirement <> @categories_requirement

    table(
      """
      <inputData id="input_year" name="year">
        <variable id="var_year" name="year"/>
      </inputData>
      <inputData id="input_categories" name="categories">
        <variable id="var_categories" name="categories"/>
      </inputData>
      <inputData id="input_region" name="region">
        <variable id="var_region" name="region"/>
      </inputData>
      """,
      requirements,
      """
      <input id="clause_year">
        <inputExpression id="expr_year"><text>year</text></inputExpression>
      </input>
      <input id="clause_hazard">
        <inputExpression id="expr_hazard" typeRef="boolean"><text>list contains(categories, "Hazard")</text></inputExpression>
      </input>
      <input id="clause_region">
        <inputExpression id="expr_region"><text>region</text></inputExpression>
      </input>
      """,
      """
      <rule id="rule_hazard_expenses">
        <description>Hazard entries this year: the hazard note explains the follow-up.</description>
        <inputEntry id="ie_hazard_year"><text>-</text></inputEntry>
        <inputEntry id="ie_hazard"><text>true</text></inputEntry>
        <inputEntry id="ie_hazard_region"><text>-</text></inputEntry>
        <outputEntry id="oe_hazard"><text>true</text></outputEntry>
      </rule>
      <rule id="rule_no_hazard_expenses">
        <description>No Hazard category in this year's totals: the hazard note stays out.</description>
        <inputEntry id="ie_none_year"><text>-</text></inputEntry>
        <inputEntry id="ie_none"><text>false</text></inputEntry>
        <inputEntry id="ie_none_region"><text>-</text></inputEntry>
        <outputEntry id="oe_none"><text>false</text></outputEntry>
      </rule>
      """
    )
  end

  # A single rule whose opaque cell matches no payload this host builds
  # (`2030 + 0` is not 2025): the analysis cannot prove the gap — the cell is
  # opaque — so the table publishes, and a payload that matches nothing
  # leaves the clause undecided rather than silently out.
  defp include_only_xml do
    requirements = @year_requirement

    table(
      """
      <inputData id="input_year" name="year">
        <variable id="var_year" name="year"/>
      </inputData>
      """,
      requirements,
      """
      <input id="clause_year">
        <inputExpression id="expr_year"><text>year</text></inputExpression>
      </input>
      """,
      """
      <rule id="rule_hazard_expenses">
        <description>Hazard entries this year: the hazard note explains the follow-up.</description>
        <inputEntry id="ie_hazard_year"><text>2030 + 0</text></inputEntry>
        <outputEntry id="oe_hazard"><text>true</text></outputEntry>
      </rule>
      """
    )
  end

  # Two rules that both match a 2025 document: UNIQUE refuses to answer, at
  # evaluation. (The cells are opaque to the publish-time analysis — literal
  # arithmetic it has not been taught — so the overlap is an obligation, not a
  # finding, and the table publishes; the engine refuses instead. Addition,
  # not subtraction: `2026 - 1` reads as a DMN interval in a cell.)
  defp overlapping_xml do
    requirements = @year_requirement

    table(
      """
      <inputData id="input_year" name="year">
        <variable id="var_year" name="year"/>
      </inputData>
      """,
      requirements,
      """
      <input id="clause_year">
        <inputExpression id="expr_year"><text>year</text></inputExpression>
      </input>
      """,
      """
      <rule id="rule_hazard_expenses">
        <description>Hazard entries this year: the hazard note explains the follow-up.</description>
        <inputEntry id="ie_hazard_year"><text>2024 + 1</text></inputEntry>
        <outputEntry id="oe_hazard"><text>true</text></outputEntry>
      </rule>
      <rule id="rule_also_the_year">
        <description>The same year again: the note goes in regardless.</description>
        <inputEntry id="ie_again_year"><text>2025 + 0</text></inputEntry>
        <outputEntry id="oe_again"><text>true</text></outputEntry>
      </rule>
      """
    )
  end

  # A rule with a blank description: the run would have nothing to record, so
  # the family's gate refuses the publish.
  defp undescribed_rule_xml do
    requirements = @year_requirement <> @categories_requirement

    table(
      """
      <inputData id="input_year" name="year">
        <variable id="var_year" name="year"/>
      </inputData>
      <inputData id="input_categories" name="categories">
        <variable id="var_categories" name="categories"/>
      </inputData>
      """,
      requirements,
      """
      <input id="clause_year">
        <inputExpression id="expr_year"><text>year</text></inputExpression>
      </input>
      <input id="clause_hazard">
        <inputExpression id="expr_hazard" typeRef="boolean"><text>list contains(categories, "Hazard")</text></inputExpression>
      </input>
      """,
      """
      <rule id="rule_hazard_expenses">
        <description>   </description>
        <inputEntry id="ie_hazard_year"><text>-</text></inputEntry>
        <inputEntry id="ie_hazard"><text>true</text></inputEntry>
        <outputEntry id="oe_hazard"><text>true</text></outputEntry>
      </rule>
      <rule id="rule_no_hazard_expenses">
        <description>No Hazard category in this year's totals: the hazard note stays out.</description>
        <inputEntry id="ie_none_year"><text>-</text></inputEntry>
        <inputEntry id="ie_none"><text>false</text></inputEntry>
        <outputEntry id="oe_none"><text>false</text></outputEntry>
      </rule>
      """
    )
  end

  # ANY hit policy: not the family's shape, refused by the same gate.
  defp any_hit_xml do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <definitions xmlns="https://www.omg.org/spec/DMN/20230324/MODEL/"
                 xmlns:dmndi="https://www.omg.org/spec/DMN/20230324/DMNDI/"
                 xmlns:dc="http://www.omg.org/spec/DMN/20180521/DC/"
                 xmlns:di="http://www.omg.org/spec/DMN/20180521/DI/"
                 id="hazard_note_any" name="Hazard note, ANY"
                 namespace="https://ash-enterprise.example/dmn/paper-clause-hazard-note-any"
                 expressionLanguage="https://www.omg.org/spec/DMN/20230324/FEEL/"
                 typeLanguage="https://www.omg.org/spec/DMN/20230324/FEEL/">
      <inputData id="input_year" name="year">
        <variable id="var_year" name="year"/>
      </inputData>
      <inputData id="input_categories" name="categories">
        <variable id="var_categories" name="categories"/>
      </inputData>
      <decision id="decision_hazard_note_any" name="hazard_note">
        <variable id="var_decision" name="include" typeRef="boolean"/>
        <informationRequirement id="req_year">
          <requiredInput href="#input_year"/>
        </informationRequirement>
        <informationRequirement id="req_categories">
          <requiredInput href="#input_categories"/>
        </informationRequirement>
        <decisionTable id="table_hazard_note_any" hitPolicy="ANY">
          <input id="clause_year">
            <inputExpression id="expr_year"><text>year</text></inputExpression>
          </input>
          <input id="clause_hazard">
            <inputExpression id="expr_hazard" typeRef="boolean"><text>list contains(categories, "Hazard")</text></inputExpression>
          </input>
          <output id="out_include" name="include" typeRef="boolean"/>
          <rule id="rule_hazard_expenses">
            <description>Hazard entries this year: the hazard note explains the follow-up.</description>
            <inputEntry id="ie_hazard_year"><text>-</text></inputEntry>
            <inputEntry id="ie_hazard"><text>true</text></inputEntry>
            <outputEntry id="oe_hazard"><text>true</text></outputEntry>
          </rule>
          <rule id="rule_no_hazard_expenses">
            <description>No Hazard category in this year's totals: the hazard note stays out.</description>
            <inputEntry id="ie_none_year"><text>-</text></inputEntry>
            <inputEntry id="ie_none"><text>false</text></inputEntry>
            <outputEntry id="oe_none"><text>false</text></outputEntry>
          </rule>
        </decisionTable>
      </decision>
    </definitions>
    """
  end

  # The shared body of the variant tables: the inputs, requirements and rules
  # vary, the decision's shape is the family's.
  defp table(input_data, requirements, input_clauses, rules) do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <definitions xmlns="https://www.omg.org/spec/DMN/20230324/MODEL/"
                 xmlns:dmndi="https://www.omg.org/spec/DMN/20230324/DMNDI/"
                 xmlns:dc="http://www.omg.org/spec/DMN/20180521/DC/"
                 xmlns:di="http://www.omg.org/spec/DMN/20180521/DI/"
                 id="hazard_note" name="Hazard note"
                 namespace="https://ash-enterprise.example/dmn/paper-clause-hazard-note"
                 expressionLanguage="https://www.omg.org/spec/DMN/20230324/FEEL/"
                 typeLanguage="https://www.omg.org/spec/DMN/20230324/FEEL/">
      #{String.trim(input_data)}
      <decision id="decision_hazard_note" name="hazard_note">
        <variable id="var_decision" name="include" typeRef="boolean"/>
        #{String.trim(requirements)}
        <decisionTable id="table_hazard_note" hitPolicy="UNIQUE">
          #{String.trim(input_clauses)}
          <output id="out_include" name="include" typeRef="boolean"/>
          #{String.trim(rules)}
        </decisionTable>
      </decision>
    </definitions>
    """
  end
end
