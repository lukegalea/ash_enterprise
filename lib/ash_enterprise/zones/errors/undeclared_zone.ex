defmodule AshEnterprise.Zones.Errors.UndeclaredZone do
  @moduledoc """
  An ingest path named a zone that has no declaration, or named none at all.

  The rule fails closed: with no declared zone there is nothing to admit data
  against, so nothing enters.
  """

  use Splode.Error, fields: [:zone], class: :invalid

  @type t :: %__MODULE__{zone: String.t() | nil}

  def message(%{zone: nil}),
    do: "no zone is configured for this store; nothing may enter an undeclared zone"

  def message(%{zone: zone}),
    do: "zone #{inspect(zone)} has no declaration; nothing may enter an undeclared zone"
end
