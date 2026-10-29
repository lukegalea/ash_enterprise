defmodule AshEnterprise.Test.Execution.ClinicNote do
  @moduledoc """
  A test-only target for governed invocations: a note a clinic's staff record, such as
  "Call the lab about the morning panel".

  It is a view of the existing `canonical_tasks` table (`migrate? false`, in a domain
  that is never registered, after `AshEnterprise.AgentSpike.Subject`), so the tests add
  no schema. Each successful run of a target inserts one row whose title the test
  chose, so counting rows by title counts committed effects.

    * `:record` writes only to this application and needs no approval: the internal
      path, exactly one committed effect.
    * `:record_reviewed` is the same write, confirmed by a person first.
    * `:retitle` changes a note, so it acts on a record the requester must be able to
      read.

  Both are self-service (ADR 0052), so a member with no role grant may run them as
  themselves, and they stamp the runner as owner.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Test.Execution,
    ownership: :user_owned,
    tenant?: true,
    lifecycle?: false,
    archival?: false,
    lineage?: false,
    self_service: [:record, :record_reviewed],
    extra_extensions: [AshAgent.Effects]

  postgres do
    table "canonical_tasks"
    repo AshEnterprise.Repo
    migrate? false
  end

  effects do
    action :record, kind: :edit, destructive?: false, open_world?: false, intent: :execute

    action :record_reviewed,
      kind: :edit,
      destructive?: false,
      open_world?: false,
      approval: :confirm,
      intent: :execute

    action :retitle, kind: :edit, destructive?: false, open_world?: false, intent: :execute
  end

  actions do
    defaults [:read]

    create :record do
      accept [:title]
      change set_attribute(:owner_id, actor(:id))
      change set_attribute(:source, "clinic_note")
    end

    create :record_reviewed do
      accept [:title]
      change set_attribute(:owner_id, actor(:id))
      change set_attribute(:source, "clinic_note")
    end

    update :retitle do
      accept [:title]
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :title, :string, allow_nil?: false, public?: true

    attribute :status, :atom do
      allow_nil? false
      public? true
      default :open
      constraints one_of: [:proposed, :open, :done, :cancelled]
    end

    attribute :plan, :atom do
      allow_nil? false
      public? true
      default :inbox
      constraints one_of: [:inbox, :today, :later]
    end

    attribute :source, :string, allow_nil?: false, public?: true
    update_timestamp :updated_at
  end
end
