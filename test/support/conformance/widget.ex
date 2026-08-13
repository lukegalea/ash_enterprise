defmodule AshEnterprise.Conformance.Widget do
  @moduledoc """
  A deliberately meaningless `:user_owned` resource, used only by the
  authorization conformance suite.

  ## Why a fake resource

  The conformance suite tests the *engine*, and the engine's behaviour depends on
  the ownership model and nothing else. Testing it against a real business entity
  would entangle the truth table with that entity's own validations, required
  fields and lifecycle — and every future change to that entity would perturb
  security tests for no reason.

  It also fills a genuine gap: none of the platform's own resources are
  `:user_owned`. Organization is organization-owned; BusinessUnit, Team and Role
  are business-owned; the join tables are unowned. So without this there is no way
  to exercise the `:basic` depth at all, which is the depth most likely to be
  wrong.

  ## Why the ETS data layer

  Ash policy checks produce data-layer-agnostic filter expressions, so the
  authorization *decisions* are identical on ETS and Postgres. Using ETS keeps
  this resource out of the production migration set entirely — a test-only table
  in `priv/repo/migrations` would ship to every deployment of this template.

  The Postgres path is not left untested: `business_unit_test.exs` exercises the
  materialized-path SQL, and the policy tests against real resources run through
  AshPostgres.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Conformance,
    ownership: :user_owned,
    data_layer: Ash.DataLayer.Ets,
    audit?: false,
    archival?: false

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
    end
  end

  actions do
    defaults [:read, :destroy]
    default_accept [:name, :owner_id, :owner_type, :owning_business_unit_id, :owning_user_id]

    create :create do
      primary? true
    end

    update :update do
      primary? true
    end
  end

  code_interface do
    define :create
    define :read
  end
end
