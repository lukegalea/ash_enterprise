defmodule AshEnterprise.Test.Provenance do
  @moduledoc """
  Test-only domain for the provenance walk's own tests (`AshEnterprise.Test.Provenance.Thing`).
  Compiled only in `:test` and never registered in `config :ash_enterprise,
  ash_domains`, so it cannot leak into a running application, the privilege
  catalogue or a migration.
  """

  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshEnterprise.Test.Provenance.Thing
  end
end

defmodule AshEnterprise.Test.Provenance.Thing do
  @moduledoc """
  An ETS thing with a secured sensitive column and a chain of calculations,
  one over the next, for the derived explainer's secured-column rule and the
  walk's bounds (ADR 0078). It declares its own permissive policies because
  only these tests read it, and nothing in it is real.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Test.Provenance,
    data_layer: Ash.DataLayer.Ets,
    ownership: :none,
    tenant?: false,
    lifecycle?: false,
    archival?: false,
    audit?: false,
    lineage?: false,
    secured_fields: [:sensitive],
    policies?: false

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id
    attribute :a, :string, public?: true
    attribute :sensitive, :string, public?: true, sensitive?: true
  end

  actions do
    defaults [:read, :create]
    default_accept [:a, :sensitive]
  end

  policies do
    bypass AshEnterprise.Security.Checks.SystemActor do
      authorize_if always()
    end

    policy action_type(:read) do
      authorize_if always()
    end

    policy action_type(:create) do
      authorize_if always()
    end
  end

  calculations do
    # A chain long enough that a small step bound cuts the walk: each names the
    # one before it, so explaining `d4` dispatches d3, d2, d1, then `a`.
    calculate :d1, :string, expr(a) do
      public? true
    end

    calculate :d2, :string, expr(d1) do
      public? true
    end

    calculate :d3, :string, expr(d2) do
      public? true
    end

    calculate :d4, :string, expr(d3) do
      public? true
    end

    # A derivation over the secured column: named as an antecedent, never
    # dispatched (ADR 0078, section 6).
    calculate :over_sensitive, :string, expr(sensitive) do
      public? true
    end
  end
end

defmodule AshEnterprise.Test.Provenance.Registry do
  @moduledoc """
  The walk's registry for `AshEnterprise.Test.Provenance.Thing`, with the same
  dispatch order as the host's (`AshEnterprise.Provenance.Registry`): the Thing
  is not in the host registry, because a test-only resource must not answer
  production addresses.
  """

  @tokens %{"test_thing" => AshEnterprise.Test.Provenance.Thing}

  def resource(token), do: Map.fetch(@tokens, token)

  def token(resource) when resource == AshEnterprise.Test.Provenance.Thing,
    do: {:ok, "test_thing"}

  def explainers_for(_resource, _field) do
    [
      AshEnterprise.Provenance.Explainers.Derived,
      AshEnterprise.Provenance.Explainers.Audit,
      AshEnterprise.Provenance.Explainers.RecordColumns
    ]
  end
end
