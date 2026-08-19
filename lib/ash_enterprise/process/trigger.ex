defmodule AshEnterprise.Process.Trigger do
  @moduledoc """
  A declaration that something happening should start a process.

  Versioned and immutable once published, copying the discipline `AshBpmn.Resources.Definition`
  uses, because a trigger is as much a deployed artifact as a process is: it decides what the
  system does in response to a write, and "which version of that rule was in force in March"
  is a question someone will ask.

  ## The three-stage funnel

  Matching is deliberately layered, because stages one and two run against *every* audited
  write in a matching resource and stage three is the expensive one:

    1. **Match** — a structural comparison on resource, action and action type. No evaluation.
    2. **Guard** — a FEEL boolean over the event context. In-process, no I/O. Where "only
       requests over five thousand" lives.
    3. **Route** — a DMN decision naming the process key and its variables.

  ## `enabled` is not `status`, and disabling is not retroactive

  Retiring a version is a deployment act. Switching a misfiring trigger off at two in the
  morning is an operational one, and conflating them means the only way to stop a bad trigger
  is to publish a new version of it.

  **Disabling does not un-fire what is already behind the cursor.** Events that arrived while
  the trigger was enabled will still be dispatched when the sweep reaches them. That is the
  opposite of what everyone assumes and is stated here rather than discovered.

  ## It may not match a process or a decision

  `AshEnterprise.Bpmn.Definition` and `AshEnterprise.Bpmn.HumanTask` carry the audit hook,
  because publishing a process and deciding a task are governance events. So a process started
  by a trigger writes audit events, and those are trigger inputs — a trigger matching one would
  feed itself.

  Refused at publish time, by name. The alternative was to rely on triggers happening to be
  filtered narrowly enough, which is "probably terminates" dressed as a design.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Process,
    ownership: :organization_owned,
    lifecycle?: false,
    audit?: true,
    archival?: false

  postgres do
    table "process_triggers"
    repo AshEnterprise.Repo
  end

  attributes do
    uuid_primary_key :id

    attribute :key, :string do
      allow_nil? false
      public? true
      description "A stable name, e.g. \"access_request.submitted\"."
    end

    attribute :version, :integer do
      allow_nil? false
      default 1
      writable? false
      public? true
    end

    attribute :status, :atom do
      allow_nil? false
      default :draft
      constraints one_of: [:draft, :published, :retired]
      writable? false
      public? true
    end

    attribute :enabled, :boolean do
      allow_nil? false
      default true
      public? true
      description "Operational switch. Not retroactive -- see the moduledoc."
    end

    attribute :match_resource, :string do
      allow_nil? false
      public? true
      description "The resource module name, as the audit log records it. The indexed key."
    end

    attribute :match_action, :string do
      public? true
      description "Nil matches any action on the resource."
    end

    attribute :match_action_type, :atom do
      constraints one_of: [:create, :update, :destroy]
      public? true
      description "Nil matches any action type."
    end

    attribute :guard_feel, :string do
      public? true
      description "A FEEL boolean over the event context. Nil always passes."
    end

    attribute :decision_key, :string do
      public? true
      description "The DMN decision that chooses the process and its variables."
    end

    attribute :process_key, :string do
      public? true
      description "Used when no decision is named. One of the two must be set."
    end

    attribute :variable_mapping, :map do
      allow_nil? false
      default %{}
      public? true
      description "Process-variable name to FEEL expression over the event context."
    end

    attribute :max_starts_per_event, :integer do
      allow_nil? false
      default 1
      public? true

      description """
      Bounds fan-out when a routing decision uses a COLLECT hit policy. Exceeding it fails the
      dispatch: refusing loudly beats starting fifty thousand processes from one write.
      """
    end
  end

  identities do
    identity :unique_key_version, [:key, :version]
  end

  validations do
    validate {AshEnterprise.Process.Trigger.Validations.HasATarget, []},
      on: [:create],
      message: "a trigger needs either a process_key or a decision_key"

    validate {AshEnterprise.Process.Trigger.Validations.NotSelfTriggering, []}, on: [:create]

    # The other way a trigger silently never fires: watching something that writes no events.
    validate {AshEnterprise.Process.Trigger.Validations.MatchesAnAuditedResource, []},
      on: [:create]
  end

  actions do
    defaults [:read]

    create :create do
      accept [
        :key,
        :match_resource,
        :match_action,
        :match_action_type,
        :guard_feel,
        :decision_key,
        :process_key,
        :variable_mapping,
        :max_starts_per_event,
        :enabled
      ]

      change AshEnterprise.Process.Trigger.Changes.NormalizeMatchResource
      change AshEnterprise.Process.Trigger.Changes.AssignVersion
    end

    update :publish do
      accept []
      require_atomic? false
      validate attribute_equals(:status, :draft), message: "only a draft can be published"
      change set_attribute(:status, :published)

      # Establish the tenant's cursor now, at the current high-water mark. Without this the
      # first sweep would create it, and everything between publishing and that sweep would
      # fall in the gap -- or, worse, a cursor created at zero would walk the whole history and
      # start a process for every matching event that ever happened.
      change AshEnterprise.Process.Trigger.Changes.EnsureCursor
    end

    update :retire do
      accept []
      require_atomic? false

      validate attribute_equals(:status, :published),
        message: "only a published trigger can be retired"

      change set_attribute(:status, :retired)
    end

    # Separate from publish/retire on purpose: an operational switch, not a deployment act.
    update :set_enabled do
      accept [:enabled]
    end

    read :published do
      filter expr(status == :published and enabled == true)
    end
  end

  code_interface do
    define :create
    define :publish
    define :retire
    define :set_enabled, args: [:enabled]
    define :published
  end
end
