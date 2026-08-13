defmodule AshEnterprise.Security.Types.AccessRightType do
  @moduledoc """
  The eight privilege verbs as an Ash attribute type.

  The verbs, their meanings and their bit values live in
  `AshEnterprise.Security.AccessRight`, which is the module to read. This exists
  only so a resource can declare `attribute :access_right, AccessRightType` and
  get validation and a stable string representation in the database.

  Kept as two modules deliberately: `AccessRight` is pure bitmask arithmetic used
  by policy checks on hot paths and by code with no Ash context at all (tests,
  seeds, imports), while this is the persistence concern. Merging them would make
  the arithmetic depend on `Ash.Type`.
  """

  use Ash.Type.Enum,
    values: [
      read: "Read",
      write: "Write",
      create: "Create",
      delete: "Delete",
      append: "Append",
      append_to: "Append To",
      assign: "Assign",
      share: "Share"
    ]
end
