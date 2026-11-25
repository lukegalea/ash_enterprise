defmodule AshEnterprise.Process.TaskNotice do
  @moduledoc """
  One person told about one firing of a task's timer: reminded, added by an escalation, or
  told the task expired (`ash_bpmn` DESIGN.md §11.7). Written by
  `AshEnterprise.Process.TaskNotices`, the application's `AshBpmn.TaskNotifier`.

  The row is the in-app notice, which the person reads as their own, and the record that
  their message went: `mailed_at` is set once the mail has been handed to the mailer.

  ## One per firing and person

  The engine calls the notifier at least once per firing, and again with the same `key`
  after a failure. The identity on `(key, user_id)` makes the second call find the first
  call's row instead of writing another, and a row whose `mailed_at` is set is not mailed
  again. A retry after a failed mail writes no second row and sends one message.

  ## Owner-only

  User-owned by the person told (`owner_id` is `user_id`), owner-only
  (`AshEnterprise.Security.Privilege.owner_only?/1`), and readable by that person without a
  grant (self-service, ADR 0052). Who was nudged about which task is nobody else's to browse.
  Only the `oban` system actor writes one (machinery-only, ADR 0059).

  **Not audited, deliberately**: the engine records every delivery as a `:notice_delivered`
  or `:notice_failed` `AshEnterprise.Bpmn.ProcessEvent`, and this row is the per-person
  record of the same fact. A third copy in the audit log would be one more to disagree.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Process,
    ownership: :user_owned,
    lifecycle?: false,
    archival?: false,
    # The ProcessEvent and this row are the record; see the moduledoc.
    audit?: false,
    self_service: [:read],
    machinery_only: [:record, :mark_mailed]

  postgres do
    table "process_task_notices"
    repo AshEnterprise.Repo

    custom_indexes do
      index [:organization_id, :owner_id, :inserted_at]
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :key, :string do
      allow_nil? false
      public? true
      constraints max_length: 400

      description "The firing's key, `<task id>/<node id>/<timer index>/<repetition>`, the same on every retry."
    end

    attribute :user_id, :uuid do
      allow_nil? false
      public? true
      description "The person told."
    end

    attribute :task_id, :uuid do
      allow_nil? false
      public? true
      description "The task the timer belongs to."
    end

    attribute :kind, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:remind, :escalated, :expired]
      description "A reminder, an escalation that added people, or the task's expiry."
    end

    attribute :due_at, :utc_datetime_usec do
      public? true
      description "The task's due date when the timer fired, if it has one."
    end

    attribute :late, :boolean do
      allow_nil? false
      default false
      public? true
      description "Whether the timer fired after its moment had passed."
    end

    attribute :mailed_at, :utc_datetime_usec do
      public? true
      description "When the message was handed to the mailer; nil until then."
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :one_per_firing_and_person, [:key, :user_id]
  end

  actions do
    defaults [:read]

    create :record do
      description "Record that a person is told about a firing; the same row again on a retry."

      accept [:key, :task_id, :kind, :due_at, :late]
      argument :user_id, :uuid, allow_nil?: false
      argument :owning_business_unit_id, :uuid

      upsert? true
      upsert_identity :one_per_firing_and_person
      # A retry changes nothing about the row, and must not clear `mailed_at`.
      upsert_fields [:updated_at]

      change set_attribute(:user_id, arg(:user_id))
      change set_attribute(:owner_id, arg(:user_id))
      change set_attribute(:owner_type, :user)
      change set_attribute(:owning_user_id, arg(:user_id))
      change set_attribute(:owning_business_unit_id, arg(:owning_business_unit_id))
    end

    update :mark_mailed do
      description "The message to this person has been handed to the mailer."
      accept []
      change set_attribute(:mailed_at, &DateTime.utc_now/0)
    end
  end
end
