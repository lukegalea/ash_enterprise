defmodule AshEnterprise.Security.Types.RoleInheritance do
  @moduledoc """
  Dataverse's `role.isinherited`, which decides what a team-held role gives its
  members.

  | Value | Here | Meaning |
  |---|---|---|
  | 0 | `:team_privileges_only` | Privileges apply only as a team member. Records created go to the **team**. No user-level (`:basic`) access. |
  | 1 | `:direct_user_and_team` | Privileges also apply directly. Records created go to the **user**. |

  `:direct_user_and_team` is the Dataverse default and the default here.

  The practical consequence is *who owns what a team member creates*, which
  determines who can still see it afterwards. Under `:team_privileges_only` the
  team owns it, so every team member retains access; under
  `:direct_user_and_team` the individual owns it, so colleagues need a
  business-unit-level grant to see it at all.

  Source: `priv/cdm/resolved/dataverse_role.json`.
  """

  use Ash.Type.Enum,
    values: [
      team_privileges_only: "Team privileges only",
      direct_user_and_team: "Direct User (Basic) access level and Team privileges"
    ]
end
