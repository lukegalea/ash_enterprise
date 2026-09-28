defmodule AshEnterprise.Zones.Errors.Inadmissible do
  @moduledoc """
  An item was refused entry to a zone by the admission rule.

  The message names the zone and the reason, never the item's content: a refusal
  is itself something that may be logged or shown to an agent outside the zone.
  """

  use Splode.Error, fields: [:zone, :reason, :field], class: :invalid

  @type t :: %__MODULE__{zone: String.t() | nil, reason: term(), field: atom() | nil}

  def message(%{zone: zone, reason: reason}) do
    "refused entry to zone #{inspect(zone)}: the item " <>
      AshEnterprise.Zones.Admission.describe(reason)
  end
end
