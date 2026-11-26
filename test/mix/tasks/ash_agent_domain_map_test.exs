defmodule Mix.Tasks.AshAgent.DomainMapTest do
  use ExUnit.Case, async: true

  alias AshAgentTools.DomainMap

  @source "docs/domain-map.json"
  @target "docs/DOMAIN-MAP.md"
  @lock "mix.lock"

  defp data, do: @source |> File.read!() |> Jason.decode!()

  test "the committed map passes validation" do
    assert DomainMap.validate!(data()) == :ok
  end

  # One-directional on purpose: several real contexts own no Ash domain, so a
  # domain missing a context is an error while an unregistered context is not.
  test "every registered domain has a context" do
    json = data()

    registered =
      Application.get_env(:ash_enterprise, :ash_domains, [])
      |> Enum.map(&String.replace_prefix(Atom.to_string(&1), "Elixir.", ""))
      |> MapSet.new()

    mapped =
      json["contexts"] |> Enum.map(& &1["domain"]) |> Enum.reject(&is_nil/1) |> MapSet.new()

    unregistered = MapSet.to_list(MapSet.difference(registered, mapped))

    assert unregistered == [],
           "domains in :ash_domains with no context in #{inspect(@source)}: #{inspect(unregistered)}"
  end

  test "every first-party lock entry is claimed by a substrate or a context package" do
    {lock, _} = @lock |> File.read!() |> Code.eval_string()

    orgs = data()["first_party_orgs"]

    first_party =
      for {package, {:git, url, _rev, _opts}} <- lock,
          org <- orgs,
          String.contains?(url, org) do
        # `"name": value` in a map literal evaluates to atom keys.
        Atom.to_string(package)
      end
      |> Enum.sort()
      |> Enum.uniq()

    claimed =
      MapSet.new(
        data()["substrates"],
        & &1["package"]
      )
      |> MapSet.union(MapSet.new(Enum.flat_map(data()["contexts"], & &1["packages"])))

    unclaimed = Enum.sort(Enum.reject(first_party, &(&1 in claimed)))

    assert unclaimed == [],
           "first-party entries in mix.lock claimed nowhere: #{inspect(unclaimed)}"
  end

  test "the artifact renders a section for every context" do
    ids = Enum.map(data()["contexts"], & &1["id"])
    content = File.read!(@target)

    missing = Enum.reject(ids, &String.contains?(content, "domain-map:context:#{&1}:start"))

    assert missing == [],
           "contexts in #{inspect(@source)} with no region in #{inspect(@target)}: #{inspect(missing)}"
  end

  # HS-8 for this artefact: no vendor or product name anywhere in it. The
  # integration resources are code-named after the providers they sync, and the
  # renderer omits those rows; this test keeps the omission from rotting. The
  # scan list is the JSON's `vendor_tokens` — the same names the generator
  # omits rows for, scanned across the whole artifact.
  test "no vendor or product name appears in the artifact" do
    content = File.read!(@target)

    hits = Enum.filter(data()["vendor_tokens"], &String.contains?(content, &1))

    assert hits == [],
           "vendor/product names present in #{inspect(@target)}: #{inspect(hits)}"
  end
end
