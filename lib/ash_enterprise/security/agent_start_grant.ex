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
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Security,
    ownership: :none,
    lifecycle?: false,
    human_only: [:grant],
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
  end

  identities do
    identity :unique_grant, [:agent_key, :principal_id]
  end

  actions do
    defaults [:read, :destroy]

    create :grant do
      primary? true
      accept [:agent_key, :principal_id, :principal_type]
      upsert? true
      upsert_identity :unique_grant
      description "Idempotent: granting what is already held is a no-op."
    end
  end

  code_interface do
    define :grant
    define :read
    define :destroy
  end
end
