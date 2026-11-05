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
    base: AshEnterprise.Platform.Resource,
    base_opts: [
      ownership: :organization_owned,
      # The subscription carries its own `draft -> published -> retired`
      # lifecycle; the platform's `lifecycle_status` would be a second one.
      lifecycle?: false,
      audit?: true,
      # Publish is one-way and retire keeps the row, because dispatches and
      # instances that reference it outlive it.
      archival?: false
    ]

  require Ash.Query

  # The prompt-invalidation wiring: every lifecycle act — publish, retire,
  # enable, disable — rebuilds the engine's ETS interest index as soon as the
  # write has committed, so the nudge path is honest within a transaction
  # rather than within a minute. The index's own TTL remains the backstop for
  # a lost refresh. See `Changes.RefreshTriggerIndex` below.
  changes do
    change {AshEnterprise.Bpmn.Changes.EnsureCursor, []}, on: [:update]
    change {AshEnterprise.Bpmn.Subscription.Changes.RefreshTriggerIndex, []}, on: [:update]
  end

  # The cycle invariant the library cannot know about: this application's own
  # bpmn, decision and process domains carry the audit hook too, so a
  # subscription matching one would start processes from governance events and
  # could be fed by them. The library refuses its own domains
  # (`AshBpmn.`/`AshDecisions.`); these are ours to refuse.
  validations do
    validate {AshEnterprise.Bpmn.Subscription.Validations.NotSelfTriggering, []}, on: [:update]
  end

  @doc """
  The tenants the trigger sweep fans out to: every organization with a
  published, enabled subscription, or with a token parked at a message catch (a process
  waiting to hear of something).

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

    waiting =
      AshEnterprise.Bpmn.Token
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(status == :waiting and contains(subscription_signature, "message:"))

    Enum.flat_map([subscribed, waiting], fn query ->
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
