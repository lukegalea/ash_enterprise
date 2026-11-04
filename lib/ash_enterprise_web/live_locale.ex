defmodule AshEnterpriseWeb.LiveLocale do
  @moduledoc """
  The `on_mount` that carries the request's locale into a LiveView: assigns
  `:locale` (a Gettext locale with a catalog) and sets Gettext's locale on the
  LiveView process, which renders every event's reply.

  It runs after `AshEnterpriseWeb.LiveUserAuth` in every live session (the
  router lists it there, and `AshEnterpriseWeb.LiveLocaleTest` fails on a
  live route without it), so the actor and their context are in place.

  ## Where the locale comes from

  `AshEnterpriseWeb.Plugs.PutLocale` resolved it for the HTTP request that
  rendered the page and stored it in the session. The connected mount reuses
  that answer, after checking it still names a catalog: it cannot read
  `Accept-Language` (the socket does not carry it), and reading the
  organization again on every mount would repeat a query the request already
  made. Without a stored answer — a LiveView mounted outside the browser
  pipeline — it resolves from the organization alone.

  ## A changed preference

  A preference applies from the next full page load, not mid-page. Whatever
  saves a person's or an organization's locale should finish with
  `Phoenix.LiveView.redirect/2` to the current page, not `push_navigate/2` or
  `push_patch/2`: only an HTTP request runs `PutLocale` again, rewrites the
  stored locale and re-renders the root layout's `<html lang>`. A live
  navigation keeps the root layout, and the language with it.
  """

  import Phoenix.Component, only: [assign: 3]

  alias AshEnterpriseWeb.Locale
  alias AshEnterpriseWeb.Plugs.PutLocale

  def on_mount(:default, _params, session, socket) do
    locale = Locale.known(session[PutLocale.session_key()]) || resolve(socket)
    Gettext.put_locale(Locale.backend(), locale)
    {:cont, assign(socket, :locale, locale)}
  end

  defp resolve(socket) do
    actor = socket.assigns[:current_user]

    Locale.resolve(
      user: Locale.user_preference(actor),
      organization: actor && actor |> organization_id() |> Locale.organization_locale()
    )
  end

  defp organization_id(actor), do: AshEnterprise.Security.ActorContext.tenant(actor)
end
