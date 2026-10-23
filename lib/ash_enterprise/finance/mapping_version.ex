defmodule AshEnterprise.Finance.MappingVersion do
  @moduledoc """
  The finance mappings as data: BIZEV's `:mapping_version` on the platform
  base. One row per compiled mapping in `AshEnterprise.Finance.Declarations`,
  identified by its content hash, walked draft → validate → activate by
  `AshEnterprise.Finance.install!/0`. Every finance ledger row's
  `provenance` (`mapping_name` + `mapping_version_hash`) joins exactly one
  row here.

  Readable by anyone who reaches the application: a mapping is a rule
  compiled from this repository, the same for every tenant, holding no data.
  Written by machinery only (`install!/0`, with `authorize?: false`): there
  is no person path to a write, so nobody activates a rule by hand.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Finance,
    ownership: :none,
    tenant?: false,
    lifecycle?: false,
    archival?: false,
    policies?: false

  use AshDiscreteBusinessEvents.Resources, :mapping_version

  postgres do
    table "finance_mapping_versions"
    repo AshEnterprise.Repo
  end

  policies do
    bypass AshEnterprise.Security.Checks.SystemActor do
      authorize_if always()
    end

    # `AshDiscreteBusinessEvents.Mappings.active_version/2` and the activate
    # change read without an actor: the rules are not secrets.
    policy action_type(:read) do
      authorize_if always()
    end

    policy action_type([:create, :update, :destroy]) do
      authorize_if never()
    end
  end
end
