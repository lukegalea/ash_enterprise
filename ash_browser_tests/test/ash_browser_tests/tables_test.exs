defmodule AshBrowserTests.TablesTest do
  @moduledoc """
  The table generator's planning and its ledger, which are pure given a host.

  The ledger is the part worth testing, because its failure mode is silence: a
  table that stops being generated, or a waiver that outlives the thing it
  waived, both leave a suite that passes while covering less than it claims.
  Obligations are built from the manifests and never from the plans, precisely
  so a dropped table shows up as uncovered rather than disappearing — and that
  property is what these assert.

  No browser here. `run/2` needs one; everything below does not.
  """

  use ExUnit.Case, async: true

  alias AshBrowserTests.Surface
  alias AshBrowserTests.Tables

  defp table(id, opts \\ []) do
    %{
      id: id,
      presets: Keyword.get(opts, :presets, []),
      query: Keyword.get(opts, :query, %{})
    }
  end

  defp preset(name), do: %{name: name}

  # A host is just a module with the callbacks, so each test builds one.
  defp host(opts) do
    surfaces = Keyword.get(opts, :surfaces, [%Surface{id: "orders", path: "/orders"}])
    manifests = Keyword.get(opts, :manifests, %{})
    table_waivers = Keyword.get(opts, :table_waivers, [])
    waivers = Keyword.get(opts, :waivers, [])

    module = :"Host#{System.unique_integer([:positive])}"

    Module.create(
      module,
      quote do
        def surfaces, do: unquote(Macro.escape(surfaces))
        def manifests, do: unquote(Macro.escape(manifests))
        def table_waivers, do: unquote(Macro.escape(table_waivers))
        def waivers, do: unquote(Macro.escape(waivers))
      end,
      Macro.Env.location(__ENV__)
    )

    module
  end

  defp names(host), do: host |> Tables.generated() |> Enum.map(&elem(&1, 0))
  defp plans(host), do: host |> Tables.generated() |> Enum.map(&elem(&1, 1))

  describe "generated/1" do
    test "one test per table, plus one per switchable preset" do
      host =
        host(
          manifests: %{
            "orders" => %{tables: [table("all", presets: [preset("open"), preset("closed")])]}
          }
        )

      assert names(host) == [
               "table orders / all",
               "preset orders / all / open",
               "preset orders / all / closed"
             ]
    end

    test "a surface with no path is not generated" do
      host =
        host(
          surfaces: [%Surface{id: "webhooks", path: nil}],
          manifests: %{"webhooks" => %{tables: [table("all")]}}
        )

      assert Tables.generated(host) == []
    end

    test "a manifest keyed by an id no surface carries generates nothing" do
      # And the ledger below still counts it, which is the point.
      host = host(manifests: %{"ghost" => %{tables: [table("all")]}})

      assert Tables.generated(host) == []
    end

    test "a preset nobody can switch to gets no test of its own" do
      # `preset_picker: false` means the page chooses; the table's default view
      # is that preset's read, so a browser test for it would be the same test.
      host =
        host(
          manifests: %{
            "orders" => %{
              tables: [
                table("all", presets: [preset("open")], query: %{preset_picker: false})
              ]
            }
          }
        )

      assert names(host) == ["table orders / all"]
    end

    test "a waived table drops its presets with it" do
      host =
        host(
          manifests: %{"orders" => %{tables: [table("all", presets: [preset("open")])]}},
          table_waivers: [{:table, "orders", "all", "no data yet"}]
        )

      assert Tables.generated(host) == []
    end

    test "a waived preset leaves its table generated" do
      host =
        host(
          manifests: %{"orders" => %{tables: [table("all", presets: [preset("open")])]}},
          table_waivers: [{:preset, "orders", "all", "open", "flaky upstream"}]
        )

      assert names(host) == ["table orders / all"]
    end
  end

  describe "assert_ledger!/1" do
    test "passes when every table and preset is generated" do
      host =
        host(manifests: %{"orders" => %{tables: [table("all", presets: [preset("open")])]}})

      assert :ok = Tables.assert_ledger!(host)
    end

    test "a table the generator dropped is uncovered, not invisible" do
      # The manifest names a surface that does not exist, so nothing is
      # generated. Obligations come from the manifests, so this is a failure
      # rather than a silently smaller suite.
      host = host(manifests: %{"ghost" => %{tables: [table("all")]}})

      assert_raise ExUnit.AssertionError, ~r/ghost/, fn -> Tables.assert_ledger!(host) end
    end

    test "a waiver covers the obligation it names" do
      host =
        host(
          manifests: %{"ghost" => %{tables: [table("all")]}},
          table_waivers: [{:table, "ghost", "all", "surface retired, manifest not yet"}]
        )

      assert :ok = Tables.assert_ledger!(host)
    end

    test "a waiver with no reason is itself a problem" do
      host =
        host(
          manifests: %{"orders" => %{tables: [table("all")]}},
          table_waivers: [{:table, "orders", "all", ""}]
        )

      assert_raise ExUnit.AssertionError, ~r/reason/i, fn -> Tables.assert_ledger!(host) end
    end

    test "a waiver naming something no longer in any manifest is stale" do
      # The case that quietly accumulates: a table is deleted, its waiver stays,
      # and the next person reads it as a known gap.
      host =
        host(
          manifests: %{"orders" => %{tables: [table("all")]}},
          table_waivers: [{:table, "orders", "removed", "was flaky"}]
        )

      assert_raise ExUnit.AssertionError, ~r/removed/, fn -> Tables.assert_ledger!(host) end
    end

    test "a waived surface carries its tables, without a table waiver each" do
      host =
        host(
          surfaces: [%Surface{id: "orders", path: "/orders"}],
          manifests: %{"orders" => %{tables: [table("all", presets: [preset("open")])]}},
          waivers: [{:surface, "orders", "behind a flag"}]
        )

      assert :ok = Tables.assert_ledger!(host)
    end

    test "an unswitchable preset is covered by its table's test, not left open" do
      host =
        host(
          manifests: %{
            "orders" => %{
              tables: [
                table("all", presets: [preset("open")], query: %{preset_picker_label: nil})
              ]
            }
          }
        )

      assert plans(host) == [{:table, "orders", "all", nil}]
      assert :ok = Tables.assert_ledger!(host)
    end
  end
end
