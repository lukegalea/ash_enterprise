defmodule AshEnterpriseWeb.LocaleTest do
  @moduledoc """
  Locale resolution (ADR 0060, section 5): the precedence, BCP 47 validation,
  the mapping onto catalogs that exist, and `Accept-Language` parsing.
  """

  use ExUnit.Case, async: true

  alias AshEnterpriseWeb.Locale

  doctest AshEnterpriseWeb.Locale

  describe "resolve/1" do
    test "the person's preference beats the organization, which beats the header" do
      assert Locale.resolve(user: "fr", organization: "en", accept_language: "en") == "fr"
      assert Locale.resolve(user: nil, organization: "fr", accept_language: "en") == "fr"
      assert Locale.resolve(organization: "en-US", accept_language: "fr") == "en"
      assert Locale.resolve(accept_language: "fr-CA,fr;q=0.9,en;q=0.8") == "fr"
    end

    test "a source naming no catalog is skipped, not obeyed" do
      assert Locale.resolve(user: "de", organization: "fr", accept_language: "en") == "fr"
      assert Locale.resolve(organization: "ja-JP", accept_language: "fr") == "fr"
      assert Locale.resolve(organization: "not a locale", accept_language: "fr") == "fr"
    end

    test "with nothing usable it is the default" do
      assert Locale.resolve([]) == "en"
      assert Locale.resolve(accept_language: "de-DE, *;q=0.5") == "en"
      assert Locale.resolve(accept_language: "fr;q=0") == "en"
      assert Locale.default() == "en"
    end
  end

  describe "parse_tag/1" do
    test "canonicalizes valid BCP 47 tags" do
      assert Locale.parse_tag("fr") == {:ok, "fr"}
      assert Locale.parse_tag("FR-ca") == {:ok, "fr-CA"}
      assert Locale.parse_tag("zh-hant-tw") == {:ok, "zh-Hant-TW"}
      assert Locale.parse_tag("es-419") == {:ok, "es-419"}
      assert Locale.parse_tag(" en-GB ") == {:ok, "en-GB"}
    end

    test "refuses what is not a language tag" do
      for bad <- [
            "",
            "f",
            "french",
            "fr_CA",
            "fr-",
            "fr--CA",
            "fr-CA;q=1",
            "../../etc/passwd",
            "fr-x-private",
            String.duplicate("a", 100),
            nil,
            :fr,
            42
          ] do
        assert Locale.parse_tag(bad) == :error, "accepted #{inspect(bad)}"
      end
    end
  end

  describe "negotiate/2" do
    test "maps BCP 47 onto the most specific catalog that exists" do
      assert Locale.negotiate("fr-CA", ["en", "fr", "fr_CA"]) == "fr_CA"
      assert Locale.negotiate("fr-CA", ["en", "fr"]) == "fr"
      assert Locale.negotiate("fr-FR", ["en"]) == nil
      assert Locale.negotiate("zh-Hant-TW", ["zh_Hant"]) == "zh_Hant"
    end

    test "only locales with catalogs are reachable" do
      assert "fr" in Locale.known_locales()
      assert "en" in Locale.known_locales()
      assert Locale.negotiate("fr-CA") == "fr"
      assert Locale.negotiate("de") == nil
    end
  end

  describe "accept_language/1" do
    test "orders by quality, keeping header order on ties" do
      assert Locale.accept_language("de;q=0.5, fr-CA, en;q=0.8, fr") == [
               "fr-CA",
               "fr",
               "en",
               "de"
             ]
    end

    test "drops q=0, wildcards and unreadable qualities" do
      assert Locale.accept_language("fr;q=0, *, en;q=abc, de;q=2, es;q=0.1") == ["es"]
    end

    test "tolerates garbage and absence" do
      assert Locale.accept_language(nil) == []
      assert Locale.accept_language(",,,;;;") |> Enum.all?(&(Locale.parse_tag(&1) == :error))
      assert Locale.resolve(accept_language: String.duplicate("x-y,", 10_000) <> "fr") == "en"
    end
  end

  test "html_lang/1 is BCP 47 and never names a locale without a catalog" do
    assert Locale.html_lang("fr") == "fr"
    assert Locale.html_lang(nil) == "en"
    assert Locale.html_lang("de") == "en"
    assert Locale.html_lang("<script>") == "en"
  end

  test "known/1 trusts a stored value only when it names a catalog" do
    assert Locale.known("fr") == "fr"
    assert Locale.known("fr-CA") == nil
    assert Locale.known(%{}) == nil
  end

  test "user_preference/1 is the seam for a field that does not exist yet" do
    assert Locale.user_preference(%{preferred_locale: "fr"}) == nil
  end
end
