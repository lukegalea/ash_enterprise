defmodule AshEnterprise.Accounts.TokenPolicy do
  @moduledoc """
  How long a signed-in session token lives.

  `ash_authentication` defaults to 14 days. This sets it explicitly, to 8 hours,
  and a host changes it with

      config :ash_enterprise, :token_lifetime, {12, :hours}

  The value is read when `AshEnterprise.Accounts.User` compiles (the DSL is
  compiled), so a changed setting needs a recompile of that module. A malformed
  setting stops the compile; there is no fallback to the library's default.
  """

  @default {8, :hours}
  @units [:days, :hours, :minutes, :seconds]

  @doc "The configured lifetime as `{n, unit}`."
  @spec lifetime() :: {pos_integer(), :days | :hours | :minutes | :seconds}
  def lifetime do
    :ash_enterprise |> Application.get_env(:token_lifetime, @default) |> validate!()
  end

  @doc false
  def validate!({n, unit} = value) when is_integer(n) and n > 0 and unit in @units, do: value

  def validate!(other) do
    raise ArgumentError,
          "config :ash_enterprise, :token_lifetime must be {positive integer, #{inspect(@units)}}, " <>
            "got: #{inspect(other)}"
  end
end
