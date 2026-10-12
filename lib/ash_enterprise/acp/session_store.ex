defmodule AshEnterprise.Acp.SessionStore do
  @moduledoc """
  `AshAcp.SessionStore` + `AshAcp.PromptTarget` for the dogfood ACP server.

  Sessions are ETS-backed (see `AshEnterprise.Acp`); the prompt target maps
  operator prompts onto declared Ash actions through the daily-loop grammar in
  `AshEnterprise.Acp.Commands`, and remembers which A2UI surface the turn
  should close with (`AshEnterprise.Acp.Surfaces` reads it back). Actions run
  inside `ash_acp` with the session's actor and `authorize?: true` — this
  module never bypasses policy.

  The session actor carries its precomputed `ActorContext`, attached once at
  `session/new` exactly as the web's `LoadActorContext` plug attaches it per
  request, so policy checks read it rather than query for it.
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
      actor: with_context(Map.get(init, "actor") || Acp.system_actor())
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
    session = %{session | transcript: session.transcript ++ [{role, message}]}
    :ets.insert(Acp.tables().sessions, {session.session_id, session})
    {:ok, session}
  end

  @impl true
  def close(session_id) do
    :ets.delete(Acp.tables().sessions, session_id)
    :ets.delete(Acp.tables().sessions, {:surface, session_id})
    :ok
  end

  # -- AshAcp.PromptTarget ----------------------------------------------------

  @impl true
  def resolve(session_id, prompt_text, ctx) do
    case Commands.route(prompt_text, ctx["session"].actor) do
      {:ok, %{spec: spec, surface: surface}} ->
        Acp.ensure_tables!()
        :ets.insert(Acp.tables().sessions, {{:surface, session_id}, surface})
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
