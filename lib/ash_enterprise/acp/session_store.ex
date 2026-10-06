defmodule AshEnterprise.Acp.SessionStore do
  @moduledoc """
  `AshAcp.SessionStore` + `AshAcp.PromptTarget` for the dogfood ACP server.

  Sessions are ETS-backed (see `AshEnterprise.Acp`); the prompt target maps
  operator prompts onto declared Ash read actions. Actions run inside
  `ash_acp` with the session's actor and `authorize?: true` — this module
  never bypasses policy.
  """

  @behaviour AshAcp.SessionStore
  @behaviour AshAcp.PromptTarget

  alias AshEnterprise.Acp
  alias AshEnterprise.Acp.Session

  @impl true
  def create(init) do
    Acp.ensure_tables!()
    id = Ash.UUID.generate()

    session = %Session{
      session_id: id,
      actor: Map.get(init, "actor") || Acp.system_actor()
    }

    :ets.insert(Acp.tables().sessions, {id, session})
    {:ok, session}
  end

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
    :ok
  end

  # -- AshAcp.PromptTarget ----------------------------------------------------

  @impl true
  def resolve(_session_id, prompt_text, ctx) do
    case String.downcase(String.trim(prompt_text)) do
      "list business units" ->
        {:ok,
         %{
           resource: AshEnterprise.Accounts.BusinessUnit,
           action: :read,
           label: "List business units",
           tenant: AshEnterprise.Acp.tenant_of(ctx["session"].actor)
         }}

      _other ->
        {:error, :no_matching_action}
    end
  end
end
