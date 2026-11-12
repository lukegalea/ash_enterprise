defmodule AshEnterprise.Accounts.Offboarding.Actions.RevokeCredentials do
  @moduledoc """
  Runs `AshEnterprise.Accounts.Offboarding.revoke_credentials`: finds the offboarding the
  occurrence opened, as the caller, and runs its `revoke` update as the caller, so the
  caller's `write` grant on this organization's row is what allows it.

  Answers `%{"leaver" => "inactive" | "reactivated", "sessions_revoked" => n,
  "api_keys_revoked" => n}`; the process routes on `leaver`.

  An occurrence no offboarding was opened for is refused with the business error
  `not_opened`. A second run revokes what is live by then, which after the first is nothing.
  """

  use Ash.Resource.Actions.Implementation

  alias AshAgent.BusinessError
  alias AshEnterprise.Accounts.Offboarding.Actions.Open

  @impl true
  def run(input, _opts, context) do
    opts = Ash.Context.to_opts(context)

    case Open.existing(input.arguments.id, opts) do
      {:ok, nil} ->
        {:error, BusinessError.exception(code: "not_opened")}

      {:ok, offboarding} ->
        with {:ok, revoked} <-
               offboarding |> Ash.Changeset.for_update(:revoke, %{}, opts) |> Ash.update() do
          {:ok,
           %{
             "leaver" => Atom.to_string(revoked.leaver_state),
             "sessions_revoked" => revoked.sessions_revoked,
             "api_keys_revoked" => revoked.api_keys_revoked
           }}
        end

      {:error, error} ->
        {:error, error}
    end
  end
end
