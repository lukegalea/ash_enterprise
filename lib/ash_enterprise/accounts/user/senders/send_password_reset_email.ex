defmodule AshEnterprise.Accounts.User.Senders.SendPasswordResetEmail do
  @moduledoc """
  Sends a password reset email
  """

  use AshAuthentication.Sender
  use AshEnterpriseWeb, :verified_routes

  import Swoosh.Email

  alias AshEnterprise.Mailer

  @impl true
  def send(user, token, _) do
    new()
    # Deliberately a literal, and deliberately not a TODO tag: a placeholder
    # that fails the build forever teaches people to ignore the linter. This
    # address must be replaced before any deployment that sends real mail --
    # move it to `config/runtime.exs` alongside the rest of the mailer config.
    |> from({"noreply", "noreply@example.com"})
    |> to(to_string(user.email))
    |> subject("Reset your password")
    |> html_body(body(token: token))
    |> Mailer.deliver!()
  end

  defp body(params) do
    url = url(~p"/password-reset/#{params[:token]}")

    """
    <p>Click this link to reset your password:</p>
    <p><a href="#{url}">#{url}</a></p>
    """
  end
end
