defmodule AshEnterprise.OwnBriefLowPrivilegeTest do
  @moduledoc """
  Composing one's own morning brief is self-service (ADR 0052): a member of
  the tenant holding no MorningBrief grant at all composes their own brief
  through the code interface and through the scheduled worker, and reads it
  back — and nothing more. Another member's brief stays out of reach, a
  deactivated account is refused, and the path does not reach across tenants.

  The ACP `compose brief` path is in `AshEnterprise.AcpLowPrivilegeTest`.
  SYNTHETIC data only.
  """

  use AshEnterprise.DataCase, async: false

  import AshEnterprise.Test.DailyFixtures

  require Ash.Query

  alias AshEnterprise.Agents.{MorningBrief, MorningBriefWorker, Today}
  alias AshEnterprise.Bpmn.Instance
  alias AshEnterprise.Platform.LocalTime
  alias AshEnterprise.Process.Resolver

  setup do
    platform_brief_process!()
    on_exit(&Resolver.forget_platform_tenant/0)

    admin = tenant!()

    %{
      admin: admin,
      member: member!(admin, "No brief grants", []),
      colleague: member!(admin, "No brief grants either", [])
    }
  end

  test "a member with no MorningBrief grant composes their own brief", %{member: member} do
    opts = [actor: member.actor, tenant: member.tenant]

    assert Ash.can?({MorningBrief, :compose_today}, member.actor, tenant: member.tenant)

    assert {:ok, said} = MorningBrief.compose_today(opts)
    assert said =~ "Composing your morning brief"

    assert [brief] = briefs(member.tenant)
    assert brief.owner_id == member.user.id
    assert brief.brief_date == LocalTime.today()
    assert brief.status == :pending_approval
    assert instance_started?(brief, member.tenant)

    # They read it back as themselves, and a second compose reports it.
    assert {:ok, %MorningBrief{id: id}} = Today.latest_brief(opts)
    assert id == brief.id
    assert {:ok, again} = MorningBrief.compose_today(opts)
    assert again =~ "You already have a morning brief"
    assert [_one] = briefs(member.tenant)
  end

  test "the scheduled worker composes it as them", %{member: member} do
    assert :ok = MorningBriefWorker.perform(job(member))

    assert [brief] = briefs(member.tenant)
    assert brief.owner_id == member.user.id
    assert instance_started?(brief, member.tenant)
  end

  test "a member still cannot read another member's brief", ctx do
    {:ok, _} =
      MorningBrief.compose_today(actor: ctx.colleague.actor, tenant: ctx.colleague.tenant)

    [theirs] = briefs(ctx.member.tenant)
    opts = [actor: ctx.member.actor, tenant: ctx.member.tenant]

    assert Ash.read!(MorningBrief, opts) == []
    assert {:ok, nil} = Today.latest_brief(opts)
    refute Ash.can?({theirs, :read}, ctx.member.actor, tenant: ctx.member.tenant)

    assert nil == MorningBrief |> Ash.Query.filter(id == ^theirs.id) |> Ash.read_one!(opts)

    # Self-service opens and reads one's own rows; it decides nothing.
    refute Ash.can?({theirs, :approve}, ctx.member.actor, tenant: ctx.member.tenant)

    # Composing again is about the member's own day, never the colleague's.
    assert {:ok, said} = MorningBrief.compose_today(opts)
    assert said =~ "Composing your morning brief"
    assert ctx.member.user.id in Enum.map(briefs(ctx.member.tenant), & &1.owner_id)
  end

  test "the owner cannot be chosen: start_for_date takes no owner", %{
    member: member,
    colleague: colleague
  } do
    assert {:error, %Ash.Error.Invalid{}} =
             MorningBrief
             |> Ash.Changeset.for_create(
               :start_for_date,
               %{brief_date: LocalTime.today(), owner_id: colleague.user.id},
               actor: member.actor,
               tenant: member.tenant
             )
             |> Ash.create()

    assert briefs(member.tenant) == []
  end

  test "a deactivated account is refused, by the code interface and by the worker", %{
    member: member
  } do
    gone = deactivate!(member)

    refute Ash.can?({MorningBrief, :compose_today}, gone.actor, tenant: gone.tenant)

    assert {:error, %Ash.Error.Forbidden{}} =
             MorningBrief.compose_today(actor: gone.actor, tenant: gone.tenant)

    assert {:cancel, :user_inactive} = MorningBriefWorker.perform(job(gone))
    assert briefs(gone.tenant) == []
  end

  test "self-service does not reach across tenants", %{member: member} do
    elsewhere = tenant!()

    refute Ash.can?({MorningBrief, :compose_today}, member.actor, tenant: elsewhere.tenant)

    assert {:error, %Ash.Error.Forbidden{}} =
             MorningBrief.compose_today(actor: member.actor, tenant: elsewhere.tenant)

    assert briefs(elsewhere.tenant) == []
  end

  # -- helpers ------------------------------------------------------------------

  defp job(%{user: user, tenant: tenant}) do
    %Oban.Job{
      args: %{
        "user_id" => user.id,
        "organization_id" => tenant,
        "brief_date" => Date.to_iso8601(LocalTime.today())
      }
    }
  end

  defp briefs(tenant), do: Ash.read!(MorningBrief, authorize?: false, tenant: tenant)

  defp instance_started?(brief, tenant) do
    Instance
    |> Ash.Query.filter(subject_id == ^brief.id)
    |> Ash.exists?(authorize?: false, tenant: tenant)
  end
end
