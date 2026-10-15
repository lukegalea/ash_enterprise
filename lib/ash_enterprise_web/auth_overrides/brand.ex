defmodule AshEnterpriseWeb.AuthOverrides.Brand do
  @moduledoc """
  The one authentication-screen override that is decided at runtime: the
  banner's product name.

  `AshAuthentication.Phoenix.Overrides` resolves `set` values at compile time,
  but the product name is deployment configuration (`AshEnterprise.Brand`) read
  when the node boots. The components look overrides up by calling
  `overrides/0` on each module in the route's `overrides:` list at render time,
  first match wins, so this module implements that function directly and is
  listed ahead of `AshEnterpriseWeb.AuthOverrides`. Appearance only, like the
  rest of the overrides.
  """

  @doc false
  def overrides do
    %{{AshAuthentication.Phoenix.Components.Banner, :text} => AshEnterprise.Brand.product_name()}
  end
end
