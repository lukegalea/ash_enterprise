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
    * `:lifecycle?` — add `state_code`/`status_code`. Default `true`.
    * `:cdm_entity` — provenance string, e.g. `"Team"`.
    * `:audit?` — write to the central event log. Default `true`.
    * `:archival?` — soft delete. Default `true`.
    * `:paper_trail?` — additionally keep a per-resource version table. Default
      `false`; see ADR 0002 for why running both is not the default.
    * `:api_type` — expose the resource over JSON:API and GraphQL under this
      type name, e.g. `:business_unit`. Omitting it (the default) means the
      resource has no public API surface at all. Exposure is opt-in per resource
      precisely so that adding an internal resource never publishes it by
      accident; the routes themselves are still declared in the domain.
    * `:policies?` — inherit the standard policy set from
      `AshEnterprise.Security.Policies`. Default `true`. Setting this to `false`
      does **not** make a resource public — with an authorizer and no policies,
      Ash denies everything. It exists for resources that must declare their own
      complete policy set, such as the security resources themselves.
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
    {cdm_entity, opts} = Keyword.pop(opts, :cdm_entity)
    {audit?, opts} = Keyword.pop(opts, :audit?, true)
    {archival?, opts} = Keyword.pop(opts, :archival?, true)
    {paper_trail?, opts} = Keyword.pop(opts, :paper_trail?, false)
    {policies?, opts} = Keyword.pop(opts, :policies?, true)
    {api_type, opts} = Keyword.pop(opts, :api_type)
    {extra_extensions, opts} = Keyword.pop(opts, :extra_extensions, [])
    {declared_extensions, opts} = Keyword.pop(opts, :extensions, [])

    extensions =
      [
        AshEnterprise.Platform.SystemAttributes,
        AshAdmin.Resource
      ]
      |> maybe_add(audit?, AshEvents.Events)
      |> maybe_add(archival?, AshArchival.Resource)
      |> maybe_add(paper_trail?, AshPaperTrail.Resource)
      |> maybe_add(not is_nil(api_type), AshJsonApi.Resource)
      |> maybe_add(not is_nil(api_type), AshGraphql.Resource)
      |> maybe_add(lifecycle?, AshStateMachine)
      |> Kernel.++(List.wrap(extra_extensions))
      |> Kernel.++(List.wrap(declared_extensions))
      |> Enum.uniq()

    # The caller wrote `extensions: [AshAuthentication]`, so what arrives here is
    # alias AST rather than the atom -- `AshAuthentication in extensions` is
    # silently false. Expanding against the caller's environment is what turns it
    # back into a module to compare against.
    authentication? =
      Enum.any?(
        List.wrap(extra_extensions) ++ List.wrap(declared_extensions),
        &(Macro.expand(&1, __CALLER__) == AshAuthentication)
      )

    resource_opts =
      opts
      |> Keyword.put_new(:data_layer, AshPostgres.DataLayer)
      |> Keyword.put_new(:authorizers, [Ash.Policy.Authorizer])
      |> Keyword.put(:extensions, extensions)

    quote do
      use Ash.Resource, unquote(resource_opts)

      platform do
        ownership(unquote(ownership))
        tenant?(unquote(tenant?))
        lifecycle?(unquote(lifecycle?))

        unquote(
          if cdm_entity do
            quote do: cdm_entity(unquote(cdm_entity))
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

      unquote(
        if policies? do
          quote do
            use AshEnterprise.Security.Policies,
              authentication?: unquote(authentication?)
          end
        end
      )

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
        if lifecycle? do
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
end
