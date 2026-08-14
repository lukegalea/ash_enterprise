defmodule AshEnterprise.ReferenceTest do
  @moduledoc """
  Smoke tests for the Reference domain -- the proof-of-concept output of
  `mix cdm.gen.resource`, see docs/HANDOFF.md.

  These are not exhaustive resource tests; they exist to confirm the generated
  attributes, identities and (for Currency) tenant scoping actually behave as
  declared, not merely that the module compiles.
  """

  use AshEnterprise.DataCase, async: false

  alias AshEnterprise.Reference.Currency
  alias AshEnterprise.Reference.LanguageLocale
  alias AshEnterprise.Reference.TimeZoneDefinition

  @opts [authorize?: false]

  defp org_id, do: Ash.UUID.generate()

  describe "Currency" do
    test "is scoped per tenant -- the same ISO code is not a global conflict" do
      org_a = org_id()
      org_b = org_id()

      attrs = %{
        exchange_rate: Decimal.new("1.0"),
        currency_symbol: "$",
        currency_name: "US Dollar",
        iso_currency_code: "USD",
        currency_precision: 2
      }

      assert %Currency{} =
               Currency
               |> Ash.Changeset.for_create(:create, attrs, Keyword.put(@opts, :tenant, org_a))
               |> Ash.create!()

      # Same code, different tenant: must not collide.
      assert %Currency{} =
               Currency
               |> Ash.Changeset.for_create(:create, attrs, Keyword.put(@opts, :tenant, org_b))
               |> Ash.create!()

      # Same code, same tenant: must collide.
      assert {:error, error} =
               Currency
               |> Ash.Changeset.for_create(:create, attrs, Keyword.put(@opts, :tenant, org_a))
               |> Ash.create()

      assert Exception.message(error) =~ "iso_currency_code"
    end
  end

  describe "TimeZoneDefinition" do
    test "is global -- no tenant required, and time_zone_code is unique across all tenants" do
      attrs = %{
        standard_name: "Pacific Standard Time",
        time_zone_code: 4,
        user_interface_name: "(UTC-08:00) Pacific Time",
        retired_order: 0
      }

      assert %TimeZoneDefinition{} =
               TimeZoneDefinition
               |> Ash.Changeset.for_create(:create, attrs, @opts)
               |> Ash.create!()

      assert {:error, error} =
               TimeZoneDefinition
               |> Ash.Changeset.for_create(:create, attrs, @opts)
               |> Ash.create()

      assert Exception.message(error) =~ "time_zone_code"
    end
  end

  describe "LanguageLocale" do
    test "is global -- no tenant required, and locale_id is unique across all tenants" do
      attrs = %{
        locale_id: 1033,
        code: "en-US",
        language: "English",
        name: "English (United States)"
      }

      assert %LanguageLocale{} =
               LanguageLocale
               |> Ash.Changeset.for_create(:create, attrs, @opts)
               |> Ash.create!()

      assert {:error, error} =
               LanguageLocale
               |> Ash.Changeset.for_create(:create, attrs, @opts)
               |> Ash.create()

      assert Exception.message(error) =~ "locale_id"
    end
  end
end
