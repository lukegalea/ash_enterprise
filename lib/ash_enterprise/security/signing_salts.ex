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

  Dev and test boot with built-in salts (`config/dev.exs`, `config/test.exs`) so a
  new checkout needs no setup. Those values are public, so `fetch_from_env!/1`
  also refuses them: an environment that runs `config/runtime.exs` in `:prod`
  must set its own.
  """

  @min_length 32
  @session "SESSION_SIGNING_SALT"
  @live_view "LIVE_VIEW_SIGNING_SALT"

  # The built-in dev and test salts. A test pins these to the values in
  # config/dev.exs and config/test.exs.
  @built_in [
    "dev-session-salt-not-for-production-use",
    "dev-live-view-salt-not-for-production",
    "test-session-salt-not-for-production-use",
    "test-live-view-salt-not-for-production"
  ]

  @doc "The salts that dev and test boot with, which no other environment may use."
  @spec built_in() :: [String.t()]
  def built_in, do: @built_in

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
        cond do
          String.trim(value) in @built_in ->
            raise "environment variable #{name} is a built-in dev/test salt, which is public " <>
                    "(generate one with: mix phx.gen.secret 32)"

          String.length(String.trim(value)) >= @min_length ->
            value

          true ->
            raise "environment variable #{name} must be at least #{@min_length} characters " <>
                    "(generate one with: mix phx.gen.secret 32)"
        end

      _ ->
        raise "environment variable #{name} is missing (generate one with: mix phx.gen.secret 32)"
    end
  end
end
