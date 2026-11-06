defmodule AshEnterprise.Planning.CheckPipelineTest do
  @moduledoc """
  The pipeline proposes a candidate per solver solution, records the MiniZinc checker's
  verdict and the independent validator's separately, and is idempotent.
  """

  use AshEnterprise.DataCase, async: false

  import AshEnterprise.Planning.TestKit

  alias AshEnterprise.Planning
  alias AshEnterprise.Planning.CheckPipeline

  setup do
    publish_requirements!()
    w = world!()
    task!(w, "write", 60)
    task!(w, "review", 30)
    %{w: w}
  end

  defp candidates(run, w),
    do:
      Planning.list_planning_candidates!(
        Keyword.put(w.aopts, :query, filter: [run_id: run.id], sort: [index: :asc])
      )

  test "a correct candidate is proposed, checked twice and recorded correct", %{w: w} do
    {run, _payload} = solved!(w)
    assert :ok = CheckPipeline.process(run)

    assert [candidate] = candidates(run, w)
    assert candidate.index == 0
    assert candidate.check_status == :correct
    assert candidate.disposition == :proposed
    assert candidate.unresolved_obligations == []

    assert [result] = Planning.list_planning_check_results!(w.aopts)
    assert {result.checker_status, result.validator_status} == {:correct, :correct}
  end

  test "processing twice does not duplicate candidates or checks", %{w: w} do
    {run, _} = solved!(w)
    assert :ok = CheckPipeline.process(run)
    assert :ok = CheckPipeline.process(run)
    assert [_one] = candidates(run, w)
    assert [_one] = Planning.list_planning_check_results!(w.aopts)
  end

  test "the checker and the validator are recorded separately", %{w: w} do
    {run, _} =
      solved!(w,
        candidate: %{"checker_ok" => false, "checker_output" => "=====UNSATISFIABLE====="}
      )

    assert :ok = CheckPipeline.process(run)
    assert [%{check_status: :incorrect}] = candidates(run, w)
    assert [r] = Planning.list_planning_check_results!(w.aopts)
    assert {r.checker_status, r.validator_status} == {:incorrect, :correct}
    assert r.checker_output_digest =~ ~r/\A[0-9a-f]{64}\z/
  end

  test "the validator can reject a candidate the checker passed", %{w: w} do
    bad = %{"scheduled" => [true, true], "start" => [-1, -1], "attended" => []}
    {run, _} = solved!(w, candidate: %{"data" => bad})
    assert :ok = CheckPipeline.process(run)
    assert [r] = Planning.list_planning_check_results!(w.aopts)
    assert {r.checker_status, r.validator_status} == {:correct, :incorrect}
    assert r.validator_reason == "negative_start"
  end
end
