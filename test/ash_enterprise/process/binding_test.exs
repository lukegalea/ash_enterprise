defmodule AshEnterprise.Process.BindingTest do
  @moduledoc """
  Platform baselines and per-tenant divergence.

  The property worth the most care is the negative one: **absence of a binding is what "follow
  the baseline" means.** Any design where the default is a row is one where provisioning a
  tenant means backfilling a row per workflow forever, and where a tenant that was never
  customized cannot be told apart from one that was and then reverted.
  """

  use AshEnterprise.DataCase, async: false

  require Ash.Query

  alias AshEnterprise.Bpmn.Definition
  alias AshEnterprise.Platform.{Seeder, SystemActor}
  alias AshEnterprise.Process.{Binding, Resolver}

  @xml """
  <?xml version="1.0" encoding="UTF-8"?>
  <bpmn2:definitions xmlns:bpmn2="http://www.omg.org/spec/BPMN/20100524/MODEL"
                     xmlns:ash="https://github.com/lukegalea/ash_bpmn/ns">
    <bpmn2:process id="P" isExecutable="true">
      <bpmn2:startEvent id="S"><bpmn2:outgoing>F</bpmn2:outgoing></bpmn2:startEvent>
      <bpmn2:endEvent id="E"><bpmn2:incoming>F</bpmn2:incoming></bpmn2:endEvent>
      <bpmn2:sequenceFlow id="F" sourceRef="S" targetRef="E"/>
    </bpmn2:process>
  </bpmn2:definitions>
  """

  setup do
    platform = Seeder.seed_platform_organization()

    %{organization: organization} =
      Seeder.seed_tenant(
        unique_name: "bind-#{System.unique_integer([:positive])}",
        email: "bind-#{System.unique_integer([:positive])}@example.com"
      )

    on_exit(&Resolver.forget_platform_tenant/0)

    %{platform: platform.id, tenant: organization.id}
  end

  defp opts(tenant), do: [actor: SystemActor.process(), tenant: tenant]

  defp publish!(key, tenant) do
    definition = Definition.create!(%{key: key, name: key, xml: @xml}, opts(tenant))

    AshEnterprise.Repo.query!(
      "UPDATE bpmn_definitions SET status = 'published' WHERE id = $1",
      [Ecto.UUID.dump!(definition.id)]
    )

    Definition
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^definition.id)
    |> Ash.read_one!(opts(tenant))
  end

  describe "the platform organization" do
    test "is seeded idempotently and is not a customer", %{platform: platform} do
      again = Seeder.seed_platform_organization()
      assert again.id == platform

      # It exists to own baselines, not to be signed into: `seed_tenant/1` provisions an
      # organization *plus* a root business unit, an Administrator role and an admin user, and
      # `seed_platform_organization/0` deliberately provisions none of those.
      #
      # Checked via business units and roles rather than users, because `Accounts.User` is
      # `tenant?: false` -- a user is not scoped to an organization, so "users in this tenant"
      # is not a question that can be asked, and asking it returns every user in the system.
      units =
        AshEnterprise.Accounts.BusinessUnit
        |> Ash.Query.for_read(:read)
        |> Ash.read!(actor: SystemActor.process(), tenant: platform)

      roles =
        AshEnterprise.Security.Role
        |> Ash.Query.for_read(:read)
        |> Ash.read!(actor: SystemActor.process(), tenant: platform)

      assert units == [], "the platform organization must have no business units"
      assert roles == [], "the platform organization must have no roles: nothing signs into it"
    end
  end

  describe "resolution" do
    test "with no binding, a tenant runs the platform baseline", %{
      platform: platform,
      tenant: tenant
    } do
      baseline = publish!("shared_process", platform)

      assert {:ok, resolved} = Resolver.resolve(:process, "shared_process", tenant)
      assert resolved.id == baseline.id
    end

    test "a newly published baseline is live immediately, with nothing written per tenant", %{
      platform: platform,
      tenant: tenant
    } do
      _v1 = publish!("moving_process", platform)
      v2 = publish!("moving_process", platform)

      assert {:ok, resolved} = Resolver.resolve(:process, "moving_process", tenant)

      assert resolved.id == v2.id
      assert resolved.version == 2

      assert Binding |> Ash.Query.for_read(:read) |> Ash.read!(opts(tenant)) == [],
             "following the baseline must not require a row"
    end

    test "a tenant binding wins over the baseline", %{platform: platform, tenant: tenant} do
      baseline = publish!("forkable", platform)
      own = publish!("forkable", tenant)

      Binding.bind!(
        %{
          kind: :process,
          key: "forkable",
          source: :tenant,
          target_id: own.id,
          bound_version: own.version,
          forked_from_version: baseline.version
        },
        opts(tenant)
      )

      assert {:ok, resolved} = Resolver.resolve(:process, "forkable", tenant)
      assert resolved.id == own.id
    end

    # A tenant may deliberately hold still while the platform moves on.
    test "a platform binding pins a version rather than tracking the latest", %{
      platform: platform,
      tenant: tenant
    } do
      v1 = publish!("pinnable", platform)
      _v2 = publish!("pinnable", platform)

      Binding.bind!(
        %{kind: :process, key: "pinnable", source: :platform, target_id: v1.id, bound_version: 1},
        opts(tenant)
      )

      assert {:ok, resolved} = Resolver.resolve(:process, "pinnable", tenant)
      assert resolved.version == 1
    end

    test "reverting a customization is deleting a row", %{platform: platform, tenant: tenant} do
      baseline = publish!("revertible", platform)
      own = publish!("revertible", tenant)

      binding =
        Binding.bind!(
          %{
            kind: :process,
            key: "revertible",
            source: :tenant,
            target_id: own.id,
            bound_version: own.version,
            forked_from_version: baseline.version
          },
          opts(tenant)
        )

      Binding.unbind!(binding, opts(tenant))

      assert {:ok, resolved} = Resolver.resolve(:process, "revertible", tenant)
      assert resolved.id == baseline.id
    end

    test "a key with no baseline anywhere is an error, not a nil", %{tenant: tenant} do
      assert {:error, {:no_published_baseline, :process, "nothing_here"}} =
               Resolver.resolve(:process, "nothing_here", tenant)
    end
  end

  describe "drift" do
    test "reports how far behind a fork is, without diffing or merging", %{
      platform: platform,
      tenant: tenant
    } do
      v1 = publish!("drifting", platform)
      _v2 = publish!("drifting", platform)
      _v3 = publish!("drifting", platform)
      own = publish!("drifting", tenant)

      Binding.bind!(
        %{
          kind: :process,
          key: "drifting",
          source: :tenant,
          target_id: own.id,
          bound_version: own.version,
          forked_from_version: v1.version
        },
        opts(tenant)
      )

      assert [report] = Resolver.drift(tenant)

      assert report.key == "drifting"
      assert report.forked_from_version == 1
      assert report.platform_version == 3
      assert report.behind_by == 2
    end

    test "a tenant that has not diverged reports nothing", %{tenant: tenant} do
      assert Resolver.drift(tenant) == []
    end
  end
end
