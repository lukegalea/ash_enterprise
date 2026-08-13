defmodule AshEnterprise.Accounts.TeamMembership do
  @moduledoc """
  Join table between users and teams.

  Modelled directly on the CDM's `TeamMembership` entity — one of the few
  intersect tables the CDM actually publishes (Dataverse's own documentation
  404s for it), so this is a case where the frozen corpus is the *better* source.
  See `priv/cdm/resolved/team_membership.json`.

  ## Why this is authorization-critical

  Two of the three grant paths run through this table:

    * A role held by an owner team is inherited by its members, so effective
      privileges are `direct roles ∪ roles of every owner team I belong to`.
    * A record shared with a team is reachable by its members, so the sharing
      check compares against `{me} ∪ my team ids`.

  Which is why `AshEnterprise.Security.ActorContext` resolves `team_ids` **once
  per request** and policy checks read the precomputed set. A policy that queried
  this table per row would multiply every list query by the number of teams the
  actor is in.

  ## Ownership

  `:none` — nobody owns a membership row, matching how Dataverse treats intersect
  tables. Access to it is governed by access to the team.

  Auditing stays **on**, though: "who was added to which team, when, by whom" is
  one of the most frequently asked questions in a security review, and it is
  invisible if only the team and user rows are audited.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Accounts,
    ownership: :none,
    lifecycle?: false,
    cdm_entity: "TeamMembership"

  postgres do
    table "team_memberships"
    repo AshEnterprise.Repo

    references do
      # Removing a user or a team removes their memberships. This is one of the
      # few genuinely safe cascades: a membership has no meaning without both
      # ends, and leaving orphans would silently grant or deny access.
      reference :user, on_delete: :delete
      reference :team, on_delete: :delete
    end
  end

  attributes do
    uuid_primary_key :id
  end

  relationships do
    belongs_to :user, AshEnterprise.Accounts.User do
      allow_nil? false
      public? true
      attribute_writable? true
    end

    belongs_to :team, AshEnterprise.Accounts.Team do
      allow_nil? false
      public? true
      attribute_writable? true
    end
  end

  identities do
    identity :unique_membership, [:user_id, :team_id]
  end

  actions do
    defaults [:read, :destroy]
    default_accept [:user_id, :team_id]

    create :create do
      primary? true
      upsert? true
      upsert_identity :unique_membership

      description """
      Idempotent by design. Adding someone to a team they are already in is not
      an error -- it is the same intent expressed twice, and directory sync and
      agent-driven flows both do it routinely.
      """
    end
  end

  code_interface do
    define :create
    define :read
    define :destroy
  end
end
