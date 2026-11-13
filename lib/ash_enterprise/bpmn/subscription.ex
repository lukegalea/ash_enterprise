defmodule AshEnterprise.Bpmn.Subscription do
  @moduledoc """
  A declaration that something happening in the audit log should start a
  process — `AshBpmn.Resources.Subscription` instantiated on the platform base,
  so the tables are this application's and the row inherits ownership, tenancy,
  provenance and the standard policy set like every other record.

  What the adoption deleted, and why, is in TRD §10 ("Replacement, not
  migration"): this resource and its two siblings replaced
  `AshEnterprise.Process.{Trigger,TriggerCursor,TriggerDispatch}` in the same
  change that adopted the library's trigger engine. No production system ever
  ran the prototype; nothing migrated and the old tables are dropped.

  Audited, because publishing one is a deployment act: it changes when the
  business starts processes, and "which version of that rule was in force in
  March" is a question someone will ask.

  ## The publish lane creates the tenant's cursor

  The library leaves one job to the host: creating the tenant's cursor when the
  first subscription goes live. A sweep-created cursor starts at the log's
  *current* high-water mark, so every event between publishing and the first
  sweep would fall in the gap; a subscription fires on what happens *after it
  exists*, so the cursor is established here instead, stamped at the mark as of
  publish. `Cursor.create/1` is an upsert, so re-publishing, enabling,
  disabling or retiring never resets an existing cursor — see
  `AshEnterprise.Bpmn.Changes.EnsureCursor`.
  """

  use AshBpmn.Resources.Subscription,
    domain: AshEnterprise.Bpmn,
    repo: AshEnterprise.Repo,
    table: "bpmn_subscriptions",
    # Without its own engine bypass: the platform's, narrowed by `EngineReach`, is the
    # engines' only one, so nothing they mark reaches a human_only action (ADR 0059).
    policies?: false,
    base: AshEnterprise.Platform.Resource,
    base_opts: [
      ownership: :organization_owned,
      # The subscription carries its own `draft -> published -> retired`
      # lifecycle; the platform's `lifecycle_status` would be a second one.
      lifecycle?: false,
      audit?: true,
      # Publish is one-way and retire keeps the row, because dispatches and
      # instances that reference it outlive it.
      archival?: false,
      # Choosing who a recipe's steps run as moves what it can do, so an automation
      # principal never reaches it (ADR 0043).
      changes_authority: [:set_authority],
      # A standing grant is a person's own act: no system actor, no automation principal
      # and nothing an engine marks may publish one (ADR 0043, ADR 0069).
      # Installing a pack is a person's act too: its drafts are created on their grants.
      human_only: [:publish_granted, :install_pack]
    ]

  require Ash.Query

  alias AshEnterprise.Bpmn.Subscription.Validations

  # Who the steps of a process this subscription starts may run as. An event grants
  # nothing: authority comes from this value, chosen while the row is a draft and
  # fixed by publishing it. See `AshEnterprise.Bpmn.Subscription.Authority`.
  attributes do
    attribute :authority, :atom do
      constraints one_of: AshEnterprise.Bpmn.Subscription.Authority.values()
      default :human_tasks_only
      allow_nil? false
      public? true

      description "Who the started process's service and send tasks run as: nobody " <>
                    "(:human_tasks_only), the person whose write caused the event " <>
                    "(:causing_person), or a person's standing grant (:standing_grant)."
    end

    # Stamped by `publish_granted` from the actor, never from input: the person within
    # whose authority a `:standing_grant` version's steps run.
    attribute :accountable_person_id, :uuid do
      public? true

      description "The person who published this version with :standing_grant. Its steps " <>
                    "run within what they may do, and stop when they no longer may."
    end

    # Stamped by `publish_granted` from what it validated, never from input: the
    # definitions a `:standing_grant` version's steps may run in.
    attribute :granted_definition_ids, {:array, :uuid} do
      public? true

      description "The process definitions this :standing_grant version's publisher saw: " <>
                    "its process and every call activity's child, as published then. A " <>
                    "step of any other definition runs nothing."
    end
  end

  actions do
    # The macro's `create` does not accept `authority`, so a draft takes it here. Only a
    # draft: publishing fixes it, and a new authority is a new version.
    update :set_authority do
      description "Choose who a draft's started processes run their service tasks as."
      accept [:authority]
      require_atomic? false

      validate attribute_equals(:status, :draft),
        message: "authority is chosen on a draft; publish a new version to change it"

      validate {Validations.AuthoritySelectable, []}
    end

    # A person publishes a draft as a standing grant: its steps run as the `recipe_runner`
    # automation principal acting for them, on the intersection of the two (ADR 0069).
    #
    # Everything the macro's `publish` does, restated by module name, because the macro has
    # no option for extra actions; `standing_grant_test.exs` fails if a step
    # `publish` carries is missing here. Then: the authority is `:standing_grant` and nothing
    # else, the steps the diagram names must be ones that can run as the intersection, the
    # actor is stamped as the accountable person, the definitions validated are stamped as
    # the only ones its steps may run in, and their start grant for this version
    # (`recipe:<key>:<version>`) is written in the same transaction, so a later version
    # never inherits it.
    update :publish_granted do
      description "Publish a draft whose steps run within your own authority, as the " <>
                    "recipe runner acting for you."

      accept []
      require_atomic? false

      validate attribute_equals(:status, :draft), message: "only a draft can be published"

      validate AshBpmn.Resources.Subscription.TargetPresent
      validate AshBpmn.Resources.Subscription.SignalNamePresent
      validate AshBpmn.Resources.Subscription.GuardFeel
      validate AshBpmn.Resources.Subscription.ExpressionsParse
      validate AshBpmn.Resources.Subscription.MatchAudited
      validate AshBpmn.Resources.Subscription.NotCyclic
      validate AshBpmn.Resources.Subscription.DecisionExists

      change set_attribute(:authority, :standing_grant)
      validate {Validations.StandingGrantSteps, []}

      # Hooks, so they run after authorization: an actor the policy refuses is Forbidden,
      # not an input error.
      change {AshEnterprise.Bpmn.Subscription.Changes.StampAccountablePerson, []}
      change {AshEnterprise.Bpmn.Subscription.Changes.StampGrantedDefinitions, []}
      change {AshEnterprise.Bpmn.Subscription.Changes.WriteStartGrant, []}

      change set_attribute(:status, :published)
      change AshBpmn.Resources.Subscription.CompileExpressions
      # Last, as in publish, so a refused publish retires nothing: the published version
      # of the same key is retired at the log's boundary in this transaction, and each
      # event starts a process for one version only.
      change AshBpmn.Resources.Subscription.SupersedePredecessor
    end

    # A pack from `priv/packs/` arrives as drafts and nothing else: never published, enabled
    # or granted, so it cannot make itself live (`AshEnterprise.Bpmn.Packs`). Its process
    # definitions and recipes are created on the installing person's own grants, and a key
    # the tenant already has is left alone, so installing again creates nothing.
    action :install_pack, :map do
      description "Install a recipe pack into this tenant as drafts, for a person to " <>
                    "review and publish. Installing it again changes nothing."

      transaction? true

      argument :pack, :string do
        allow_nil? false
        description "The pack's name: a directory under priv/packs."
      end

      run AshEnterprise.Bpmn.Subscription.Actions.InstallPack
    end
  end

  code_interface do
    define :set_authority, action: :set_authority, args: [:authority]
    define :publish_granted, action: :publish_granted
    define :install_pack, action: :install_pack, args: [:pack]
    define :get_subscription, action: :read, get_by: [:id]
  end

  # The prompt-invalidation wiring: every lifecycle act — publish, retire,
  # enable, disable — rebuilds the engine's ETS interest index as soon as the
  # write has committed, so the nudge path is honest within a transaction
  # rather than within a minute. The index's own TTL remains the backstop for
  # a lost refresh. See `Changes.RefreshTriggerIndex` below.
  #
  # Choosing a draft's authority is none of those: it makes no tenant interested in
  # anything, so it neither stamps the cursor nor rebuilds the index.
  changes do
    change {AshEnterprise.Bpmn.Changes.EnsureCursor, []},
      on: [:update],
      where: [negate(action_is(:set_authority))]

    change {AshEnterprise.Bpmn.Subscription.Changes.RefreshTriggerIndex, []},
      on: [:update],
      where: [negate(action_is(:set_authority))]
  end

  # The cycle invariant the library cannot know about: this application's own
  # bpmn, decision and process domains carry the audit hook too, so a
  # subscription matching one would start processes from governance events and
  # could be fed by them. The library refuses its own domains
  # (`AshBpmn.`/`AshDecisions.`); these are ours to refuse.
  validations do
    validate {AshEnterprise.Bpmn.Subscription.Validations.NotSelfTriggering, []}, on: [:update]

    # Authority, checked where the macro's `publish` cannot see it: narrowed from here
    # without touching the action the library wrote.
    #
    # A recipe on a resource with no tenant is refused whatever its authority: those
    # writes land in no tenant's chain, so nothing would ever sweep them.
    validate {Validations.TenantScopedMatch, []} do
      on [:update]
      where action_is([:publish, :publish_granted])
    end

    # These two read the authority a draft carries into `publish`. `publish_granted` sets
    # its own (`:standing_grant`), which neither is about.

    validate {Validations.HumanTasksOnly, []} do
      on [:update]
      where action_is(:publish)
    end

    validate {Validations.CausingPersonAllowlisted, []} do
      on [:update]
      where action_is(:publish)
    end

    # A standing grant is a person's act: the path the setup task and system actors use
    # cannot publish one.
    validate attribute_does_not_equal(:authority, :standing_grant) do
      on [:update]
      where action_is(:publish)

      message "a standing grant is published by the person accountable for it, with " <>
                "publish_granted, not by publish"
    end
  end

  @doc """
  The tenants the trigger sweep fans out to: every organization with a
  published, enabled subscription, with a retired version whose window the sweep has not
  finished (the backlog before its successor was published), or with a token parked at a
  message catch (a process waiting to hear of something).

  Wired as `config :ash_bpmn, trigger_tenants: {__MODULE__, :trigger_tenants,
  []}` — the `ash_oban` `list_tenants` pattern, evaluated per call. Deliberately
  derived from what is listening rather than from a listing of all
  organizations, which is how the prototype's cron sweep enumerated tenants:
  a tenant with nothing listening costs nothing, and the ordering guarantee the
  cursor relies on holds *within* a tenant, so there is one sweep per tenant
  and no global one.

  A cross-tenant read, and the index is why that is safe: it answers "does
  *anyone* care", a resource name is not customer data, and the per-tenant
  question is answered later by the sweep inside that tenant's scope.
  """
  @spec trigger_tenants() :: [Ash.UUID.t()]
  def trigger_tenants do
    subscribed =
      __MODULE__
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(status == :published and enabled == true and kind == :message)

    # A retired version still finishing its window: the events before its successor was
    # published are still its own, and the sweep dispatches them under it, whatever the
    # successor watches or whether it is enabled. Until the tenant's cursor reaches the
    # boundary, the tenant is swept.
    finishing =
      __MODULE__
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(
        status == :retired and enabled == true and kind == :message and
          not is_nil(retired_sequence) and
          not exists(
            AshEnterprise.Bpmn.Cursor,
            organization_id == parent(organization_id) and
              last_sequence >= parent(retired_sequence)
          )
      )

    waiting =
      AshEnterprise.Bpmn.Token
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(status == :waiting and contains(subscription_signature, "message:"))

    Enum.flat_map([subscribed, finishing, waiting], fn query ->
      query
      |> Ash.Query.select(:organization_id)
      |> Ash.read!(actor: AshEnterprise.Platform.SystemActor.process(), tenant: nil)
      |> Enum.map(& &1.organization_id)
    end)
    |> Enum.uniq()
  end

  defmodule Validations.NotSelfTriggering do
    @moduledoc """
    Refuses a subscription that matches a resource in this application's bpmn,
    decision or process domains.

    The engine closes its own half of the cycle: a subscription may not match
    `AshBpmn.` or `AshDecisions.` resources, because those write rows that feed
    subscriptions. But this application's *own* engine domains are audited the
    same way — a definition published, a decision evaluated, a binding changed
    are all events — so the same refusal has to be restated here, by host
    prefix, or a subscription on `AshEnterprise.Bpmn.Definition` would be
    accepted and start a process on every publish.

    Matched by module prefix rather than an enumerated list, so a resource
    added to any of the three domains later is covered without anyone
    remembering to come back here. Runs on every update, so an operational
    `enable` of a draft cannot smuggle a cyclic match past publish.
    """

    use Ash.Resource.Validation

    @refused_prefixes [
      "AshEnterprise.Bpmn.",
      "AshEnterprise.Decisions.",
      "AshEnterprise.Process."
    ]

    @impl true
    def validate(changeset, _opts, _context) do
      resource =
        changeset
        |> Ash.Changeset.get_attribute(:match_resource)
        |> Kernel.||("")
        |> AshBpmn.Resources.Subscription.ResourceName.short()

      if Enum.any?(@refused_prefixes, &String.starts_with?(resource, &1)) do
        {:error,
         field: :match_resource,
         message:
           "a subscription may not match #{resource}: this application's bpmn, decision " <>
             "and process domains audit their own writes, so a subscription on one would " <>
             "start processes that feed it"}
      else
        :ok
      end
    end
  end

  defmodule Changes.RefreshTriggerIndex do
    @moduledoc """
    Rebuilds `AshBpmn.Triggers.Index` after a subscription lifecycle write.

    The engine's nudge path answers "does anyone care about this resource" from
    an ETS index that is deliberately stale by up to a TTL — safe, because the
    cron sweep is the driver and a stale index costs latency, never a process.
    But the application administers subscriptions here, in its own actions, and
    "we knew the answer a minute ago" is a worse answer than "we know the
    answer" when the write is one we just made. So each publish/retire/
    enable/disable rebuilds the index **after the transaction commits**
    (`after_transaction`, not an in-transaction hook: a rebuild inside the
    write's own transaction would read the pre-commit snapshot and miss the row
    that caused it).

    Skipped when the index is not running — the TTL is the backstop, and a
    missing index costs queries, never correctness. `reload!/0` (synchronous)
    rather than `refresh/0` so the invalidation is visible in the caller's next
    statement.
    """

    use Ash.Resource.Change

    @impl true
    def change(changeset, _opts, _context) do
      Ash.Changeset.after_transaction(changeset, fn _changeset, result ->
        case result do
          {:ok, _} -> refresh()
          _ -> :ok
        end

        result
      end)
    end

    defp refresh do
      if AshBpmn.Triggers.Index.started?() do
        AshBpmn.Triggers.Index.reload!()
      else
        :ok
      end
    end
  end
end
