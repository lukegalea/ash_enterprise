defmodule Battery.Operations.Submission do
  @moduledoc """
  The record a governed call to the declared registry acts on, and the subject the
  registry's disclosure gate reads (`disclosure_ref` is its id).

    * `submit` sends it to the registry (`Registry.create_activation`), keyed to the
      provider by the invocation's own key (`client_reference`). Governed, with no
      approval: it runs only through its invocation. Not idempotent and open-world, so a
      lost answer leaves the row `outcome_unknown` and `lookup_submission` settles it.
    * `lookup_submission` asks the provider whether it took the submission, by that same
      key (`Battery.Operations.LookupSubmission`).
    * `record_activation` stores an activation id without a call, for the scenarios that
      start from one the provider already holds.
  """

  use Ash.Resource,
    domain: Battery.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshAgent.Effects]

  postgres do
    table "battery_submissions"
    repo Battery.Repo
  end

  effects do
    action :submit,
      kind: :edit,
      destructive?: false,
      idempotent?: false,
      open_world?: true,
      intent: :execute,
      reconcile_with: :lookup_submission

    action :lookup_submission,
      kind: :fetch,
      destructive?: false,
      idempotent?: true,
      open_world?: true,
      intent: :inspect
  end

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:data_class, :consent_on_file]
    end

    create :record_activation do
      accept [:data_class, :consent_on_file, :activation_id]
    end

    update :submit do
      accept []
      require_atomic? false
      validate {AshAgent.Validations.Governed, invocation: Battery.Execution.Invocation}
      change Battery.Operations.Submit
      change optimistic_lock(:version_number)
    end

    action :lookup_submission, :map do
      argument :id, :uuid, allow_nil?: false
      argument :invocation_key, :string, allow_nil?: false
      run Battery.Operations.LookupSubmission
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :data_class, :string, allow_nil?: false, public?: true
    attribute :consent_on_file, :boolean, allow_nil?: false, default: false, public?: true
    attribute :client_reference, :string, public?: true
    attribute :activation_id, :string, public?: true
    attribute :version_number, :integer, allow_nil?: false, default: 1, public?: true
  end
end
