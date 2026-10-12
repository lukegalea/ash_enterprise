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
  #
  # The header's logo rather than the favicon: the favicon is dark artwork and
  # vanished on the dark theme. One image for both themes, beside the brand
  # name in the display face, as in the app header.
  override AshAuthentication.Phoenix.Components.Banner do
    set :image_url, "/images/logo.svg"
    set :dark_image_url, "/images/logo.svg"
    set :root_class, "mb-4 flex w-full items-center justify-center gap-2.5"
    set :href_class, "flex items-center gap-2.5"
    set :image_class, "h-9 w-auto"
    set :dark_image_class, "hidden"
    set :text, "Ash Enterprise"
    set :text_class, "font-display text-xl tracking-tight text-foreground"
  end

  # --- The design system ------------------------------------------------------
  #
  # The generated screens ship gray/blue Tailwind classes with `dark:` variants.
  # These restate them in the app's token utilities (assets/css/neobrutalism.css)
  # so sign-in, registration, reset and confirmation follow the same dark and
  # light themes as the rest of the app: the form sits on a raised card with the
  # ink border and hard shadow, inputs are the core-components field, and the
  # submit is the primary button. Appearance only, as above.

  @screen "grid min-h-screen place-items-center bg-background px-4 py-10"

  @card """
  flex flex-col justify-center mx-auto w-full max-w-sm rounded-base border-2 border-border
  bg-secondary-background px-6 py-8 text-foreground shadow-shadow sm:px-8
  """

  @heading "mb-4 font-display text-2xl tracking-tight text-foreground"

  @submit """
  mt-4 mb-2 inline-flex h-10 w-full cursor-pointer items-center justify-center rounded-base
  border-2 border-border bg-main px-4 text-sm font-base text-main-foreground shadow-shadow
  transition-all hover:shadow-lift active:translate-x-0.5 active:translate-y-0.5
  active:shadow-press focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-ring
  focus-visible:ring-offset-2 focus-visible:ring-offset-background disabled:opacity-50
  """

  @field """
  block h-10 w-full rounded-base border-2 bg-secondary-background px-3 py-2 text-sm font-base
  text-foreground placeholder:text-foreground/60 focus-visible:outline-hidden
  focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2
  focus-visible:ring-offset-background
  """

  override AshAuthentication.Phoenix.SignInLive do
    set :root_class, @screen
  end

  override AshAuthentication.Phoenix.SignOutLive do
    set :root_class, @screen
  end

  override AshAuthentication.Phoenix.ResetLive do
    set :root_class, @screen
  end

  override AshAuthentication.Phoenix.ConfirmLive do
    set :root_class, @screen
  end

  override AshAuthentication.Phoenix.MagicSignInLive do
    set :root_class, @screen
  end

  override AshAuthentication.Phoenix.Components.SignIn do
    set :root_class, @card
    set :strategy_class, "w-full"
    set :authentication_error_container_class, "text-center text-sm text-error"
  end

  override AshAuthentication.Phoenix.Components.Reset do
    set :root_class, @card
    set :strategy_class, "w-full"
  end

  override AshAuthentication.Phoenix.Components.Confirm do
    set :root_class, @card
    set :strategy_class, "w-full"
  end

  override AshAuthentication.Phoenix.Components.SignOut do
    set :root_class, @card
    set :h2_class, @heading
    set :info_text_class, "mb-4 text-sm text-foreground/70"
    set :button_class, @submit
  end

  override AshAuthentication.Phoenix.Components.HorizontalRule do
    set :hr_inner_class, "w-full border-t-2 border-border"
    set :text_inner_class, "bg-secondary-background px-2 font-base text-foreground/70"
  end

  override AshAuthentication.Phoenix.Components.Flash do
    set :message_class_info, """
    fixed top-4 right-4 z-50 w-80 rounded-base border-2 border-border bg-secondary-background
    px-4 py-3 text-sm text-foreground shadow-shadow sm:w-96
    """

    set :message_class_error, """
    fixed top-4 right-4 z-50 w-80 rounded-base border-2 border-border bg-red px-4 py-3 text-sm
    text-on-vivid shadow-shadow sm:w-96
    """
  end

  override AshAuthentication.Phoenix.Components.Password do
    set :interstitial_class, "flex flex-row flex-wrap justify-between gap-2 text-sm font-base"

    set :toggler_class, """
    flex-none text-foreground underline decoration-2 decoration-main underline-offset-4
    hover:decoration-foreground
    """
  end

  override AshAuthentication.Phoenix.Components.Password.SignInForm do
    set :label_class, @heading
  end

  override AshAuthentication.Phoenix.Components.Password.RegisterForm do
    set :label_class, @heading
  end

  override AshAuthentication.Phoenix.Components.Password.ResetForm do
    set :label_class, @heading
  end

  override AshAuthentication.Phoenix.Components.Reset.Form do
    set :label_class, @heading
  end

  override AshAuthentication.Phoenix.Components.MagicLink do
    set :label_class, @heading
  end

  override AshAuthentication.Phoenix.Components.Password.Input do
    set :field_class, "mt-2 mb-3"
    set :label_class, "mb-1 block text-sm font-heading text-foreground"
    set :input_class, @field <> " border-border"
    set :input_class_with_error, @field <> " border-error ring-2 ring-error"
    set :submit_class, @submit
    set :error_ul, "my-2 text-sm text-error"
    set :remember_me_class, "mt-2 mb-2 flex items-center gap-2 text-sm text-foreground"
    set :checkbox_class, "size-4 accent-main"
    set :checkbox_label_class, "text-sm font-base text-foreground"
  end

  override AshAuthentication.Phoenix.Components.MagicLink.Input do
    set :submit_class, @submit
  end

  override AshAuthentication.Phoenix.Components.Confirm.Input do
    set :submit_class, @submit
  end
end
