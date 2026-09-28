defmodule AshEnterprise.Zones.AdmitChangeTest do
  # Not async: the zone declarations are application config.
  use ExUnit.Case, async: false

  alias AshEnterprise.Zones
  alias AshEnterprise.Zones.Errors.{Inadmissible, UndeclaredZone}
  alias AshEnterprise.Zones.TestItem

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    today = Date.utc_today()

    declaration = %{
      "id" => "test-ontario",
      "jurisdiction" => "CA-ON",
      "classification_ceiling" => "customer_confidential",
      "inadmissible_restrictions" => ["US"],
      "declared_by" => "Test Operator",
      "declared_at" => Date.to_iso8601(Date.add(today, -1)),
      "review_by" => Date.to_iso8601(Date.add(today, 30))
    }

    path = Path.join(tmp_dir, "test-ontario.json")
    File.write!(path, Jason.encode!(declaration))

    previous = Application.get_env(:ash_enterprise, Zones)
    Application.put_env(:ash_enterprise, Zones, declarations: [path])

    on_exit(fn ->
      if previous,
        do: Application.put_env(:ash_enterprise, Zones, previous),
        else: Application.delete_env(:ash_enterprise, Zones)
    end)

    %{path: path, declaration: declaration}
  end

  defp ingest(attrs, action \\ :ingest) do
    TestItem
    |> Ash.Changeset.for_create(action, attrs, authorize?: false)
    |> Ash.create(authorize?: false)
  end

  defp refusal({:error, %Ash.Error.Invalid{errors: errors}}) do
    Enum.find(errors, &match?(%Inadmissible{}, &1)) ||
      Enum.find(errors, &match?(%UndeclaredZone{}, &1))
  end

  test "admits Canadian-restricted customer data into the Ontario zone" do
    assert {:ok, item} =
             ingest(%{label: "a", data_class: :customer_confidential, residency: "CA"})

    assert item.residency == "CA"
  end

  test "refuses US-only data, naming the zone and the field but not the data" do
    result = ingest(%{label: "a private label", data_class: :internal, residency: "US"})

    assert %Inadmissible{
             zone: "test-ontario",
             reason: :inadmissible_restriction,
             field: :residency
           } =
             error = refusal(result)

    refute Exception.message(error) =~ "a private label"
  end

  test "refuses untagged data until it is tagged" do
    assert %Inadmissible{reason: :untagged_residency, field: :residency} =
             refusal(ingest(%{label: "a", data_class: :internal}))

    assert %Inadmissible{reason: :untagged_data_class, field: :data_class} =
             refusal(ingest(%{label: "a", residency: "CA"}))
  end

  test "refuses re-tagging a stored record to a restriction the zone cannot hold" do
    {:ok, item} = ingest(%{label: "a", data_class: :internal, residency: "CA"})

    result =
      item
      |> Ash.Changeset.for_update(:retag, %{residency: "US"}, authorize?: false)
      |> Ash.update(authorize?: false)

    assert %Inadmissible{reason: :inadmissible_restriction} = refusal(result)

    assert {:ok, %{residency: "CA-ON"}} =
             item
             |> Ash.Changeset.for_update(:retag, %{residency: "CA-ON"}, authorize?: false)
             |> Ash.update(authorize?: false)
  end

  test "fails closed when the store's zone has no declaration" do
    assert %UndeclaredZone{zone: "not-declared"} =
             refusal(
               ingest(
                 %{label: "a", data_class: :public, residency: "unrestricted"},
                 :ingest_elsewhere
               )
             )
  end

  test "fails closed when no zones are configured at all" do
    Application.delete_env(:ash_enterprise, Zones)

    assert %UndeclaredZone{zone: "test-ontario"} =
             refusal(ingest(%{label: "a", data_class: :public, residency: "unrestricted"}))
  end

  test "a lapsed declaration admits nothing", %{path: path, declaration: declaration} do
    lapsed =
      declaration
      |> Map.put("declared_at", Date.to_iso8601(Date.add(Date.utc_today(), -100)))
      |> Map.put("review_by", Date.to_iso8601(Date.add(Date.utc_today(), -1)))

    File.write!(path, Jason.encode!(lapsed))

    assert %Inadmissible{reason: :declaration_lapsed, field: nil} =
             refusal(ingest(%{label: "a", data_class: :public, residency: "unrestricted"}))
  end

  test "two declarations with the same id are a configuration error", %{path: path} do
    Application.put_env(:ash_enterprise, Zones, declarations: [path, path])
    assert_raise ArgumentError, ~r/more than once/, fn -> Zones.all() end
  end
end
