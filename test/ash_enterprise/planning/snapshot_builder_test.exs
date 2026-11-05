defmodule AshEnterprise.Planning.SnapshotBuilderTest do
  @moduledoc """
  The builder reads the declared inputs, records `(resource, id, version_number, content_hash)`
  per input, and writes the preparation axis: `:prepared` with a sealed lowered problem,
  `:needs_input` naming the unresolved source, or `:preparation_failed`.
  """

  use AshEnterprise.DataCase, async: false

  import AshEnterprise.Planning.TestKit

  alias AshEnterprise.Planning.{Lowering, SnapshotBuilder}

  setup do
    publish_requirements!()
    %{w: world!()}
  end

  defp monday_plus(days, hours),
    do:
      Lowering.week_start(DateTime.utc_now())
      |> DateTime.add(days * 86_400 + hours * 3600, :second)

  test "estimated tasks, a pinned task and a meeting lower to a prepared, sealed problem", %{w: w} do
    a = task!(w, "write", 120)
    b = task!(w, "review", 60)
    pinned = task!(w, "already planned", 30, schedule: {monday_plus(4, 9), monday_plus(4, 10)})
    event = event(w, "sync", monday_plus(2, 10), 30)

    assert {:ok, run} = SnapshotBuilder.prepare(w.run)
    assert run.preparation_status == :prepared
    assert run.snapshot_digest =~ ~r/\A[0-9a-f]{64}\z/

    assert {:ok, payload} = SnapshotBuilder.problem_payload(run)
    assert payload["n_tasks"] == 2
    assert payload["n_pinned"] == 1
    assert payload["n_meetings"] == 1
    assert Enum.sort(payload["ids"]["tasks"]) == Enum.sort([a.id, b.id])
    assert payload["ids"]["pinned"] == [pinned.id]
    assert payload["ids"]["meetings"] == [event.id]
    assert Enum.sort(payload["t_dur"]) == [4, 8]
    refute Map.has_key?(Lowering.solver_data(payload), "ids")
    refute Map.has_key?(Lowering.solver_data(payload), "snapshot")

    assert {:ok, snapshot} = SnapshotBuilder.snapshot_from_payload(payload)
    assert snapshot.digest == run.snapshot_digest
    assert snapshot.authority.completeness == :complete

    sources = for %{source: %{} = s} <- snapshot.inputs, do: {s.id, is_integer(s.version_number)}
    assert length(sources) == 4 and Enum.all?(sources, &elem(&1, 1))

    assert Enum.any?(
             snapshot.definitions,
             &(&1.kind == :dmn and &1.key == "canonical.planning_requirements")
           )

    assert Enum.any?(snapshot.definitions, &(&1.kind == :validator))
  end

  test "an unestimated task makes the run needs_input, naming the source and no value", %{w: w} do
    task!(w, "estimated", 30)
    bare = task!(w, "no estimate")

    assert {:ok, run} = SnapshotBuilder.prepare(w.run)
    assert run.preparation_status == :needs_input
    assert {:error, :empty} = SnapshotBuilder.unseal(run, :problem_payload, run.organization_id)
    assert run.snapshot_digest =~ ~r/\A[0-9a-f]{64}\z/

    assert [
             %{
               "id" => id,
               "status" => "unresolved",
               "reason" => "missing_estimate",
               "resource" => resource
             }
           ] =
             run.unresolved_inputs

    assert id == bare.id
    assert resource == "AshEnterprise.Canonical.Task"
  end

  test "an unsupported purpose fails preparation with a reason code" do
    w = world!(purpose: "planning.something_else")
    assert {:ok, run} = SnapshotBuilder.prepare(w.run)
    assert run.preparation_status == :preparation_failed
    assert run.stats["reason"] == "unsupported_purpose"
  end

  test "preparing a prepared run is a no-op", %{w: w} do
    task!(w, "t", 15)
    assert {:ok, run} = SnapshotBuilder.prepare(w.run)
    assert {:ok, again} = SnapshotBuilder.prepare(run)
    assert again.snapshot_digest == run.snapshot_digest
  end
end
