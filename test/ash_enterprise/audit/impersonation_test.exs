defmodule AshEnterprise.Audit.ImpersonationTest do
  @moduledoc """
  Two facts that were both silently missing.

  **Nothing filled the provenance columns.** `AshEnterprise.Platform.SystemAttributes`
  has always declared Dataverse's `created_by_id`, `modified_by_id`,
  `created_on_behalf_by_id` and `modified_on_behalf_by_id` on every platform
  resource, and no code anywhere wrote to any of them. A `grep` for
  `created_by_id` outside the transformer that declares it returned nothing.
  Every row carried four nulls describing who was responsible for it.

  **Impersonation had no representation at all.** Which is the operation an
  auditor asks about first, because it is the one where "who did this" has two
  answers.
  """

  use AshEnterprise.DataCase, async: false

  require Ash.Query

  alias AshEnterprise.Accounts.BusinessUnit
  alias AshEnterprise.Audit.EventLog
  alias AshEnterprise.Platform.Correlation
  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.Security.Impersonation

  setup do
    Correlation.start_new()
    org = Ash.UUID.generate()

    %{
      org: org,
      customer: %{id: Ash.UUID.generate(), __metadata__: %{}},
      operator: %{id: Ash.UUID.generate(), __metadata__: %{}}
    }
  end

  defp create_bu(name, org, actor) do
    BusinessUnit
    |> Ash.Changeset.for_create(:create, %{name: name},
      authorize?: false,
      tenant: org,
      actor: actor
    )
    |> Ash.create!()
  end

  defp events_for(record, org) do
    EventLog
    |> Ash.Query.filter(record_id == ^record.id)
    |> Ash.read!(authorize?: false, tenant: org)
  end

  describe "provenance" do
    test "a create records who made it", ctx do
      bu = create_bu("Root", ctx.org, ctx.customer)

      assert bu.created_by_id == ctx.customer.id
      assert is_nil(bu.created_on_behalf_by_id)
    end

    test "an update records who changed it, without losing who made it", ctx do
      other = %{id: Ash.UUID.generate(), __metadata__: %{}}

      bu = create_bu("Root", ctx.org, ctx.customer)

      updated =
        bu
        |> Ash.Changeset.for_update(:update, %{name: "Renamed"},
          authorize?: false,
          tenant: ctx.org,
          actor: other
        )
        |> Ash.update!()

      assert updated.created_by_id == ctx.customer.id
      assert updated.modified_by_id == other.id
    end

    test "a system actor leaves the columns null rather than guessing", ctx do
      bu = create_bu("Root", ctx.org, SystemActor.seed())

      # Not an oversight: a system actor is a compile-time constant with no id,
      # so its attribution lives in the audit event's `system_actor` metadata,
      # where it can actually be represented.
      assert is_nil(bu.created_by_id)

      [event] = events_for(bu, ctx.org)
      assert event.metadata["system_actor"] == "seed"
    end
  end

  describe "acting on someone else's behalf" do
    test "the record names both the customer and the operator", ctx do
      actor = Impersonation.acting_as(ctx.customer, ctx.operator)

      bu = create_bu("Root", ctx.org, actor)

      # The record belongs to the customer; the second column is what tells an
      # auditor a support engineer was at the keyboard.
      assert bu.created_by_id == ctx.customer.id
      assert bu.created_on_behalf_by_id == ctx.operator.id
    end

    test "every audit event during the session names the operator", ctx do
      actor = Impersonation.acting_as(ctx.customer, ctx.operator)

      bu = create_bu("Root", ctx.org, actor)

      [event] = events_for(bu, ctx.org)

      assert event.metadata["impersonator_id"] == ctx.operator.id

      # The customer's side of it is on the record rather than on the event here,
      # because `persist_actor_primary_key` needs a real `User` row to point a
      # foreign key at and these fixtures use a bare map. Both halves are present
      # in the trail either way, which is the property being tested.
      assert bu.created_by_id == ctx.customer.id
    end

    test "the key is absent, not null, when nobody is impersonating", ctx do
      bu = create_bu("Root", ctx.org, ctx.customer)

      [event] = events_for(bu, ctx.org)

      # So that `metadata ? 'impersonator_id'` is the query for "every support
      # access this month" without also matching ordinary activity.
      refute Map.has_key?(event.metadata, "impersonator_id")
    end

    test "impersonation adds attribution, never reach", ctx do
      actor = Impersonation.acting_as(ctx.customer, ctx.operator)

      # The actor is still the customer as far as authorization is concerned.
      # If this ever stopped being true, impersonation would be a
      # privilege-escalation path rather than a support tool.
      assert actor.id == ctx.customer.id
      assert Impersonation.impersonator_id(actor) == ctx.operator.id
      assert Impersonation.impersonating?(actor)
      refute Impersonation.impersonating?(ctx.customer)
    end
  end
end
