defmodule AshEnterprise.Secrets do
  @moduledoc """
  Resolves `ash_authentication`'s secrets at runtime rather than compile time.

  Reading these from the application environment inside a callback -- instead of
  interpolating them into the DSL -- is what keeps a signing secret out of the
  compiled BEAM files and out of a release image.
  """
  use AshAuthentication.Secret

  def secret_for(
        [:authentication, :tokens, :signing_secret],
        AshEnterprise.Accounts.User,
        _opts,
        _context
      ) do
    Application.fetch_env(:ash_enterprise, :token_signing_secret)
  end

  # The deployment's OpenID Connect identity provider (ADR 0071), from
  # `config :ash_enterprise, :oidc` (set in `config/runtime.exs` from the `OIDC_*`
  # environment). Missing configuration is `:error`, and the sign-in is refused.
  def secret_for(
        [:authentication, :strategies, :oidc, key],
        AshEnterprise.Accounts.User,
        _opts,
        _context
      )
      when key in [:base_url, :client_id, :client_secret, :redirect_uri] do
    with {:ok, config} <- Application.fetch_env(:ash_enterprise, :oidc),
         value when is_binary(value) and value != "" <- Keyword.get(config, key) do
      {:ok, value}
    else
      _ -> :error
    end
  end
end
