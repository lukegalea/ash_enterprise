defmodule AshEnterprise.Accounts.TeamRestoreTest do
  @moduledoc """
  A deletion can be undone (q10): a deleted team is archived, kept, and can be restored by a
  person holding write on teams, within the restore window, with the restore audited.

  Every refusal first: no write grant, not a person, another tenant, outside the window, and
  a team that was never deleted.
  """

  use AshEnterprise.DataCase, async: false

  import AshEnterprise.Test.DailyFixtures

  alias AshEnterprise.Accounts
  alias AshEnterprise.Accounts.Team
  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.Repo
  alias AshEnterprise.Security.ActionReach

  setup do
    admin = tenant!()

    team =
      Team
      |> Ash.Changeset.for_create(
        :create,
        %{
          name: "Night shift #{System.unique_integer([:positive])}",
          team_type: :access,
          owning_business_unit_id: admin.user.owning_business_unit_id
        },
        actor: admin.actor,
        tenant: admin.tenant
      )
      |> Ash.create!()

    %{admin: admin, team: team}
  end

  defp delete!(team, admin), do: Ash.destroy!(team, actor: admin.actor, tenant: admin.tenant)

  defp archived!(team, admin),
    do: Accounts.get_archived_team!(team.id, actor: admin.actor, tenant: admin.tenant)

  defp visible?(team, admin) do
    Team
    |> Ash.Query.for_read(:read, %{}, actor: admin.actor, tenant: admin.tenant)
    |> Ash.read!()
    |> Enum.any?(&(&1.id == team.id))
  end

  describe "restore refuses" do
    test "a person without write on teams", %{admin: admin, team: team} do
      delete!(team, admin)
      reader = member!(admin, "Team reader", [{Team, :read, :global}])
      archived = Accounts.get_archived_team!(team.id, actor: reader.actor, tenant: admin.tenant)

      assert {:error, %Ash.Error.Forbidden{}} =
               Accounts.restore_team(archived, actor: reader.actor, tenant: admin.tenant)

      refute visible?(team, admin)
    end

    test "a system actor: the action is human-only", %{admin: admin, team: team} do
      delete!(team, admin)
      archived = archived!(team, admin)

      assert ActionReach.human_only?(Team, :restore)

      for actor <- [SystemActor.oban(), SystemActor.process(), SystemActor.seed()] do
        assert {:error, %Ash.Error.Forbidden{}} =
                 Accounts.restore_team(archived, actor: actor, tenant: admin.tenant)
      end

      refute visible?(team, admin)
    end

    test "another tenant's administrator cannot even find it", %{admin: admin, team: team} do
      delete!(team, admin)
      other = tenant!()

      assert {:error, _} =
               Accounts.get_archived_team(team.id, actor: other.actor, tenant: other.tenant)
    end

    test "outside the restore window", %{admin: admin, team: team} do
      delete!(team, admin)

      Repo.query!(
        "UPDATE teams SET archived_at = now() - interval '31 days' WHERE id = $1::uuid",
        [Ecto.UUID.dump!(team.id)]
      )

      assert {:error, %Ash.Error.Invalid{} = error} =
               Accounts.restore_team(archived!(team, admin),
                 actor: admin.actor,
                 tenant: admin.tenant
               )

      assert Exception.message(error) =~ "restore window"
      refute visible?(team, admin)
    end

    test "a team that was never deleted is not among the archived", %{admin: admin, team: team} do
      assert {:error, _} =
               Accounts.get_archived_team(team.id, actor: admin.actor, tenant: admin.tenant)
    end
  end

  describe "restore" do
    test "brings a deleted team back, and the log records who did it", %{admin: admin, team: team} do
      delete!(team, admin)
      refute visible?(team, admin)

      restored =
        Accounts.restore_team!(archived!(team, admin), actor: admin.actor, tenant: admin.tenant)

      assert is_nil(restored.archived_at)
      assert visible?(team, admin)

      assert [[user_id]] =
               Repo.query!(
                 "SELECT user_id FROM audit_events WHERE record_id = $1::uuid AND action = 'restore'",
                 [Ecto.UUID.dump!(team.id)]
               ).rows

      assert Ecto.UUID.cast!(user_id) == admin.user.id
    end
  end
end
