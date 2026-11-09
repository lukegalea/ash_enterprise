defmodule AshEnterprise.Security.SigningSalts do
  @moduledoc """
  The session cookie salt and the LiveView salt, read from the environment in
  production.

  `config/runtime.exs` calls `fetch_from_env!/1`; it raises, and so the release
  does not boot, when either variable is missing, blank, shorter than 32
  characters, or when both are the same value:

    * `SESSION_SIGNING_SALT` signs the session cookie
    * `LIVE_VIEW_SIGNING_SALT` signs LiveView's session

  Generate each with `mix phx.gen.secret 32`.
  """

  @min_length 32
  @session "SESSION_SIGNING_SALT"
  @live_view "LIVE_VIEW_SIGNING_SALT"

  @doc "Both salts from `env` (a map of variable name to value), or a raised `RuntimeError`."
  @spec fetch_from_env!(%{optional(String.t()) => String.t()}) :: %{
          session: String.t(),
          live_view: String.t()
        }
  def fetch_from_env!(env) do
    session = fetch!(env, @session)
    live_view = fetch!(env, @live_view)

    if session == live_view do
      raise "#{@session} and #{@live_view} must differ"
    end

    %{session: session, live_view: live_view}
  end

  defp fetch!(env, name) do
    case Map.get(env, name) do
      value when is_binary(value) ->
        if String.length(String.trim(value)) >= @min_length do
          value
        else
          raise "environment variable #{name} must be at least #{@min_length} characters " <>
                  "(generate one with: mix phx.gen.secret 32)"
        end

      _ ->
        raise "environment variable #{name} is missing (generate one with: mix phx.gen.secret 32)"
    end
  end
end
