defmodule AshEnterprise.Accounts.TokenPolicy do
  @moduledoc """
  How long a signed-in session token lives.

  `ash_authentication` defaults to 14 days. This sets it explicitly, to 8 hours,
  and a host changes it with

      config :ash_enterprise, :token_lifetime, {12, :hours}

  The value is read when `AshEnterprise.Accounts.User` compiles (the DSL is
  compiled), so a changed setting needs a recompile of that module. A malformed
  setting stops the compile; there is no fallback to the library's default.

  The browser session cookie lives exactly as long (`seconds/0`, read by
  `AshEnterpriseWeb.Endpoint.session_options/0`), and a connected LiveView stops
  acting when its token expires (`AshEnterpriseWeb.LiveUserAuth`), so the token, the
  cookie and the socket share one bound.
  """

  @default {8, :hours}
  @units [:days, :hours, :minutes, :seconds]

  @doc "The configured lifetime as `{n, unit}`."
  @spec lifetime() :: {pos_integer(), :days | :hours | :minutes | :seconds}
  def lifetime do
    :ash_enterprise |> Application.get_env(:token_lifetime, @default) |> validate!()
  end

  @doc """
  The lifetime `AshEnterprise.Accounts.User` was compiled with, in seconds: what a
  session token it issues actually lives, whatever the configuration says now.
  """
  @spec seconds() :: pos_integer()
  def seconds do
    AshEnterprise.Accounts.User
    |> AshAuthentication.Info.authentication_tokens_token_lifetime!()
    |> to_seconds()
  end

  defp to_seconds({n, :days}), do: n * 86_400
  defp to_seconds({n, :hours}), do: n * 3_600
  defp to_seconds({n, :minutes}), do: n * 60
  defp to_seconds({n, :seconds}), do: n

  @doc false
  def validate!({n, unit} = value) when is_integer(n) and n > 0 and unit in @units, do: value

  def validate!(other) do
    raise ArgumentError,
          "config :ash_enterprise, :token_lifetime must be {positive integer, #{inspect(@units)}}, " <>
            "got: #{inspect(other)}"
  end
end
