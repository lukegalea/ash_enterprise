defmodule AshEnterprise.AI.ModelCall do
  @moduledoc """
  One model call: the ADR 0042 flow record.

  Written by `AshEnterprise.AI.Models` for every call that passes through it —
  made, failed, or refused by the in-zone guard — so "which model saw what
  kind of request, from where, and was it inside the zone" is answerable from
  data rather than from logs.

  **Structural only.** Caller, profile, model, residency, zone, operation,
  outcome, correlation id, duration and token counts. Never a prompt, an
  output, a tool argument or an error message (which can echo either): a
  failure is recorded by its error *class*. The correlation id joins a call to
  the audited action that made it (`AshEnterprise.Audit.EventLog`).

  ## Append-only

  One create action, no update, no destroy: a row is never changed or
  removed. Deliberate opt-outs, each because of that:

    * `audit?: false` — this *is* an append-only log; mirroring every row into
      the event log would double each call and add nothing a reader of either
      could use. The audited action that made the call carries the same
      correlation id.
    * `archival?: false` — nothing is ever deleted, softly or otherwise.
    * `ownership: :none`, `tenant?: false`, `lifecycle?: false` — operational
      bookkeeping like the sync cursors, written by the `system` actor.
      Reads go through the inherited grant union like any other resource.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.AI,
    ownership: :none,
    tenant?: false,
    lifecycle?: false,
    archival?: false,
    audit?: false

  postgres do
    table "ai_model_calls"
    repo AshEnterprise.Repo

    custom_indexes do
      index [:created_on]
      index [:correlation_id]
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :caller, :string do
      allow_nil? false
      public? true
      constraints max_length: 120
      description "What made the call, e.g. \"ai.interpret_request\"."
    end

    attribute :profile, :string do
      allow_nil? false
      public? true
      constraints max_length: 60

      description ~s("in_zone_generative" for the operator's in-zone profile; "hosted" for anything else.)
    end

    attribute :model, :string do
      allow_nil? false
      public? true
      constraints max_length: 200
      description "The model, as provider:id."
    end

    attribute :residency, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:in_zone, :outside_zone]
    end

    attribute :zone, :string do
      public? true
      constraints max_length: 120
      description "The declared zone of an in-zone profile; nil outside every zone."
    end

    attribute :operation, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:generate_object, :generate_text, :stream_text]
    end

    attribute :outcome, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:ok, :error, :refused]
      description ":refused means the in-zone guard stopped the call before anything was sent."
    end

    attribute :correlation_id, :string do
      public? true
      constraints max_length: 64
    end

    attribute :input_tokens, :integer, public?: true, constraints: [min: 0]
    attribute :output_tokens, :integer, public?: true, constraints: [min: 0]
    attribute :duration_ms, :integer, public?: true, constraints: [min: 0]

    attribute :error_class, :string do
      public? true
      constraints max_length: 200
      description "The failure's exception module. Never its message."
    end
  end

  actions do
    defaults [:read]

    create :record do
      description "Append one call record. There is no update and no destroy."

      accept [
        :caller,
        :profile,
        :model,
        :residency,
        :zone,
        :operation,
        :outcome,
        :correlation_id,
        :input_tokens,
        :output_tokens,
        :duration_ms,
        :error_class
      ]
    end
  end

  code_interface do
    define :record
  end
end
