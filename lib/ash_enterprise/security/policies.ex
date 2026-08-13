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

  ## What is not here yet

  **Hierarchy security** — the manager and position chains — is the third grant
  path in the model and is not implemented. It needs `manager_id` on User and a
  Position resource. Until then, managers get no implicit access to their
  reports' records; grant it explicitly with roles or shares.

  This is a gap, not a decision. It is tracked rather than quietly omitted,
  because the alternative — pretending the model is complete — is how a security
  architecture ends up with a hole nobody documented.
  """

  @doc """
  The quoted policy block injected into every platform resource.

  A macro rather than a shared module because Spark DSL sections are built at
  compile time into the resource's own DSL state; there is nothing to delegate to
  at runtime.
  """
  defmacro __using__(_opts) do
    quote do
      policies do
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
        end
      end
    end
  end
end
