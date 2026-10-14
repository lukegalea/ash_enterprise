defmodule AshEnterprise.Audit.TenantIsolationTest do
  @moduledoc """
  A customer can see their own audit trail, and provably not anyone else's.

  Neither half was true before. `audit_events` had no tenant column at all, and
  reading the log required a `:global` grant — which, on a resource with no owner
  and no business unit, was the *only* meaningful depth. So the only route a
  customer had to their own history was through someone holding a grant over
  every tenant's log, and there was no column that could have narrowed it.

  The fix deliberately reuses the mechanism that isolates everything else rather
  than inventing a policy check for the audit log: the log is attribute-multitenant
  on `organization_id`, so a tenant-scoped read is filtered by the data layer.
  Depth answers "how much of a tenant may you see"; tenancy answers "which
  tenant". Two questions, two mechanisms — and the second one is already tested
  to hold even when the first is wrong (`AshEnterprise.Security.ConformanceTest`).
  """

  use AshEnterprise.DataCase, async: false

  require Ash.Query

  alias AshEnterprise.Accounts.BusinessUnit
  alias AshEnterprise.Audit.EventLog
  alias AshEnterprise.Platform.Correlation
  alias AshEnterprise.Platform.SystemActor

  setup do
    Correlation.start_new()
    %{acme: Ash.UUID.generate(), globex: Ash.UUID.generate()}
  end

  defp create_bu(name, org) do
    BusinessUnit
    |> Ash.Changeset.for_create(:create, %{name: name},
      authorize?: false,
      tenant: org,
      actor: SystemActor.seed()
    )
    |> Ash.create!()
  end

  defp read(tenant) do
    EventLog
    |> Ash.Query.for_read(:read)
    |> Ash.read!(authorize?: false, tenant: tenant)
  end

  describe "reading the log" do
    test "a tenant sees its own events", ctx do
      bu = create_bu("Acme root", ctx.acme)

      assert [event] = read(ctx.acme)
      assert event.record_id == bu.id
      assert event.organization_id == ctx.acme
    end

    test "a tenant does not see another tenant's events", ctx do
      create_bu("Acme root", ctx.acme)
      create_bu("Globex root", ctx.globex)

      acme_records = read(ctx.acme) |> Enum.map(& &1.record_id)
      globex_records = read(ctx.globex) |> Enum.map(& &1.record_id)

      assert length(acme_records) == 1
      assert length(globex_records) == 1
      assert acme_records != globex_records
    end

    test "a read with no tenant still spans everything, for cross-tenant work", ctx do
      create_bu("Acme root", ctx.acme)
      create_bu("Globex root", ctx.globex)

      # `global? true`. This is what a system actor and an incident investigation
      # need, and it is why the tenant has to be set on ordinary requests rather
      # than merely available -- the same property
      # `AshEnterprise.Security.TenantResolutionTest` exists to protect.
      assert length(read(nil)) == 2
    end

    test "the tenant on the event is not a value any caller supplied", ctx do
      create_bu("Acme root", ctx.acme)

      [event] = read(ctx.acme)

      # It is derived twice, from two directions: the platform stamps it into
      # `ash_events_metadata` from the changeset's tenant, and the database
      # trigger lifts it back out into the column.
      assert event.metadata["organization_id"] == ctx.acme
      assert event.organization_id == ctx.acme
    end

    test "an ordinary actor cannot write to the log", ctx do
      # AshEvents does declare a `:create` action -- it has to, that is how
      # events get written -- so "the log offers only :read" was never quite the
      # claim. Two things are: the integrity columns are not among what that
      # action will accept, and the policy admits only the system actor and
      # holders of an explicit grant.
      accepted = Ash.Resource.Info.action(EventLog, :create).accept

      for column <- [:hash, :previous_hash, :sequence, :organization_id] do
        refute column in accepted,
               "#{column} is written by the database; a caller supplying it would defeat the point"
      end

      # `Ash.can?` rather than attempting the create: a create with no attributes
      # fails validation first and returns Invalid, which would have made this
      # pass for the wrong reason.
      refute Ash.can?({EventLog, :create}, nil, tenant: ctx.acme)

      # Reads are different on purpose, and it is worth being precise about it.
      # `RoleGrant` is a filter check, so an ungranted reader is not refused --
      # they are narrowed to nothing. A 403 would confirm that events exist,
      # which is the thing the grant is protecting.
      assert Ash.can?({EventLog, :read}, nil, tenant: ctx.acme)

      assert [] =
               EventLog
               |> Ash.Query.for_read(:read)
               |> Ash.read!(actor: nil, tenant: ctx.acme)
    end
  end

  describe "the export window" do
    test "returns one tenant's events in chain order", ctx do
      create_bu("First", ctx.acme)
      create_bu("Second", ctx.acme)
      create_bu("Elsewhere", ctx.globex)

      from = DateTime.add(DateTime.utc_now(), -1, :hour)
      to = DateTime.add(DateTime.utc_now(), 1, :hour)

      events =
        EventLog
        |> Ash.Query.for_read(:for_export, %{from: from, to: to})
        |> Ash.read!(authorize?: false, tenant: ctx.acme)

      assert length(events) == 2
      assert Enum.map(events, & &1.sequence) == Enum.sort(Enum.map(events, & &1.sequence))
      assert Enum.all?(events, &(&1.organization_id == ctx.acme))
    end

    test "a window that excludes everything returns nothing", ctx do
      create_bu("First", ctx.acme)

      from = DateTime.add(DateTime.utc_now(), -2, :hour)
      to = DateTime.add(DateTime.utc_now(), -1, :hour)

      assert [] =
               EventLog
               |> Ash.Query.for_read(:for_export, %{from: from, to: to})
               |> Ash.read!(authorize?: false, tenant: ctx.acme)
    end
  end
end
