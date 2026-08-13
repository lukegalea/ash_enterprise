defmodule AshEnterprise.Accounts.Types.TeamType do
  @moduledoc """
  The four kinds of team, transcribed from Dataverse's `teamtype` option set.

  Values are pinned to Dataverse's integers so data can round-trip with a real
  Dataverse instance without a translation table:

  | Value | Here | Owns records? | Holds roles? | Membership |
  |---|---|---|---|---|
  | 0 | `:owner` | yes | yes | managed here |
  | 1 | `:access` | **no** | **no** | managed here |
  | 2 | `:security_group` | yes | yes | mirrored from Entra ID |
  | 3 | `:office_group` | yes | yes | mirrored from Entra ID |

  Source: `priv/cdm/resolved/dataverse_team.json`, scraped from the Dataverse
  table reference. Not guessed.
  """

  use Ash.Type.Enum,
    values: [
      owner: "Owner",
      access: "Access",
      security_group: "Security Group",
      office_group: "Office Group"
    ]
end
