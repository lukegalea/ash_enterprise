defmodule Battery.Integration.SimulationPerRunRowsTest do
  @moduledoc """
  Scenario — a simulation projection keeps one row per run.

  The vendor review is projected from the simulation twin by a projector that
  declares `simulation_projection: true`; its projection resource is grained by
  `(region, subject, simulation_run)`. Outcomes are drawn through the
  common-random-numbers identity, so two replications of the same subject differ
  only in their draw. Asserted: two runs of one subject give two rows, neither
  overwriting the other; a re-drain adds none; the operational projection and the
  real ledger are untouched; draining the real ledger through the simulation
  projector is refused; and a projector whose resource lacks the run in its grain
  does not compile.
  """

  use ExUnit.Case, async: false

  alias AshDiscreteBusinessEvents.Simulation.Identity
  alias Battery.BusinessEvents.{Ledger, SimulatedProjector, SimulatedVendorState, VendorState}

  @stream "crn-per-run"
  @vendor "vendor-9"

  setup do
    Ecto.Adapters.SQL.Sandbox.checkout(Battery.Repo, sandbox: false)
    Battery.Repo.query!("TRUNCATE ledger_events, ledger_simulation_events")

    for table <-
          ~w(battery_vendor_states battery_simulated_vendor_states bizev_projection_checkpoints
             bizev_projection_dead_letter_events bizev_projection_registry battery_event_log) do
      Battery.Repo.query!("DELETE FROM " <> table)
    end

    :ok
  end

  defp outcome(vendor, replication) do
    draw = Identity.draw(subject: vendor, random_stream_id: @stream, replication_id: replication)
    if draw < 0.5, do: "approved", else: "rejected"
  end

  defp simulate!(run, replication) do
    Ledger.SimulationEvent.record!(
      %{
        event_kind: :"vendor_review.completed",
        region: :us,
        residency_tag: "us",
        subject_type: "vendor",
        subject_external_id: @vendor,
        subject_stream: :vendor,
        occurred_at: ~U[2026-11-09 09:00:00.000000Z],
        delivery_key: "per-run:#{run}",
        simulation_run: run,
        provenance: %{
          "mapping_name" => "planning_evaluation",
          "mapping_version_hash" => "manual",
          "source_record_id" => nil
        },
        data: %{"review_status" => outcome(@vendor, replication), "reviewer" => "simulated"}
      },
      authorize?: false
    )
  end

  defp rows, do: Ash.read!(SimulatedVendorState, authorize?: false)

  # Two replications that draw differently, found from the identity itself.
  defp differing_replications do
    Enum.find_value(0..40, fn n ->
      if outcome(@vendor, n) != outcome(@vendor, n + 1), do: {n, n + 1}
    end)
  end

  test "the real ledger cannot be drained through a simulation projector" do
    assert SimulatedProjector.__simulation_projection__()

    assert_raise ArgumentError, ~r/simulation_projection: true/, fn ->
      SimulatedProjector.drain(:us)
    end

    assert rows() == []
  end

  test "a simulation projector whose resource lacks the run in its grain does not compile" do
    assert_raise ArgumentError, ~r/must include :simulation_run/, fn ->
      Code.compile_string("""
      defmodule Battery.Integration.SimulationPerRunRowsTest.NoRunProjector do
        use AshDiscreteBusinessEvents.Projections,
          name: "vendor_state_no_run_v1",
          event_log: Battery.BusinessEvents.Ledger,
          projection_resource: Battery.BusinessEvents.VendorState,
          simulation_projection: true

        grain(fn event -> %{region: event.region, subject: event.record_id} end)
      end
      """)
    end
  end

  test "two runs of one subject give two rows, each with its own draw" do
    {r0, r1} = differing_replications()
    run0 = "run-#{r0}"
    run1 = "run-#{r1}"

    simulate!(run0, r0)
    simulate!(run1, r1)

    assert SimulatedProjector.drain_simulation(run0, :us) == 1
    assert SimulatedProjector.drain_simulation(run1, :us) == 1

    by_run = Map.new(rows(), &{&1.simulation_run, &1})
    assert map_size(by_run) == 2
    assert by_run[run0].subject == by_run[run1].subject
    assert by_run[run0].review_status == outcome(@vendor, r0)
    assert by_run[run1].review_status == outcome(@vendor, r1)
    refute by_run[run0].review_status == by_run[run1].review_status
  end

  test "a re-drain adds no row, and the operational projection and ledger stay empty" do
    simulate!("run-again", 0)

    assert SimulatedProjector.drain_simulation("run-again", :us) == 1
    assert SimulatedProjector.drain_simulation("run-again", :us) == 0
    assert length(rows()) == 1

    assert Ash.read!(Ledger, authorize?: false) == []
    assert Ash.read!(VendorState, authorize?: false) == []
  end
end
