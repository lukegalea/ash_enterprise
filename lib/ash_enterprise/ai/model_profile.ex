defmodule AshEnterprise.AI.ModelProfile do
  @moduledoc """
  A model profile as the model-profile surface (`/app/models`) shows it: which model it
  runs, what it may be used for, whether it is known to answer, and what it is
  restricted from.

  One profile today, `in_zone_generative` (`AshEnterprise.AI.Models`): the operator's
  in-zone runtime, the only profile an agent version may be published to run on.

  A computed read (`AshEnterprise.AI.ModelProfiles`), made as the person. Nothing
  probes the model: readiness comes from configuration, the zone check and the last
  call on record (`AshEnterprise.AI.ModelCall`) that the person may read.

  ## Readiness

    * `:ready` — configured, in the canonical store's zone, and its last recorded call,
      within the last day, answered.
    * `:not_ready` — configured, but its zone is not the store's or its last recorded
      call failed or was refused.
    * `:not_configured` — the operator has not set it up; nothing runs on it.
    * `:unknown` — configured, but nothing recorded that the person may read says
      whether it answers: no call yet, none within the last day, or the record of calls
      could not be read.

  `ready` is true for `:ready` only. An `:unknown` profile is never offered as ready.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.AI,
    data_layer: Ash.DataLayer.Simple,
    ownership: :none,
    tenant?: false,
    lifecycle?: false,
    archival?: false,
    audit?: false,
    self_service: [:list]

  resource do
    require_primary_key? false
  end

  attributes do
    attribute :key, :string, public?: true
    attribute :label, :string, public?: true
    attribute :model, :string, public?: true
    attribute :zone, :string, public?: true

    attribute :readiness, :atom,
      public?: true,
      constraints: [one_of: [:ready, :not_ready, :not_configured, :unknown]]

    attribute :ready, :boolean, public?: true, default: false
    attribute :readiness_note, :string, public?: true
    attribute :last_call_at, :utc_datetime_usec, public?: true
    attribute :permitted_use, {:array, :string}, public?: true, default: []
    attribute :restrictions, {:array, :string}, public?: true, default: []
  end

  actions do
    read :list do
      description "The model profiles, with their permitted use, readiness and restrictions."
      manual AshEnterprise.AI.ModelProfiles
    end
  end
end
