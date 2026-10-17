defmodule AshEnterprise.Acp.SessionStore do
  @moduledoc """
  `AshAcp.SessionStore` + `AshAcp.PromptTarget` for the dogfood ACP server.

  Sessions are ETS-backed (see `AshEnterprise.Acp`); the prompt target maps
  operator prompts onto declared Ash actions through the daily-loop grammar in
  `AshEnterprise.Acp.Commands`, and remembers which A2UI surface the turn
  should close with (`AshEnterprise.Acp.Surfaces` reads it back). Actions run
  inside `ash_acp` with the session's actor and `authorize?: true` — this
  module never bypasses policy.

  The session actor carries its precomputed `ActorContext`, attached at
  `session/new` as the web's `LoadActorContext` plug attaches it per request,
  so policy checks read it rather than query for it. A session outlives a
  request, so the context is rebuilt for each prompt turn: `ash_acp` runs the
  turn's action with the session `append_message/3` returns for the person's
  prompt, and that session's actor carries a context built then. Roles,
  shares and live tasks (`task_ids`) are as they are at that turn, not as they
  were when the session opened; the stored session keeps the actor it was
  created with, so ownership checks still compare like with like.
  """

  @behaviour AshAcp.SessionStore
  @behaviour AshAcp.PromptTarget

  alias AshEnterprise.Acp
  alias AshEnterprise.Acp.{Commands, Session}
  alias AshEnterprise.Security.ActorContext

  @impl true
  def create(init) do
    Acp.ensure_tables!()
    id = Ash.UUID.generate()

    session = %Session{
      session_id: id,
      actor: with_context(Map.get(init, "actor") || Acp.system_actor()),
      updated_at: DateTime.utc_now()
    }

    :ets.insert(Acp.tables().sessions, {id, session})
    {:ok, session}
  end

  defp with_context(%{__ash_enterprise_context__: %ActorContext{}} = actor), do: actor

  defp with_context(%{__struct__: _} = user),
    do: ActorContext.attach(user, ActorContext.build(user))

  defp with_context(actor), do: actor

  @impl true
  def load(session_id) do
    Acp.ensure_tables!()

    case :ets.lookup(Acp.tables().sessions, session_id) do
      [{_, session}] -> {:ok, session}
      [] -> {:error, :unknown_session}
    end
  end

  @impl true
  def append_message(%Session{} = session, role, message) do
    session = %{
      session
      | transcript: session.transcript ++ [{role, message}],
        updated_at: DateTime.utc_now()
    }

    :ets.insert(Acp.tables().sessions, {session.session_id, session})
    {:ok, for_turn(session, role)}
  end

  # The person's prompt opens a turn, and the turn runs with the session this
  # returns: its actor's context is built now (see the moduledoc).
  defp for_turn(%Session{actor: %AshEnterprise.Accounts.User{} = user} = session, :user),
    do: %{session | actor: ActorContext.attach(user, ActorContext.build(user))}

  defp for_turn(session, _role), do: session

  @impl true
  def close(session_id) do
    :ets.delete(Acp.tables().sessions, session_id)
    :ets.delete(Acp.tables().sessions, {:surface, session_id})
    :ok
  end

  @doc """
  `session/list`: the sessions in this node's store, newest first, as the
  shape `AshAcp.Server` reads (`session_id`, `title`, `updated_at`). With an
  authenticated actor, only theirs. Sessions live in memory until epic E5's
  durable store, so a restart empties the list.
  """
  @impl true
  def list(filter) do
    Acp.ensure_tables!()
    actor = Map.get(filter, "actor")

    sessions =
      for {id, %Session{} = session} when is_binary(id) <- :ets.tab2list(Acp.tables().sessions),
          is_nil(actor) or same_actor?(session.actor, actor) do
        %{session_id: id, title: title(session), updated_at: session.updated_at}
      end

    {:ok, Enum.sort_by(sessions, & &1.updated_at, {:desc, DateTime})}
  end

  defp same_actor?(%{id: id}, %{id: id}), do: true
  defp same_actor?(_session_actor, _actor), do: false

  # The first thing said in it, on one line.
  defp title(%Session{transcript: transcript}) do
    Enum.find_value(transcript, fn
      {:user, text} when is_binary(text) ->
        text |> String.split("\n") |> hd() |> String.slice(0, 60)

      _other ->
        nil
    end)
  end

  @doc """
  Records the surface a session is showing (`{ui, opts}`) — a prompt's, or one
  opened directly over `_ash/surface/open` — so the next turn's close and a
  `session/load` re-emit it (`AshEnterprise.Acp.Surfaces`).
  """
  @spec put_surface(String.t(), term()) :: true
  def put_surface(session_id, surface) do
    Acp.ensure_tables!()
    :ets.insert(Acp.tables().sessions, {{:surface, session_id}, surface})
  end

  # -- AshAcp.PromptTarget ----------------------------------------------------

  @impl true
  def resolve(session_id, prompt_text, ctx) do
    case Commands.route(prompt_text, ctx["session"].actor) do
      {:ok, %{spec: spec, surface: surface}} ->
        put_surface(session_id, surface)
        {:ok, spec}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  # The surface the session's latest routed prompt asked for (nil: none).
  def surface_for(session_id) do
    Acp.ensure_tables!()

    case :ets.lookup(Acp.tables().sessions, {:surface, session_id}) do
      [{_, surface}] -> surface
      [] -> nil
    end
  end
end
