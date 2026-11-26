defmodule AshEnterpriseWeb.HiddenField do
  @moduledoc """
  How a page shows a value its reader may not see: a secured column read without the
  column's grant (`AshEnterprise.Platform.Resource`'s `secured_fields`), which Ash
  returns as `%Ash.ForbiddenField{}`.

  A template that interpolates one renders the masked text instead of raising
  (`Phoenix.HTML.Safe` is implemented for the struct, in
  `lib/ash_enterprise_web/hidden_field/safe.ex`). Text built outside a template, such as a
  translated message's bindings, goes through `shown/1`.

  On the JSON wire the struct is `null`, as AshJsonApi renders a forbidden field
  (`Jason.Encoder`, beside the `Phoenix.HTML.Safe` implementation). An A2UI surface
  shows it as masked text, with the reason at the record's reserved `_masked` key
  (`ash_a2ui` does this itself, `AshA2ui.Masked`), so a cell, a card or a badge there never
  reads as known and empty. Its edit buffers (`/form`, `_edit_<field>`) and its CSV exports
  keep `null` or an empty cell, so a form filled from the record holds a stand-in, never
  the masked word, and an
  update keeps the stored value when a writer who cannot see the column sends a stand-in back
  (`AshEnterprise.Security.Changes.KeepHiddenSecuredFields`). `String.Chars` is
  deliberately not implemented, so code that builds a key or a request from a hidden
  value fails instead of using a mask.
  """

  use Gettext, backend: AshEnterpriseWeb.Gettext

  @doc "The masked text a page shows in place of a hidden value."
  @spec masked() :: String.t()
  def masked, do: dgettext("default", "hidden")

  @doc "`value`, or the masked text when it is a field the reader may not see."
  @spec shown(term()) :: term()
  def shown(%Ash.ForbiddenField{}), do: masked()
  def shown(value), do: value

  @doc "Whether `value` is a field the reader may not see."
  @spec hidden?(term()) :: boolean()
  def hidden?(%Ash.ForbiddenField{}), do: true
  def hidden?(_value), do: false
end
