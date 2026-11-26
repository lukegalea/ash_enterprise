defmodule AshEnterprise.Test.Facades do
  @moduledoc """
  Test-only domain for the ontology facades the platform profile (`facade?: true`) is
  proven on. Compiled only in `:test` and never registered in `config :ash_enterprise,
  ash_domains`, so it cannot leak into a running application or a migration.
  """

  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AshEnterprise.Test.Facades.WorkItem
    resource AshEnterprise.Test.Facades.Licence
  end
end

defmodule AshEnterprise.Test.Facades.WorkItem do
  @moduledoc """
  A work-tracking vocabulary over `AshEnterprise.Canonical.Task`: a rename, a decoded
  state, a provenance column mapped from the source, and two writes, one by value
  (`finish`, through `:complete`) and one by acceptance (`set_effort`, through
  `:set_estimate`).
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Test.Facades,
    facade?: true

  @system_column "A platform system column of the source; this vocabulary has no owner, tenant column or provenance of its own."

  attributes do
    attribute :id, :uuid, primary_key?: true, allow_nil?: false, public?: true
    attribute :name, :string, public?: true

    attribute :state, :atom,
      public?: true,
      constraints: [one_of: [:suggested, :new, :finished, :dropped]]

    attribute :effort_minutes, :integer, public?: true
    attribute :due, :utc_datetime_usec, public?: true
    attribute :recorded_at, :utc_datetime_usec, public?: true
  end

  facade do
    source AshEnterprise.Canonical.Task

    map :id, from: :id
    map :name, from: :title

    decode :state,
      from: :status,
      values: %{proposed: :suggested, open: :new, done: :finished, cancelled: :dropped}

    map :effort_minutes, from: :estimated_minutes
    map :due, from: :due_at
    map :recorded_at, from: :created_on

    hide :organization_id, because: @system_column

    hide :owning_team_id, because: @system_column

    hide :owning_user_id, because: @system_column

    hide :owner_type, because: @system_column

    hide :owner_id, because: @system_column

    hide :owning_business_unit_id, because: @system_column

    hide :version_number, because: @system_column

    hide :import_sequence_number, because: @system_column

    hide :overridden_created_on, because: @system_column

    hide :modified_on_behalf_by_id, because: @system_column

    hide :created_on_behalf_by_id, because: @system_column

    hide :modified_by_id, because: @system_column

    hide :created_by_id, because: @system_column

    hide :modified_on, because: @system_column

    hide :inserted_at, because: @system_column

    hide :updated_at, because: @system_column

    hide :scheduled_start_at, because: "Not part of this vocabulary."
    hide :scheduled_end_at, because: "Not part of this vocabulary."
    hide :proposer, because: "Not part of this vocabulary."
    hide :instrument, because: "Not part of this vocabulary."
    hide :plan, because: "Not part of this vocabulary."
    hide :source, because: "Not part of this vocabulary."
    hide :origin_type, because: "Not part of this vocabulary."
    hide :origin_id, because: "Not part of this vocabulary."
    hide :external_system, because: "Not part of this vocabulary."
    hide :external_id, because: "Not part of this vocabulary."
    hide :erasure_scope_id, because: "Not part of this vocabulary."
    hide :judgment_digests, because: "Not part of this vocabulary."

    hide :encrypted_commitment,
      because:
        "Sealed under the source's erasure scope; a value computed in the BEAM stays the source's."

    hide :encrypted_evidence,
      because:
        "Sealed under the source's erasure scope; a value computed in the BEAM stays the source's."

    write :finish, via: :complete, sets: [state: :finished]
    write :set_effort, via: :set_estimate, accepts: [:effort_minutes]
  end
end

defmodule AshEnterprise.Test.Facades.Licence do
  @moduledoc """
  A licence vocabulary over `AshEnterprise.Credentialing.Credential`, whose `number` is a
  secured column (ADR 0073): a reader without the column's grant gets
  `%Ash.ForbiddenField{}` through the facade exactly as at the source.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Test.Facades,
    facade?: true

  @system_column "A platform system column of the source; this vocabulary has no owner, tenant column or provenance of its own."

  attributes do
    attribute :id, :uuid, primary_key?: true, allow_nil?: false, public?: true
    attribute :kind, :atom, public?: true, constraints: [one_of: [:licence, :certification]]

    # Inherited from the source's `number`; the facade never sets it (the verifier refuses a difference).
    attribute :licence_number, :string, public?: true, sensitive?: true
    attribute :expires_on, :date, public?: true
  end

  facade do
    source AshEnterprise.Credentialing.Credential

    map :id, from: :id
    map :kind, from: :kind
    map :licence_number, from: :number
    map :expires_on, from: :expires_on

    hide :organization_id, because: @system_column

    hide :owning_team_id, because: @system_column

    hide :owning_user_id, because: @system_column

    hide :owner_type, because: @system_column

    hide :owner_id, because: @system_column

    hide :owning_business_unit_id, because: @system_column

    hide :version_number, because: @system_column

    hide :import_sequence_number, because: @system_column

    hide :overridden_created_on, because: @system_column

    hide :modified_on_behalf_by_id, because: @system_column

    hide :created_on_behalf_by_id, because: @system_column

    hide :modified_by_id, because: @system_column

    hide :created_by_id, because: @system_column

    hide :modified_on, because: @system_column

    hide :created_on, because: @system_column

    hide :archived_at, because: @system_column

    hide :status, because: "Not part of this vocabulary."
    hide :registry_reference, because: "Not part of this vocabulary."

    defer :activated_at
    defer :clinician_id
  end
end

defmodule AshEnterprise.Test.Facades.Registry do
  @moduledoc """
  The walk's registry for the test facades: their type tokens added to the host's
  (`AshEnterprise.Provenance.Registry`), and the host's own dispatch order for
  everything, so a facade is explained by what it is. The test facades are not in
  the host registry because a test-only resource must not answer production addresses.
  """

  alias AshEnterprise.Provenance.Registry

  @tokens %{
    "work_item" => AshEnterprise.Test.Facades.WorkItem,
    "licence" => AshEnterprise.Test.Facades.Licence
  }

  def resource(token) do
    case Map.fetch(@tokens, token) do
      {:ok, resource} -> {:ok, resource}
      :error -> Registry.resource(token)
    end
  end

  def token(resource) do
    case Enum.find(@tokens, &(elem(&1, 1) == resource)) do
      {token, _} -> {:ok, token}
      nil -> Registry.token(resource)
    end
  end

  defdelegate explainers_for(resource, field), to: Registry
end
