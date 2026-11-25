defmodule AshEnterprise.Accounts.SelfDeactivationTest do
  @moduledoc """
  An administrator cannot deactivate their own account
  (`AshEnterprise.Accounts.Validations.NotSelf`), and is told why. The same
  administrator deactivating someone else succeeds, so the refusal is the
  validation's and not a missing grant.
  """

  use AshEnterprise.DataCase, async: true

  alias AshEnterprise.Accounts.User
  alias AshEnterprise.Test.DailyFixtures

  defp deactivate(user, actor) do
    user
    |> Ash.Changeset.for_update(:deactivate, %{}, actor: actor)
    |> Ash.update()
  end

  test "an administrator deactivating themselves is refused with the reason" do
    admin = DailyFixtures.tenant!()

    assert {:error, %Ash.Error.Invalid{} = error} = deactivate(admin.user, admin.actor)

    assert Exception.message(error) =~
             "You cannot deactivate your own account. Ask another administrator to do it."

    assert Ash.get!(User, admin.user.id, authorize?: false).lifecycle_status == :active
  end

  test "the same administrator deactivates another person" do
    admin = DailyFixtures.tenant!()
    %{user: member} = DailyFixtures.member!(admin, "Leaver", [])

    assert {:ok, %User{lifecycle_status: :inactive}} = deactivate(member, admin.actor)
  end
end
