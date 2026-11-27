defmodule AshEnterpriseWeb.Gettext do
  @moduledoc """
  A module providing Internationalization with a gettext-based API.

  By using [Gettext](https://gettext.hexdocs.pm), your module compiles translations
  that you can use in your application. To use this Gettext backend module,
  call `use Gettext` and pass it as an option:

      use Gettext, backend: AshEnterpriseWeb.Gettext

      # Simple translation
      gettext("Here is the string to translate")

      # Plural translation
      ngettext("Here is the string to translate",
               "Here are the strings to translate",
               3)

      # Domain-based translation
      dgettext("errors", "Here is the error message to translate")

  See the [Gettext Docs](https://gettext.hexdocs.pm) for detailed usage.
  """
  use Gettext.Backend, otp_app: :ash_enterprise

  alias AshEnterpriseWeb.Gettext.Pseudo

  # The pseudo-locale (`AshEnterpriseWeb.Locale.pseudo/0`) has no catalog: every
  # message is missing from it, and answers as its msgid pseudo-translated.
  # Anything a screen shows in that locale that is not accented text was never
  # translated (`AshBrowserTests.Journeys`).
  @impl Gettext.Backend
  def handle_missing_translation(locale, domain, msgctxt, msgid, bindings) do
    if pseudo?(locale),
      do: Gettext.Interpolation.Default.runtime_interpolate(Pseudo.translate(msgid), bindings),
      else: super(locale, domain, msgctxt, msgid, bindings)
  end

  @impl Gettext.Backend
  def handle_missing_plural_translation(locale, domain, msgctxt, msgid, msgid_plural, n, bindings) do
    if pseudo?(locale) do
      Gettext.Interpolation.Default.runtime_interpolate(
        Pseudo.translate(if n == 1, do: msgid, else: msgid_plural),
        Map.put(bindings, :count, n)
      )
    else
      super(locale, domain, msgctxt, msgid, msgid_plural, n, bindings)
    end
  end

  defp pseudo?(locale), do: locale == AshEnterpriseWeb.Locale.pseudo()
end
