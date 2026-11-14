defmodule AshEnterprise.Platform.Resource do
  @moduledoc """
  The base resource. **Every resource in this application uses it.**

  This is where "batteries included" actually lives. Audit, telemetry,
  ownership, tenancy, soft delete and authorization are consequences of using
  this module — not per-resource chores that decay under deadline. See
  `docs/manifesto/04-batteries-are-inherited.md` for the argument.

      defmodule AshEnterprise.Accounts.Team do
        use AshEnterprise.Platform.Resource,
          domain: AshEnterprise.Accounts,
          cdm_entity: "Team"

        attributes do
          attribute :name, :string, allow_nil?: false, public?: true
        end
      end

  ## What that supplies

  | Concern | Source |
  |---|---|
  | Data layer | `AshPostgres.DataLayer` |
  | Authorization | `Ash.Policy.Authorizer` |
  | Ownership, provenance, lifecycle, concurrency, tenancy | `AshEnterprise.Platform.SystemAttributes` |
  | Audit | `AshEvents.Events` — one central log, see ADR 0002 |
  | Soft delete | `AshArchival.Resource` |
  | Admin UI | `AshAdmin.Resource` |

  ## Options

    * `:domain` — required, as for any Ash resource.
    * `:ownership` — `:user_owned` (default), `:business_owned`,
      `:organization_owned`, or `:none`. Mirrors Dataverse's OwnershipType and
      decides which authorization depths apply. See
      `AshEnterprise.Platform.SystemAttributes` for what each adds.
    * `:tenant?` — add `organization_id` and attribute multitenancy. Default `true`.
    * `:lifecycle?` — add `lifecycle_status` and the derived `state_code`/
      `status_code`. Default `true`.
    * `:state_machine?` — drive `lifecycle_status` with `AshStateMachine` and add
      its transition actions. Default `true`; off only for a strangled read model
      whose status is a read-only projection of a legacy value
      (`AshEnterprise.Platform.Verifiers.ProjectedLifecycle`).
    * `:cdm_entity` — provenance string, e.g. `"Team"`.
    * `:self_service` — actions any active tenant member may run on their own
      behalf with no role grant; see `AshEnterprise.Security.Checks.SelfService`
      and ADR 0052. Default `[]`.
    * `:human_only` — actions only a person may run: neither engine bypass nor
      the system-actor bypass reaches them, so only the caller's own grants
      can authorize one. Narrows bypasses; denies nothing. ADR 0059. Default `[]`.
    * `:changes_authority` — actions that change who may do what (role
      assignments, a role's privileges, team membership, a user's place in the
      hierarchy, a record share): the grant union does
      not apply to an automation principal on them. People, system actors and
      the engines are untouched. ADR 0043. Default `[]`.
    * `:machinery_only` — actions only the `oban` system actor may run: the
      system-actor bypass reaches them for `oban` alone, and the grant union
      does not apply to them. ADR 0059. Default `[]`.
    * `:engine_only` — actions only the process and decision engines may run: the
      engine bypasses reach them, the system-actor bypass does not, and the grant
      union does not apply to them. For rows other code trusts as the engines'
      own record. Default `[]`.
    * `:optimistic_lock?` — put `optimistic_lock(:version_number)` on every
      update action, so a write made from a stale copy of a row fails with
      `Ash.Error.Changes.StaleRecord` instead of overwriting the write it did
      not see, and `version_number` counts writes. Default `true`; off only for
      a strangled read model that projects `version_number` as a constant
      (`AshStrangler.Verifiers.VerifyOptimisticLock` refuses the lock on its
      writes while a view stands in for the table). ADR 0059.
    * `:secured_fields` — attributes a row grant does not hand over: Dataverse's
      secured columns, distinct from Ash's `sensitive?`, which only redacts logs. For
      each one the base writes a field policy authorizing a read only through a role
      granting `:read` on the column's own privilege, `"<Resource>#<field>"`, at a depth
      that reaches the row (`{AshEnterprise.Security.Checks.RoleGrant, field: name}`),
      plus `field_policy :*` authorizing every other field. Additive like every grant: no
      `forbid_if`, and the privilege catalogue writes the column's privilege at boot, so
      the Administrator holds it. Without the grant the value reads as
      `%Ash.ForbiddenField{}` and a filter on it matches nothing. Reads only: a write to
      the column follows the row grant. Verified by
      `AshEnterprise.Platform.Verifiers.SecuredFields`. Default `[]`.
    * `:audit?` — write to the central event log. Default `true`.
    * `:archival?` — soft delete. Default `true`.
    * `:lineage?` — emit an OpenLineage COMPLETE RunEvent on every successful
      write. Default `true`. Off only for the lineage store's own resources
      (`AshEnterprise.Lineage`): recording a run must not emit a run, or every
      write would feed itself.
    * `:api_type` — expose the resource over JSON:API and GraphQL under this
      type name, e.g. `:business_unit`. Omitting it (the default) means the
      resource has no public API surface at all. Exposure is opt-in per resource
      precisely so that adding an internal resource never publishes it by
      accident; the routes themselves are still declared in the domain.
    * `:policies?` — inherit the standard policy set from
      `AshEnterprise.Security.Policies`. Default `true`. Setting this to `false`
      does **not** make a resource public — with an authorizer and no policies,
      Ash denies everything. It exists for resources that must declare their own
      complete policy set, such as the security resources themselves. Either way
      the resource keeps the tenant boundary (`AshEnterprise.Security.TenantBoundary`).
    * `:extra_grants` — grant paths this resource adds to the inherited union
      (filter checks, each one more `authorize_if`). Additive only; see
      `AshEnterprise.Security.Policies`. Ignored with `policies?: false`.
    * `:authentication_plumbing?` — prepend the `ash_authentication` bypass on a
      resource that carries no `AshAuthentication` extension but is read or
      written by the sign-in machinery itself (API keys, the sign-in lockout
      counter). Those calls carry the private `ash_authentication?` context
      flag. Default `false`.
    * `:extra_extensions` — extensions to add on top (e.g. `AshStateMachine`).

  Anything else is passed through to `use Ash.Resource`.

  ## Opting out is explicit

  Uniformity that cannot be escaped becomes an obstacle, so the switches above
  exist. The rule is that opting out is **local and greppable** — `audit?: false`
  in a resource file is a decision someone made on purpose and can be reviewed
  in a diff. A resource that silently never had auditing is not.

  Two opt-outs are structural rather than preference: the audit log itself must
  set `audit?: false` or it recurses, and immutable reference data sets
  `archival?: false` because it is never deleted.
  """

  @doc false
  defmacro __using__(opts) do
    {ownership, opts} = Keyword.pop(opts, :ownership, :user_owned)
    {tenant?, opts} = Keyword.pop(opts, :tenant?, true)
    {lifecycle?, opts} = Keyword.pop(opts, :lifecycle?, true)
    {state_machine?, opts} = Keyword.pop(opts, :state_machine?, true)
    {cdm_entity, opts} = Keyword.pop(opts, :cdm_entity)
    {self_service, opts} = Keyword.pop(opts, :self_service, [])
    {human_only, opts} = Keyword.pop(opts, :human_only, [])
    {machinery_only, opts} = Keyword.pop(opts, :machinery_only, [])
    {engine_only, opts} = Keyword.pop(opts, :engine_only, [])
    {changes_authority, opts} = Keyword.pop(opts, :changes_authority, [])
    {optimistic_lock?, opts} = Keyword.pop(opts, :optimistic_lock?, true)
    {secured_fields, opts} = Keyword.pop(opts, :secured_fields, [])
    {audit?, opts} = Keyword.pop(opts, :audit?, true)
    {archival?, opts} = Keyword.pop(opts, :archival?, true)
    {lineage?, opts} = Keyword.pop(opts, :lineage?, true)
    {policies?, opts} = Keyword.pop(opts, :policies?, true)
    {extra_grants, opts} = Keyword.pop(opts, :extra_grants, [])
    {api_type, opts} = Keyword.pop(opts, :api_type)
    {extra_extensions, opts} = Keyword.pop(opts, :extra_extensions, [])
    {declared_extensions, opts} = Keyword.pop(opts, :extensions, [])
    {authentication_plumbing?, opts} = Keyword.pop(opts, :authentication_plumbing?, false)

    extensions =
      [
        AshEnterprise.Platform.SystemAttributes,
        AshAdmin.Resource,
        # ADR 0012: every platform resource emits OpenLineage
        # RunEvents on successful writes, through the host transport (which is
        # a silent no-op until `:http_base_url` is configured). Table-level
        # names only — the leak rule forbids actor/tenant/value facets.
        AshOpenLineage.Extension
      ]
      |> maybe_add(audit?, AshEvents.Events)
      |> maybe_add(archival?, AshArchival.Resource)
      |> maybe_add(not is_nil(api_type), AshJsonApi.Resource)
      |> maybe_add(not is_nil(api_type), AshGraphql.Resource)
      |> maybe_add(lifecycle? and state_machine?, AshStateMachine)
      |> Kernel.++(List.wrap(extra_extensions))
      |> Kernel.++(List.wrap(declared_extensions))
      |> Enum.uniq()

    # The caller wrote `extensions: [AshAuthentication]`, so what arrives here is
    # alias AST rather than the atom -- `AshAuthentication in extensions` is
    # silently false. Expanding against the caller's environment is what turns it
    # back into a module to compare against.
    authentication? =
      authentication_plumbing? or
        Enum.any?(
          List.wrap(extra_extensions) ++ List.wrap(declared_extensions),
          &(Macro.expand(&1, __CALLER__) == AshAuthentication)
        )

    resource_opts =
      opts
      |> Keyword.put_new(:data_layer, AshPostgres.DataLayer)
      |> Keyword.put_new(:authorizers, [Ash.Policy.Authorizer])
      |> Keyword.put(:extensions, extensions)

    # Recorded in the platform section so a tool can read a resource's exposure
    # from its declaration (`AshEnterprise.Governance.DataInventory`).
    api_type_declaration = api_type && quote(do: api_type(unquote(api_type)))

    quote do
      use Ash.Resource, unquote(resource_opts)

      # Fills the four provenance columns SystemAttributes declares. Outside the
      # `audit?` branch on purpose -- the columns come from being a platform
      # resource, not from being audited, so a resource with `audit?: false`
      # still records who created and last modified it.
      changes do
        change AshEnterprise.Platform.Changes.StampProvenance, on: [:create, :update]
      end

      unquote(version_lock(optimistic_lock?))

      platform do
        ownership(unquote(ownership))
        tenant?(unquote(tenant?))
        lifecycle?(unquote(lifecycle?))
        self_service(unquote(self_service))
        human_only(unquote(human_only))
        machinery_only(unquote(machinery_only))
        engine_only(unquote(engine_only))
        changes_authority(unquote(changes_authority))
        optimistic_lock?(unquote(optimistic_lock?))
        state_machine?(unquote(state_machine?))
        audit?(unquote(audit?))
        secured_fields(unquote(secured_fields))

        unquote(api_type_declaration)

        unquote(
          if cdm_entity do
            quote do: cdm_entity(unquote(cdm_entity))
          end
        )
      end

      lineage do
        transport(AshEnterprise.Lineage.Transport)

        unquote(
          unless lineage? do
            quote do: emit_on([])
          end
        )
      end

      unquote(
        if audit? do
          quote do
            events do
              event_log AshEnterprise.Audit.EventLog
            end

            changes do
              # Stamps the request's correlation id onto every audit event, so
              # the several rows one user action produces can be reconstructed
              # as one operation. Dataverse's audit.transactionid, essentially.
              change AshEnterprise.Platform.Changes.StampCorrelation,
                on: [:create, :update, :destroy]
            end
          end
        end
      )

      # Before every other policy, and with `policies?: false` too: an actor's
      # authority applies only in the tenant its context was built for.
      use AshEnterprise.Security.TenantBoundary

      unquote(
        if policies? do
          quote do
            use AshEnterprise.Security.Policies,
              authentication?: unquote(authentication?),
              extra_grants: unquote(extra_grants)
          end
        end
      )

      unquote(secured_field_policies(secured_fields))

      unquote(
        if api_type do
          quote do
            json_api do
              type unquote(to_string(api_type))
            end

            graphql do
              type unquote(api_type)
            end
          end
        end
      )

      unquote(
        if lifecycle? and state_machine? do
          lifecycle = AshEnterprise.Platform.Lifecycle

          transitions =
            for {action, from, to} <- lifecycle.transitions() do
              quote do
                transition unquote(action), from: unquote(from), to: unquote(to)
              end
            end

          # One update action per transition. Named after the transition rather
          # than being a generic `:update` that happens to set a field, so the
          # audit log records "deactivate" and not an anonymous update -- the
          # same argument as User.assign_to_business_unit.
          actions =
            for {action, _from, to} <- lifecycle.transitions() do
              quote do
                update unquote(action) do
                  description "Lifecycle transition. Guarded by the state machine."
                  accept []
                  require_atomic? false
                  # transition_state/1 takes the TARGET STATE, not the action
                  # name. Passing the action name yields the confusing
                  # "Attempted to change state to :deactivate ... no matching
                  # transition was configured".
                  change transition_state(unquote(to))
                end
              end
            end

          quote do
            state_machine do
              state_attribute :lifecycle_status
              initial_states [unquote(lifecycle.default_status())]
              default_initial_state unquote(lifecycle.default_status())

              transitions do
                (unquote_splicing(transitions))
              end
            end

            actions do
              (unquote_splicing(actions))
            end
          end
        end
      )
    end
  end

  defp maybe_add(list, true, extension), do: [extension | list]
  defp maybe_add(list, false, _extension), do: list

  # ADR 0059: `version_number` is an optimistic lock. Ash's own change, not an
  # increment: on a non-atomic update (every audited one -- the AshEvents wrapper
  # refuses atomics) an increment computes N+1 from the row each writer loaded, so two
  # writers both write N+1 and the second silently wins. The lock adds
  # `WHERE version_number = N` to the UPDATE, so the second writer matches no row and
  # gets a StaleRecord error.
  defp version_lock(false), do: nil

  defp version_lock(true) do
    quote do
      changes do
        change optimistic_lock(:version_number), on: [:update]
      end
    end
  end

  # Column security as grants (ADR 0073): each secured field is readable through a role
  # granting its own privilege, and every other field is as visible as the row. The
  # preparation sits on every platform resource, because a lookup by a secured column
  # can start from another resource, across a relationship.
  defp secured_field_policies([]) do
    quote do
      preparations do
        prepare AshEnterprise.Security.Preparations.SecuredFieldRefs
      end
    end
  end

  defp secured_field_policies(secured_fields) do
    field_policies =
      for field <- secured_fields do
        quote do
          field_policy unquote(field) do
            authorize_if {AshEnterprise.Security.Checks.RoleGrant, field: unquote(field)}
          end
        end
      end

    quote do
      unquote(secured_field_policies([]))

      field_policies do
        (unquote_splicing(field_policies))

        field_policy :* do
          authorize_if always()
        end
      end
    end
  end
end
