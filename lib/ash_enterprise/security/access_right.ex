defmodule AshEnterprise.Security.AccessRight do
  @moduledoc """
  The eight privilege verbs, and the bitmask they pack into.

  ## The verbs

  | Verb | Meaning |
  |---|---|
  | `:read` | Open a record and view its contents |
  | `:write` | Change a record |
  | `:create` | Make a new record |
  | `:delete` | Permanently remove a record |
  | `:append` | Attach *this* record to another one |
  | `:append_to` | Allow another record to be attached to *this* one |
  | `:assign` | Give ownership of a record to someone else |
  | `:share` | Give someone else access while keeping your own |

  `:append` and `:append_to` are the pair everyone gets wrong. `:append` lives on
  the **child** ("I may be attached to something"); `:append_to` lives on the
  **parent** ("something may be attached to me"). Linking two records requires
  *both*, on both sides. Dataverse is explicit that a many-to-many association
  needs `Append` on both tables involved.

  ## The bit values are deliberately non-contiguous

  These are Microsoft's `AccessRights` `[Flags]` enum values, preserved exactly:

      None        0
      Read        1        0x00001
      Write       2        0x00002
      Append      4        0x00004
      AppendTo    16       0x00010
      Create      32       0x00020
      Delete      65536    0x10000
      Share       262144   0x40000
      Assign      524288   0x80000

  Note the gaps: 8, and everything between 64 and 32768. They are historical
  reservations, and we keep them rather than renumbering to 1..8, because
  `access_rights_mask` on a sharing row is the one value most likely to be
  imported from or exported to a real Dataverse instance. Renumbering would make
  every such mask silently mean something else.

  Source: `Microsoft.Crm.Sdk.Messages.AccessRights`. These values *are* verified.
  """

  @bits %{
    read: 0x00001,
    write: 0x00002,
    append: 0x00004,
    append_to: 0x00010,
    create: 0x00020,
    delete: 0x10000,
    share: 0x40000,
    assign: 0x80000
  }

  @verbs Map.keys(@bits)

  @type verb :: :read | :write | :append | :append_to | :create | :delete | :share | :assign
  @type mask :: non_neg_integer()

  @doc "Every verb."
  def verbs, do: @verbs

  @doc "The single bit for one verb."
  def bit(verb) when is_map_key(@bits, verb), do: @bits[verb]

  @doc """
  Packs verbs into a mask.

      iex> AshEnterprise.Security.AccessRight.to_mask([:read, :write])
      3
  """
  def to_mask(verbs) when is_list(verbs) do
    Enum.reduce(verbs, 0, fn verb, acc -> Bitwise.bor(acc, bit(verb)) end)
  end

  @doc """
  Unpacks a mask back into verbs. Unknown bits are ignored rather than raising —
  a mask imported from another system may carry rights we do not model, and
  refusing to read the row would be worse than reading the part we understand.

      iex> AshEnterprise.Security.AccessRight.from_mask(3)
      [:read, :write]
  """
  def from_mask(mask) when is_integer(mask) do
    @verbs
    |> Enum.filter(&granted?(mask, &1))
    |> Enum.sort_by(&@bits[&1])
  end

  @doc """
  Does this mask grant this verb?

      iex> AshEnterprise.Security.AccessRight.granted?(3, :write)
      true
      iex> AshEnterprise.Security.AccessRight.granted?(3, :delete)
      false
  """
  def granted?(mask, verb) when is_integer(mask) and is_map_key(@bits, verb) do
    Bitwise.band(mask, @bits[verb]) != 0
  end

  @doc """
  Maps an Ash action type onto the verb it requires.

  This is the seam between Ash's vocabulary and Dataverse's. Ash has four action
  types; Dataverse has eight verbs, and the extra four (`:append`, `:append_to`,
  `:assign`, `:share`) have no Ash action type — they are checked explicitly by
  the actions that perform them, because Ash cannot infer "this update reassigns
  ownership" from the action type alone.
  """
  def for_action_type(:create), do: :create
  def for_action_type(:read), do: :read
  def for_action_type(:update), do: :write
  def for_action_type(:destroy), do: :delete

  @doc "The full mask: every verb. Convenient for owner-team templates and tests."
  def all_mask, do: to_mask(@verbs)
end
