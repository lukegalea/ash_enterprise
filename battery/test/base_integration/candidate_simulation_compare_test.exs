defmodule Battery.Integration.CandidateSimulationCompareTest do
  @moduledoc """
  Scenario — planning: two candidates over the same week, evaluated on the
  simulation twin, reported apart from what actually happened.

  The cross-substrate seam: a planning solve (the package's Fake backend)
  proposes two candidates over one sealed snapshot; each is evaluated by
  drawing the outcomes of its planned reviews from a seeded stream, and the
  draws are recorded on the BIZEV ledger's simulation twin. Mirroring
  clinic-demo's `BusinessEvents.Scenarios`, a run's identity is the five-tuple

      (candidate_id, snapshot_digest, model_hash, random_stream_id, replication_id)

  and the run's LABEL is presentation only: the seed is `(subject, identity)`,
  never the label. Here the two candidates share a snapshot, a model and a
  random stream and differ in candidate and replication, so their identities
  differ in exactly those fields.

  Asserted: the five-tuples and their keys differ (and any single field alone
  moves the key); the same identity always draws the same outcomes whatever
  the run is called, while changing any one field draws independently; a
  partial identity is refused; every twin row says it is simulated, names its
  run, and carries the identity's ids and digests; the real ledger never holds
  a simulated row; the real projector folds only the operational events; and
  the report keeps simulated runs and the operational record in separate rows,
  never a sum.

  Synthetic vendor ids and slots; only ids, digests and counters cross.
  """

  use ExUnit.Case, async: false

  import Battery.PlanningKit

  alias AshOpenLineage.Snapshot
  alias AshOpenLineage.Snapshot.{Definition, Input}
  alias AshPlanning.Snapshot, as: PlanSnapshot
  alias Battery.BusinessEvents.{Ledger, Projector, VendorState}

  require Ash.Query

  @week_start ~U[2026-11-09 08:00:00.000000Z]
  @model "var 1..12: a; var 1..12: b; constraint a != b;"
  @stream "crn-2026-w46"
  @vendors for n <- 1..12, do: "vendor-#{n}"
  @planned length(@vendors)

  @identity_keys [
    :candidate_id,
    :snapshot_digest,
    :model_hash,
    :random_stream_id,
    :replication_id
  ]

  # P(a simulated review comes back approved), in percent: integers, so no
  # float enters the draw.
  @p_approved 60

  setup do
    Ecto.Adapters.SQL.Sandbox.checkout(Battery.Repo, sandbox: false)

    # The ledger's immutability trigger forbids DELETE; TRUNCATE is the
    # sanctioned, conspicuous reset.
    Battery.Repo.query!("TRUNCATE ledger_events, ledger_simulation_events")

    for table <-
          ~w(mapping_versions battery_vendor_states bizev_projection_checkpoints
             bizev_projection_dead_letter_events bizev_projection_registry battery_event_log) do
      Battery.Repo.query!("DELETE FROM " <> table)
    end

    :ok
  end

  # ── the planned week: one snapshot, one solve, two candidates ────────────

  defp week_snapshot do
    {:ok, cut, _} = DateTime.from_iso8601("2026-11-08T22:00:00.000000Z")

    %Snapshot{
      id: Ecto.UUID.generate(),
      purpose: :"planning.battery",
      effective_at: @week_start,
      knowledge_cutoff: cut,
      world: :scenario,
      authority: %{tenant: "t-battery", actor_id: "usr-battery", completeness: :full},
      inputs:
        for vendor <- @vendors do
          %Input{
            key: "review.#{vendor}",
            role: :demand,
            status: :value,
            source: %{resource: "VendorReview", id: vendor, version_number: 1},
            content_hash: sha(vendor)
          }
        end,
      definitions: [
        %Definition{kind: :mzn, key: "battery_week", version: "1", content_hash: sha(@model)}
      ],
      payload_hash: sha("lowered-week")
    }
    |> PlanSnapshot.seal()
  end

  # Candidate A reviews in id order; candidate B in reverse. Same vendors, same
  # week, different slots.
  defp layouts do
    forward = for {vendor, n} <- Enum.with_index(@vendors), do: %{"id" => vendor, "slot" => n * 2}

    backward =
      for {vendor, n} <- Enum.with_index(Enum.reverse(@vendors)),
          do: %{"id" => vendor, "slot" => n * 2}

    [forward, backward]
  end

  defp plan! do
    sealed = week_snapshot()
    {candidates, result} = solve!(for(l <- layouts(), do: %{assignments: l}))
    run_id = Ecto.UUID.generate()

    rows =
      for c <- candidates do
        propose!(run_id, c.index, c.data.assignments)
      end

    assert result.status == :feasible and result.complete?
    [a, b] = rows

    %{
      snapshot: sealed,
      a: a,
      b: b,
      digest: PlanSnapshot.digest(sealed),
      model_hash: PlanSnapshot.definition(sealed, :mzn, "battery_week").content_hash
    }
  end

  # ── the evaluation identity (the five-tuple), after clinic-demo ──────────

  defp identity!(opts) do
    given = Enum.filter(@identity_keys, &Keyword.has_key?(opts, &1))

    if length(given) != length(@identity_keys) do
      raise ArgumentError,
            "planning identity needs all of #{inspect(@identity_keys)}; " <>
              "missing #{inspect(@identity_keys -- given)}"
    end

    Map.new(@identity_keys, &{&1, Keyword.fetch!(opts, &1)})
  end

  # One canonical string: the five in fixed order, joined by a byte no id,
  # digest or counter can contain.
  defp identity_key(identity),
    do: Enum.map_join(@identity_keys, <<0>>, &to_string(Map.fetch!(identity, &1)))

  # Content-addressed, so two identities never share a delivery-key namespace;
  # presentation only, never part of a seed.
  defp default_label(identity),
    do: "plan:" <> binary_part(sha(identity_key(identity)), 0, 16)

  # The draw is seeded by (subject, identity) ALONE: never the label, never
  # the clock.
  defp draw(vendor, identity) do
    <<a::unsigned-integer-32, b::unsigned-integer-32, c::unsigned-integer-32, _::binary>> =
      :crypto.hash(:sha256, vendor <> ":plan:" <> identity_key(identity))

    {percent, _state} = :rand.uniform_s(100, :rand.seed_s(:exsss, {a, b, c}))
    if percent <= @p_approved, do: "approved", else: "rejected"
  end

  defp draws(identity), do: Map.new(@vendors, &{&1, draw(&1, identity)})

  # Records one candidate's evaluation on the twin: each planned review's drawn
  # outcome, through the same event kind the operational reviews use.
  defp evaluate!(%{assignments: assignments}, identity, label \\ nil) do
    label = label || default_label(identity)

    for %{"id" => vendor, "slot" => slot} <- Jason.decode!(assignments) do
      Ledger.SimulationEvent.record!(
        %{
          event_kind: :"vendor_review.completed",
          region: :us,
          residency_tag: "us",
          subject_type: "vendor",
          subject_external_id: vendor,
          subject_stream: :vendor,
          occurred_at: DateTime.add(@week_start, slot * 30 * 60, :second),
          delivery_key: "scenario:#{label}:#{vendor}",
          simulation_run: label,
          provenance: %{
            "mapping_name" => "planning_evaluation",
            "mapping_version_hash" => "manual",
            "source_record_id" => nil
          },
          context: %{"evaluation" => Map.new(identity, fn {k, v} -> {to_string(k), v} end)},
          data: %{"review_status" => draw(vendor, identity), "reviewer" => "simulated"}
        },
        authorize?: false
      )
    end

    label
  end

  # What actually happened that week: two reviews, on the real ledger.
  defp record_operational! do
    for {vendor, status} <- [{"vendor-1", "approved"}, {"vendor-2", "rejected"}] do
      Ledger.record!(%{
        event_kind: :"vendor_review.completed",
        region: :us,
        residency_tag: "us",
        subject_type: "vendor",
        subject_external_id: vendor,
        subject_stream: :vendor,
        occurred_at: DateTime.add(@week_start, 3 * 3600, :second),
        data: %{"review_status" => status, "reviewer" => "Dana Ops"},
        provenance: %{
          "mapping_name" => "manual_vendor_review",
          "mapping_version_hash" => "manual",
          "source_record_id" => nil
        }
      })
    end
  end

  # ── the report: simulated and operational never share a row ──────────────

  defp twin_rows(label) do
    Ledger.SimulationEvent
    |> Ash.Query.filter(simulation_run == ^label)
    |> Ash.read!(authorize?: false)
  end

  defp simulated_report(label) do
    rows = twin_rows(label)

    %{
      kind: :simulated,
      run: label,
      evaluation: rows |> Enum.map(& &1.context["evaluation"]) |> Enum.uniq() |> one!(),
      events: length(rows),
      approved: Enum.count(rows, &(&1.data["review_status"] == "approved"))
    }
  end

  defp operational_report do
    rows = Ash.read!(Ledger, authorize?: false)

    %{
      kind: :operational,
      events: length(rows),
      approved: Enum.count(rows, &(&1.data["review_status"] == "approved"))
    }
  end

  defp one!([one]), do: one

  test "two candidates over one week get distinct evaluation identities" do
    %{a: a, b: b, digest: digest, model_hash: model_hash, snapshot: snapshot} = plan!()

    assert a.run_id == b.run_id
    refute a.id == b.id

    ia =
      identity!(
        candidate_id: a.id,
        snapshot_digest: digest,
        model_hash: model_hash,
        random_stream_id: @stream,
        replication_id: 0
      )

    ib = %{ia | candidate_id: b.id, replication_id: 1}

    # same week, same model, same stream; different candidate and replication
    assert {ia.snapshot_digest, ia.model_hash, ia.random_stream_id} ==
             {ib.snapshot_digest, ib.model_hash, ib.random_stream_id}

    refute ia == ib
    refute identity_key(ia) == identity_key(ib)
    refute default_label(ia) == default_label(ib)

    # any ONE field moves the key, so no two evaluations alias
    mutations = [
      %{ia | candidate_id: b.id},
      %{ia | snapshot_digest: sha("another week")},
      %{ia | model_hash: sha("another model")},
      %{ia | random_stream_id: "crn-2026-w47"},
      %{ia | replication_id: 1}
    ]

    keys = Enum.map([ia | mutations], &identity_key/1)
    assert length(Enum.uniq(keys)) == 6

    # the digest and the model hash are the snapshot's, not invented here
    assert PlanSnapshot.verify(snapshot)
    assert ia.snapshot_digest =~ ~r/\A[0-9a-f]{64}\z/
    assert ia.model_hash == sha(@model)
  end

  test "simulated runs and the operational record are reported apart, and never mix" do
    %{a: a, b: b, digest: digest, model_hash: model_hash} = plan!()

    ia =
      identity!(
        candidate_id: a.id,
        snapshot_digest: digest,
        model_hash: model_hash,
        random_stream_id: @stream,
        replication_id: 0
      )

    ib = %{ia | candidate_id: b.id, replication_id: 1}

    # ── the operational record, and the twin's two runs ──────────────────
    record_operational!()
    label_a = evaluate!(a, ia)
    label_b = evaluate!(b, ib)

    refute label_a == label_b

    # ── the real ledger holds ONLY what happened ─────────────────────────
    real = Ash.read!(Ledger, authorize?: false)
    assert length(real) == 2

    # a real row cannot be simulated: the resource has no such column at all
    assert is_nil(Ash.Resource.Info.attribute(Ledger, :simulated))
    assert is_nil(Ash.Resource.Info.attribute(Ledger, :simulation_run))
    assert Enum.all?(real, &(is_nil(&1.context) or not Map.has_key?(&1.context, "evaluation")))

    # ── the twin: every row says so, names its run, carries its identity ─
    twin = Ash.read!(Ledger.SimulationEvent, authorize?: false)
    assert length(twin) == 2 * @planned
    assert Enum.all?(twin, &(&1.simulated == true))

    assert twin |> Enum.map(& &1.simulation_run) |> Enum.uniq() |> Enum.sort() ==
             Enum.sort([label_a, label_b])

    for {label, identity} <- [{label_a, ia}, {label_b, ib}] do
      rows = twin_rows(label)
      assert length(rows) == @planned

      assert Enum.all?(
               rows,
               &(&1.context["evaluation"] == Map.new(identity, fn {k, v} -> {to_string(k), v} end))
             )
    end

    # the package's supported read lists the runs apart, each over its own events
    assert [%{events: @planned, subjects: @planned}, %{events: @planned, subjects: @planned}] =
             AshDiscreteBusinessEvents.simulation_runs(Ledger)

    assert Enum.sort(
             Enum.map(AshDiscreteBusinessEvents.simulation_runs(Ledger), & &1.simulation_run)
           ) ==
             Enum.sort([label_a, label_b])

    # ── the report: three rows, three kinds of fact, no total ────────────
    report_a = simulated_report(label_a)
    report_b = simulated_report(label_b)
    operational = operational_report()

    assert report_a.kind == :simulated and report_b.kind == :simulated
    assert operational.kind == :operational

    assert {report_a.events, report_b.events, operational.events} == {@planned, @planned, 2}
    assert report_a.evaluation["candidate_id"] == a.id
    assert report_b.evaluation["candidate_id"] == b.id

    assert {report_a.evaluation["replication_id"], report_b.evaluation["replication_id"]} ==
             {0, 1}

    # each simulated approval count is that run's draws and nothing else
    assert report_a.approved == ia |> draws() |> Map.values() |> Enum.count(&(&1 == "approved"))
    assert report_b.approved == ib |> draws() |> Map.values() |> Enum.count(&(&1 == "approved"))
    assert operational.approved == 1

    # ── the real projector folds only the operational events ─────────────
    assert Projector.drain(:us) == 2

    states = VendorState |> Ash.read!() |> Map.new(&{&1.subject, &1.review_status})
    assert map_size(states) == 2
    assert states |> Map.keys() |> Enum.sort() == ["vendor-1", "vendor-2"]
    assert states == %{"vendor-1" => "approved", "vendor-2" => "rejected"}

    # a simulated verdict for a vendor nobody actually reviewed never reached it
    refute Map.has_key?(states, "vendor-12")
    assert Enum.any?(twin, &(&1.subject_external_id == "vendor-12"))
  end

  test "an identity draws the same outcomes whatever the run is called; any one field draws anew" do
    %{a: a, b: b, digest: digest, model_hash: model_hash} = plan!()

    ia =
      identity!(
        candidate_id: a.id,
        snapshot_digest: digest,
        model_hash: model_hash,
        random_stream_id: @stream,
        replication_id: 0
      )

    # ── the label is presentation only ────────────────────────────────────
    evaluate!(a, ia, "presentation-one")
    evaluate!(a, ia, "presentation-two")

    recorded = fn label ->
      label |> twin_rows() |> Map.new(&{&1.subject_external_id, &1.data["review_status"]})
    end

    assert recorded.("presentation-one") == recorded.("presentation-two")
    assert recorded.("presentation-one") == draws(ia)

    # and the draw is stable: the same identity, drawn again, is the same
    assert draws(ia) == draws(%{ia | candidate_id: ia.candidate_id})

    # ── change any one field and the draw is independent of the first ─────
    for changed <- [
          %{ia | candidate_id: b.id},
          %{ia | snapshot_digest: sha("another week")},
          %{ia | model_hash: sha("another model")},
          %{ia | random_stream_id: "crn-2026-w47"},
          %{ia | replication_id: 1}
        ] do
      refute draws(changed) == draws(ia)
    end
  end

  test "a partial identity is not an identity" do
    assert_raise ArgumentError, ~r/missing \[:model_hash, :replication_id\]/, fn ->
      identity!(
        candidate_id: Ecto.UUID.generate(),
        snapshot_digest: sha("week"),
        random_stream_id: @stream
      )
    end
  end
end
