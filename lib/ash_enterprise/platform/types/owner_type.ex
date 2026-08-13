defmodule AshEnterprise.Platform.Types.OwnerType do
  @moduledoc """
  Discriminates a record's owner between a user and a team.

  The CDM models ownership as an inline `Owner` entity holding a `userOption` and
  a `teamOption`, discriminated at the database level by `ownerIdType`. Dataverse
  exposes the same thing as a lookup with `Targets: systemuser, team`.

  We keep the discriminator as a real column next to `owner_id` rather than
  modelling two nullable foreign keys, because authorization needs to answer
  "does this actor own this row, directly or through a team?" as a filter over
  a column — not as a join. See `docs/manifesto/03-authorization-is-data.md`.
  """

  use Ash.Type.Enum, values: [:user, :team]
end
