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
  (`Jason.Encoder`, beside the `Phoenix.HTML.Safe` implementation): an A2UI surface shows
  an empty cell. Never a placeholder string there: a form that sent it back would write
  the placeholder as the value. `String.Chars` is deliberately not implemented, so code
  that builds a key or a request from a hidden value fails instead of using a mask.
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
