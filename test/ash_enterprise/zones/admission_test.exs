defmodule AshEnterprise.Zones.AdmissionTest do
  use ExUnit.Case, async: true

  alias AshEnterprise.Zones.{Admission, Jurisdiction, Residency}
  alias AshEnterprise.Zones.Types.DataClass

  doctest Admission
  doctest Jurisdiction
  doctest Residency
  doctest DataClass

  @ontario %{
    jurisdiction: "CA-ON",
    classification_ceiling: :customer_confidential,
    inadmissible_restrictions: ["US"],
    review_by: ~D[2026-12-27]
  }

  defp check(tags, opts \\ []), do: Admission.check(@ontario, tags, opts)

  describe "residency" do
    test "admits unrestricted, Canada-restricted and Ontario-restricted data" do
      for residency <- ["unrestricted", "CA", "CA-ON"] do
        assert check(%{data_class: :customer_confidential, residency: residency}) == :ok
      end
    end

    test "refuses US-only data, and anything restricted to a US subdivision" do
      assert check(%{data_class: :internal, residency: "US"}) ==
               {:error, :inadmissible_restriction}

      assert check(%{data_class: :public, residency: "US-NY"}) ==
               {:error, :inadmissible_restriction}
    end

    test "refuses data restricted to a jurisdiction the zone is not inside, even if not declared inadmissible" do
      assert check(%{data_class: :internal, residency: "CA-QC"}) ==
               {:error, :restriction_unsatisfied}

      assert check(%{data_class: :internal, residency: "DE"}) ==
               {:error, :restriction_unsatisfied}
    end

    test "refuses untagged data until it is tagged" do
      assert check(%{data_class: :internal, residency: nil}) == {:error, :untagged_residency}
      assert check(%{data_class: nil, residency: "CA"}) == {:error, :untagged_data_class}
      assert check(%{}) == {:error, :untagged_data_class}
    end

    test "refuses a malformed residency tag rather than guessing" do
      assert check(%{data_class: :internal, residency: "canada"}) == {:error, :invalid_residency}
      assert check(%{data_class: :internal, residency: ""}) == {:error, :invalid_residency}
    end
  end

  describe "classification" do
    test "refuses data above the ceiling" do
      zone = %{@ontario | classification_ceiling: :internal}

      assert Admission.check(zone, %{data_class: :customer_confidential, residency: "CA"}) ==
               {:error, :above_ceiling}

      assert Admission.check(zone, %{data_class: :internal, residency: "CA"}) == :ok
    end

    test "accepts the class as a string, as it arrives from JSON" do
      assert check(%{data_class: "internal", residency: "CA"}) == :ok
      assert check(%{data_class: "secret", residency: "CA"}) == {:error, :invalid_data_class}
    end
  end

  describe "lapse" do
    test "a zone is valid through its review_by date and refuses everything after it" do
      tags = %{data_class: :public, residency: "unrestricted"}
      assert check(tags, on: ~D[2026-12-27]) == :ok
      assert check(tags, on: ~D[2026-12-28]) == {:error, :declaration_lapsed}
    end

    test "without a date, the pure check does not consult a clock" do
      assert check(%{data_class: :public, residency: "unrestricted"}) == :ok
    end
  end

  test "every reason has a description, and none of them carries data" do
    for reason <- [
          :declaration_lapsed,
          :untagged_data_class,
          :untagged_residency,
          :invalid_data_class,
          :invalid_residency,
          :above_ceiling,
          :inadmissible_restriction,
          :restriction_unsatisfied
        ] do
      assert is_binary(Admission.describe(reason))
    end
  end
end
