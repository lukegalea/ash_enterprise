defmodule AshEnterprise.Audit.EveryWriteTest do
  @moduledoc """
  The audit log's coverage claim, asserted rather than inferred.

  The claim is that every create, update and destroy on a platform resource
  writes an event, because the base resource adds the audit extension, so a new
  table cannot quietly have no history. Two halves prove it: one resource that
  wires nothing for auditing records all three kinds of write, and no platform
  resource is unaudited unless its own declaration says `audit?: false`.

  A role assignment is the write an auditor asks about first, so it gets its
  own case: the event names who granted it, and the record names who received
  it, under the correlation id of the request.
  """

  use AshEnterprise.DataCase, async: false

  require Ash.Query

  alias AshEnterprise.Accounts.BusinessUnit
  alias AshEnterprise.Accounts.Team
  alias AshEnterprise.Accounts.User
  alias AshEnterprise.Audit.EventLog
  alias AshEnterprise.Audit.EventSource
  alias AshEnterprise.Platform.Correlation
  alias AshEnterprise.Platform.SystemAttributes
  alias AshEnterprise.Security.Role
  alias AshEnterprise.Security.UserRole

  setup do
    Correlation.start_new()
    org = Ash.UUID.generate()

    unit =
      BusinessUnit
      |> Ash.Changeset.for_create(:create, %{name: "Root"}, authorize?: false, tenant: org)
      |> Ash.create!()

    %{org: org, unit: unit}
  end

  describe "every write is recorded" do
    test "a create, an update and a destroy each write one event, on a resource that wires nothing for it",
         ctx do
      team =
        Team
        |> Ash.Changeset.for_create(
          :create,
          %{name: "Desk", owning_business_unit_id: ctx.unit.id},
          authorize?: false,
          tenant: ctx.org
        )
        |> Ash.create!()

      team =
        team
        |> Ash.Changeset.for_update(:update, %{name: "Front desk"},
          authorize?: false,
          tenant: ctx.org
        )
        |> Ash.update!()

      team
      |> Ash.Changeset.for_destroy(:destroy, %{}, authorize?: false, tenant: ctx.org)
      |> Ash.destroy!()

      assert team |> events_for(ctx.org) |> Enum.map(& &1.action_type) ==
               [:create, :update, :destroy]
    end

    test "a platform resource writes no events only where its declaration says audit?: false" do
      silent =
        for domain <- Application.fetch_env!(:ash_enterprise, :ash_domains),
            resource <- Ash.Domain.Info.resources(domain),
            SystemAttributes in Ash.Resource.Info.extensions(resource),
            not EventSource.audited?(resource),
            not declares_opt_out?(resource) do
          resource
        end

      assert silent == [],
             "these platform resources write no audit events and do not say so: " <>
               inspect(silent)
    end
  end

  describe "role assignments are attributable" do
    test "assigning a role records the grantor, the grantee and the request's correlation id",
         ctx do
      grantor = user!("grantor", ctx.unit)
      grantee = user!("grantee", ctx.unit)

      role =
        Role
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Reviewer #{System.unique_integer([:positive])}",
            owning_business_unit_id: ctx.unit.id
          },
          authorize?: false,
          tenant: ctx.org
        )
        |> Ash.create!()

      assignment =
        UserRole
        |> Ash.Changeset.for_create(
          :assign,
          %{user_id: grantee.id, role_id: role.id, scoping_business_unit_id: ctx.unit.id},
          actor: grantor,
          authorize?: false,
          tenant: ctx.org
        )
        |> Ash.create!()

      assert [event] = events_for(assignment, ctx.org)

      assert event.action_type == :create
      assert event.user_id == grantor.id
      assert event.metadata["correlation_id"] == Correlation.id()
      assert assignment.user_id == grantee.id
      assert assignment.created_by_id == grantor.id
    end
  end

  defp events_for(record, org) do
    EventLog
    |> Ash.Query.filter(record_id == ^record.id)
    |> Ash.Query.sort(sequence: :asc)
    |> Ash.read!(authorize?: false, tenant: org)
  end

  defp user!(name, unit) do
    User
    |> Ash.Changeset.for_create(
      :register_with_password,
      %{
        email: "#{name}-#{System.unique_integer([:positive])}@example.com",
        password: "password1234",
        password_confirmation: "password1234"
      },
      authorize?: false
    )
    |> Ash.create!()
    |> Ash.Changeset.for_update(:assign_to_business_unit, %{owning_business_unit_id: unit.id},
      authorize?: false
    )
    |> Ash.update!()
  end

  # Opting out is local and greppable by design (see the base resource's
  # moduledoc), so the declaration is where to look for it.
  defp declares_opt_out?(resource) do
    source = resource.module_info(:compile)[:source]
    is_list(source) and source |> List.to_string() |> File.read!() =~ "audit?: false"
  end
end
