defmodule AshEnterpriseWeb.AuthOverrides.Brand do
  @moduledoc """
  The authentication-screen overrides that are decided at runtime: the banner's
  product name, and the sign-in divider's word, which is read in the reader's
  language.

  `AshAuthentication.Phoenix.Overrides` resolves `set` values at compile time,
  but the product name is deployment configuration (`AshEnterprise.Brand`) read
  when the node boots, and a language is the request's. The components look
  overrides up by calling `overrides/0` on each module in the route's
  `overrides:` list at render time, first match wins, so this module implements
  that function directly and is listed ahead of
  `AshEnterpriseWeb.AuthOverrides`. Appearance only, like the rest of the
  overrides.
  """

  use Gettext, backend: AshEnterpriseWeb.Gettext

  @doc false
  def overrides do
    %{
      {AshAuthentication.Phoenix.Components.Banner, :text} => AshEnterprise.Brand.product_name(),
      # GAP: the divider's word is not translated by ash_authentication_phoenix
      # (it renders the `:text` override as given); upstream issue to be opened.
      {AshAuthentication.Phoenix.Components.HorizontalRule, :text} =>
        pgettext("sign-in divider between the password form and other ways in", "or")
    }
  end
end
