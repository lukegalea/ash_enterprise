defmodule AshEnterprise.JourneyLedgerTest do
  @moduledoc """
  The documentation ledger: every surface and row action the browser tier adopts
  (`AshEnterpriseWeb.E2E.Surfaces`) is walked by a journey whose approved run
  the lock holds current in every locale, or carries a hand-written
  `:undocumented` waiver there. It runs with no browser, from the declarations
  and `priv/journeys/`.

  It also reports how much of the whole registry (`AshEnterprise.Surfaces.all/0`
  and the row actions of each surface's A2UI manifest) the journeys walk.
  Waivers do not count toward that number.
  """

  use ExUnit.Case, async: true

  alias AshBrowserTests.{Action, Journeys, Ledger, Surface}
  alias AshEnterpriseWeb.E2E.Surfaces, as: Host
  alias AshJourneys.Lock

  defp journeys, do: Application.fetch_env!(:ash_journeys, :journeys)

  test "every adopted surface and row action is walked by an approved journey or waived by hand" do
    assert :ok = Journeys.assert_documented!(Host, journeys())
  end

  test "the waivers here pass the ledger's own refusals" do
    undocumented = Enum.filter(Host.waivers(), &(elem(&1, 0) == :undocumented))
    assert undocumented != []
    assert Ledger.waiver_problems(undocumented) == []
  end

  describe "a journey the lock does not hold current walks nothing" do
    # A copy of the committed lock and approved runs, so one can be broken.
    defp copied_root do
      root =
        Path.join(System.tmp_dir!(), "ae_journey_ledger_#{System.unique_integer([:positive])}")

      File.mkdir_p!(Path.join(root, "priv"))
      File.cp_r!("priv/journeys", Path.join(root, "priv/journeys"))
      on_exit(fn -> File.rm_rf!(root) end)
      root
    end

    defp edit_lock!(root, fun) do
      {:ok, lock} = Lock.read(root)
      Lock.write!(fun.(lock), root)
    end

    test "one locale unapproved: what the journey walks is undocumented, and the reason is named" do
      root = copied_root()

      edit_lock!(root, fn lock ->
        update_in(lock.journeys["revoke_a_leavers_access"], &Map.delete(&1, "fr"))
      end)

      error =
        assert_raise ExUnit.AssertionError, fn ->
          Journeys.assert_documented!(Host, journeys(), root: root)
        end

      assert error.message =~ ~s|surface "users" is in no journey|

      assert error.message =~
               ~s|action "row:table.deactivate" on surface "users" is in no journey|

      assert error.message =~
               "journey revoke_a_leavers_access walks nothing yet: fr is unapproved"
    end

    test "a stale run: the pinned build moved after approval" do
      root = copied_root()
      edit_lock!(root, &%{&1 | browser: %{name: "chromium", version: "999.0.0.0"}})

      error =
        assert_raise ExUnit.AssertionError, fn ->
          Journeys.assert_documented!(Host, journeys(), root: root)
        end

      assert error.message =~ ~s|surface "users" is in no journey|
      assert error.message =~ "journey revoke_a_leavers_access walks nothing yet: en is stale"
    end
  end

  test "registry coverage: what the approved journeys walk, out of every surface and row action" do
    {:ok, %{documented: documented}} = Journeys.proven(journeys(), File.cwd!())
    coverage = Ledger.documentation_coverage(registry(), documented)

    IO.puts(
      "[journeys] documented by an approved journey: " <>
        "#{coverage.surfaces.documented} of #{coverage.surfaces.of} registry surfaces, " <>
        "#{coverage.actions.documented} of #{coverage.actions.of} row actions"
    )

    # Every surface a current journey walks is in the registry under the same id,
    # so the number is never short for a naming mismatch.
    registry_ids = MapSet.new(registry(), & &1.id)
    walked = for {:journey, _id, {:surface, surface}} <- documented, uniq: true, do: surface
    pages = ["launcher", "sign_in"]

    assert Enum.reject(walked, &(&1 in pages)) |> Enum.all?(&MapSet.member?(registry_ids, &1))
    assert coverage.surfaces.documented == length(Enum.reject(walked, &(&1 in pages)))
    assert coverage.actions.documented > 0
  end

  # The whole registry, each surface with the row actions of its manifest, named as
  # the ledger names them.
  defp registry do
    opts = AshEnterpriseWeb.Locale.a2ui_opts("en")

    for %{path: path} = surface <- AshEnterprise.Surfaces.all(), is_binary(path) do
      actions =
        case surface.ui && AshA2ui.Manifest.for_surface(surface.ui, opts) do
          %{row_actions: row_actions} -> Enum.map(row_actions, &%Action{id: "row:#{&1.id}"})
          _no_manifest -> []
        end

      %Surface{id: to_string(surface.key), path: path, actions: actions}
    end
  end
end
