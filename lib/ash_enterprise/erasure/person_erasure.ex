defmodule AshEnterprise.Erasure.PersonErasure do
  @moduledoc """
  Erasing a person by their address, and the receipt that says it was done (ADR 0024,
  `docs/runbooks/crypto-shredding.md`).

  `erase` takes an address, finds what it reaches in the tenant
  (`AshEnterprise.Erasure.PersonErasure.Subject`) and, in one transaction:

    * shreds each of those people's own erasure scopes through `AshEnterprise.Erasure.Scope`'s
      `shred`, run as the person asking, so the key destroy, the derived-join cleanup and
      the business-event tombstones are the shred's own;
    * when a sign-in account in the tenant has the address, shreds the scopes that
      account's own content is sealed under (its requests and its assistant threads);
    * blanks what the shred does not reach on each person (`Canonical.Person`'s `erase`):
      the plaintext name, the blind index, the plaintext column from before the seal and
      the merge provenance;
    * deletes their MDM attribute statements (`ash_mdm`'s `erase`), the staged rows whose
      mapped address is this one, and their attendances and conversation participations;
    * refolds any golden that absorbed one of them without what was erased;
    * writes this row.

  Any failure rolls all of it back: no scope shredded, no row deleted, no receipt.

  ## The receipt holds no person

  Counts, the ids of the scopes shredded (opaque, and their `ref`s name record ids, never
  a person), the reason in the operator's words, and the residuals: what this act does not
  reach. Never the address, its blind index or any key. The address and its confirmation
  are `sensitive?` arguments, which the audit log records as nil.

  ## Who may

  A person, never a system actor, an engine or an automation principal, holding a
  `write` grant on this resource (`AshEnterprise.Erasure.Checks.HumanRoleGrant`) and on
  erasure scopes, since the shreds run as them. Both are operator-only
  (`AshEnterprise.Security.Privilege.operator_only?/1`): no tenant Administrator holds
  them. `confirm` must repeat the address. Like every tenant-scoped call, it runs in the
  tenant the person's authority was built for (`AshEnterprise.Security.TenantBoundary`).

  Audited, never deleted (`archival?: false`, no destroy action): the receipt is the
  evidence that the erase happened.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Erasure,
    ownership: :none,
    tenant?: true,
    lifecycle?: false,
    archival?: false,
    policies?: false,
    human_only: [:erase]

  alias AshEnterprise.Erasure.Checks.HumanRoleGrant

  postgres do
    table "erasure_person_erasures"
    repo AshEnterprise.Repo
  end

  attributes do
    uuid_primary_key :id

    attribute :reason, :string do
      allow_nil? false
      public? true
      constraints max_length: 1024
      description "Why, in the operator's words. Never the address."
    end

    attribute :shredded_scope_ids, {:array, :uuid} do
      allow_nil? false
      public? true
      default []
      description "The erasure scopes this erase shredded."
    end

    attribute :counts, :map do
      allow_nil? false
      public? true
      default %{}

      description "What was reached, by class: people, scopes, statements, staged rows, joins."
    end

    attribute :residuals, {:array, :string} do
      allow_nil? false
      public? true
      default []
      description "What this erase does not reach, as the runbook lists it."
    end

    attribute :completed_at, :utc_datetime_usec do
      public? true
      description "When the erase committed its work."
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  actions do
    defaults [:read]

    create :erase do
      description """
      Erase everything the address reaches in this tenant, in one transaction, and record
      the receipt. `confirm` must repeat the address. Irreversible.
      """

      accept [:reason]

      argument :email, :ci_string do
        allow_nil? false
        sensitive? true
        constraints max_length: 320
        description "The address to erase. Recorded nowhere."
      end

      argument :confirm, :ci_string do
        allow_nil? false
        sensitive? true
        constraints max_length: 320
        description "The address again, to confirm whom to erase."
      end

      validate AshEnterprise.Erasure.Validations.ConfirmErasure
      change AshEnterprise.Erasure.Changes.ErasePerson
    end

    read :by_shredded_scope do
      description """
      The receipt of the erase that shredded one erasure scope: what an
      explanation (ADR 0078, section 3) names to a reader who may read one,
      as that reader. Anyone else is refused, and the explanation shows the
      erasure alone.
      """

      get? true

      argument :scope_id, :uuid, allow_nil?: false

      prepare build(sort: [inserted_at: :desc], limit: 1)
      filter expr(^arg(:scope_id) in shredded_scope_ids)
    end
  end

  # Declared in full (`policies?: false`) for the reason the scope's are: the inherited
  # set opens with a system-actor bypass, and erasing a person must not be reachable by
  # any system actor. No `forbid_if`: each policy is a grant path.
  policies do
    policy action(:erase) do
      description "Only a person holding a write grant on person erasures may erase one."
      authorize_if HumanRoleGrant
    end

    policy action_type(:read) do
      description "Granted operators may read the receipts."
      authorize_if AshEnterprise.Security.Checks.RoleGrant
    end
  end
end
