defmodule AshEnterprise.Security.Policies do
  @moduledoc """
  The policy set every platform resource inherits.

  Injected by `AshEnterprise.Platform.Resource`, so authorization is a property of
  being a resource rather than something each one remembers to declare — see
  `docs/manifesto/04-batteries-are-inherited.md`.

  ## The shape, and why it looks like this

  ```elixir
  policies do
    # The process and decision engines, which must precede everything else -- see the
    # comment in `__using__/1` for why a bypass only covers what follows it.
    bypass AshBpmn.Checks.AshBpmnInteraction do
      authorize_if always()
    end

    bypass AshDecisions.Checks.AshDecisionsInteraction do
      authorize_if always()
    end

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

        # The two engines, and why they are *first*.
        #
        # Ash folds a resource's policies into one boolean expression in which a bypass
        # contributes a disjunct covering the policies declared *after* it -- so a bypass
        # skips only what follows. This policy set is injected by `use`, ahead of anything a
        # resource adds for itself, which means an engine bypass declared by `ash_bpmn` on its
        # own resources lands second and never fires. A work item sitting on this base
        # resource would refuse the engine that has to write it.
        #
        # ADR 0009 gives two ways out and this is the one it prefers. The alternative --
        # `config :ash_bpmn, engine_actor: {AshEnterprise.Platform.SystemActor, :system, []}`
        # -- needs no change here at all, because the `SystemActor` bypass below already
        # admits it. It is rejected for the reason the audit log exists: it attributes *every*
        # engine write to a system actor, so the human who approved survives only in
        # `decided_by_id` and its siblings, and "who did this" stops being answerable from the
        # trail alone.
        #
        # Keeping the human actor is the whole point. Ownership, provenance and the audit
        # entry all derive from it, so a task completed by a manager is recorded as completed
        # by that manager rather than by "the engine".
        #
        # These checks are narrow by construction: each passes only for calls its own package
        # marked with a private context flag, which is what makes the engine's authority one
        # named, greppable, testable thing in the policy set rather than ninety anonymous
        # `authorize?: false` options. The packages' own docs are honest that this is not a
        # *stronger* boundary than the option it replaced -- anything that can set private
        # context could have passed the option -- and that honesty is why it is worth having:
        # a host reading a resource's policies can see the engine path and replace it.
        bypass AshBpmn.Checks.AshBpmnInteraction do
          authorize_if always()
        end

        bypass AshDecisions.Checks.AshDecisionsInteraction do
          authorize_if always()
        end

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
