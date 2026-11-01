defmodule Battery.Execution.Referral do
  @moduledoc """
  A referral of a synthetic patient: the record a governed invocation acts on.

    * `escalate` marks it urgent, after a clinic lead other than the requester approves
      within four hours (`approval: :four_eyes`). It writes only here.
    * `amend` changes it outside any invocation, and moves `version_number` on (an
      optimistic lock), as every write of a subject must for an approval to notice it.
    * `acknowledge` records that the clinic took the referral on. Governed, with no
      approval and nothing outside: a process's service task runs it through its
      invocation (`Battery.Execution.ProcessTask`), and nothing else may.
    * `check_consent` answers whether the patient's consent is on file, or refuses with
      the business error `consent_missing`, which a process's error boundary catches.
  """

  use Ash.Resource,
    domain: Battery.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshAgent.Effects]

  postgres do
    table "battery_referrals"
    repo Battery.Repo
  end

  effects do
    action :escalate,
      kind: :edit,
      destructive?: false,
      open_world?: false,
      approval: :four_eyes,
      approver_role: :clinic_lead,
      approval_expires_in: [hours: 4],
      intent: :execute

    action :acknowledge,
      kind: :edit,
      destructive?: false,
      idempotent?: true,
      open_world?: false,
      intent: :execute

    action :check_consent,
      kind: :read,
      destructive?: false,
      idempotent?: true,
      open_world?: false,
      intent: :inspect
  end

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:patient]
    end

    update :escalate do
      accept []
      change set_attribute(:urgent?, true)
      change optimistic_lock(:version_number)
    end

    update :amend do
      accept [:patient, :consent_on_file?]
      change optimistic_lock(:version_number)
    end

    update :acknowledge do
      accept []
      validate {AshAgent.Validations.Governed, invocation: Battery.Execution.Invocation}
      change set_attribute(:acknowledged_at, &DateTime.utc_now/0)
      change optimistic_lock(:version_number)
    end

    action :check_consent, :map do
      argument :id, :uuid, allow_nil?: false
      run Battery.Execution.CheckConsent
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :patient, :string, allow_nil?: false, public?: true
    attribute :urgent?, :boolean, allow_nil?: false, default: false, public?: true
    attribute :consent_on_file?, :boolean, allow_nil?: false, default: false, public?: true
    attribute :acknowledged_at, :utc_datetime_usec, public?: true
    attribute :version_number, :integer, allow_nil?: false, default: 1, public?: true
  end
end
