defmodule AshEnterpriseWeb.AuthOverrides do
  @moduledoc """
  Presentation overrides for `ash_authentication_phoenix`'s generated screens.

  Appearance only. Anything that changes what an unauthenticated caller may do
  belongs in the resource's strategies or its policies, not here.
  """
  use AshAuthentication.Phoenix.Overrides

  # configure your UI overrides here

  # First argument to `override` is the component name you are overriding.
  # The body contains any number of configurations you wish to override
  # Below are some examples

  # For a complete reference, see https://hexdocs.pm/ash_authentication_phoenix/ui-overrides.html

  # override AshAuthentication.Phoenix.Components.Banner do
  #   set :image_url, "https://media.giphy.com/media/g7GKcSzwQfugw/giphy.gif"
  #   set :text_class, "bg-red-500"
  # end

  # override AshAuthentication.Phoenix.Components.SignIn do
  #  set :show_banner, false
  # end

  # The default banner points `image_url` at https://ash-hq.org, which this application's
  # Content-Security-Policy refuses -- `img-src 'self' data: blob:` names no remote host. So
  # every visitor to the sign-in page has seen a broken image, and the only place it was
  # reported was a console the screenshot script now reads.
  #
  # Replaced with the application's own icon rather than by widening the policy. A sign-in
  # page that fetches an image from a third party is a beacon on the one page an unauthenticated
  # visitor is guaranteed to load, and the CSP is right to refuse it.
  override AshAuthentication.Phoenix.Components.Banner do
    set :image_url, "/favicon.ico"
    set :dark_image_url, "/favicon.ico"
  end
end
