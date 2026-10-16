defmodule AshEnterprise.Accounts.Validations.ProvisionedBySystemActor do
  @moduledoc """
  Refuses `AshEnterprise.Accounts.User`'s `:provision_with_password` unless a
  system actor runs it (`AshEnterprise.Security.Checks.SystemActor`, so never
  the `ai` label).

  That action creates a user who is already confirmed and sends no
  confirmation email. Seeding needs exactly that: the seed and demo tasks
  provision addresses like `admin@example.com` that nobody can receive mail
  at, from a mix task that does not start the endpoint the confirmation link
  is built against. For anyone else it would be a way round email
  confirmation, so a person (an Administrator included) cannot use it, and
  nor can trusted code that turns authorization off. People register through
  `:register_with_password`, which still confirms.
  """

  use Ash.Resource.Validation

  alias AshEnterprise.Security.Checks.SystemActor

  @impl true
  def validate(_changeset, _opts, context) do
    if SystemActor.match?(context.actor, nil, []) do
      :ok
    else
      {:error,
       Ash.Error.Changes.InvalidChanges.exception(
         message:
           "provision_with_password creates a confirmed user without sending a confirmation " <>
             "email, so only a system actor may run it; register with register_with_password"
       )}
    end
  end
end
