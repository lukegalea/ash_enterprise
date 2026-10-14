defmodule AshEnterprise.Canonical.Person do
  @moduledoc """
  A person in the operator's world (dogfood §11): the organizer of a meeting,
  a message correspondent, a task's assignee.

  Identity for v1 is the email address and nothing else — matching the program
  decision that entity resolution stays external-id + email, with no fuzzy
  matching (roadmap P4). A person the fixture only knows by display name and no
  address is not linked at all; a duplicate email merges automatically by
  upsert, and nobody pretends that is entity resolution.

  PERSONAL DATA (ADR 0042): when the Gmail/Slack verticals start projecting
  correspondents from real mailboxes, zone admission must already gate the
  SourceObject land path. See the TODO on
  `AshEnterprise.Canonical.Projection` before wiring those projectors.

  Opt-outs from the platform base, same reasoning as `SourceObject`'s: these
  rows are machine-derived projections — reconstructable from raw landings by
  `Projection.replay/2` — so `archival?: false` (a stale projection is
  re-replayed, not soft-deleted; an archived ghost would also poison the
  replay's upsert identity) and `lifecycle?: false` (a person's lifecycle is
  the source system's business, not the Dataverse Active/Inactive pair).
  Audit stays on: who/what last projected a person is provenance the
  operator's own model should answer for.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Canonical,
    ownership: :user_owned,
    tenant?: true,
    lifecycle?: false,
    archival?: false

  postgres do
    table "canonical_people"
    repo AshEnterprise.Repo

    custom_indexes do
      # MDM-3 blocking (ADR 0017): the trigram shortlist reads
      # `lower(name) % lower($name)` — this GIN index is what keeps that
      # a shortlist instead of an org-wide scan.
      index [:organization_id, "lower(name) gin_trgm_ops"],
        using: "gin",
        name: "canonical_people_name_trgm_idx"
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      public? true
      constraints max_length: 256
      description "Display name, when the source system carried one. Stays nil otherwise."
    end

    # CDM master/merged shape (ADR 0017, adopted by ADR 0050): the merge
    # keeps the loser's row, pointing at its survivor.
    attribute :merged, :boolean do
      public? false
      default false
    end

    attribute :master_id, :uuid do
      public? false
    end

    # What the merge took from this record, so the unmerge correction can
    # restore exactly that (prior email, moved identity ids).
    attribute :merge_provenance, :map do
      public? false
    end

    attribute :email, :ci_string do
      public? true
      constraints max_length: 320
      description "The v1 linkage key. Nullable: a name-only contact is a person with no link."
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    # "Unique on email where present": Postgres unique indexes leave multiple
    # NULLs alone, so name-only contacts do not collide.
    identity :unique_email, [:email]
  end

  actions do
    defaults [:read]

    read :by_external do
      description """
      Look up the person a source-system contact projected to, by the external
      identity stamped at projection time.

      KNOWN GAP (E1 review, fix owned by a dedicated E1 follow-up):
      SourceObject identity is `[external_system, external_id]` *without* the
      stream, and this lookup inherits that shape — two streams sharing an
      external id would land on one row here. Projectors disambiguate by
      filtering `source_metadata["stream"]` when they select their raw rows;
      until the identity is fixed, lookups cannot.
      """

      get? true
      argument :system, :string, allow_nil?: false
      argument :id, :string, allow_nil?: false

      filter expr(external_system == ^arg(:system) and external_id == ^arg(:id))
    end

    read :goldens do
      description """
      The golden records (MDM-6): persons some SourceIdentity points at and no
      merge has absorbed. The A2UI golden surface reads through this, so a
      merged loser never presents itself as the customer.
      """

      filter expr(
               merged == false and
                 exists(AshEnterprise.Mdm.SourceIdentity, golden_id == parent(id))
             )
    end

    create :upsert_from_source do
      description """
      The replay write path: upsert on the email identity so every pass of
      `Projection.replay/2` converges on the same row instead of minting
      duplicates. Fields absent from a pass's payload are simply not in
      `upsert_fields` for that write — a name-less source never blanks an
      existing name. The owner context is INSERT-time only: a re-projected
      person keeps whoever projected them first, matching every other
      resource in this domain.
      """

      accept [
        :name,
        :email,
        :owner_id,
        :owner_type,
        :owning_user_id,
        :owning_business_unit_id
      ]

      upsert? true
      upsert_identity :unique_email

      # `upsert_fields` is chosen per write by the projector: a payload that
      # carries a display name refreshes it, a name-less payload conflicts and
      # changes nothing. The action cannot pin that choice — it depends on the
      # payload, and pinning it here would let a name-less source blank an
      # existing name.
    end

    update :mdm_survivor_update do
      description "The merge's survivor write: fill the survivor's gaps from the loser (ADR 0050 survivorship)."
      accept [:name, :email]
    end

    update :mdm_merge_into do
      description """
      The merge write (ADR 0050): this record folds into the survivor.
      Non-destructive by construction — the loser keeps its row.
      """

      argument :survivor_id, :uuid, allow_nil?: false
      require_atomic? false

      change AshEnterprise.Mdm.Changes.MergeInto
    end

    update :mdm_merge_provenance do
      description "Records what the merge took from this record (ADR 0050: unmerge restores exactly that)."
      accept [:merge_provenance]
    end

    update :mdm_unmerge do
      description "The merge correction: this record stands alone again — email and XREF restored."
      accept []
      validate attribute_equals(:merged, true)
      require_atomic? false

      change set_attribute(:merged, false)
      change set_attribute(:master_id, nil)
      # Stale provenance must not survive the correction: a later
      # merge→unmerge cycle would restore from data the merge retracted.
      change set_attribute(:merge_provenance, nil)
      change AshEnterprise.Mdm.Changes.Unmerge
    end

    create :mdm_create_golden do
      description """
      The new-golden write (MDM-4/5 band routing): an omit-banded or
      candidate-less staged row becomes a golden of its own. Deliberately
      NOT an upsert — the omit band ruled a merge out, so an e-mail
      collision with an existing person fails loudly and the caller routes
      the row back to stewardship instead of overwriting anyone.
      """

      accept [:name, :email, :owner_id, :owning_business_unit_id]
    end

    action :mdm_export, {:array, :map} do
      description """
      The egress departure (MDM-6, ADR 0050 §8): the tenant's active `:egress`
      mapping turns this tenant's golden records into customer-shaped rows —
      after the zone disclosure gate refuses the departure on the residency
      tags recorded at land. Person-gated and grant-checked like every
      surface; see `AshEnterprise.Mdm.Export`.
      """

      argument :zone, :string, allow_nil?: false

      run AshEnterprise.Mdm.Export
    end
  end

  code_interface do
    define :by_external, args: [:system, :id], not_found_error?: false
    define :upsert_from_source
    define :read
    define :mdm_export, args: [:zone]
  end

  policies do
    # The egress departure is a grant-checked act (MDM-6): a principal
    # holding a role grant on the tenant's data may export; a person with
    # no grants — and a nil actor — is refused by the grant union below.
    # The zone disclosure gate itself lives in the run
    # (AshEnterprise.Mdm.Export), on the land-recorded residency tags.
    policy action(:mdm_export) do
      authorize_if AshEnterprise.Security.Checks.RoleGrant
    end
  end
end
