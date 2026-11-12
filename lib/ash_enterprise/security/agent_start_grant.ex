defmodule AshEnterprise.Security.AgentStartGrant do
  @moduledoc """
  Who may start an agent that runs as an automation principal: one row per `(agent,
  person or team)`, in RFC 8693's `may_act` sense (ADR 0043).

  An automation principal runs on the intersection of its own grants and those of the
  person it acts for (`AshEnterprise.Security.ActorContext.intersect/2`), so it can
  never do more than that person could. The start grant answers the question the
  intersection cannot: may this person have this agent act for them at all? It is per
  agent key, not per principal, because two agents running as one principal are two
  different things to hand work to.

  A person holds it directly, or through a team they belong to. It is checked when the
  work is requested and again at every claim (`AshEnterprise.Execution.Identity`), by
  claim logic that may read, never by a policy check. Revoking it stops queued work
  before it runs.

  Making one is a person's decision: `grant` is `human_only`.

  A recipe's start grant (`recipe:<key>:<version>`, ADR 0069) is not made with `grant`,
  which refuses that key (`AshEnterprise.Security.Validations.NotARecipeGrant`). Publishing
  the recipe with `publish_granted` writes it, through `grant_recipe`, for the person it
  stamps as accountable. No grant and no system actor but `oban` reaches `grant_recipe`
  (`machinery_only`), and `publish_granted` writes it without authorization, as part of
  that person's own act.

  A grant may carry `valid_until`, like a role grant (ADR 0066): it counts while that is unset
  or later than now, and at the instant itself it is gone. A recipe's standing grant always
  carries one (`AshEnterprise.Bpmn.Subscription.Authority`, ADR 0069).
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Security,
    ownership: :none,
    lifecycle?: false,
    human_only: [:grant],
    machinery_only: [:grant_recipe],
    changes_authority: [:destroy]

  postgres do
    table "agent_start_grants"
    repo AshEnterprise.Repo
  end

  attributes do
    uuid_primary_key :id

    attribute :agent_key, :string do
      allow_nil? false
      public? true
      constraints max_length: 255
      description "The agent that may be started."
    end

    attribute :principal_id, :uuid do
      allow_nil? false
      public? true
      description "The user or team that may start it."
    end

    attribute :principal_type, AshEnterprise.Platform.Types.OwnerType do
      allow_nil? false
      public? true
      description "Discriminates principal_id between a user and a team."
    end

    attribute :valid_until, :utc_datetime_usec do
      public? true
      description "When the grant ends. Nil: until it is revoked."
    end
  end

  identities do
    identity :unique_grant, [:agent_key, :principal_id]
  end

  actions do
    defaults [:read, :destroy]

    create :grant do
      primary? true
      accept [:agent_key, :principal_id, :principal_type, :valid_until]
      upsert? true
      upsert_identity :unique_grant
      description "Idempotent: granting what is already held is a no-op."
      validate AshEnterprise.Security.Validations.NotARecipeGrant
    end

    # Only publish_granted's own write (`AshEnterprise.Bpmn.Subscription.Changes.WriteStartGrant`).
    create :grant_recipe do
      description "A recipe version's start grant, written by publishing it as a standing grant."
      accept [:agent_key, :principal_id, :principal_type, :valid_until]
      upsert? true
      upsert_identity :unique_grant
    end
  end

  code_interface do
    define :grant
    define :grant_recipe
    define :read
    define :destroy
  end
end
