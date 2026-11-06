defmodule Battery.Integration.PlanningSnapshotCheckTest do
  @moduledoc """
  Scenario — planning: model → solve → checker → candidate → snapshot replay.

  The cross-substrate seam of ash_planning: a published model version pins its
  hashes into an `AshOpenLineage` snapshot; a backend (the package's Fake)
  solves; an independent checker (a stub validator on the package's
  `AshPlanning.Validators.Intervals`) judges the candidate; the snapshot is
  then replayed — serialised, reconstructed from ids/hashes alone, and its
  digest verified. The AshOpenLineage cross-host golden digest is re-asserted.

  Only ids, hashes and digests cross between the substrates; no DB fixtures.
  """

  use ExUnit.Case, async: true

  alias AshOpenLineage.Snapshot
  alias AshOpenLineage.Snapshot.{CanonicalJSON, Definition, Input}
  alias AshPlanning.Backend.Fake
  alias AshPlanning.{Candidate, Problem}
  alias AshPlanning.Snapshot, as: PlanSnapshot
  alias AshPlanning.Validators.Intervals

  @golden_digest "2be6f74cd9c618c1c0d0513b1acada801eda16113e21e6f33b86d542b73c036d"

  defmodule CheckerStub do
    @moduledoc false
    # Stands in for the MiniZinc checker: accepts iff the independent
    # interval validator finds no violation.
    def check(problem, assignments) do
      case Intervals.validate(problem, assignments) do
        :ok -> {:ok, "CORRECT"}
        {:error, violations} -> {:error, "INCORRECT", violations}
      end
    end
  end

  defp sha(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  defp snapshot(model_hash) do
    {:ok, eff, _} = DateTime.from_iso8601("2026-11-09T08:00:00.000000Z")
    {:ok, cut, _} = DateTime.from_iso8601("2026-11-08T22:00:00.000000Z")

    %Snapshot{
      id: "019a2c7e-4b1d-7c2e-9f3a-5d6e7f8a9b0c",
      purpose: :"planning.battery",
      effective_at: eff,
      knowledge_cutoff: cut,
      world: :operational,
      authority: %{tenant: "t-battery", actor_id: "usr-battery", completeness: :full},
      inputs: [
        %Input{
          key: "task.a",
          role: :demand,
          status: :value,
          source: %{resource: "Task", id: "task-a", version_number: 3},
          content_hash: sha("task-a")
        },
        %Input{
          key: "task.b",
          role: :demand,
          status: :value,
          source: %{resource: "Task", id: "task-b", version_number: 1},
          content_hash: sha("task-b")
        }
      ],
      definitions: [
        %Definition{kind: :mzn, key: "battery_model", version: "1", content_hash: model_hash}
      ],
      payload_hash: sha("lowered-problem")
    }
  end

  defp reconstruct(json, digest) do
    m = Jason.decode!(json)
    {:ok, eff, _} = DateTime.from_iso8601(m["effective_at"])
    {:ok, cut, _} = DateTime.from_iso8601(m["knowledge_cutoff"])

    %Snapshot{
      id: m["id"],
      purpose: String.to_existing_atom(m["purpose"]),
      effective_at: eff,
      knowledge_cutoff: cut,
      world: String.to_existing_atom(m["world"]),
      authority: %{
        tenant: m["authority"]["tenant"],
        actor_id: m["authority"]["actor_id"],
        completeness: String.to_existing_atom(m["authority"]["completeness"])
      },
      inputs:
        Enum.map(m["inputs"], fn i ->
          %Input{
            key: i["key"],
            role: String.to_existing_atom(i["role"]),
            status: String.to_existing_atom(i["status"]),
            source:
              i["source"] &&
                %{
                  resource: i["source"]["resource"],
                  id: i["source"]["id"],
                  version_number: i["source"]["version_number"]
                },
            content_hash: i["content_hash"]
          }
        end),
      definitions:
        Enum.map(m["definitions"], fn d ->
          %Definition{
            kind: String.to_existing_atom(d["kind"]),
            key: d["key"],
            version: d["version"],
            content_hash: d["content_hash"]
          }
        end),
      payload_hash: m["payload_hash"],
      digest: digest
    }
  end

  test "model → solve → checker → candidate → snapshot replay verifies" do
    # ── 1. model: pinned by content hash ─────────────────────────────────
    model_hash = sha("var 0..10: s; solve satisfy;")

    # ── 2. snapshot sealed over ids/hashes ───────────────────────────────
    sealed = PlanSnapshot.seal(snapshot(model_hash))
    assert PlanSnapshot.verify(sealed)
    assert PlanSnapshot.complete?(sealed)
    assert %{content_hash: ^model_hash} = PlanSnapshot.definition(sealed, :mzn, "battery_model")

    # ── 3. solve via the package's Fake backend ──────────────────────────
    assignments = [%{id: "task-a", start: 0, end: 30}, %{id: "task-b", start: 30, end: 60}]

    problem = %Problem{
      model_path: "battery_model.mzn",
      data: %{fake_candidates: [%{assignments: assignments}], fake_objective: 3}
    }

    assert {:ok, session} = Fake.start(problem, [])
    assert {:ok, result} = Fake.await(session, 1_000)
    assert result.status == :feasible and result.complete? and result.optimality == :proven

    [cand_map] = result.payload.candidates
    candidate = Candidate.from_map(cand_map)
    assert Decimal.equal?(candidate.objective, 3)
    refute is_float(candidate.objective)

    # ── 4. checker stub judges the candidate ─────────────────────────────
    assert {:ok, "CORRECT"} = CheckerStub.check(%{}, candidate.data.assignments)

    corrupted = [%{id: "task-a", start: 0, end: 40}, %{id: "task-b", start: 30, end: 60}]
    assert {:error, "INCORRECT", [%{code: :overlap}]} = CheckerStub.check(%{}, corrupted)

    # ── 5. snapshot replay: serialise → reconstruct from ids/hashes → verify
    json = CanonicalJSON.encode!(sealed)
    # The canonical encoding excludes the digest; it is stored beside it.
    replayed = reconstruct(json, PlanSnapshot.digest(sealed))
    assert PlanSnapshot.verify(replayed)
    assert PlanSnapshot.digest(replayed) == PlanSnapshot.digest(sealed)

    # A different model hash changes the digest; tampering breaks verification.
    other = PlanSnapshot.seal(snapshot(sha("another model")))
    refute PlanSnapshot.digest(other) == PlanSnapshot.digest(sealed)
    refute PlanSnapshot.verify(%{replayed | payload_hash: sha("tampered")})
  end

  test "AshOpenLineage cross-host golden digest is reproduced" do
    {:ok, eff, _} = DateTime.from_iso8601("2026-11-05T08:30:00.123456Z")
    {:ok, cut, _} = DateTime.from_iso8601("2026-11-04T22:00:00.000000Z")

    golden = %Snapshot{
      id: "019a2c7e-4b1d-7c2e-9f3a-5d6e7f8a9b0c",
      purpose: :"planning.personal_week",
      effective_at: eff,
      knowledge_cutoff: cut,
      world: :operational,
      authority: %{tenant: "t-demo-01", actor_id: "usr-042", completeness: :full},
      inputs: [
        %Input{
          key: "task.alpha",
          role: :demand,
          status: :value,
          source: %{resource: "Task", id: "task-1", version_number: 7},
          content_hash: "aa11"
        },
        %Input{
          key: "policy.hours",
          role: :parameter,
          status: :value,
          source: %{resource: "Policy", id: "pol-9", version_number: 2},
          content_hash: "bb22"
        },
        %Input{
          key: "policy.hours",
          role: :constraint,
          status: :unresolved,
          source: nil,
          content_hash: nil
        }
      ],
      definitions: [
        %Definition{
          kind: :dmn,
          key: "canonical.planning_requirements",
          version: "1.0.0",
          content_hash: "cc33"
        },
        %Definition{kind: :mzn, key: "personal_week", version: "3", content_hash: "dd44"}
      ],
      payload_hash: "ee55"
    }

    sealed = PlanSnapshot.seal(golden)
    assert PlanSnapshot.digest(sealed) == @golden_digest
  end
end
