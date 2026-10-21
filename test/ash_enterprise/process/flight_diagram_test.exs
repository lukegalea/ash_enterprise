defmodule AshEnterprise.Process.FlightDiagramTest do
  @moduledoc """
  The flight-view adapter (`AshEnterprise.Process.FlightDiagram`) at the data
  level, and the grant that lets someone asked to decide a step see its run
  (`AshEnterprise.Security.Checks.TaskInstance`).

    * MDM stewardship: every `mdm.steward_review` run under way, each a marker
      on "Steward decision" for a Data Steward (a role candidate with no grant
      on instances); a member who is no candidate sees no marker and no run.
    * The grant reads only: the run and its tokens, never another run, and
      no write.
    * Node labels are the definition's step names; a marker names the run's
      subject only as far as the reader may read it.

  The live LiveView behaviour is in `AshEnterpriseWeb.FlightLiveTest`.
  SYNTHETIC data only.
  """

  use AshEnterprise.DataCase, async: false

  import AshEnterprise.Mdm.TestSupport

  import AshEnterprise.Test.DailyFixtures,
    only: [tenant!: 0, member!: 3, actor: 1, platform_brief_process!: 0]

  require Ash.Query

  alias AshEnterprise.Accounts.User
  alias AshEnterprise.Bpmn.{Definition, Instance, Token}
  alias AshEnterprise.Platform.{Seeder, SystemActor}
  alias AshEnterprise.Process.{FlightDiagram, Resolver}
  alias AshEnterprise.Security

  @xml File.read!("priv/bpmn/mdm_steward_review.bpmn")

  setup do
    Resolver.forget_platform_tenant()
    on_exit(&Resolver.forget_platform_tenant/0)

    platform = Seeder.seed_platform_organization().id

    %{key: "mdm.steward_review", name: "MDM steward review", xml: @xml}
    |> Definition.create!(actor: SystemActor.process(), tenant: platform)
    |> Definition.publish!(actor: SystemActor.process(), tenant: platform)

    admin = tenant!()
    org = admin.tenant

    # The steward exists before the tasks open: candidacy comes from the role.
    steward = data_steward!(admin)
    outsider = member!(admin, "No grants", [])

    runs =
      for name <- ["Bea Smith", "Cy Jones"] do
        {candidate, _staged, _golden} =
          staged_candidate!(org, admin.user, name, "#{String.downcase(name)}@x.io")

        start_review!(candidate, org)
      end

    %{admin: admin, org: org, steward: steward, outsider: outsider, runs: runs}
  end

  test "a Data Steward sees every review under way on the steward-decision step", ctx do
    steward = actor(ctx.steward.user)

    assert {:ok, %{source: source, markers: markers}} =
             FlightDiagram.process(%{actor: steward, tenant: ctx.org}, "mdm.steward_review")

    # The definition's own drawing, its node labels the step names.
    assert source =~ "flowchart TD"
    assert source =~ ~s(StewardDecision["Steward decision"])

    assert length(markers) == 2
    assert Enum.all?(markers, &(&1.node_id == "StewardDecision" and &1.status == "waiting"))
    assert Enum.all?(markers, &String.starts_with?(&1.label, "Match"))

    assert Enum.sort(Enum.map(markers, &elem(&1.link, 1))) ==
             Enum.sort(Enum.map(ctx.runs, & &1.id))

    assert Enum.all?(markers, &(elem(&1.link, 0) == "flight"))
  end

  test "someone who is no candidate sees no review, and no run", ctx do
    outsider = actor(ctx.outsider.user)

    assert {:ok, %{markers: []}} =
             FlightDiagram.process(%{actor: outsider, tenant: ctx.org}, "mdm.steward_review")

    assert FlightDiagram.runs("mdm.steward_review", actor: outsider, tenant: ctx.org) == []

    [run | _] = ctx.runs
    assert FlightDiagram.instance_for(run.id, outsider, ctx.org) == nil

    assert {:error, :no_run} =
             FlightDiagram.diagram(%{
               actor: outsider,
               tenant: ctx.org,
               contexts: %{instance: run.id}
             })
  end

  test "one review's flight view: its token on the step, the marker opening its task", ctx do
    [run | _] = ctx.runs
    steward = actor(ctx.steward.user)

    assert {:ok, %{markers: [marker]}} =
             FlightDiagram.diagram(%{
               actor: steward,
               tenant: ctx.org,
               contexts: %{instance: run.id}
             })

    assert marker.node_id == "StewardDecision"
    assert marker.node_label == "Steward decision"
    assert marker.status == "waiting"
    assert {AshEnterprise.Bpmn.HumanTask, _task_id} = marker.link
  end

  test "the candidacy grant reads the run and its tokens, nothing else", ctx do
    steward = actor(ctx.steward.user)
    [run, other] = ctx.runs
    context = AshEnterprise.Security.ActorContext.for_actor(steward)

    assert Enum.sort(context.task_instance_ids) == Enum.sort([run.id, other.id])

    assert [_one] =
             Token
             |> Ash.Query.filter(instance_id == ^run.id and status == :waiting)
             |> Ash.read!(actor: steward, tenant: ctx.org)

    # Read only: the grant moves nothing.
    refute Ash.can?({run, :cancel}, steward, tenant: ctx.org)

    # A run with no step waiting on them — the administrator's morning brief,
    # whose approval waits on its owner — stays out of reach.
    platform_brief_process!()

    {:ok, _said} =
      AshEnterprise.Agents.MorningBrief.compose_today(actor: ctx.admin.actor, tenant: ctx.org)

    brief_run =
      Instance
      |> Ash.Query.filter(subject_type == "Elixir.AshEnterprise.Agents.MorningBrief")
      |> Ash.read_one!(tenant: ctx.org, authorize?: false)

    steward = actor(ctx.steward.user)
    refute Ash.can?({brief_run, :read}, steward, tenant: ctx.org)
    assert FlightDiagram.instance_for(brief_run.id, steward, ctx.org) == nil
  end

  # -- fixtures -------------------------------------------------------------------

  defp steward_definition!(org) do
    {:ok, definition} = Resolver.resolve(:process, "mdm.steward_review", org)
    definition
  end

  defp start_review!(candidate, org) do
    AshBpmn.start_instance!(AshEnterprise.Bpmn,
      definition: steward_definition!(org),
      subject: candidate,
      actor: SystemActor.process(),
      tenant: org
    )

    Instance
    |> Ash.Query.filter(subject_id == ^candidate.id)
    |> Ash.read_one!(tenant: org, authorize?: false)
  end

  # A member holding only the seeded Data Steward role.
  defp data_steward!(admin) do
    org = admin.tenant
    unit_id = admin.user.owning_business_unit_id

    user =
      User
      |> Ash.Changeset.for_create(
        :register_with_password,
        %{
          email: "steward-#{System.unique_integer([:positive])}@example.test",
          password: "password1234",
          password_confirmation: "password1234"
        },
        authorize?: false
      )
      |> Ash.create!()
      |> Ash.Changeset.for_update(:assign_to_business_unit, %{owning_business_unit_id: unit_id},
        authorize?: false
      )
      |> Ash.update!()

    role =
      Security.Role
      |> Ash.Query.filter(name == ^Seeder.data_steward_role())
      |> Ash.read_one!(actor: SystemActor.seed(), tenant: org)

    Security.UserRole
    |> Ash.Changeset.for_create(
      :assign,
      %{user_id: user.id, role_id: role.id, scoping_business_unit_id: unit_id},
      actor: SystemActor.seed(),
      tenant: org
    )
    |> Ash.create!()

    %{user: user, tenant: org}
  end
end
