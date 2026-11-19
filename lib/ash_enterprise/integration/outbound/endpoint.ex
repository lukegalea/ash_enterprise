defmodule AshEnterprise.Integration.Outbound.Endpoint do
  @moduledoc """
  A tenant's outbound webhook endpoint: a public HTTPS URL that is sent a signed CloudEvent
  for each subscribed event in that tenant's audit log (ADR 0075).

  A subscription is a filtered view of the tenant's own event log. `event_types` names
  entries of `AshEnterprise.Integration.Outbound.Catalogue` (the create, update and destroy
  of resources with a public API type); `cursor_sequence` is how far into the tenant's chain
  the endpoint has been fanned out. It starts at the tenant's high-water mark when the
  endpoint is registered, so an endpoint never receives what happened before it existed.

  ## The signing secret

  Issued by `register` and replaced by `rotate_secret`, both of which hand the plaintext back
  once, as the returned record's `signing_secret` metadata
  (`AshEnterprise.Integration.Outbound.Changes.IssueSigningSecret`). It is stored only sealed
  under the endpoint's own erasure scope, in the sensitive `sealed_secret`, so the audit log
  records it as `nil`. Shredding the scope leaves the endpoint unable to sign, and nothing is
  sent for it again.

  ## Status

  | `status` | Meaning |
  |---|---|
  | `active` | fanned out every minute; its deliveries are sent |
  | `disabled` | a person disabled it; nothing is fanned out or sent |
  | `failing` | disabled by the platform: three deliveries in a row were dead-lettered, a send was refused by the egress guard, or the cursor fell behind audit retention. `status_reason` says which. `enable` turns it back on |

  ## Who may do what

  Tenanted and organization-owned; the inherited grant union decides (`create` for
  `register`, `write` for the updates). `register`, `update`, `rotate_secret` and `enable`
  choose where a tenant's events go or with what key, so they are `human_only`: an
  automation principal never reaches them. `fan_out` and `note_outcome` are the platform's
  own bookkeeping and `machinery_only`. `fan_out` is not audited: it only moves the cursor,
  every minute that the tenant wrote something, and the deliveries it creates are the
  record of what it did.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Integration,
    ownership: :organization_owned,
    lifecycle?: false,
    human_only: [:register, :update, :rotate_secret, :enable],
    machinery_only: [:fan_out, :fan_out_tenant, :note_outcome],
    extra_extensions: [AshOban]

  alias AshEnterprise.Integration.Outbound.{Changes, Validations}
  alias AshEnterprise.Platform.SystemActor

  postgres do
    table "integration_outbound_endpoints"
    repo AshEnterprise.Repo
  end

  # The cursor moves every minute the tenant writes something; the deliveries it creates are
  # the record, and auditing the move would put a row in the very chain the cursor walks.
  events do
    ignore_actions [:fan_out]
  end

  # Every minute, once per tenant with an active endpoint (`Outbound.Tenants`). An endpoint
  # whose cursor is already at the tenant's high-water mark is not written to.
  oban do
    scheduled_actions do
      schedule :fan_out, "* * * * *" do
        action :fan_out_tenant
        list_tenants AshEnterprise.Integration.Outbound.Tenants
        queue :webhooks
        max_attempts 1
        actor_persister :none
        default_actor SystemActor.oban()
        worker_module_name AshEnterprise.Integration.Outbound.Endpoint.FanOutWorker
      end
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :url, :string do
      allow_nil? false
      public? true
      constraints max_length: 2048
      description "The public HTTPS URL a delivery is POSTed to. Port 443 only."
    end

    attribute :description, :string do
      public? true
      constraints max_length: 500
    end

    attribute :event_types, {:array, :string} do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 100
      description "The catalogue event types sent to this endpoint."
    end

    attribute :status, :atom do
      allow_nil? false
      public? true
      default :active
      constraints one_of: [:active, :disabled, :failing]
    end

    attribute :status_reason, :string do
      public? true
      description "A short code saying why the endpoint is not active."
    end

    attribute :consecutive_dead, :integer do
      allow_nil? false
      public? true
      default 0
      description "Dead-lettered deliveries in a row. Three disable the endpoint."
    end

    attribute :cursor_sequence, :integer do
      allow_nil? false
      default 0
      description "The last audit-log sequence of this tenant that has been fanned out."
    end

    attribute :sealed_secret, :string do
      allow_nil? false
      sensitive? true
      description "The signing secret, sealed under the endpoint's erasure scope."
    end
  end

  relationships do
    belongs_to :erasure_scope, AshEnterprise.Erasure.Scope do
      allow_nil? false
      attribute_writable? false
    end

    has_many :deliveries, AshEnterprise.Integration.Outbound.Delivery
  end

  actions do
    defaults [:read, :destroy]

    create :register do
      description "Register an endpoint. The signing secret is returned once, as metadata."
      accept [:url, :description, :event_types]

      validate Validations.EndpointUrl
      validate Validations.CatalogueTypes

      change Changes.IssueSigningSecret
      change Changes.StampCursor

      metadata :signing_secret, :string do
        allow_nil? false
      end
    end

    update :update do
      primary? true
      description "Change what the endpoint is sent, or its description."
      accept [:description, :event_types]
      validate Validations.CatalogueTypes
    end

    update :rotate_secret do
      description "Replace the signing secret. The new one is returned once, as metadata."
      accept []
      require_atomic? false
      change Changes.IssueSigningSecret

      metadata :signing_secret, :string do
        allow_nil? false
      end
    end

    update :disable do
      description "Stop fanning out and sending to this endpoint."
      accept []
      change set_attribute(:status, :disabled)
      change set_attribute(:status_reason, "disabled")
    end

    update :enable do
      description """
      Turn the endpoint back on. Events written while it was off are sent, unless its cursor
      fell behind audit retention, in which case it restarts at the tenant's high-water mark.
      """

      accept []
      require_atomic? false
      change Changes.Reenable
    end

    update :fan_out do
      description "Turn the tenant's new audit events into pending deliveries."
      accept []
      require_atomic? false
      change Changes.FanOut
    end

    action :fan_out_tenant do
      description "Fan out every active endpoint of the tenant that has something new."
      run AshEnterprise.Integration.Outbound.Actions.FanOutTenant
    end

    update :note_outcome do
      description "Record what became of a delivery: delivered, dead-lettered or refused."
      accept []
      require_atomic? false

      argument :outcome, :atom do
        allow_nil? false
        constraints one_of: [:delivered, :dead, :egress_refused]
      end

      argument :code, :string

      change Changes.NoteOutcome
    end
  end

  greenmask do
    # Without production's scope keys (Erasure.Key.wrapped_key is replaced) a copy cannot
    # open the secret, so its endpoints cannot sign and nothing is sent from it.
    keep(:sealed_secret,
      because:
        "the signing secret sealed under an erasure-scope key; a copy's scope keys are replaced (Erasure.Key.wrapped_key), so it cannot be opened there"
    )
  end
end
