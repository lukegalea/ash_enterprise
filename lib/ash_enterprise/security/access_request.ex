defmodule AshEnterprise.Security.AccessRequest do
  @moduledoc """
  Someone asking for a role they do not have.

  The demonstration this repository owed. [ADR 0009](../../../docs/adr/0009-strangler-and-bpmn-are-first-party.md)
  has claimed since it was written that a process is an ordinary owned, tenant-scoped, audited
  record and that *who may approve* comes from the same union of grants as *who may read*.
  This is the resource that makes the claim checkable, and it was chosen over inventing a
  domain because it is self-referential in the useful way: the approval workflow governs the
  authorization model that governs the approval workflow.

  ## It carries no approval change, deliberately

  `AshBpmn.Changes.RequireApproval` would put a gate on the action, and that is the
  single-gate case the package documents. This one starts its process from the **event** the
  submission writes, because that is the harder claim and the one nothing here demonstrated:
  a process begins because something happened, not because a developer wired this particular
  action to that particular process.

  The consequence worth stating: submitting is a plain create. It succeeds immediately, the
  request sits `:submitted`, and the process that decides it starts moments later when the
  trigger sweep reaches the event. A caller who expected `submit` to block until approved
  would be surprised — and would be wrong, because a human approval is not something to hold
  a request open for.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Security,
    ownership: :user_owned,
    audit?: true,
    api_type: :both

  postgres do
    table "access_requests"
    repo AshEnterprise.Repo

    references do
      reference :requested_role, on_delete: :nothing
      reference :scoping_business_unit, on_delete: :nothing
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :justification, :string do
      allow_nil? false
      public? true
      constraints min_length: 10
      description "Why the requester needs it. The guard on the trigger reads this."
    end

    attribute :requested_role_tier, :atom do
      allow_nil? false
      default :standard
      constraints one_of: [:standard, :elevated, :privileged]
      public? true

      description """
      How much the role is worth stealing, as the requester's own claim.

      A separate attribute rather than something derived from the role, because the decision
      table that routes this is business configuration and must be able to change what counts
      as privileged without a deploy.
      """
    end

    attribute :risk_tier, :atom do
      constraints one_of: [:low, :medium, :high]
      public? true
      description "Set by the decision the process invokes. Nil until it has run."
    end

    attribute :decision_outcome, :atom do
      constraints one_of: [:granted, :rejected, :expired]
      public? true
    end

    attribute :granted_user_role_id, :uuid do
      public? true
      description "The assignment this produced, when it was granted."
    end
  end

  relationships do
    belongs_to :requested_role, AshEnterprise.Security.Role do
      allow_nil? false
      public? true
    end

    belongs_to :scoping_business_unit, AshEnterprise.Accounts.BusinessUnit do
      public? true
      description "Which subtree the role would be scoped to. Defaults to the requester's own."
    end
  end

  actions do
    defaults [:read]

    create :submit do
      primary? true
      accept [:justification, :requested_role_tier, :requested_role_id, :scoping_business_unit_id]
      description "Raise a request. Starts nothing directly -- see the moduledoc."

      # Ownership is the requester. `owner_id` is `allow_nil? false` on a `:user_owned`
      # resource and nothing sets it for you -- the platform supplies the *columns* and the
      # grant model that reads them, but who owns a given record is a decision only the action
      # can make. Set explicitly rather than defaulted, because "the actor owns what they
      # created" is true here and is not true of, say, a record created on someone's behalf.
      change set_attribute(:owner_id, actor(:id))
      change set_attribute(:owner_type, :user)
      change set_attribute(:owning_user_id, actor(:id))

      # The business unit the request belongs to, which is what `:local` and `:deep` grants
      # resolve against when deciding who can see it.
      change AshEnterprise.Security.AccessRequest.Changes.OwnFromActor
    end

    # Called by the process, through `AshEnterprise.Process.ActionInvoker`'s allowlist. An
    # ordinary action with ordinary policies: the process orchestrates and the mutation is
    # still guarded the way every other mutation is.
    update :record_risk do
      accept [:risk_tier]
      description "Records what the risk decision returned, so the request shows why it routed."
    end

    update :grant do
      accept [:granted_user_role_id]
      require_atomic? false
      change set_attribute(:decision_outcome, :granted)
      change set_attribute(:lifecycle_status, :active)
    end

    update :reject do
      accept []
      require_atomic? false
      change set_attribute(:decision_outcome, :rejected)
      change set_attribute(:lifecycle_status, :inactive)
    end
  end

  code_interface do
    define :submit
    define :record_risk, args: [:risk_tier]
    define :grant, args: [:granted_user_role_id]
    define :reject
  end
end

defmodule AshEnterprise.Security.AccessRequest.Changes.OwnFromActor do
  @moduledoc """
  Places the request in the requester's own business unit, and scopes the requested role there
  when the requester did not say otherwise.

  Two separate defaults that look like one. `owning_business_unit_id` is what the grant model
  reads to decide who can *see* the request; `scoping_business_unit_id` is what the role would
  be scoped to if granted. They coincide in the ordinary case and must not be conflated: asking
  for a role scoped to a different subtree is exactly the request that needs approving.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, %{actor: actor}) when is_map(actor) do
    unit = Map.get(actor, :owning_business_unit_id)

    changeset
    |> put_default(:owning_business_unit_id, unit)
    |> put_default(:scoping_business_unit_id, unit)
  end

  def change(changeset, _opts, _context), do: changeset

  defp put_default(changeset, _field, nil), do: changeset

  defp put_default(changeset, field, value) do
    case Ash.Changeset.get_attribute(changeset, field) do
      nil -> Ash.Changeset.force_change_attribute(changeset, field, value)
      _ -> changeset
    end
  end
end
