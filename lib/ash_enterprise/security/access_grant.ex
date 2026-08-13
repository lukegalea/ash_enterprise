defmodule AshEnterprise.Security.AccessGrant do
  @moduledoc """
  An explicit share: `(principal, record, rights)`. Dataverse's
  `principalobjectaccess`, usually shortened to POA.

  This is the second of the three grant paths in
  `docs/manifesto/03-authorization-is-data.md`, and the one that exists because
  roles cannot express every real case. *"Give Priya access to this one contract"*
  is not a role — inventing one would leave a permanent, misleading artefact in
  the role list.

  ## Two masks, not one

  `rights_mask` is what was granted directly. `inherited_rights_mask` is what
  arrived by cascade from a parent record. Keeping them apart is what makes a
  cascade **reversible**: un-sharing the parent clears the inherited bits and
  leaves any direct grant intact. Collapse them into one column and you can no
  longer tell "Priya was given this specifically" from "Priya got this because she
  was given the account", so undoing the second silently revokes the first.

  Bit values are Microsoft's, preserved exactly — see
  `AshEnterprise.Security.AccessRight`.

  ## Polymorphic on purpose

  `record_id` + `resource_name` point at a row in any resource, with no foreign
  key. That is a deliberate cost: a share can outlive its record and become an
  orphan. The alternative — a join table per shareable resource — would mean the
  sharing check consults a different table per resource and cannot be written once.
  Since sharing is checked on **every** read of **every** resource, one uniform
  table is worth an orphan sweep.

  ⚠️ Orphan cleanup is not implemented. Deleting a record leaves its grants behind.
  They are harmless (nothing can match a nonexistent id) but they accumulate.

  ## Performance

  Dataverse's own documentation says sharing "should be an exception" and is
  "a less performant way of controlling access", and that is true here too: the
  check is an `exists` subquery against this table on every row of every read.

  The mitigations are the index below and `AshEnterprise.Security.ActorContext`,
  which resolves the actor's principal ids (self + teams) once per request so the
  subquery is a small `IN` list rather than a join through team membership.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Security,
    ownership: :none,
    lifecycle?: false,
    cdm_entity: "PrincipalObjectAccess"

  postgres do
    table "access_grants"
    repo AshEnterprise.Repo

    custom_indexes do
      # Drives the per-row `exists` check: given a record, which principals can
      # reach it? Leading with the record narrows hardest.
      index ["organization_id", "resource_name", "record_id", "principal_id"],
        name: "access_grants_record_principal_index"

      # Drives "what has been shared with me", for the UI and for revocation.
      index ["organization_id", "principal_id", "resource_name"],
        name: "access_grants_principal_index"
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :principal_id, :uuid do
      allow_nil? false
      public? true
      description "The user or team granted access."
    end

    attribute :principal_type, AshEnterprise.Platform.Types.OwnerType do
      allow_nil? false
      public? true
      description "Discriminates principal_id between a user and a team."
    end

    attribute :resource_name, :string do
      allow_nil? false
      public? true
      description ~S(The shared record's resource module, e.g. "AshEnterprise.Accounts.Team".)
    end

    attribute :record_id, :uuid do
      allow_nil? false
      public? true
      description "The shared record. Intentionally not a foreign key -- see the moduledoc."
    end

    attribute :rights_mask, :integer do
      allow_nil? false
      default 0
      public? true
      description "Directly granted rights. See AshEnterprise.Security.AccessRight."
    end

    attribute :inherited_rights_mask, :integer do
      allow_nil? false
      default 0
      public? true

      description "Rights arriving by cascade from a parent record. Kept separate so cascades are reversible."
    end
  end

  calculations do
    calculate :effective_rights_mask,
              :integer,
              # The union of both masks is what actually applies. Ash cannot
              # express a bitwise OR portably in an expression, and the sum is
              # NOT equivalent when both masks share a bit -- so this is computed
              # in Elixir rather than pushed into SQL.
              {AshEnterprise.Security.Calculations.EffectiveRightsMask, []} do
      public? true
    end
  end

  identities do
    identity :unique_grant, [:principal_id, :resource_name, :record_id]
  end

  actions do
    defaults [:read, :destroy]

    default_accept [
      :principal_id,
      :principal_type,
      :resource_name,
      :record_id,
      :rights_mask,
      :inherited_rights_mask
    ]

    create :share do
      primary? true
      upsert? true
      upsert_identity :unique_grant

      description """
      Grant or re-grant. Idempotent: re-sharing with the same rights is a no-op,
      and sharing with different rights replaces them.
      """
    end

    update :revoke_direct do
      description "Clears directly granted rights, leaving anything inherited from a parent."
      accept []
      change set_attribute(:rights_mask, 0)
    end

    update :revoke_inherited do
      description "Clears cascaded rights, leaving any direct grant intact."
      accept []
      change set_attribute(:inherited_rights_mask, 0)
    end

    read :for_principals do
      description "Every grant held by any of the given principals. Used to build ActorContext."
      argument :principal_ids, {:array, :uuid}, allow_nil?: false

      filter expr(principal_id in ^arg(:principal_ids))
    end
  end

  code_interface do
    define :share
    define :read
    define :for_principals, args: [:principal_ids]
    define :revoke_direct
    define :revoke_inherited
  end
end
