defmodule AshEnterprise.Brand do
  @moduledoc """
  The product name a deployment presents to its users.

  This application is also a reference template, so the name on the header,
  the browser tab, the sign-in screen, outgoing mail and the ACP agent's
  handshake is configuration rather than copy:

      config :ash_enterprise, :product_name, "Dogfood"

  `config/runtime.exs` sets it from `PRODUCT_NAME` when that is present, so a
  deployment renames itself without a code change. Unset, it is
  `"Ash Enterprise"`. Read at call time, so the value is whatever the node
  booted with.

  Every user-visible spelling of the name goes through `product_name/0`;
  module names, the OTP app and the docs keep their own.
  """

  @default "Ash Enterprise"

  @doc "The configured product name, or `#{inspect(@default)}`."
  @spec product_name() :: String.t()
  def product_name do
    case Application.get_env(:ash_enterprise, :product_name) do
      name when is_binary(name) and name != "" -> name
      _ -> @default
    end
  end

  @doc """
  The `agentInfo` this node's ACP endpoint reports on `initialize`: a
  machine-friendly `name` derived from the product name, the product name
  itself as the display `title`, and the application's version.
  """
  @spec acp_agent_info() :: %{name: String.t(), title: String.t(), version: String.t()}
  def acp_agent_info do
    title = product_name()

    %{
      name: slug(title),
      title: title,
      version: :ash_enterprise |> Application.spec(:vsn) |> to_string()
    }
  end

  defp slug(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.trim("-")
    |> case do
      "" -> "ash_enterprise"
      slug -> slug
    end
  end
end
