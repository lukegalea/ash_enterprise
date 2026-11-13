defmodule AshEnterprise.Automation.Occurrence do
  @moduledoc """
  A fact that happened and has no audited tenant row of its own, recorded into a
  tenant's audit chain so a subscription (a recipe's WHEN) can match it.

  Two things are not audited tenant writes today:

    * `User` is `tenant?: false`, so deactivating one lands in the `NULL` chain, which
      the trigger sweep never reads (the sweep is per tenant).
    * A refused sign-in writes nothing at all.

  An `Occurrence` is tenant-scoped, so creating one writes a row into the audit chain of
  the tenant it is recorded in. A subscription on `AshEnterprise.Automation.Occurrence`
  with `match_action_type: :create` and a guard on `type` then starts its process after one
  sweep, like any other audited write.

  ## The envelope

  The attribute names are
  [CloudEvents 1.0](https://github.com/cloudevents/spec/blob/v1.0.2/cloudevents/spec.md):
  `source`, `type`, `time`, `subject`, `data`. The CloudEvents `id` is `event_id` here,
  because `id` is the primary key. A consumer dedupes on `source` and `event_id` together,
  which is this resource's identity, per tenant: writing the same fact twice is one row.

  ## Facts, never secrets

  `data` holds a few flat, short facts (a reason, a count) and is checked on every write
  (`AshEnterprise.Automation.Validations.FactsOnly`): no nesting, at most 8 keys, at most
  1 KiB encoded, and no key that names a password, token, secret or credential. Nothing
  here is an attempted credential, and `subject` is an id, never an address.

  ## Append-only, and written only by the platform

  The only actions are `read` and `record`. There is no update and no destroy, and no
  lifecycle or archival (an occurrence that happened stays happened). `record` is
  machinery-only: no grant, however broad, lets a tenant member create one; the platform's
  writers (`AshEnterprise.Automation.Occurrences`) run it as the `oban` system actor.
  Reading follows the grant union like any tenant row, and another tenant never sees it.

  ## Alerts open incidents

  An `alert.firing` or `alert.resolved` occurrence opens, joins or closes an
  `AshEnterprise.Automation.Incident` in the same transaction
  (`AshEnterprise.Automation.Changes.TrackIncident`).

  Not exposed over any API.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Automation,
    ownership: :organization_owned,
    lifecycle?: false,
    archival?: false,
    machinery_only: [:record]

  postgres do
    table "automation_occurrences"
    repo AshEnterprise.Repo
  end

  actions do
    defaults [:read]

    create :record do
      description "Record that something happened. Machinery only."
      primary? true
      accept [:event_id, :source, :type, :subject, :time, :data]
      validate AshEnterprise.Automation.Validations.FactsOnly
      change AshEnterprise.Automation.Changes.TrackIncident
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :specversion, :string do
      allow_nil? false
      default "1.0"
      writable? false
      public? true
    end

    attribute :event_id, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 255
      description "CloudEvents `id`: the writer's id for the fact; with `source`, its identity."
    end

    attribute :source, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 255
      description "CloudEvents `source`: which part of the platform recorded it."
    end

    attribute :type, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 100

      description "CloudEvents `type`, e.g. `user.deactivated`. What a subscription's guard reads."
    end

    attribute :subject, :string do
      public? true
      constraints max_length: 255

      description "CloudEvents `subject`: the id of what it is about (a user id), never an address."
    end

    attribute :time, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :datacontenttype, :string do
      allow_nil? false
      default "application/json"
      writable? false
      public? true
    end

    attribute :data, :map do
      allow_nil? false
      public? true
      default %{}
      description "CloudEvents `data`: a few flat facts. Never a secret; see the moduledoc."
    end
  end

  identities do
    identity :envelope, [:source, :event_id]
  end
end
