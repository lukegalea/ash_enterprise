defmodule Battery.Operations.Registry do
  @moduledoc """
  The battery's provider, declared with `AshOperations`: a synthetic registry that takes
  activations. Three operations over one vendored spec pinned by sha-256, one transport
  (`Battery.Operations.Transport`) and one disclosure gate (`Battery.Operations.Gate`).

    * `create_activation` writes and is not idempotent: a lost answer is `:ambiguous`,
      reconciled through `list_activations` by the caller's own `client_reference`, never
      re-sent. It sends data about a subject, so it discloses.
    * `list_activations` and `get_activation` read.

  A plain resource with no data layer and no rows: the actions are the declared operations.
  """

  use Ash.Resource,
    domain: Battery.Domain,
    extensions: [AshOperations]

  operations do
    provider :battery_registry
    transport Battery.Operations.Transport
    spec "priv/operations/registry.openapi.json"
    spec_sha256 "116f98b7b47c12ac6dfe899e69735771c8877e5f4bf403d70c7b98421d561109"
    disclosure_gate Battery.Operations.Gate
    telemetry_prefix [:battery_operations, :request]

    operation :create_activation, :post, "/activations" do
      description "Create an activation. Not idempotent: reconcile through list_activations."
      reconcile_with :list_activations
      discloses? true
      param :client_reference, :string, in: :body, as: "clientReference", allow_nil?: false
    end

    operation :list_activations, :get, "/activations" do
      description "Activations, filtered by the caller's own reference."
      param :client_reference, :string, as: "clientReference"
    end

    operation :get_activation, :get, "/activations/{activation_id}" do
      description "One activation, by the id the provider gave it."
      param :activation_id, :string, in: :path
    end
  end

  resource do
    require_primary_key? false
  end
end
