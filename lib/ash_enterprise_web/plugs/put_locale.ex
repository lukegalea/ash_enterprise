defmodule AshEnterpriseWeb.Plugs.PutLocale do
  @moduledoc """
  Resolves the request's locale (`AshEnterpriseWeb.Locale.resolve/1`) and
  exposes it as `conn.assigns.locale`, a Gettext locale with a catalog
  (`"en"`, `"fr"`).

  It runs **after** `AshEnterpriseWeb.Plugs.LoadActorContext`, because the
  organization's default is read through the tenant that plug resolved. With
  no actor the organization step is skipped and nothing is queried.

  It also sets Gettext's process locale, so HEEx rendered for this request
  (controllers, the root layout, a LiveView's dead render) is translated
  without each call site passing one. That ambient locale is a rendering
  convenience only: anything that leaves the request — the A2UI and ACP
  boundaries, a job — is handed `conn.assigns.locale` explicitly.

  ## Options

    * `:session` — also store the answer in the session as `"locale"`, so a
      LiveView's connected mount (`AshEnterpriseWeb.LiveLocale`) reuses it
      rather than reading the organization again; it has no `Accept-Language`
      to read. The browser pipeline sets it; the JSON:API pipeline has no
      session and does not.
  """

  @behaviour Plug

  alias AshEnterpriseWeb.Locale

  @session_key "locale"

  @doc "The session key the resolved locale is stored under."
  def session_key, do: @session_key

  @impl true
  def init(opts), do: %{session?: Keyword.get(opts, :session, false)}

  @impl true
  def call(%Plug.Conn{} = conn, %{session?: session?}) do
    actor = conn.assigns[:current_user]

    locale =
      Locale.resolve(
        user: Locale.user_preference(actor),
        organization: organization_locale(conn),
        accept_language: conn |> Plug.Conn.get_req_header("accept-language") |> List.first()
      )

    Gettext.put_locale(Locale.backend(), locale)

    conn
    |> Plug.Conn.assign(:locale, locale)
    |> maybe_store(session?, locale)
  end

  defp organization_locale(conn) do
    case conn.assigns[:actor_context] do
      %{organization_id: organization_id} -> Locale.organization_locale(organization_id)
      _no_actor -> nil
    end
  end

  # Written only when it changed: an unchanged session is not re-sent.
  defp maybe_store(conn, false, _locale), do: conn

  defp maybe_store(conn, true, locale) do
    if Plug.Conn.get_session(conn, @session_key) == locale,
      do: conn,
      else: Plug.Conn.put_session(conn, @session_key, locale)
  end
end
