defmodule AshEnterprise.Platform.OptimisticLockTest do
  @moduledoc """
  ADR 0059: `version_number` is an optimistic lock on every platform resource's
  update actions. Exercised on `BusinessUnit`, an audited Postgres resource, so
  the lock runs through the AshEvents wrapper's non-atomic update path -- the
  path where a plain increment would let two writers both write N+1.
  """

  use AshEnterprise.DataCase, async: false

  alias AshEnterprise.Accounts.BusinessUnit

  setup do
    org = Ash.UUID.generate()

    unit =
      BusinessUnit
      |> Ash.Changeset.for_create(:create, %{name: "Front desk"}, authorize?: false, tenant: org)
      |> Ash.create!()

    %{org: org, unit: unit}
  end

  defp rename(unit, name, org) do
    unit
    |> Ash.Changeset.for_update(:update, %{name: name}, authorize?: false, tenant: org)
    |> Ash.update()
  end

  test "a created row is version 1, and each write counts: two writes give version 3", ctx do
    assert ctx.unit.version_number == 1

    {:ok, once} = rename(ctx.unit, "Reception", ctx.org)
    {:ok, twice} = rename(once, "Front of house", ctx.org)

    assert once.version_number == 2
    assert twice.version_number == 3

    assert Ash.get!(BusinessUnit, ctx.unit.id, authorize?: false, tenant: ctx.org).version_number ==
             3
  end

  test "a write made from a stale copy is refused with StaleRecord, not applied", ctx do
    {:ok, _first} = rename(ctx.unit, "Reception", ctx.org)

    assert {:error, %Ash.Error.Invalid{errors: errors}} =
             rename(ctx.unit, "Lost update", ctx.org)

    assert Enum.any?(errors, &match?(%Ash.Error.Changes.StaleRecord{}, &1))

    stored = Ash.get!(BusinessUnit, ctx.unit.id, authorize?: false, tenant: ctx.org)
    assert stored.name == "Reception"
    assert stored.version_number == 2
  end

  test "two concurrent writers on one version: one wins, the other gets StaleRecord", ctx do
    parent = self()

    results =
      ["Writer A", "Writer B"]
      |> Task.async_stream(
        fn name ->
          Ecto.Adapters.SQL.Sandbox.allow(AshEnterprise.Repo, parent, self())
          rename(ctx.unit, name, ctx.org)
        end,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, result} -> result end)

    {wins, losses} = Enum.split_with(results, &match?({:ok, _}, &1))

    assert [{:ok, winner}] = wins
    assert winner.version_number == 2

    assert [{:error, %Ash.Error.Invalid{errors: errors}}] = losses
    assert Enum.any?(errors, &match?(%Ash.Error.Changes.StaleRecord{}, &1))

    stored = Ash.get!(BusinessUnit, ctx.unit.id, authorize?: false, tenant: ctx.org)
    assert stored.name == winner.name
    assert stored.version_number == 2
  end

  test "every platform resource with update actions carries the lock, except declared exemptions" do
    resources =
      for domain <- Application.fetch_env!(:ash_enterprise, :ash_domains),
          resource <- Ash.Domain.Info.resources(domain),
          AshEnterprise.Platform.SystemAttributes in Spark.extensions(resource),
          do: resource

    unlocked =
      for resource <- resources,
          not Spark.Dsl.Extension.get_opt(resource, [:platform], :optimistic_lock?, true),
          do: resource

    assert unlocked == [AshEnterprise.Legacy.User]

    for resource <- resources -- unlocked,
        %{type: :update} = action <- Ash.Resource.Info.actions(resource) do
      locked? =
        resource
        |> Ash.Resource.Info.changes()
        |> Enum.any?(fn change ->
          match?({Ash.Resource.Change.OptimisticLock, _}, change.change) and
            :update in change.on
        end)

      assert locked?, "#{inspect(resource)}.#{action.name} is not optimistically locked"
    end
  end
end
