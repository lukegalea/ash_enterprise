defmodule AshEnterpriseWeb.LiveUserAuth do
  @moduledoc """
  Helpers for authenticating users in LiveViews.

  ## The actor's context

  `AshEnterpriseWeb.Plugs.LoadActorContext` attaches the signed-in user's
  `AshEnterprise.Security.ActorContext` to the conn, which reaches a
  LiveView's dead render. The connected mount does not get it: AshAuthentication
  loads the user from the session again, as a bare `User`, and every policy
  check would then rebuild the whole context (`ActorContext.for_actor/2`'s
  fallback) — several queries per check. So `:live_user_required` and
  `:live_user_optional` attach it to `:current_user` when it is missing (once
  per mount), and rebuild it before each event, which is a LiveView's
  equivalent of a request: what an event decides is authorized against the
  person's roles, shares and live tasks as they are now, not as they were when
  the page opened.

  ## The session's bound

  A connected LiveView outlives the request that opened it, so it would otherwise
  keep acting on a session token long after the token expired. The same two
  on_mounts read the expiry (`exp`) of the session token the page was opened with
  and stop the socket there: an event that arrives after it is not handled, and a
  timer sends an idle page to sign-in when the token runs out. The token's lifetime
  is `AshEnterprise.Accounts.TokenPolicy`'s, which the session cookie shares.
  """

  import Phoenix.Component
  use AshEnterpriseWeb, :verified_routes
  use Gettext, backend: AshEnterpriseWeb.Gettext

  alias AshEnterprise.Security.ActorContext

  # This is used for nested liveviews to fetch the current user.
  # To use, place the following at the top of that liveview:
  # on_mount {AshEnterpriseWeb.LiveUserAuth, :current_user}
  def on_mount(:current_user, _params, session, socket) do
    {:cont, AshAuthentication.Phoenix.LiveSession.assign_new_resources(socket, session)}
  end

  def on_mount(:live_user_optional, _params, session, socket) do
    if socket.assigns[:current_user] do
      {:cont,
       socket
       |> bound_by_session(session_expiry(session))
       |> with_actor_context()
       |> refresh_before_events()}
    else
      {:cont, assign(socket, :current_user, nil)}
    end
  end

  def on_mount(:live_user_required, _params, session, socket) do
    if socket.assigns[:current_user] do
      {:cont,
       socket
       |> bound_by_session(session_expiry(session))
       |> with_actor_context()
       |> refresh_before_events()}
    else
      {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/sign-in")}
    end
  end

  def on_mount(:live_no_user, _params, _session, socket) do
    if socket.assigns[:current_user] do
      {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/")}
    else
      {:cont, assign(socket, :current_user, nil)}
    end
  end

  @doc """
  `socket` with its `:current_user` carrying an `ActorContext`: the one it
  already has (the dead render's, from the plug), else one built now.
  """
  @spec with_actor_context(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def with_actor_context(socket), do: assign_context(socket, &ActorContext.for_actor/1)

  @doc "`socket` with `:current_user`'s `ActorContext` built afresh."
  @spec refresh_actor_context(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def refresh_actor_context(socket), do: assign_context(socket, &ActorContext.build/1)

  @doc """
  The expiry, in Unix seconds, of the session token in a LiveView's `session`, or
  nil when it carries none. The token was verified when the user was loaded from it;
  this only reads its `exp`.
  """
  @spec session_expiry(map()) :: integer() | nil
  def session_expiry(%{"user_token" => token}) when is_binary(token) do
    case AshAuthentication.Jwt.peek(token) do
      {:ok, %{"exp" => exp}} when is_integer(exp) -> exp
      _ -> nil
    end
  end

  def session_expiry(_session), do: nil

  @doc "Whether a session that expires at `exp` (Unix seconds) has expired at `now`."
  @spec expired?(integer() | nil, integer()) :: boolean()
  def expired?(nil, _now), do: false
  def expired?(exp, now), do: now >= exp

  # Before the context refresh, so an expired session rebuilds nothing. Detached first,
  # for the same reason as below.
  defp bound_by_session(socket, nil), do: socket

  defp bound_by_session(socket, exp) do
    if Phoenix.LiveView.connected?(socket), do: schedule_expiry(exp)

    socket
    |> Phoenix.LiveView.detach_hook(:session_bound, :handle_event)
    |> Phoenix.LiveView.detach_hook(:session_bound, :handle_info)
    |> Phoenix.LiveView.attach_hook(:session_bound, :handle_event, fn _event, _params, socket ->
      if expired?(exp, now()), do: {:halt, end_session(socket)}, else: {:cont, socket}
    end)
    |> Phoenix.LiveView.attach_hook(:session_bound, :handle_info, fn
      {__MODULE__, :session_expired}, socket ->
        if expired?(exp, now()) do
          {:halt, end_session(socket)}
        else
          schedule_expiry(exp)
          {:halt, socket}
        end

      _message, socket ->
        {:cont, socket}
    end)
  end

  defp schedule_expiry(exp) do
    delay = max(exp * 1000 - System.os_time(:millisecond), 0)
    Process.send_after(self(), {__MODULE__, :session_expired}, delay)
  end

  defp end_session(socket) do
    socket
    |> Phoenix.LiveView.put_flash(:error, gettext("Your session has expired. Sign in again."))
    |> Phoenix.LiveView.redirect(to: ~p"/sign-in")
  end

  defp now, do: System.os_time(:second)

  # Detached first: a LiveView that declares this on_mount itself, inside a
  # live_session that declares it too, mounts it twice.
  defp refresh_before_events(socket) do
    socket
    |> Phoenix.LiveView.detach_hook(:actor_context, :handle_event)
    |> Phoenix.LiveView.attach_hook(:actor_context, :handle_event, fn _event, _params, socket ->
      {:cont, refresh_actor_context(socket)}
    end)
  end

  defp assign_context(socket, context_for) do
    case socket.assigns[:current_user] do
      %AshEnterprise.Accounts.User{} = user ->
        assign(socket, :current_user, ActorContext.attach(user, context_for.(user)))

      _other ->
        socket
    end
  end
end
