defmodule AshEnterprise.Anonymization.GreenmaskConfigTest do
  @moduledoc """
  ADR 0032: the greenmask config is generated from the `greenmask` blocks, and
  every attribute that could name a person has a position in it. `mix
  ash_greenmask.gen.config --check` gates the committed file in CI; these
  tests say what the file must contain, and that the gates refuse a gap.
  """
  use ExUnit.Case, async: true

  alias AshEnterprise.Governance.DataInventory
  alias AshGreenmask.Generator
  alias AshGreenmask.Info

  @root Path.expand("../../..", __DIR__)

  defmodule Fixtures.Domain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource AshEnterprise.Anonymization.GreenmaskConfigTest.Fixtures.Uncovered
      resource AshEnterprise.Anonymization.GreenmaskConfigTest.Fixtures.UnflaggedPersonal
    end
  end

  defmodule Fixtures.Uncovered do
    @moduledoc false
    use Ash.Resource,
      domain: AshEnterprise.Anonymization.GreenmaskConfigTest.Fixtures.Domain,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshGreenmask.Resource]

    postgres do
      table "greenmask_fixture_uncovered"
      repo AshEnterprise.Repo
      migrate? false
    end

    attributes do
      uuid_primary_key :id
      attribute :secret, :string, sensitive?: true
    end
  end

  defmodule Fixtures.UnflaggedPersonal do
    @moduledoc false
    use Ash.Resource,
      domain: AshEnterprise.Anonymization.GreenmaskConfigTest.Fixtures.Domain,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshGreenmask.Resource]

    postgres do
      table "greenmask_fixture_personal"
      repo AshEnterprise.Repo
      migrate? false
    end

    attributes do
      uuid_primary_key :id
      attribute :contact_email, :string
      attribute :payload, :map
    end
  end

  defp domains, do: Application.fetch_env!(:ash_enterprise, :ash_domains)

  defp options do
    [
      strict?: Application.fetch_env!(:ash_greenmask, :strict?),
      layout: Application.fetch_env!(:ash_greenmask, :layout),
      default_schema: Application.fetch_env!(:ash_greenmask, :default_schema)
    ]
  end

  # Personal-looking attributes (the data inventory's heuristic) on a stored
  # resource whose block neither transforms nor keeps them, nor excludes the rows.
  defp without_position(resources) do
    for resource <- resources,
        Ash.Resource.Info.data_layer(resource) == AshPostgres.DataLayer,
        is_nil(Info.exclude_data(resource)),
        attribute <- Ash.Resource.Info.attributes(resource),
        DataInventory.looks_personal?(attribute.name),
        not positioned?(resource, attribute.name) do
      {resource, attribute.name}
    end
  end

  # Columns stored as JSON on a stored resource whose block neither transforms nor keeps
  # them, nor excludes the rows. What a map holds is invisible to a name heuristic: a raw
  # landing's keys are a spreadsheet's own headers.
  defp json_without_position(resources) do
    for resource <- resources,
        Ash.Resource.Info.data_layer(resource) == AshPostgres.DataLayer,
        is_nil(Info.exclude_data(resource)),
        attribute <- Ash.Resource.Info.attributes(resource),
        json?(attribute),
        not attribute.sensitive?,
        not positioned?(resource, attribute.name) do
      "#{inspect(resource)}.#{attribute.name}"
    end
  end

  defp json?(attribute) do
    Ash.Type.storage_type(attribute.type, attribute.constraints) in [
      :map,
      :jsonb,
      {:array, :map},
      {:array, :jsonb}
    ]
  end

  defp positioned?(resource, name) do
    Enum.any?(Info.transforms(resource), &(&1.attribute == name)) or
      Enum.any?(Info.keeps(resource), &(&1.attribute == name))
  end

  # Free-form JSON columns a copy holds as they are, carried as they stood on 2026-11-18
  # when the MDM landing and staging columns were found copied in plaintext, and the
  # document columns added on 2026-11-21 (a decision table's impact report among them). Each still needs
  # a decision in its resource's `greenmask` block (a transform, or a keep with its reason in
  # the generated header); until then it is listed here and in
  # docs/runbooks/production-copy.md. A JSON column added to a stored resource fails the
  # test below until it has a position or is listed.
  @json_copied_as_is ~w(
    AshCompliance.Resources.ControlRevision.params
    AshCompliance.Resources.EvidenceArtifact.chain_of_custody
    AshCompliance.Resources.PolicyBundle.contributions
    AshCompliance.Resources.ProfileRevision.operations
    AshEnterprise.Accounts.Offboarding.holdings
    AshEnterprise.Audit.ArchivedEvidence.chain_of_custody
    AshEnterprise.Automation.Occurrence.data
    AshEnterprise.Bpmn.Definition.errors
    AshEnterprise.Bpmn.Definition.graph
    AshEnterprise.Bpmn.HumanTask.on_complete
    AshEnterprise.Bpmn.ProcessEvent.data
    AshEnterprise.Bpmn.Subscription.compiled
    AshEnterprise.Bpmn.Subscription.variable_mapping
    AshEnterprise.Bpmn.Token.routing
    AshEnterprise.Canonical.Task.judgment_digests
    AshEnterprise.Credentialing.DocumentEvent.data
    AshEnterprise.Decisions.Definition.errors
    AshEnterprise.Decisions.Definition.graph
    AshEnterprise.Decisions.Definition.impact_report
    AshEnterprise.Decisions.Definition.verification
    AshEnterprise.Decisions.Evaluation.error
    AshEnterprise.Decisions.Evaluation.inputs
    AshEnterprise.Decisions.Evaluation.outputs
    AshEnterprise.Documents.PaperAnswer.scope
    AshEnterprise.Documents.PaperBinding.selection
    AshEnterprise.Documents.PaperClause.runs
    AshEnterprise.Documents.PaperDraft.issue_outcomes
    AshEnterprise.Documents.PaperDraft.unresolved_obligations
    AshEnterprise.Documents.PaperRun.clause_reasons
    AshEnterprise.Documents.PaperRun.problems
    AshEnterprise.Documents.PaperRun.snapshot
    AshEnterprise.Erasure.PersonErasure.counts
    AshEnterprise.Execution.AgentVersion.authority
    AshEnterprise.Execution.AgentVersion.limits
    AshEnterprise.Execution.AgentVersion.toolset
    AshEnterprise.Execution.Invocation.authorization_details
    AshEnterprise.Execution.Invocation.delegation
    AshEnterprise.Execution.Invocation.effects
    AshEnterprise.Execution.Invocation.evidence
    AshEnterprise.Execution.Invocation.executing_principal
    AshEnterprise.Execution.Invocation.preconditions
    AshEnterprise.Execution.ReleaseManifest.entries
    AshEnterprise.Execution.ReleaseManifest.gate_result
    AshEnterprise.Execution.ReleaseManifest.requests
    AshEnterprise.Execution.Run.budget_holds
    AshEnterprise.Execution.Run.executing_principal
    AshEnterprise.Execution.Run.fixtures
    AshEnterprise.Execution.RunFinished.data
    AshEnterprise.Execution.Step.tool_calls
    AshEnterprise.Ingestion.SourceObject.cursor
    AshEnterprise.Ingestion.SourceObject.source_metadata
    AshEnterprise.Lineage.Job.inputs
    AshEnterprise.Lineage.Job.outputs
    AshEnterprise.Lineage.JobRun.inputs
    AshEnterprise.Lineage.JobRun.outputs
    AshEnterprise.Mdm.AttributeAssertion.origin_ref
    AshEnterprise.Mdm.ImportBatch.counts
    AshEnterprise.Mdm.Mapping.field_rules
    AshEnterprise.Mdm.Mapping.observed_schema
    AshEnterprise.Mdm.MatchCandidate.explanation
    AshEnterprise.Mdm.MatchCandidate.human_verdict_ref
    AshEnterprise.Mdm.MatchRuleSet.rules
    AshEnterprise.Mdm.MatchRuleSet.survivorship
    AshEnterprise.Mdm.SourceRecord.cursor
    AshEnterprise.Mdm.SourceRecord.source_metadata
    AshEnterprise.Planning.Binding.selection
    AshEnterprise.Planning.Candidate.unresolved_obligations
    AshEnterprise.Planning.ModelVersion.backend_profile
    AshEnterprise.Planning.Run.backend
    AshEnterprise.Planning.Run.stats
    AshEnterprise.Planning.Run.unresolved_inputs
    AshEnterprise.Quality.CaseResult.assertion_results
    AshEnterprise.Quality.CaseResult.scores
    AshEnterprise.Quality.Suite.cases
    AshEnterprise.Quality.Suite.provenance
    AshEnterprise.Quality.Suite.scorers
    AshEnterprise.Quality.Suite.thresholds
    AshEnterprise.Quality.SuiteRun.summary
    AshEnterprise.SystemOne.BandTableCertification.verification
    AshEnterprise.SystemOne.Banding.band_table
    AshEnterprise.SystemOne.Banding.inputs
    AshEnterprise.SystemOne.CalibrationRun.conformal_thresholds
    AshEnterprise.SystemOne.CalibrationRun.metrics
    AshEnterprise.SystemOne.CalibrationRun.n_per_class
    AshEnterprise.SystemOne.CalibrationRun.pass_bar
    AshEnterprise.SystemOne.CalibrationRun.proposed_band_table
    AshEnterprise.SystemOne.EvidenceAssertion.distribution
    AshEnterprise.SystemOne.EvidenceAssertion.subject
    AshEnterprise.SystemOne.Fact.scope
    AshEnterprise.SystemOne.Fact.subject
    AshEnterprise.SystemOne.FilterExecution.document
    AshEnterprise.SystemOne.FilterExecution.plan
    AshEnterprise.SystemOne.FilterExecution.scope
    AshEnterprise.SystemOne.FilterProposal.document
    AshEnterprise.SystemOne.HumanVerdict.model_answer
    AshEnterprise.SystemOne.HumanVerdict.state_ref
    AshEnterprise.SystemOne.Judgment.envelope
    AshEnterprise.SystemOne.Judgment.probabilities
    AshEnterprise.SystemOne.Judgment.state_ref
    AshEnterprise.SystemOne.Judgment.usage
    AshEnterprise.SystemOne.QuestionProposal.proposals
  )

  describe "refusals" do
    test "a stored resource with a sensitive attribute and no position is a generation error" do
      assert {:error, [reason]} = Generator.build([Fixtures.Domain], options())
      assert reason =~ "#{inspect(Fixtures.Uncovered)}: :secret is sensitive"
    end

    test "a personal-looking attribute with no position is reported" do
      assert without_position([Fixtures.UnflaggedPersonal]) == [
               {Fixtures.UnflaggedPersonal, :contact_email}
             ]
    end

    test "a free-form JSON column with no position is reported, whatever it is called" do
      assert json_without_position([Fixtures.UnflaggedPersonal]) == [
               "#{inspect(Fixtures.UnflaggedPersonal)}.payload"
             ]
    end
  end

  test "the config is strict and is the dump section greenmask reads" do
    assert options() == [strict?: true, layout: :config, default_schema: "public"]
  end

  test "every sensitive? attribute across the domains has a transform or a keep with a reason" do
    assert {:ok, _document, residuals} = Generator.build(domains(), options())

    for line <- residuals do
      [_position, because] = String.split(line, " — ", parts: 2)
      assert String.length(because) > 20, "a keep with no real reason: #{line}"
    end
  end

  test "every looks-personal attribute in the data inventory has a greenmask position" do
    assert without_position(DataInventory.resources()) == []
  end

  test "every free-form JSON column has a greenmask position or is listed as copied as it is" do
    unpositioned = json_without_position(DataInventory.resources())

    assert unpositioned -- @json_copied_as_is == [],
           "a JSON column has no greenmask position: transform it, keep it with a reason, " <>
             "or list it in @json_copied_as_is and in docs/runbooks/production-copy.md"

    assert @json_copied_as_is -- unpositioned == [],
           "listed as copied as it is but now positioned (or gone): drop it from the list"
  end

  test "MDM raw landings, staged rows and proposals reach a copy replaced, not as landed" do
    for {resource, attribute} <- [
          {AshEnterprise.Mdm.SourceRecord, :raw_payload},
          {AshEnterprise.Mdm.StagedRecord, :mapped},
          {AshEnterprise.Mdm.StagedRecord, :validation_findings},
          {AshEnterprise.Mdm.Mapping, :validation_findings},
          {AshEnterprise.Mdm.MappingProposal, :raw}
        ] do
      assert [%{transformer: :replace}] =
               Enum.filter(Info.transforms(resource), &(&1.attribute == attribute)),
             "#{inspect(resource)}.#{attribute} is not replaced in a copy"
    end
  end

  test "Erasure.Key.wrapped_key is transformed, never kept" do
    resource = AshEnterprise.Erasure.Key

    assert nil == Info.exclude_data(resource)

    assert [%{transformer: :replace}] =
             Enum.filter(Info.transforms(resource), &(&1.attribute == :wrapped_key))

    refute Enum.any?(Info.keeps(resource), &(&1.attribute == :wrapped_key))
  end

  test "no production password hash and no address reaches a copy" do
    transforms = Map.new(Info.transforms(AshEnterprise.Accounts.User), &{&1.attribute, &1})

    assert %{transformer: :replace} = transforms.hashed_password
    assert %{transformer: :random_email, options: options} = transforms.email
    assert options[:engine] == "hash"
    assert options[:domains] == ["example.com"]
  end

  test "the committed greenmask.yml equals the generator output, and its residuals header names the audit tables and large objects" do
    assert {:ok, document, residuals} = Generator.build(domains(), options())
    rendered = document |> Generator.render(residuals) |> IO.iodata_to_binary()

    assert File.read!(Path.join(@root, "greenmask.yml")) == rendered,
           "greenmask.yml has drifted: run `mix ash_greenmask.gen.config` and commit it"

    excluded = get_in(document, ["dump", "pg_dump_options", "exclude-table-data"])
    assert "public.audit_events" in excluded
    assert "public.audit_event_archive" in excluded
    assert get_in(document, ["dump", "pg_dump_options", "no-blobs"]) == true

    assert rendered =~ "#{inspect(AshEnterprise.Audit.EventLog)}: rows not copied (exclude_data)"

    assert rendered =~
             "#{inspect(AshEnterprise.Audit.ArchivedEvent)}: rows not copied (exclude_data)"

    assert rendered =~ "Large objects are not copied"
    assert rendered =~ "GREENMASK_GLOBAL_SALT"
    refute rendered =~ ~r/GREENMASK_GLOBAL_SALT\s*[:=]\s*\S/
  end
end
