defmodule AshEnterpriseWeb.PseudoLocaleTest do
  # The pseudo-locale is an application setting the Locale reads on every request.
  use ExUnit.Case, async: false

  alias AshEnterpriseWeb.Gettext, as: Backend
  alias AshEnterpriseWeb.Gettext.Pseudo
  alias AshEnterpriseWeb.Locale

  doctest Pseudo

  defp pseudo(fun), do: Gettext.with_locale(Backend, Locale.pseudo(), fun)

  test "the test environment configures one, and it is a known locale" do
    assert Locale.pseudo() == "en_XA"
    assert Locale.known("en_XA") == "en_XA"
    assert Locale.negotiate("en-XA") == "en_XA"
    assert Locale.html_lang("en_XA") == "en-XA"
  end

  test "an environment that configures none does not know it" do
    pseudo = Application.fetch_env!(:ash_enterprise, :pseudo_locale)
    Application.delete_env(:ash_enterprise, :pseudo_locale)
    on_exit(fn -> Application.put_env(:ash_enterprise, :pseudo_locale, pseudo) end)

    assert Locale.known("en_XA") == nil
    assert Locale.resolve(accept_language: "en-XA") == "en"
    refute "en_XA" in Locale.known_locales()
  end

  test "a message, in any domain, comes back accented with its placeholders filled" do
    pseudo(fn ->
      assert Gettext.dgettext(Backend, "default", "Users") == "⟦Ûšéŕš~⟧"

      assert Gettext.dgettext(Backend, "journeys", "Open %{surface}.", surface: "Utilisateurs") ==
               "⟦Öþéñ Utilisateurs.~~⟧"

      assert Gettext.dpgettext(Backend, "default", "a context", "or") == "⟦öŕ⟧"
      assert Gettext.dngettext(Backend, "default", "One row", "%{count} rows", 3) == "⟦3 ŕöŵš~⟧"
    end)
  end

  test "an accented message has no ASCII word left in it but its placeholders" do
    refute "Create a new user, then confirm: %{action}"
           |> Pseudo.translate()
           |> String.replace("%{action}", "")
           |> String.match?(~r/[A-Za-z]{2,}/)
  end

  test "a real locale is not touched" do
    assert Gettext.with_locale(Backend, "fr", fn ->
             Gettext.dgettext(Backend, "auth", "Forgot your password?")
           end) =~ "Mot de passe oublié"
  end
end
