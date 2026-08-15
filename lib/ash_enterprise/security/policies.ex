defmodule AshEnterprise.Security.Policies do
  @moduledoc """
  The policy set every platform resource inherits.

  Injected by `AshEnterprise.Platform.Resource`, so authorization is a property of
  being a resource rather than something each one remembers to declare — see
  `docs/manifesto/04-batteries-are-inherited.md`.

  ## The shape, and why it looks like this

  ```elixir
  policies do
    bypass AshEnterprise.Security.Checks.SystemActor do
      authorize_if always()
    end

    policy always() do
      authorize_if AshEnterprise.Security.Checks.RoleGrant
      authorize_if AshEnterprise.Security.Checks.SharedWithActor
    end
  end
  ```

  Each `authorize_if` is **one grant path**. Ash evaluates them top to bottom and
  stops at the first decisive result, which makes the sequence a union — exactly
  the additive model Dataverse specifies:

  > *"all privilege grants are accumulative with the greatest amount of access
  > prevailing."*

  ### The rule that matters most

  **Never add `forbid_if` here, or to any resource, for row access.** A single
  `forbid_if` breaks additivity and reintroduces order-dependence, at which point
  no grant can be reasoned about in isolation and every new rule potentially
  interacts with every existing one.

  `forbid_if` is legitimate only for concerns that are not row access at all — a
  disabled account, a decommissioned tenant — and those belong in a bypass or a
  plug, not in the per-record union.

  ### Fail closed

  If no path authorizes, access is denied. A resource with no grants is
  unreachable rather than public, which is the correct default for a system whose
  whole point is access control.

  ## Hierarchy security is off by default

  The third grant path (`AshEnterprise.Security.Checks.HierarchyGrant`) is wired
  in but contributes nothing until enabled:

      config :ash_enterprise, :hierarchy_security, mode: :manager

  It is opt-in because switching it on widens access for everyone who has a
  report, without changing a single role — which is exactly the kind of change
  that should be deliberate. See `AshEnterprise.Security.Hierarchy`.
  """

  @doc """
  The quoted policy block injected into every platform resource.

  A macro rather than a shared module because Spark DSL sections are built at
  compile time into the resource's own DSL state; there is nothing to delegate to
  at runtime.

  ## Options

    * `:authentication?` — prepend the `ash_authentication` bypass. Set
      automatically by `AshEnterprise.Platform.Resource` when the resource carries
      the `AshAuthentication` extension. It has to be prepended here rather than
      declared on the resource, because policy order is declaration order and this
      set is injected first.
  """
  defmacro __using__(opts) do
    authentication? = Keyword.get(opts, :authentication?, false)

    quote do
      policies do
        unquote(
          if authentication? do
            quote do
              # Must come first, and cannot live in the resource's own `policies`
              # block. Policies are evaluated in declaration order and this set is
              # injected by `use`, so anything the resource declares itself lands
              # *after* the grant union below -- which forbids a nil actor and
              # collapses the read to `filter false`. Sign-in never reaches the
              # password check; the query is skipped and the failure presents as
              # "Email or password was incorrect".
              #
              # The check is narrow: it passes only for interactions
              # ash_authentication itself initiates, which is why granting them
              # everything is safe.
              bypass AshAuthentication.Checks.AshAuthenticationInteraction do
                authorize_if always()
              end
            end
          end
        )

        # Non-human actors bypass the role model entirely. They are not given a
        # superuser role, because a role would appear in the admin UI as
        # something an administrator could revoke -- and revoking it would break
        # background processing in a way that looks like a permissions bug rather
        # than a configuration change. Every such write is still attributed; see
        # AshEnterprise.Platform.SystemActor.
        bypass AshEnterprise.Security.Checks.SystemActor do
          authorize_if always()
        end

        # The union. Each clause is one grant path; any one succeeding is
        # sufficient; none of them ever subtracts.
        policy always() do
          authorize_if AshEnterprise.Security.Checks.RoleGrant
          authorize_if AshEnterprise.Security.Checks.SharedWithActor
          authorize_if AshEnterprise.Security.Checks.HierarchyGrant
        end
      end
    end
  end
end
