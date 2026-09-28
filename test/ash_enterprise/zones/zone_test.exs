defmodule AshEnterprise.Zones.ZoneTest do
  use ExUnit.Case, async: true

  alias AshEnterprise.Zones
  alias AshEnterprise.Zones.Zone

  @valid %{
    "id" => "lab",
    "jurisdiction" => "CA-ON",
    "classification_ceiling" => "customer_confidential",
    "inadmissible_restrictions" => ["US"],
    "declared_by" => "Operator",
    "declared_at" => "2026-09-28",
    "review_by" => "2026-12-27",
    "controls" => [
      %{"name" => "overlay network only", "status" => "in_place", "evidence" => "acl"},
      %{"name" => "hypervisor firewall", "status" => "gap"}
    ]
  }

  test "parses a valid declaration" do
    assert {:ok, %Zone{} = zone} = Zone.from_map(@valid)
    assert zone.jurisdiction == "CA-ON"
    assert zone.classification_ceiling == :customer_confidential
    assert zone.inadmissible_restrictions == ["US"]
    assert zone.review_by == ~D[2026-12-27]
    assert [%{name: "hypervisor firewall", status: :gap}] = Zone.gaps(zone)
  end

  test "reports every problem at once" do
    bad =
      @valid
      |> Map.put("jurisdiction", "Ontario")
      |> Map.put("classification_ceiling", "secret")
      |> Map.delete("declared_by")
      |> Map.put("inadmissible_restrictions", ["US", "usa"])

    assert {:error, problems} = Zone.from_map(bad)
    assert Enum.any?(problems, &String.starts_with?(&1, "jurisdiction "))
    assert Enum.any?(problems, &String.starts_with?(&1, "classification_ceiling "))
    assert "declared_by is required" in problems
    assert Enum.any?(problems, &String.starts_with?(&1, "inadmissible_restrictions [1]"))
  end

  test "a control marked in place must give evidence" do
    bad = Map.put(@valid, "controls", [%{"name" => "encryption", "status" => "in_place"}])
    assert {:error, [problem]} = Zone.from_map(bad)
    assert problem =~ "gives no evidence"
  end

  test "review_by must follow declared_at" do
    assert {:error, ["review_by must be after declared_at"]} =
             Zone.from_map(Map.put(@valid, "review_by", "2026-09-01"))
  end

  test "the shipped example declaration is valid and describes an Ontario zone that refuses US-only data" do
    zone = Zones.load!({:priv, "zones/examples/ontario.json"})
    assert zone.id == "example-ontario"
    assert zone.jurisdiction == "CA-ON"
    assert "US" in zone.inadmissible_restrictions

    on = zone.declared_at

    assert Zones.admit(zone, %{data_class: :customer_confidential, residency: "CA"}, on: on) ==
             :ok

    assert {:error, %Zones.Errors.Inadmissible{reason: :inadmissible_restriction}} =
             Zones.admit(zone, %{data_class: :internal, residency: "US"}, on: on)

    assert {:error, %Zones.Errors.Inadmissible{reason: :untagged_residency}} =
             Zones.admit(zone, %{data_class: :internal, residency: nil}, on: on)
  end

  test "load/1 explains an unreadable or malformed file" do
    assert {:error, message} = Zones.load("/nonexistent/zone.json")
    assert message =~ "cannot read"
  end
end
