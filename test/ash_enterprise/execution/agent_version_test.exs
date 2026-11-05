defmodule AshEnterprise.Execution.AgentVersionTest do
  @moduledoc """
  Agent versions (ADR 0056) on the platform base: the code sync, publishing under four
  eyes through a governed invocation (ADR 0055), what this application requires of a
  published version, pinning and drift, and copying a platform baseline into a tenant.
  """

  use AshEnterprise.DataCase, async: false

  import AshEnterprise.Test.AssistantFixtures, only: [tenant!: 0, colleague!: 2]
  import Ecto.Query, only: [from: 2]

  require Ash.Query

  alias AshAgent.AgentVersion.{Definition, DefinitionDrift}
  alias AshAgent.Invocation.{Executor, Ungoverned}
  alias AshEnterprise.Bpmn.HumanTask
  alias AshEnterprise.Execution
  alias AshEnterprise.Execution.{AgentVersion, Invocation}
  alias AshEnterprise.Platform.{Seeder, SystemActor}
  alias AshEnterprise.Process.Resolver
  alias AshEnterprise.Repo
  alias AshEnterprise.Security
  alias AshEnterprise.Test.Execution.{NoteReader, NoteTaker}

  @key "clinic.note_taker"

  setup do
    on_exit(fn -> Application.delete_env(:ash_enterprise, :note_taker_instructions) end)
    ctx = tenant!()
    %{ctx: ctx, approver: colleague!(ctx, admin?: true)}
  end

  defp opts(%{actor: actor, tenant: tenant}), do: [actor: actor, tenant: tenant]
  defp oban(tenant), do: [actor: SystemActor.oban(), tenant: tenant]

  defp change_prompt(text),
    do: Application.put_env(:ash_enterprise, :note_taker_instructions, text)

  defp register!(ctx, agent \\ NoteTaker),
    do: Execution.register_agent_from_code!(agent, opts(ctx))

  defp invocation(ctx, %{"invocation_id" => id}),
    do: Execution.get_invocation!(id, authorize?: false, tenant: ctx.tenant)

  defp decide!(row, approver, action \\ :approve) do
    task = Ash.load!(row, :approval_task, authorize?: false).approval_task

    HumanTask
    |> Ash.ActionInput.for_action(action, %{record_id: task.id},
      actor: approver.actor,
      tenant: approver.tenant
    )
    |> Ash.run_action()
  end

  # Asked for by `ctx`'s administrator, approved by a second one, applied and run as the
  # job runner runs it.
  defp published!(ctx, approver, version, extra \\ %{}) do
    asked = Execution.request_agent_publish!(version.id, extra, opts(ctx))
    row = invocation(ctx, asked)
    {:ok, _approved} = decide!(row, approver)
    %{status: :ready} = Execution.apply_invocation_decision!(row, oban(ctx.tenant))
    {:ok, :succeeded} = Executor.execute(Invocation, row.id, oban(ctx.tenant))
    Execution.get_agent_version!(version.id, opts(ctx))
  end

  defp written_against_earlier_tools(version) do
    toolset = Enum.map(version.toolset, &Map.put(&1, "target_digest", "earlier"))

    {1, _} =
      Repo.update_all(
        from(v in "exec_agent_versions", where: v.id == type(^version.id, Ecto.UUID)),
        set: [toolset: toolset]
      )

    Ash.get!(AgentVersion, version.id, authorize?: false, tenant: version.organization_id)
  end

  describe "the code sync" do
    test "the same code writes no new version; a changed prompt is the next one", %{ctx: ctx} do
      first = register!(ctx)
      assert %{key: @key, version: 1, status: :draft, source: :code} = first
      assert register!(ctx).id == first.id

      change_prompt("Record the note, and its date.")
      second = register!(ctx)

      assert second.version == 2
      assert second.content_hash != first.content_hash

      assert [1, 2] =
               Execution.list_agent_versions!(opts(ctx)) |> Enum.map(& &1.version) |> Enum.sort()
    end
  end

  describe "publishing" do
    test "waits for a second administrator, then runs as the requester", %{
      ctx: ctx,
      approver: approver
    } do
      draft = register!(ctx)
      asked = Execution.request_agent_publish!(draft.id, opts(ctx))

      assert %{"status" => "awaiting_approval", "approval_url" => url} = asked
      assert url =~ "/app/r/approvals/"
      assert Execution.get_agent_version!(draft.id, opts(ctx)).status == :draft

      row = invocation(ctx, asked)
      assert row.target == "AshEnterprise.Execution.AgentVersion.apply_publish"
      assert row.approval_mode == :four_eyes
      assert row.executing_principal.id == ctx.user.id

      # The requester is not one of the four eyes.
      assert {:error, _not_theirs} = decide!(row, ctx)

      assert {:ok, _} = decide!(row, approver)
      assert %{status: :ready} = Execution.apply_invocation_decision!(row, oban(ctx.tenant))
      assert {:ok, :succeeded} = Executor.execute(Invocation, row.id, oban(ctx.tenant))

      published = Execution.get_agent_version!(draft.id, opts(ctx))
      assert %{status: :published, requesterless: false} = published
      assert published.authority == %{type: :requester}
      assert Execution.latest_published_agent_version!(@key, opts(ctx)).id == draft.id
    end

    test "an automation principal and requesterless runs are what the approver approved", %{
      ctx: ctx,
      approver: approver
    } do
      choice = %{
        authority: %{"type" => "automation", "name" => "evidence_admitter"},
        requesterless: true
      }

      published = published!(ctx, approver, register!(ctx), choice)

      assert published.authority == %{type: :automation, name: "evidence_admitter"}
      assert published.requesterless
    end

    test "is refused, opening no approval, when a toolset target declares no effects", %{
      ctx: ctx
    } do
      draft = register!(ctx, NoteReader)

      assert {:error, %Ash.Error.Invalid{} = error} =
               Execution.request_agent_publish(draft.id, opts(ctx))

      assert Exception.message(error) =~ "ClinicNote.read declares no effects"
      assert Execution.list_invocations!(authorize?: false, tenant: ctx.tenant) == []
    end

    test "is refused for a model profile outside the zone and an unknown principal", %{ctx: ctx} do
      outside =
        Execution.create_agent_draft!(
          %{
            key: "clinic.outside",
            instructions: "x",
            model_profile: "hosted",
            limits: %{
              max_steps: 1,
              max_tool_calls: 1,
              deadline: 60,
              token_budget: 1,
              max_repairs: 0
            }
          },
          opts(ctx)
        )

      assert {:error, error} = Execution.request_agent_publish(outside.id, opts(ctx))
      assert Exception.message(error) =~ "not the in-zone profile"

      assert {:error, error} =
               Execution.request_agent_publish(
                 register!(ctx).id,
                 %{authority: %{"type" => "automation", "name" => "night_shift"}},
                 opts(ctx)
               )

      assert Exception.message(error) =~ "is not an automation principal"
    end

    test "runs only as its invocation, even for an administrator", %{ctx: ctx} do
      draft = register!(ctx)

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               draft
               |> Ash.Changeset.for_update(:apply_publish, %{}, opts(ctx))
               |> Ash.update()

      assert [%Ungoverned{reason: :no_invocation}] =
               Enum.filter(errors, &match?(%Ungoverned{}, &1))

      assert Execution.get_agent_version!(draft.id, opts(ctx)).status == :draft
    end

    test "a draft revised while its approval waits is not published", %{
      ctx: ctx,
      approver: approver
    } do
      draft = register!(ctx)
      row = invocation(ctx, Execution.request_agent_publish!(draft.id, opts(ctx)))

      Execution.revise_agent_draft!(draft, %{instructions: "Something else."}, opts(ctx))

      {:ok, _} = decide!(row, approver)

      assert %{status: :stale, error_code: "subject_changed"} =
               Execution.apply_invocation_decision!(row, oban(ctx.tenant))

      assert Execution.get_agent_version!(draft.id, opts(ctx)).status == :draft
    end

    test "a new tenant's Administrator may draft, publish and retire agent versions" do
      seeded = Seeder.seed_tenant(unique_name: "agents-#{System.unique_integer([:positive])}")
      name = inspect(AgentVersion)

      granted =
        Security.RolePrivilege
        |> Ash.Query.filter(role_id == ^seeded.role.id and privilege.resource_name == ^name)
        |> Ash.Query.load(:privilege)
        |> Ash.read!(actor: SystemActor.seed(), tenant: seeded.organization.id)
        |> Enum.map(& &1.privilege.access_right)

      for verb <- [:read, :create, :write], do: assert(verb in granted)
    end
  end

  describe "pinning" do
    test "a run pinned to version 1 carries on after version 2 is published", %{
      ctx: ctx,
      approver: approver
    } do
      v1 = published!(ctx, approver, register!(ctx))
      change_prompt("Record the note, and its date.")
      v2 = published!(ctx, approver, register!(ctx))

      assert v2.version == 2
      assert Execution.latest_published_agent_version!(@key, opts(ctx)).id == v2.id

      pinned = Execution.get_agent_version!(v1.id, opts(ctx))
      assert {:ok, %{status: :published}} = Definition.check_pinned(pinned)
      assert pinned.instructions == v1.instructions
    end

    test "a pinned version whose tool changed since is definition drift", %{
      ctx: ctx,
      approver: approver
    } do
      pinned = published!(ctx, approver, register!(ctx)) |> written_against_earlier_tools()

      assert {:error, %DefinitionDrift{reason: :definition_drift, drifted: [drifted]}} =
               Definition.check_pinned(pinned)

      assert drifted["target"] == "AshEnterprise.Test.Execution.ClinicNote.record"
    end
  end

  describe "platform baselines" do
    test "a tenant forks the latest baseline into its own draft, once per content", %{ctx: ctx} do
      platform = Seeder.seed_platform_organization()

      baseline =
        Execution.register_agent_from_code!(NoteTaker,
          actor: SystemActor.seed(),
          tenant: platform.id
        )

      assert {:ok, %{id: id}} = Resolver.agent_baseline(@key)
      assert id == baseline.id

      fork = Execution.fork_agent_for_tenant!(@key, opts(ctx))

      assert %{version: 1, status: :draft, source: :code, organization_id: tenant} = fork
      assert tenant == ctx.tenant
      assert fork.baseline_id == baseline.id
      assert fork.content_hash == baseline.content_hash

      assert Execution.fork_agent_for_tenant!(@key, opts(ctx)).id == fork.id
    end
  end
end
