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

  An expiry is not the only way a session ends: deactivating a person revokes their
  tokens, and so does a password change. So before each event the page
  also checks that its session is still good, as a new request would: the token verifies,
  is still stored for sign-in and not revoked, and its subject is still a user who may sign
  in (`get_by_subject` does not find a deactivated one). If not, the event is not handled
  and the page goes to sign-in. Only then is the context rebuilt. The check reads the
  database, as the context's rebuild does; a page with no event in flight is not
  interrupted until its next event or its token's expiry.
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
       |> refresh_before_events(session["user_token"])}
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
       |> refresh_before_events(session["user_token"])}
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

  @doc """
  Whether the session `token` still signs its user in, as a new request would check it:
  it verifies, it is still stored for sign-in (not revoked, as deactivation and a password
  change revoke it), and its subject is still a user who may sign in. True for a session
  with no token, which has no stored session to end.
  """
  @spec session_live?(String.t() | nil) :: boolean()
  def session_live?(nil), do: true

  def session_live?(token) when is_binary(token) do
    with {:ok, %{"sub" => subject, "jti" => jti}, resource} <-
           AshAuthentication.Jwt.verify(token, :ash_enterprise),
         token_resource = AshAuthentication.Info.authentication_tokens_token_resource!(resource),
         {:ok, [_stored]} <-
           AshAuthentication.TokenResource.Actions.get_token(token_resource, %{
             "jti" => jti,
             "purpose" => "user"
           }),
         {:ok, _user} <- AshAuthentication.subject_to_user(subject, resource) do
      true
    else
      _ended -> false
    end
  end

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
    end_session(socket, gettext("Your session has expired. Sign in again."))
  end

  defp end_session(socket, message) do
    socket
    |> Phoenix.LiveView.put_flash(:error, message)
    |> Phoenix.LiveView.redirect(to: ~p"/sign-in")
  end

  defp now, do: System.os_time(:second)

  # Detached first: a LiveView that declares this on_mount itself, inside a
  # live_session that declares it too, mounts it twice. A session that has ended since the
  # page connected (the person deactivated, the token revoked) handles nothing more.
  defp refresh_before_events(socket, token) do
    socket
    |> Phoenix.LiveView.detach_hook(:actor_context, :handle_event)
    |> Phoenix.LiveView.attach_hook(:actor_context, :handle_event, fn _event, _params, socket ->
      if session_live?(token) do
        {:cont, refresh_actor_context(socket)}
      else
        {:halt, end_session(socket, gettext("Your session has ended. Sign in again."))}
      end
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
