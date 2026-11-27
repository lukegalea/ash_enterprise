defmodule AshEnterprise.Journeys.EvidenceSinkTest do
  @moduledoc """
  A journey run as compliance evidence (`AshEnterprise.Journeys.EvidenceSink`).

  The runs are the offboarding journey's approved CI run (`priv/journeys/en/`) and runs
  derived from it: the same manifest failed at a step, retried, errored, of an older
  declaration, from another browser build, or operated. Everything a run is refused for
  writes nothing at all: no artifact and no finding.

  Not async: one test sets the deployment class, which the sink reads from config.
  """

  use AshEnterprise.DataCase, async: false

  alias AshBrowserTests.Journeys.Candidates
  alias AshCompliance.Domain
  alias AshEnterprise.Compliance.FreshnessSweepWorker
  alias AshEnterprise.Journeys.{EvidenceSink, Offboarding}
  alias AshJourneys.{Info, Ir, Manifest, Run}

  @id "revoke_a_leavers_access"
  @producer "journey:revoke_a_leavers_access"
  @now ~U[2026-11-27 12:00:00.000000Z]

  setup do
    {:ok, approved} =
      Manifest.read(
        Path.join(Application.app_dir(:ash_enterprise), "priv/journeys/en/#{@id}/manifest.json")
      )

    %{
      org: Ash.UUID.generate(),
      ir: Ir.build(Info.journey!(Offboarding, :revoke_a_leavers_access)),
      approved: approved
    }
  end

  defp record(manifest, ctx),
    do: EvidenceSink.record(manifest, ctx.ir, organization_id: ctx.org, now: @now)

  defp artifacts(org, control),
    do: Domain.evidence_for_control!(org, control, authorize?: false)

  defp journey_findings(org) do
    org
    |> Domain.findings_for_organization!(authorize?: false)
    |> Enum.filter(&(&1.subject_type == EvidenceSink.subject_type()))
  end

  defp nothing_written!(org) do
    assert artifacts(org, "CC6.2") == []
    assert artifacts(org, "CC6.3") == []
    assert journey_findings(org) == []
  end

  # The approved run, failed at `deactivate`: the step that acts on the leaver's row.
  defp failed(manifest) do
    steps =
      Enum.map(manifest.steps, fn
        %{name: "deactivate"} = step ->
          %{step | status: :failed, figures: [], error: "the leaver's row still shows Active"}

        %{name: "their_next_action_signs_them_out"} = step ->
          %{step | status: :skipped, figures: [], cursor: nil, span_ids: [], correlation_id: nil}

        step ->
          step
      end)

    %{manifest | status: :failed, steps: steps}
  end

  defp operated(manifest) do
    %{
      manifest
      | environment: :operated,
        steps: Enum.map(manifest.steps, &%{&1 | figures: []})
    }
  end

  describe "exit: what a run files" do
    test "a failing offboarding run files a :noncompliant finding for CC6.2 (and CC6.3)", ctx do
      assert :ok = record(failed(ctx.approved), ctx)

      for control <- ["CC6.2", "CC6.3"] do
        assert [finding] = Enum.filter(journey_findings(ctx.org), &(&1.control_id == control))

        assert %{
                 status: :noncompliant,
                 severity: :high,
                 gap: "journey_failed",
                 subject_id: "revoke_a_leavers_access/en/non_production",
                 resolved_at: nil
               } = finding

        assert finding.explanation =~ "failed at step deactivate"
        assert finding.explanation =~ ctx.approved.run_id
      end

      # A failure is not evidence.
      assert artifacts(ctx.org, "CC6.2") == []
    end

    test "a passing CC6.2 run recorded as :test exists and is not counted toward freshness",
         ctx do
      assert ctx.approved.environment == :test
      assert :ok = record(ctx.approved, ctx)

      assert [artifact] = artifacts(ctx.org, "CC6.2")

      assert %{
               collector: @producer,
               method: :test,
               media_type: "application/json",
               environment_class: :non_production,
               subject_type: "journey",
               subject_id: "revoke_a_leavers_access/en"
             } = artifact

      # The artifact is the manifest, byte for byte, and no figure.
      assert artifact.content == Manifest.encode(ctx.approved)
      assert {:ok, _manifest} = Manifest.decode(artifact.content)

      assert {:ok, results} =
               FreshnessSweepWorker.sweep(ctx.org, controls_file: controls_file(), now: @now)

      assert %{state: :unknown, reason: :non_production} =
               Enum.find(results, &(&1.criterion == "CC6.2"))
    end

    test "only an :operated run in an audited deployment counts, and it records no figures",
         ctx do
      previous = Application.get_env(:ash_enterprise, :deployment_class)
      on_exit(fn -> restore_deployment_class(previous) end)

      # Operated, but not in an audited deployment: recorded, not counted.
      assert :ok = record(operated(ctx.approved), ctx)
      assert [%{environment_class: :non_production}] = artifacts(ctx.org, "CC6.2")
      assert {:ok, results} = sweep(ctx.org)
      assert %{state: :unknown, reason: :non_production} = cc62(results)

      Application.put_env(:ash_enterprise, :deployment_class, :audited)

      # A test run in an audited deployment is still not production.
      other = Ash.UUID.generate()
      assert :ok = EvidenceSink.record(ctx.approved, ctx.ir, organization_id: other, now: @now)
      assert [%{environment_class: :non_production}] = artifacts(other, "CC6.2")

      assert :ok = record(operated(ctx.approved), ctx)

      production =
        Enum.filter(artifacts(ctx.org, "CC6.2"), &(&1.environment_class == :production))

      assert [artifact] = production

      assert {:ok, %Manifest{environment: :operated, steps: steps}} =
               Manifest.decode(artifact.content)

      assert Enum.all?(steps, &(&1.figures == []))

      assert {:ok, results} = sweep(ctx.org)
      assert %{state: :evidenced, sources: [@producer]} = cc62(results)
    end

    test "a pass closes the failure of its own class of environment, never another's", ctx do
      previous = Application.get_env(:ash_enterprise, :deployment_class)
      on_exit(fn -> restore_deployment_class(previous) end)
      Application.put_env(:ash_enterprise, :deployment_class, :audited)

      assert :ok = record(operated(failed(ctx.approved)), ctx)
      assert :ok = record(ctx.approved, ctx)

      assert [%{subject_id: "revoke_a_leavers_access/en/production", resolved_at: nil}] =
               Enum.filter(journey_findings(ctx.org), &(&1.control_id == "CC6.2"))

      assert :ok = record(operated(ctx.approved), ctx)

      assert [%{status: :noncompliant, resolved_at: %DateTime{}}] =
               Enum.filter(journey_findings(ctx.org), &(&1.control_id == "CC6.2"))
    end
  end

  describe "a run that is not evidence writes nothing" do
    test "a retried run, passed or failed", ctx do
      for manifest <- [%{ctx.approved | retries: 1}, %{failed(ctx.approved) | retries: 2}] do
        assert {:error, {:not_evidence, [reason]}} = record(manifest, ctx)
        assert reason =~ "only a first attempt is evidence"
      end

      nothing_written!(ctx.org)
    end

    test "a run whose step took a second attempt (flaky)", ctx do
      steps =
        Enum.map(
          ctx.approved.steps,
          &if(&1.name == "deactivate", do: %{&1 | attempts: 2}, else: &1)
        )

      assert {:error, {:not_evidence, [reason]}} = record(%{ctx.approved | steps: steps}, ctx)
      assert reason =~ "deactivate took more than one attempt (flaky)"
      nothing_written!(ctx.org)
    end

    test "an errored run, and one that says passed over a step that did not", ctx do
      errored = %{failed(ctx.approved) | status: :errored}
      assert {:error, {:not_evidence, ["the run errored" <> _]}} = record(errored, ctx)

      lying = %{failed(ctx.approved) | status: :passed}
      assert {:error, {:not_evidence, [reason]}} = record(lying, ctx)
      assert reason =~ "did not pass"

      nothing_written!(ctx.org)
    end

    test "a stale run: of an older declaration, or of a declaration newer than its approval",
         ctx do
      older = %{ctx.approved | declaration_hash: String.duplicate("0", 64)}
      assert {:error, {:not_evidence, [reason]}} = record(older, ctx)
      assert reason =~ "the run is stale"

      # The journey changed since its run was approved: `Lock.verify/6` refuses it.
      changed = Map.put(ctx.ir, "title", "Revoke someone's access")

      assert {:error, {:not_evidence, ["the approved run: stale" <> _]}} =
               EvidenceSink.record(ctx.approved, changed, organization_id: ctx.org, now: @now)

      newer_version = %{ctx.approved | version: 2}
      assert {:error, {:not_evidence, [reason]}} = record(newer_version, ctx)
      assert reason =~ "version 2"

      nothing_written!(ctx.org)
    end

    test "a run from another browser build than the lock pins", ctx do
      other = %{ctx.approved | browser: %{ctx.approved.browser | version: "151.0.0.0"}}

      assert {:error, {:not_evidence, [reason]}} = record(other, ctx)
      assert reason =~ "chromium 151.0.0.0, but the lock pins chromium"
      assert {:error, {:not_evidence, _}} = record(failed(other), ctx)
      nothing_written!(ctx.org)
    end

    test "an :operated run that recorded figures", ctx do
      with_figures = %{ctx.approved | environment: :operated}

      assert {:error, {:not_evidence, [reason]}} = record(with_figures, ctx)
      assert reason =~ "an :operated run records no figures"
      nothing_written!(ctx.org)
    end

    test "a run of another journey or locale, and a journey that names no controls", ctx do
      assert {:error, {:not_evidence, _}} =
               record(%{ctx.approved | journey: "something_else"}, ctx)

      assert {:error, {:not_evidence, _}} = record(%{ctx.approved | locale: "de"}, ctx)

      bare = Map.put(ctx.ir, "metadata", %{})

      assert {:error, {:not_evidence, ["the journey names no controls in its metadata"]}} =
               EvidenceSink.record(ctx.approved, bare, organization_id: ctx.org, now: @now)

      nothing_written!(ctx.org)
    end
  end

  describe "retries as the runner records them" do
    setup do
      root = Path.join(System.tmp_dir!(), "evidence_sink_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(root) end)
      %{root: root}
    end

    test "a second run at the same commit is a retry, and writes nothing", ctx do
      run_id = Candidates.local_run_id()
      first = %{ctx.approved | run_id: run_id}

      # The first run, by another test VM at this commit: its claim and its manifest.
      dir = Run.candidate_dir(ctx.root, run_id, @id, "en")
      Manifest.write!(first, dir)
      File.write!(Path.join(dir, ".claim"), "an earlier VM")

      claim = Candidates.claim!(ctx.root, run_id, @id, "en", 1)
      assert claim.run_id == run_id
      assert %Manifest{retries: 0} = claim.prior

      # The runner counts the earlier run as a retry of this one
      # (AshBrowserTests.Journeys: earlier attempts plus the prior run's retries, plus one).
      second = %{first | retries: claim.earlier_attempts + claim.prior.retries + 1}

      assert :ok = record(first, ctx)
      assert [_first_artifact] = artifacts(ctx.org, "CC6.2")

      assert {:error, {:not_evidence, [reason]}} = record(second, ctx)
      assert reason =~ "needed 1 retry"
      assert length(artifacts(ctx.org, "CC6.2")) == 1
    end

    test "a CI re-run (JOURNEYS_RUN_ATTEMPT 2) is a retry, and writes nothing", ctx do
      claim = Candidates.claim!(ctx.root, "ci-1", @id, "en", 2)
      assert claim.earlier_attempts == 1

      assert {:error, {:not_evidence, _}} =
               record(
                 %{ctx.approved | run_id: claim.run_id, retries: claim.earlier_attempts},
                 ctx
               )

      nothing_written!(ctx.org)
    end

    test "two claims of one journey in the same VM are independent first attempts", ctx do
      first = Candidates.claim!(ctx.root, "ci-2", @id, "en", 1)
      second = Candidates.claim!(ctx.root, "ci-2", @id, "en", 1)

      assert {first.run_id, second.run_id} == {"ci-2", "ci-2-2"}
      assert {first.prior, second.prior, second.earlier_attempts} == {nil, nil, 0}

      for claim <- [first, second],
          do: assert(:ok = record(%{ctx.approved | run_id: claim.run_id}, ctx))

      assert length(artifacts(ctx.org, "CC6.2")) == 2
    end
  end

  test "environment_class/2: only an operated run in an audited deployment is production" do
    for environment <- [:test, :staging, :operated], class <- [nil, :audited] do
      expected =
        if {environment, class} == {:operated, :audited}, do: :production, else: :non_production

      assert EvidenceSink.environment_class(environment, class) == expected
    end
  end

  defp restore_deployment_class(nil),
    do: Application.delete_env(:ash_enterprise, :deployment_class)

  defp restore_deployment_class(class),
    do: Application.put_env(:ash_enterprise, :deployment_class, class)

  defp sweep(org), do: FreshnessSweepWorker.sweep(org, controls_file: controls_file(), now: @now)

  defp cc62(results), do: Enum.find(results, &(&1.criterion == "CC6.2"))

  # docs/controls.json with CC6.2's evidence producer the journey. Whether the real row
  # names it is the control map's decision; this is the evaluator's question alone.
  defp controls_file do
    document = "docs/controls.json" |> File.read!() |> Jason.decode!()

    criteria =
      Enum.map(document["criteria"], fn
        %{"id" => "CC6.2"} = row -> Map.put(row, "evidence_producer", @producer)
        row -> row
      end)

    path = Path.join(System.tmp_dir!(), "controls_#{System.unique_integer([:positive])}.json")
    File.write!(path, Jason.encode!(%{document | "criteria" => criteria}))
    on_exit(fn -> File.rm(path) end)
    path
  end
end
