defmodule AshEnterprise.Process.SubscriptionTest do
  @moduledoc """
  The app's wiring around the engine's subscription resource, as assertions.

  The subscription resource itself is `ash_bpmn`'s and its internals are
  covered by the library's own suite. What is *this* application's to prove is
  the wiring it contributes: that the publish-time refusals fire against the
  `AshEnterprise.Audit.EventSource` this app configures, that resource names
  are stored in the one spelling the sweep compares against, that the publish
  lane establishes the tenant's cursor at the high-water mark, and that the
  dispatch ledger's identity is what it is here for. The engine's behaviour
  over an installed subscription is the end-to-end demo test's subject.
  """

  use AshEnterprise.DataCase, async: false

  require Ash.Query

  alias AshEnterprise.Bpmn.{Cursor, Dispatch, Subscription}
  alias AshEnterprise.Platform.{Seeder, SystemActor}

  setup do
    %{organization: organization} =
      Seeder.seed_tenant(
        unique_name: "sub-#{System.unique_integer([:positive])}",
        email: "sub-#{System.unique_integer([:positive])}@example.com"
      )

    %{tenant: organization.id}
  end

  defp opts(tenant), do: [actor: SystemActor.process(), tenant: tenant]

  defp subscription!(tenant, attrs) do
    defaults = %{
      key: "s-#{System.unique_integer([:positive])}",
      match_resource: "AshEnterprise.Accounts.Team",
      process_key: "some_process"
    }

    tenant
    |> subscription_changeset!(Map.merge(defaults, attrs))
    |> Subscription.publish!(opts(tenant))
  end

  defp subscription_changeset!(tenant, attrs) do
    Subscription.create!(attrs, opts(tenant))
  end

  describe "a subscription may not feed the engines" do
    # The invariant that was nearly left to luck in the prototype: some bpmn and
    # decision resources carry the audit hook, so a process started by a
    # subscription writes audit events, and those are subscription inputs.
    # Two refusals, two owners: the engine refuses its own domains; this
    # application refuses its own (`Validations.NotSelfTriggering`) — both
    # at publish, by name.
    for resource <- [
          "AshEnterprise.Bpmn.Definition",
          "AshEnterprise.Process.Binding"
        ] do
      test "refuses to match #{resource}", %{tenant: tenant} do
        subscription =
          subscription_changeset!(tenant, %{
            key: "self-#{System.unique_integer([:positive])}",
            match_resource: unquote(resource),
            process_key: "p"
          })

        assert {:error, error} = Subscription.publish(subscription, opts(tenant))
        assert Exception.message(error) =~ "may not match"
      end
    end
  end

  describe "a subscription must watch something that actually writes events" do
    # The audit log is a feed of writes that went through an Ash action, not a
    # change feed — and `audited?/1` on the app's adapter narrows that to
    # "writes into *this* log".
    test "refuses an unaudited resource", %{tenant: tenant} do
      # `Legacy.User` reads a Postgres view; the writes worth reacting to are the old
      # application's raw SQL, which runs no Ash action. This is the case that will actually
      # come up on a strangler-migrated application.
      subscription =
        subscription_changeset!(tenant, %{
          key: "legacy-#{System.unique_integer([:positive])}",
          match_resource: "AshEnterprise.Legacy.User",
          process_key: "onboarding"
        })

      assert {:error, error} = Subscription.publish(subscription, opts(tenant))
      assert Exception.message(error) =~ "not audited"
      assert Exception.message(error) =~ "never fire"
    end

    test "refuses a resource that does not exist, which is how a typo presents", %{
      tenant: tenant
    } do
      subscription =
        subscription_changeset!(tenant, %{
          key: "typo-#{System.unique_integer([:positive])}",
          match_resource: "AshEnterprise.Accounts.Uzer",
          process_key: "p"
        })

      assert {:error, error} = Subscription.publish(subscription, opts(tenant))
      assert Exception.message(error) =~ "is not a loadable Ash resource"
    end

    test "an audited resource publishes", %{tenant: tenant} do
      assert %Subscription{status: :published} =
               subscription!(tenant, %{match_resource: "AshEnterprise.Security.Role"})
    end

    # The bug this caught in the prototype's own code: the audit log stores
    # `to_string(module)`, which carries the `Elixir.` prefix. A stored
    # inspect-style name would compare unequal to every event forever — the
    # same silent-never-fires failure, arriving through the back door. So a
    # name is accepted in either form and stored in one.
    test "the resource name is stored the way the adapter's context spells it", %{tenant: tenant} do
      from_short =
        subscription!(tenant, %{
          key: "short-#{System.unique_integer([:positive])}",
          match_resource: "AshEnterprise.Security.Role"
        })

      from_full =
        subscription!(tenant, %{
          key: "full-#{System.unique_integer([:positive])}",
          match_resource: "Elixir.AshEnterprise.Security.Role"
        })

      assert from_short.match_resource == "AshEnterprise.Security.Role"
      assert from_full.match_resource == from_short.match_resource
    end
  end

  describe "the publish lane establishes the cursor" do
    # The engine leaves this to the host: a sweep-created cursor starts at the
    # log's *current* end, so everything between publishing and the first sweep
    # would fall in the gap. Publishing here stamps the mark as of publish.
    test "publishing stamps the cursor at the current high-water mark", %{tenant: tenant} do
      assert is_nil(cursor(tenant)), "a tenant with no subscription has no cursor"

      # Some audited writes, so the high-water mark is past zero.
      create_role(tenant, "cursor-a-#{System.unique_integer()}")
      high_water_before = highest_sequence(tenant)

      published = subscription!(tenant, %{match_resource: "AshEnterprise.Security.Role"})

      published_cursor = cursor(tenant)

      # The mark is as of publish — the subscription's own audit events (the
      # draft's create and the publish itself) sit behind it, which is correct:
      # a subscription does not fire on its own deployment.
      assert published_cursor.last_sequence >= high_water_before

      # And the events that matter — writes *after* the subscription existed —
      # sit ahead of it, so the sweep will reach them.
      create_role(tenant, "cursor-b-#{System.unique_integer()}")
      assert highest_sequence(tenant) > published_cursor.last_sequence

      # The next lifecycle act must not roll the cursor forward: an
      # enable/disable/retire is an operational or deployment act, never a
      # re-stamp, or everything in between would be skipped silently.
      published
      |> Subscription.disable!(opts(tenant))
      |> Subscription.enable!(opts(tenant))

      assert cursor(tenant).last_sequence == published_cursor.last_sequence
    end
  end

  describe "versioning and the operational switch" do
    test "versions are per key and per tenant", %{tenant: tenant} do
      a =
        subscription!(tenant, %{
          key: "shared",
          match_resource: "AshEnterprise.Accounts.Team",
          process_key: "p"
        })

      b =
        subscription!(tenant, %{
          key: "shared",
          match_resource: "AshEnterprise.Accounts.Team",
          process_key: "p"
        })

      assert a.version == 1
      assert b.version == 2
    end

    test "another tenant's versions are independent", %{tenant: tenant} do
      %{organization: other} =
        Seeder.seed_tenant(
          unique_name: "sub-other-#{System.unique_integer([:positive])}",
          email: "sub-other-#{System.unique_integer([:positive])}@example.com"
        )

      a =
        subscription!(tenant, %{
          key: "same",
          match_resource: "AshEnterprise.Accounts.Team",
          process_key: "p"
        })

      b =
        subscription!(other.id, %{
          key: "same",
          match_resource: "AshEnterprise.Accounts.Team",
          process_key: "p"
        })

      assert a.version == 1
      assert b.version == 1
    end

    test "disabling is an operational switch, not a deployment act", %{tenant: tenant} do
      subscription = subscription!(tenant, %{})

      off = Subscription.disable!(subscription, opts(tenant))

      assert off.enabled == false
      assert off.status == :published, "disabling must not retire it"
      assert off.version == subscription.version, "disabling must not create a version"
    end
  end

  describe "the dispatch ledger" do
    setup %{tenant: tenant} do
      %{subscription: subscription!(tenant, %{match_resource: "AshEnterprise.Accounts.Team"})}
    end

    # What makes a replayed batch idempotent after a sweep crashes mid-way:
    # the identity, written in the same transaction as the instance start.
    test "the same subscription cannot record twice for one event", %{
      tenant: tenant,
      subscription: subscription
    } do
      event_id = Ash.UUID.generate()

      assert {:ok, _} =
               Dispatch.create(
                 %{
                   subscription_id: subscription.id,
                   event_id: event_id,
                   event_sequence: 1,
                   event_occurred_at: DateTime.utc_now(),
                   kind: :start,
                   status: :started
                 },
                 opts(tenant)
               )

      assert {:error, _} =
               Dispatch.create(
                 %{
                   subscription_id: subscription.id,
                   event_id: event_id,
                   event_sequence: 1,
                   event_occurred_at: DateTime.utc_now(),
                   kind: :start,
                   status: :started
                 },
                 opts(tenant)
               )
    end

    # A skip is as much a fact as a start: it answers "why did nothing happen",
    # which is the harder of the two questions. Plain guard *false* is the one
    # outcome that records nothing — an ordinary no, not a condition to
    # investigate — so the rows that exist are the ones worth reading.
    test "a skipped dispatch is recorded with its reason; depth rides along", %{
      tenant: tenant,
      subscription: subscription
    } do
      {:ok, skipped} =
        Dispatch.create(
          %{
            subscription_id: subscription.id,
            event_id: Ash.UUID.generate(),
            event_sequence: 2,
            event_occurred_at: DateTime.utc_now(),
            kind: :start,
            status: :skipped,
            reason: :guard_null,
            depth: 2
          },
          opts(tenant)
        )

      assert skipped.status == :skipped
      assert skipped.reason == :guard_null
      assert skipped.depth == 2

      assert {:error, _} =
               Dispatch.create(
                 %{
                   subscription_id: subscription.id,
                   event_id: Ash.UUID.generate(),
                   event_sequence: 3,
                   event_occurred_at: DateTime.utc_now(),
                   kind: :start,
                   status: :bogus
                 },
                 opts(tenant)
               )
    end
  end

  describe "the sweep fan-out" do
    # `trigger_tenants/0` is what the cron fans out to, so "every tenant with a
    # published, enabled subscription" is the property worth pinning: a tenant
    # with nothing listening costs nothing, and drafts and disabled switches
    # never earn a sweep.
    test "enumerates exactly the tenants with a live subscription", %{tenant: tenant} do
      before = Subscription.trigger_tenants()
      refute tenant in before

      subscription!(tenant, %{match_resource: "AshEnterprise.Security.Role"})
      assert tenant in Subscription.trigger_tenants()

      disabled =
        subscription!(tenant, %{
          key: "off-#{System.unique_integer([:positive])}",
          match_resource: "AshEnterprise.Security.Role"
        })

      _draft =
        Subscription.create!(
          %{
            key: "draft-#{System.unique_integer([:positive])}",
            match_resource: "AshEnterprise.Security.Role",
            process_key: "p"
          },
          opts(tenant)
        )

      with_disabled = Subscription.trigger_tenants()
      Subscription.disable!(disabled, opts(tenant))

      assert with_disabled == Subscription.trigger_tenants(),
             "a disabled or draft subscription neither adds nor removes a tenant"
    end
  end

  defp create_role(tenant, name) do
    AshEnterprise.Security.Role
    |> Ash.Changeset.for_create(:create, %{name: name},
      actor: SystemActor.seed(),
      tenant: tenant
    )
    |> Ash.create!()
  end

  defp highest_sequence(tenant) do
    AshEnterprise.Audit.EventLog
    |> Ash.Query.for_read(:read)
    |> Ash.Query.sort(sequence: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read!(actor: SystemActor.process(), tenant: tenant)
    |> case do
      [%{sequence: sequence}] -> sequence
      [] -> 0
    end
  end

  defp cursor(tenant) do
    Cursor
    |> Ash.Query.for_read(:read)
    |> Ash.read_one!(opts(tenant))
  end
end
