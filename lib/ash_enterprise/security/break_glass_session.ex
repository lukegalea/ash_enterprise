defmodule AshEnterprise.Security.BreakGlassSession do
  @moduledoc """
  The record that an operator may act as someone else, for now.

  A row names the operator, the person they act as, why, who is to approve it and
  when it ends. Opening one is an audited write (`open`) and is only a request:
  the named approver must then run `approve` themselves, and only that stamps
  `approved_at`. Ending one is the platform's `deactivate`.
  `AshEnterprise.Security.Impersonation.break_glass/3` hands back an impersonating
  actor only while a row is live: approved, active, unexpired, and with operator
  and subject both still active.

  `open` and `approve` are `human_only`: a system actor cannot do either, because
  the row names the people who did.

  A host sets the longest session:

      config :ash_enterprise, :break_glass_max_minutes, 120
  """
  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Security,
    ownership: :none,
    tenant?: false,
    human_only: [:open, :approve],
    changes_authority: [:open, :approve]

  @default_max_minutes 240

  @doc "The longest a session may be opened for, in minutes."
  @spec max_minutes() :: pos_integer()
  def max_minutes do
    case Application.get_env(:ash_enterprise, :break_glass_max_minutes, @default_max_minutes) do
      n when is_integer(n) and n > 0 ->
        n

      other ->
        raise ArgumentError,
              "config :ash_enterprise, :break_glass_max_minutes must be a positive integer, " <>
                "got: #{inspect(other)}"
    end
  end

  postgres do
    table "break_glass_sessions"
    repo AshEnterprise.Repo

    references do
      reference :operator, on_delete: :restrict
      reference :subject, on_delete: :restrict
      reference :approver, on_delete: :restrict
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :reason, :string do
      allow_nil? false
      public? true
      constraints min_length: 10, max_length: 2000, trim?: true
    end

    attribute :started_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :expires_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :approved_at, :utc_datetime_usec do
      public? true
      description "When the named approver approved. Nil until they do; only `approve` sets it."
    end
  end

  relationships do
    belongs_to :operator, AshEnterprise.Accounts.User do
      allow_nil? false
      public? true
    end

    belongs_to :subject, AshEnterprise.Accounts.User do
      allow_nil? false
      public? true
      attribute_writable? true
    end

    belongs_to :approver, AshEnterprise.Accounts.User do
      allow_nil? false
      public? true
      attribute_writable? true
    end
  end

  actions do
    defaults [:read]

    read :live_for do
      description """
      Sessions in force at `now` for one operator acting as one subject: approved,
      active, not yet expired, and with both people still active.
      """

      argument :operator_id, :uuid, allow_nil?: false
      argument :subject_id, :uuid, allow_nil?: false
      argument :now, :utc_datetime_usec, allow_nil?: false

      filter expr(
               lifecycle_status == :active and not is_nil(approved_at) and operator_id == ^arg(:operator_id) and
                 subject_id == ^arg(:subject_id) and expires_at > ^arg(:now) and
                 operator.lifecycle_status == :active and subject.lifecycle_status == :active
             )

      prepare build(sort: [expires_at: :desc], limit: 1)
    end

    create :open do
      description """
      Requests a session for the acting person to act as `subject`, to be approved
      by someone else, for `duration_minutes`. The session is not live until the
      approver runs `approve`. Refused without a reason, for an approver who is the
      operator, the subject or inactive, and for a duration past `max_minutes/0`.
      """

      accept [:subject_id, :approver_id, :reason]
      argument :duration_minutes, :integer, allow_nil?: false, public?: true

      change relate_actor(:operator, allow_nil?: false)
      change AshEnterprise.Security.Changes.StampBreakGlassWindow
      validate AshEnterprise.Security.Validations.BreakGlassTerms
    end

    update :approve do
      description """
      The named approver approves the session, which makes it live until
      `expires_at`. Refused for anyone else, for the operator or subject, for a
      session that has ended, expired or been approved, and for an inactive approver.
      """

      accept []
      require_atomic? false

      validate AshEnterprise.Security.Validations.BreakGlassApproval
      change set_attribute(:approved_at, &DateTime.utc_now/0)
    end
  end
end
