defmodule AshEnterprise.Bpmn.PacksTest do
  @moduledoc """
  The pack installer (`AshEnterprise.Bpmn.Packs`, `Subscription.install_pack/2`,
  `mix ash_enterprise.packs.install`): a pack under `priv/packs/` installs into one tenant
  as drafts, on the installing person's grants, and cannot make itself live.

  Refusals first: a name that is not a pack, a manifest that would run a recipe as the
  causing person or carry a standing grant or set anything else, a caller that is not a
  person, and a person who may not create definitions and subscriptions. Then what an
  install leaves: drafts only, nothing published, enabled or granted, nothing in any other
  tenant, and nothing more on a second run.
  SYNTHETIC data only.
  """

  use AshEnterprise.DataCase, async: false

  import AshEnterprise.Test.AssistantFixtures, only: [tenant!: 0]

  require Ash.Query

  alias AshEnterprise.Audit.EventLog
  alias AshEnterprise.Bpmn.{Definition, Packs, Subscription}
  alias AshEnterprise.Platform.{Seeder, SystemActor}
  alias AshEnterprise.Security.{ActorContext, AgentStartGrant}
  alias AshEnterprise.Test.DailyFixtures

  @pack "soc2_cc6_3"
  @process "access.review_role_change"
  @recipe "soc2.cc6_3.role_assigned"

  defp install(who, tenant), do: Subscription.install_pack(@pack, actor: who, tenant: tenant)

  defp rows(resource, tenant, key) do
    resource
    |> Ash.Query.filter(key == ^key)
    |> Ash.read!(authorize?: false, tenant: tenant)
  end

  defp events(tenant, resource) do
    EventLog
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(resource == ^resource)
    |> Ash.read!(actor: SystemActor.process(), tenant: tenant)
  end

  # A pack directory of our own making, to show what a manifest may not say.
  defp pack_dir!(name, recipe, file \\ "review.bpmn") do
    root = Path.join(System.tmp_dir!(), "packs-#{System.unique_integer([:positive])}")
    dir = Path.join(root, name)
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(root) end)

    File.write!(
      Path.join(dir, "pack.json"),
      Jason.encode!(%{
        "name" => name,
        "processes" => [%{"key" => "test.review", "file" => file}],
        "recipes" => [
          Map.merge(%{"key" => "test.recipe", "process_key" => "test.review"}, recipe)
        ]
      })
    )

    File.write!(Path.join(dir, "review.bpmn"), "<definitions/>")
    root
  end

  defp shell_output(acc \\ []) do
    receive do
      {:mix_shell, :info, [line]} -> shell_output([line | acc])
    after
      0 -> acc |> Enum.reverse() |> Enum.join("\n")
    end
  end

  describe "refused" do
    test "a name that is not a pack, and a path, are refused before anything is read" do
      admin = tenant!()

      for name <- ["no_such_pack", "../packs/soc2_cc6_3", "soc2_cc6_3/../soc2_cc6_3", ""] do
        assert {:error, _} =
                 Subscription.install_pack(name, actor: admin.actor, tenant: admin.tenant)
      end

      assert {:error, "no pack named " <> _} = Packs.load("../../config")
      assert rows(Subscription, admin.tenant, @recipe) == []
    end

    test "a recipe that would run as the causing person is refused" do
      root = pack_dir!("causing", %{"authority" => "causing_person"})
      assert {:error, message} = Packs.load("causing", root)
      assert message =~ "cannot run a recipe as the causing person"
    end

    test "a recipe that would arrive with a standing grant is refused" do
      root = pack_dir!("granted", %{"authority" => "standing_grant"})
      assert {:error, message} = Packs.load("granted", root)
      assert message =~ "cannot carry a standing grant"
    end

    test "an unknown authority, a field a pack does not set, and a process outside the pack are refused" do
      assert {:error, "recipe test.recipe: unknown authority" <> _} =
               Packs.load("odd", pack_dir!("odd", %{"authority" => "everyone"}))

      for field <- ["enabled", "status", "accountable_person_id", "max_starts_per_event"] do
        assert {:error, message} =
                 Packs.load("live", pack_dir!("live", %{field => true}))

        assert message =~ "a pack does not set #{field}"
      end

      assert {:error, message} = Packs.load("escape", pack_dir!("escape", %{}, "../review.bpmn"))
      assert message =~ "must be a .bpmn file in the pack's directory"
    end

    test "only a person installs a pack: a system actor is refused" do
      admin = tenant!()

      for system <- [SystemActor.process(), SystemActor.seed(), SystemActor.oban()] do
        assert {:error, %Ash.Error.Forbidden{}} = install(system, admin.tenant)
      end

      assert rows(Definition, admin.tenant, @process) == []
      assert rows(Subscription, admin.tenant, @recipe) == []
    end

    test "a person who may not create definitions and subscriptions installs nothing" do
      admin = tenant!()

      reader =
        DailyFixtures.member!(admin, "Recipe reader", [
          {Subscription, :read, :global},
          {Definition, :read, :global}
        ])

      assert {:error, %Ash.Error.Forbidden{}} = install(reader.actor, admin.tenant)

      # One transaction: a refusal part-way leaves nothing behind.
      assert rows(Definition, admin.tenant, @process) == []
      assert rows(Subscription, admin.tenant, @recipe) == []
    end
  end

  describe "installed" do
    test "as drafts only: nothing published, enabled for publishing, or granted" do
      admin = tenant!()

      assert {:ok,
              %{pack: @pack, processes: %{@process => :created}, recipes: %{@recipe => :created}}} =
               install(admin.actor, admin.tenant)

      assert [%{status: :draft, errors: errors}] = rows(Definition, admin.tenant, @process)
      assert errors in [nil, []]

      assert [recipe] = rows(Subscription, admin.tenant, @recipe)
      assert recipe.status == :draft
      assert recipe.authority == :human_tasks_only
      assert recipe.accountable_person_id == nil
      assert recipe.match_resource == "AshEnterprise.Security.UserRole"
      assert recipe.match_action_type == :create

      assert {:ok, []} =
               Definition.latest_published(@process, authorize?: false, tenant: admin.tenant)

      assert {:ok, []} =
               Subscription.latest_published(@recipe, authorize?: false, tenant: admin.tenant)

      assert [] ==
               AgentStartGrant
               |> Ash.Query.filter(contains(agent_key, "recipe:"))
               |> Ash.read!(authorize?: false, tenant: admin.tenant)

      refute admin.tenant in Subscription.trigger_tenants()
    end

    test "installing again creates nothing" do
      admin = tenant!()
      assert {:ok, _} = install(admin.actor, admin.tenant)
      before = {events(admin.tenant, Definition), events(admin.tenant, Subscription)}

      assert {:ok, %{processes: %{@process => :existing}, recipes: %{@recipe => :existing}}} =
               install(admin.actor, admin.tenant)

      assert [_one] = rows(Definition, admin.tenant, @process)
      assert [_one] = rows(Subscription, admin.tenant, @recipe)
      assert {events(admin.tenant, Definition), events(admin.tenant, Subscription)} == before
    end

    test "into one tenant: another tenant has none of it" do
      admin = tenant!()
      other = tenant!()

      assert {:ok, _} = install(admin.actor, admin.tenant)

      assert rows(Definition, other.tenant, @process) == []
      assert rows(Subscription, other.tenant, @recipe) == []

      # A person of another tenant, acting in this one, holds nothing here and installs
      # nothing (their context is built for the tenant they act in, as the mix task builds it).
      outsider =
        ActorContext.attach(other.user, ActorContext.build(other.user, tenant: admin.tenant))

      assert {:error, %Ash.Error.Forbidden{}} = install(outsider, admin.tenant)
    end

    test "the mix task installs as the named person, and a re-run installs nothing more" do
      admin = tenant!()
      Mix.shell(Mix.Shell.Process)
      on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

      args = [
        @pack,
        "--tenant",
        admin.organization.unique_name,
        "--as",
        to_string(admin.user.email)
      ]

      Mix.Tasks.AshEnterprise.Packs.Install.run(args)
      assert shell_output() =~ "recipe #{@recipe}: created"

      Mix.Tasks.AshEnterprise.Packs.Install.run(args)
      assert shell_output() =~ "recipe #{@recipe}: existing"

      assert [%{status: :draft, created_by_id: created_by}] =
               rows(Subscription, admin.tenant, @recipe)

      assert created_by == admin.user.id
    end

    test "the mix task takes a sixteen-character unique name as a name, not an id" do
      # Ecto.UUID.cast/1 reads any 16-byte binary as a raw UUID.
      digits =
        System.unique_integer([:positive]) |> Integer.to_string() |> String.pad_leading(10, "0")

      unique_name = "packs-" <> String.slice(digits, -10, 10)
      assert byte_size(unique_name) == 16

      seeded =
        Seeder.seed_tenant(
          name: "Packs",
          unique_name: unique_name,
          email: "packs-#{System.unique_integer([:positive])}@example.test"
        )

      Mix.shell(Mix.Shell.Process)
      on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

      Mix.Tasks.AshEnterprise.Packs.Install.run([
        @pack,
        "--tenant",
        unique_name,
        "--as",
        seeded.user.email
      ])

      assert shell_output() =~ "recipe #{@recipe}: created"
      assert [_draft] = rows(Subscription, seeded.organization.id, @recipe)
    end

    test "the mix task refuses a person who is not a member of the tenant" do
      admin = tenant!()
      other = tenant!()

      assert_raise Mix.Error, ~r/is not a member/, fn ->
        Mix.Tasks.AshEnterprise.Packs.Install.run([
          @pack,
          "--tenant",
          admin.tenant,
          "--as",
          to_string(other.user.email)
        ])
      end

      assert rows(Subscription, admin.tenant, @recipe) == []
    end
  end
end
