defmodule AshEnterprise.Security.TenantBoundary do
  @moduledoc """
  The one policy every platform resource carries, whether it inherits the standard
  set (`AshEnterprise.Security.Policies`) or declares its own with `policies?: false`:
  a call naming a tenant other than the one the actor's context was built for is
  refused.

      policies do
        policy AshEnterprise.Security.Checks.ForeignTenant do
          authorize_if never()
        end
      end

  ## Why it is not part of the standard set

  Resources that declare their own policy set (the MDM and System One resources, the
  erasure keys, lineage) copy the grant union by hand, and a hand-copied set is one a
  new rule never reaches. The tenant boundary is not a grant and not a choice a
  resource makes: a context's grants were read in one tenant and mean nothing in
  another. So `AshEnterprise.Platform.Resource` injects it ahead of everything else,
  on every resource.

  ## Why it changes nothing else

  Nothing passes the policy, and it applies only to a call in a foreign tenant
  (`AshEnterprise.Security.Checks.ForeignTenant`). Every other call is decided by
  the resource's bypasses and grant union exactly as before. A policy that applied
  to every call and passed would not be neutral: Ash authorizes an action when every
  policy that applies to it passes, so it would open actions no other policy applies
  to, such as a `machinery_only` one.

  It is first because a bypass skips only the policies declared after it. A system
  actor is never foreign, so its bypass still reaches every tenant.

  It is not a `forbid_if` and not row access: it does not ask which records the
  actor may reach, only whether the actor's authority applies in this tenant at all
  (the decommissioned-tenant kind of concern `docs/manifesto/03-authorization-is-data.md`
  sets apart from the union).
  """

  defmacro __using__(_opts) do
    quote do
      policies do
        policy AshEnterprise.Security.Checks.ForeignTenant do
          description "An actor's authority applies only in the tenant its context was built for."
          authorize_if never()
        end
      end
    end
  end
end
