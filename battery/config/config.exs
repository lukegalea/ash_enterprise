import Config

# Ash house config — same choices every substrate suite makes.
config :ash, default_string_length_count: :codepoints
config :ash, :validate_domain_config_inclusion?, false
config :ash, :validate_domain_resource_inclusion?, false

# The battery's domains: the reference instantiation (Battery.Domain) plus
# the package-owned domains the concrete package resources belong to.
config :ash, ash_domains: [Battery.Domain, AshEvidence.Domain, AshCompliance.Domain]

# ash_compliance binds its repo (and table prefix) at COMPILE time — this
# must live in config.exs so the dep compiles against the battery's repo.
# See the ash_compliance host-wiring checklist.
config :ash_compliance, :repo, Battery.Repo
config :ash_compliance, :table_prefix, "ash_compliance_"

# Same compile-time binding for the projections engine's internal
# resources (checkpoints, dead letters, registry).
config :ash_events_projections, :repo, Battery.Repo

# The BPMN engine's three seams, wired to battery doubles. The decision
# resolver here is REAL: it routes business-rule tasks into ash_decisions.
# Scenario 2 overrides it with the recording variant via Application env.
config :ash_bpmn,
  assignment_resolver: Battery.Bpmn.Resolver,
  action_invoker: Battery.Bpmn.Invoker,
  ash_domains: [Battery.Domain],
  queue: :bpmn,
  max_attempts: 5

# Formatter only: the same Spark.Formatter settings as the root
# config/config.exs. The root's commit hook formats battery files with the
# root's config, so the battery's own `mix format` must agree with it or the
# two rewrite each other (section order, DSL parens).
config :spark,
  formatter: [
    remove_parens?: true,
    "Ash.Resource": [
      section_order: [
        :rate_limit,
        :graphql,
        :json_api,
        :admin,
        :authentication,
        :token,
        :user_identity,
        :postgres,
        :resource,
        :code_interface,
        :actions,
        :policies,
        :pub_sub,
        :preparations,
        :changes,
        :validations,
        :multitenancy,
        :attributes,
        :relationships,
        :calculations,
        :aggregates,
        :identities
      ]
    ],
    "Ash.Domain": [
      section_order: [
        :graphql,
        :json_api,
        :admin,
        :resources,
        :policies,
        :authorization,
        :domain,
        :execution
      ]
    ]
  ]

import_config "#{config_env()}.exs"
