defmodule AshEnterprise.Integration do
  @moduledoc """
  The provider edge (ADR 0011, AST-155 exercised in epic E4): outbound calls to
  third-party APIs through Nango's proxy, each one an ordinary Ash action.

  ## The shape

    * `AshEnterprise.Integration.LinkedAccount` maps one of an actor's own
      provider accounts to a Nango connection. It is the only place a Nango
      connection id lives.
    * `AshEnterprise.Integration.GoogleCalendar`, `.Gmail` and `.Slack` are
      operation resources. Each declares its provider operations with the
      `AshEnterprise.Integration.Nango.Operations` DSL, and each declared
      operation becomes **one generic action** — policy-gated, traced and
      correlated like any other action. There is no integration log.
    * `AshEnterprise.Integration.Nango.Proxy` is the one module that speaks HTTP
      to Nango (Iron Law #20).
    * `AshEnterprise.Integration.Landing.land/2` is the one call an adapter
      makes to land a fetched record, under the linked account's scope.

  ## The rule that does not bend

  **The connection id is never an action argument.** It is resolved inside the
  action from the actor's own linked accounts (ADR 0011, dogfood deviation 1:
  per-user, not per-tenant). An adapter that holds several linked accounts for
  one provider names *which* by `linked_account_id` — a row the actor must own,
  read under the actor's policies — never by connection.

  ## Tier 3

  Removable by deletion: nothing in `accounts/`, `security/` or `audit/` imports
  this directory.

  `validate_config_inclusion?: false` is temporary: the domain is not yet in
  `config :ash_enterprise, :ash_domains` (config is owned by a concurrent
  change). Registering it there and dropping the flag is an integration step.
  """

  use Ash.Domain,
    validate_config_inclusion?: false

  resources do
    resource AshEnterprise.Integration.LinkedAccount
    resource AshEnterprise.Integration.GoogleCalendar
    resource AshEnterprise.Integration.Gmail
    resource AshEnterprise.Integration.Slack
  end
end
