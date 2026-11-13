defmodule AshEnterprise.Accounts.Changes.RefuseSelfRegistration do
  @moduledoc """
  Fails `:register_with_password` unless self-registration is on
  (`config :ash_enterprise, self_registration?: true`).

  The register form renders in every environment, because the sign-in LiveView
  needs its action paths configured to render at all. A deployment must not
  accept self-registration: its accounts are provisioned by the operator
  (`:provision_with_password`, `mix ash_enterprise.seed`). `config/dev.exs` and
  `config/test.exs` turn it on, since the suite and a developer register users
  this way; `config/config.exs` leaves it off, so a release refuses. An instance
  running the dev configuration for people turns it off with
  `SELF_REGISTRATION=false` (`config/runtime.exs`).

  A change, not a policy, so it applies whatever `authorize?` says: registration
  runs before there is a session by definition, and the refusal is a fact about
  the deployment, not a decision about an actor.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    if Application.get_env(:ash_enterprise, :self_registration?, false) do
      changeset
    else
      Ash.Changeset.add_error(changeset,
        field: :email,
        message: "Registration is disabled on this deployment."
      )
    end
  end
end
