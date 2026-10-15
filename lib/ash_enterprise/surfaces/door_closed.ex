defmodule AshEnterprise.Surfaces.DoorClosed do
  @moduledoc """
  A registry surface's door is closed for the actor
  (`AshEnterprise.Surfaces.Doors`). A `:forbidden`-class error, so an action
  that checks a door (`Console.open`) fails as `Ash.Error.Forbidden`, exactly
  as a policy refusal would.
  """

  use Splode.Error, fields: [:label, :door], class: :forbidden

  def message(error),
    do: "#{error.label} is for #{AshEnterprise.Surfaces.Doors.audience(error.door)}."
end
