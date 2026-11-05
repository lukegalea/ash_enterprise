defmodule AshEnterprise.Credentialing.DocumentEvent do
  @moduledoc """
  The messages about a credential's licence documents that pass between the clinic and the
  people who file them: a
  [CloudEvents 1.0](https://github.com/cloudevents/spec/blob/v1.0.2/cloudevents/spec.md)
  envelope per message, one row each, written as the clinic's machinery.

    * `request` records that the clinic asked for a document (`type` `"document.requested"`):
      the credentialing case's service task writes it, once per execution of the task. In a
      deployment this row is the outbox the clinician's message is sent from.
    * `receive` records that a document arrived (`type` `"document.received"`): what the
      filing system's webhook handler writes (`AshEnterprise.Credentialing.DocumentWebhook`).
      A case waiting for the document hears of it through the audit log and correlates on the
      credential (`subject`).

  ## One delivery, one row

  `event_id` is the sender's own id for the message, and a consumer dedupes on `source` and
  `id` together, which is the identity of this resource: a webhook delivered twice is one
  row, and a delivery that arrives before the case waits for it, or after it moved on, is
  the same row as ever. Whatever the order and however often, the waiting case moves on once
  (the engine's claim of a parked token has one winner).

  The document's own text is never in the message: `data` names the kind of document and
  nothing a person wrote. Written only by machinery (`request` and `receive` are
  machinery-only). Not exposed over any API.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Credentialing,
    ownership: :organization_owned,
    lifecycle?: false,
    archival?: false,
    machinery_only: [:request, :receive]

  postgres do
    table "credentialing_document_events"
    repo AshEnterprise.Repo
  end

  @requested "document.requested"
  @received "document.received"

  actions do
    defaults [:read]

    create :request do
      description "Record that the clinic asked for a licence document."
      accept [:event_id, :source, :subject, :time, :data]
      change set_attribute(:type, @requested)
    end

    create :receive do
      description "Record that a licence document arrived."
      accept [:event_id, :source, :subject, :time, :data]
      change set_attribute(:type, @received)
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
      description "CloudEvents `id`: the sender's id for the message."
    end

    attribute :source, :string do
      allow_nil? false
      public? true
      description "CloudEvents `source`: who sent it."
    end

    attribute :type, :string do
      allow_nil? false
      writable? false
      public? true
      description "CloudEvents `type`: `document.requested` or `document.received`."
    end

    attribute :subject, :string do
      allow_nil? false
      public? true

      description "CloudEvents `subject`: the credential's id, which a waiting case correlates on."
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
      description "CloudEvents `data`: which kind of document. Nothing a person wrote."
    end
  end

  identities do
    identity :envelope, [:source, :event_id]
  end

  @doc "The `type` of a request for a document."
  @spec requested() :: String.t()
  def requested, do: @requested

  @doc "The `type` of an arrived document."
  @spec received() :: String.t()
  def received, do: @received
end
