defmodule Battery.Integration.CrnIdentityTest do
  @moduledoc """
  Scenario — common random numbers, at the host's pins.

  Comparing two simulated candidates is sound only when both draw the same
  random numbers. `AshDiscreteBusinessEvents.Simulation.Identity` seeds a draw
  by `(subject, random_stream_id, replication_id)` and nothing else. Asserted:
  anything about the candidate, the snapshot, the model or the run's label is
  refused as an input; a missing stream is refused, never defaulted; the same
  triple draws the same number whichever candidate asks, so two identical plans
  differ by exactly zero; each field of the triple on its own changes the draw;
  and one seed is pinned, because changing it re-rolls every recorded run.
  """

  use ExUnit.Case, async: true

  alias AshDiscreteBusinessEvents.Simulation.Identity

  @triple [subject: "vendor-1", random_stream_id: "arrivals", replication_id: 0]

  describe "what is refused" do
    for key <- [:candidate_id, :snapshot_digest, :model_hash, :label, :simulation_run] do
      test "#{key} is not an input of the draw" do
        assert_raise ArgumentError, ~r/unknown key/, fn ->
          Identity.seed([{unquote(key), "x"} | @triple])
        end
      end
    end

    test "a missing random_stream_id is refused, never defaulted" do
      assert_raise ArgumentError, ~r/missing required key :random_stream_id/, fn ->
        Identity.seed(subject: "vendor-1", replication_id: 0)
      end

      assert_raise ArgumentError, ~r/random_stream_id must be a non-empty binary/, fn ->
        Identity.seed(Keyword.put(@triple, :random_stream_id, ""))
      end
    end

    test "a negative or non-integer replication is refused" do
      for bad <- [-1, "0", 0.0, nil] do
        assert_raise ArgumentError, fn ->
          Identity.seed(Keyword.put(@triple, :replication_id, bad))
        end
      end
    end
  end

  describe "the property" do
    test "two candidates draw the same number for the same subject, stream and replication" do
      draws = fn _candidate ->
        for n <- 1..12, do: Identity.draw(Keyword.put(@triple, :subject, "vendor-#{n}"))
      end

      assert draws.(:plan_a) == draws.(:plan_b)

      # a paired difference between identical plans is exactly zero
      assert Enum.zip_with(draws.(:plan_a), draws.(:plan_b), &(&1 - &2)) ==
               List.duplicate(0.0, 12)
    end

    test "each field of the triple alone changes the draw" do
      base = Identity.seed(@triple)

      for changed <- [
            Keyword.put(@triple, :subject, "vendor-2"),
            Keyword.put(@triple, :random_stream_id, "service"),
            Keyword.put(@triple, :replication_id, 1)
          ] do
        refute Identity.seed(changed) == base
      end
    end

    test "a keyword list and a map give the same seed, in any order" do
      assert Identity.seed(@triple) == Identity.seed(Map.new(@triple))
      assert Identity.seed(@triple) == Identity.seed(Enum.reverse(@triple))
    end

    test "a draw is in [0, 1) and the seed is pinned" do
      assert Identity.seed(@triple) == Identity.seed(@triple)

      assert Identity.seed(subject: "subject-1", random_stream_id: "arrivals", replication_id: 0) ==
               7_051_631_904_854_280_433

      for n <- 0..50 do
        draw = Identity.draw(Keyword.put(@triple, :replication_id, n))
        assert draw >= 0.0 and draw < 1.0
      end
    end
  end
end
