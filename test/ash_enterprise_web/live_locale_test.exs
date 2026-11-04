defmodule AshEnterpriseWeb.LiveLocaleTest do
  @moduledoc """
  The request's locale end to end (ADR 0060, section 5): the browser and
  JSON:API pipelines resolve it after the actor, the organization's default
  beats `Accept-Language`, the root layout's `<html lang>` follows it, a
  LiveView renders in it, and every live route carries the hook.
  """

  use AshEnterpriseWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import AshEnterprise.Test.DailyFixtures

  alias AshEnterprise.Accounts.Organization
  alias AshEnterprise.Reference.LanguageLocale
  alias AshEnterpriseWeb.Locale

  defp sign_in(conn, user) do
    {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(user)

    conn
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session("user_token", token)
  end

  defp bearer(conn, user) do
    {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(user)
    put_req_header(conn, "authorization", "Bearer " <> token)
  end

  # The organization's default locale, as an administrator would set it.
  defp organization_locale!(%{tenant: tenant}, code) do
    locale =
      LanguageLocale.create!(
        %{
          locale_id: System.unique_integer([:positive]),
          code: code,
          language: "French",
          name: "French (#{code})"
        },
        authorize?: false
      )

    Organization
    |> Ash.get!(tenant, authorize?: false)
    |> Ash.Changeset.for_update(:update, %{languagelocale_id: locale.id})
    |> Ash.update!(authorize?: false)

    locale
  end

  describe "the organization's default" do
    test "is read by code, and nil without one" do
      ctx = tenant!()
      assert Locale.organization_locale(ctx.tenant) == nil
      assert Locale.organization_locale(nil) == nil

      organization_locale!(ctx, "fr-CA")
      assert Locale.organization_locale(ctx.tenant) == "fr-CA"
    end

    test "beats Accept-Language in the browser, and lands in the session", %{conn: conn} do
      ctx = tenant!()
      organization_locale!(ctx, "fr-CA")

      conn =
        conn
        |> sign_in(ctx.user)
        |> put_req_header("accept-language", "en-US,en;q=0.9")
        |> get(~p"/app")

      assert conn.assigns.locale == "fr"
      assert get_session(conn, "locale") == "fr"
      assert html_lang(html_response(conn, 200)) == "fr"
    end

    test "beats Accept-Language over JSON:API, which has no session", %{conn: conn} do
      ctx = tenant!()
      organization_locale!(ctx, "fr-FR")

      conn =
        conn
        |> bearer(ctx.user)
        |> put_req_header("accept", "application/vnd.api+json")
        |> put_req_header("accept-language", "en")
        |> get("/api/json/teams")

      assert json_response(conn, 200)
      assert conn.assigns.locale == "fr"
      refute Map.has_key?(conn.private, :plug_session)
    end
  end

  describe "without an organization default" do
    test "Accept-Language decides, then English", %{conn: conn} do
      ctx = tenant!()
      signed_in = sign_in(conn, ctx.user)

      french = signed_in |> put_req_header("accept-language", "fr-CA, en;q=0.5") |> get(~p"/app")
      assert french.assigns.locale == "fr"
      assert html_lang(html_response(french, 200)) == "fr"

      german =
        build_conn()
        |> sign_in(ctx.user)
        |> put_req_header("accept-language", "de")
        |> get(~p"/app")

      assert german.assigns.locale == "en"
      assert html_lang(html_response(german, 200)) == "en"
    end

    test "a signed-out visitor's sign-in page follows the header", %{conn: conn} do
      html =
        conn
        |> put_req_header("accept-language", "fr")
        |> get(~p"/sign-in")
        |> html_response(200)

      assert html_lang(html) == "fr"
      # ash_authentication_phoenix's own copy, through the `auth` domain.
      assert html =~ "Se connecter"
    end
  end

  test "a host page renders in French, dead and connected", %{conn: conn} do
    ctx = tenant!()
    organization_locale!(ctx, "fr-CA")

    {:ok, view, html} = live(sign_in(conn, ctx.user), ~p"/app")

    assert html =~ "Interfaces clés"
    refute html =~ "Key interfaces"
    assert has_element?(view, "#nav-launcher", "Toutes les applications")
    assert render(view) =~ "Filtrer vos applications"
  end

  test "an English organization's page stays English", %{conn: conn} do
    ctx = tenant!()
    organization_locale!(ctx, "en-CA")

    {:ok, _view, html} =
      conn |> sign_in(ctx.user) |> put_req_header("accept-language", "fr") |> live(~p"/app")

    assert html =~ "Key interfaces"
  end

  test "every live route resolves the locale after the actor" do
    routes =
      for %{metadata: %{phoenix_live_view: {module, _action, _opts, live_session}}} = route <-
            Phoenix.Router.routes(AshEnterpriseWeb.Router) do
        {route.path, module, live_session.extra[:on_mount] || []}
      end

    assert routes != []

    for {path, module, hooks} <- routes do
      ids = Enum.map(hooks, &hook_module/1)

      assert AshEnterpriseWeb.LiveLocale in ids,
             "#{path} (#{inspect(module)}) mounts without AshEnterpriseWeb.LiveLocale"

      if AshEnterpriseWeb.LiveUserAuth in ids do
        assert index(ids, AshEnterpriseWeb.LiveLocale) > index(ids, AshEnterpriseWeb.LiveUserAuth),
               "#{path} resolves the locale before LiveUserAuth"
      end
    end
  end

  # The root layout's `<html lang>` (LiveView adds its own attributes beside it).
  defp html_lang(html) do
    [_match, lang] = Regex.run(~r/<html[^>]*\slang="([^"]*)"/, html)
    lang
  end

  defp hook_module(%{id: {module, _fun}}), do: module
  defp hook_module(%{id: module}), do: module
  defp hook_module({module, _arg}), do: module
  defp hook_module(module) when is_atom(module), do: module

  defp index(list, value), do: Enum.find_index(list, &(&1 == value))
end
