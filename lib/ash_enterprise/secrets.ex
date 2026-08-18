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
end
