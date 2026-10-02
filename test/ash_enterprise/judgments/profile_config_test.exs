defmodule AshEnterprise.Judgments.ProfileConfigTest do
  @moduledoc """
  The host's instrument profile wiring (`config/runtime.exs`), as assertions.

  A profile is host configuration, never code (S1-23: nothing
  model-specific in code), so these tests pin the *shape* of the wiring —
  every entry validates, every local model has a route, and no URL, key or
  digest is committed as a literal — rather than any particular model.
  """

  use ExUnit.Case, async: true

  alias AshJudgments.Profile

  test "every configured profile builds through the package schema" do
    # registry/1 runs new!/1 on every entry: a typo in the config is a
    # failure here, not a boot surprise in some other environment.
    assert profiles = Profile.registry()
    assert length(profiles) >= 2
  end

  test "every profile is in-zone, in-region, and carries no literal transport" do
    for profile <- Profile.registry() do
      assert profile.residency == :in_cluster,
             "#{profile.name} must be in_cluster on this deployment (ADR 0042)"

      assert profile.region == :ca, "#{profile.name} must pin the stack's region"

      assert {:system, _} = profile.api_key,
             "#{profile.name}: api_key accepts only {:system, var} — never a literal"

      if profile.base_url do
        assert {:system, _} = profile.base_url,
               "#{profile.name}: base_url accepts only {:system, var}"
      end

      if profile.digest do
        assert {:system, _} = profile.digest,
               "#{profile.name}: digests are fetched at warm time, never committed"
      end
    end
  end

  test "the route map names a host for every profile's model" do
    routes = Application.get_env(:ash_judgments, :model_routes)

    # A non-empty route map is authoritative: a model without an entry would
    # be a loud RouteMissing at call time. Catch it here, at test time.
    assert is_map(routes) and routes != %{}

    for profile <- Profile.registry() do
      assert Map.has_key?(routes, profile.model),
             "model_routes has no entry for #{inspect(profile.model)}"

      assert {:system, _} = Map.fetch!(routes, profile.model)
    end
  end

  test "the registered residency policy is this host's" do
    assert Application.get_env(:ash_judgments, :residency_policy) ==
             AshEnterprise.Zones.ResidencyPolicy
  end

  test "the stack region is declared" do
    # The package's region guard refuses every profile when it is missing.
    assert Application.get_env(:ash_judgments, :region) == :ca
  end
end
