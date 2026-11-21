defmodule Battery.Canonical.CredentialCard do
  @moduledoc """
  The card facade over the canonical credential: a card shows the
  holder, the number and a display string made of both. The source's
  field policy decides who sees the number, and the display follows —
  a card never shows more than the credential does.
  """

  use Ash.Resource,
    domain: Battery.Domain,
    data_layer: Ash.DataLayer.Simple,
    extensions: [AshStrangler.Facade]

  facade do
    source Battery.Canonical.Credential

    map :id, from: :id
    map :holder, from: :holder
    map :number, from: :number

    concat(:display,
      from: [:holder, :number],
      read_only?: true,
      because: "A display string cannot be split back into a holder and a number."
    )
  end

  attributes do
    attribute :id, :uuid, primary_key?: true, allow_nil?: false, public?: true
    attribute :holder, :string, public?: true
    attribute :number, :string, public?: true, sensitive?: true
    attribute :display, :string, public?: true, sensitive?: true
  end
end
