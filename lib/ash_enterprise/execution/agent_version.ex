defmodule AshEnterprise.Execution.AgentVersion do
  @moduledoc """
  One version of an agent (ADR 0056): the `AshAgent.AgentVersion` fragment on the
  platform base, in table `exec_agent_versions`. A run pins a version's id, so what an
  agent was when it ran is this row, not whatever the code says now.

  ## What the fragment brings

  The attributes (`key`, `version`, plain-text `instructions`, `model_profile`,
  `toolset` with each target's digest, `limits`, `output_type`, `content_hash`,
  `authority`, `requesterless`, `baseline_id`), the one-way lifecycle `draft →
  published → retired`, the code sync (`register_from_code`), drafts, `apply_publish`,
  `retire`, `latest_published`, and the drift check a run makes before every step
  (`AshAgent.AgentVersion.Definition.check_pinned/1`). See the fragment's docs.

  ## What this resource adds

    * **Tenancy and ownership.** Tenant-scoped, organization-owned (reached at global
      depth by a role grant), audited, not temporal: versions are rows, as process and
      decision definitions are (ADR 0049). No soft delete; a version is retired, not
      deleted.
    * **Baselines.** Agents declared in code are registered into the platform
      organization (`register_from_code` as the `seed` system actor) as the baselines a
      tenant adopts. `fork_for_tenant` copies the key's latest baseline into the tenant
      as a draft (`baseline_id` records which), through
      `AshEnterprise.Process.Resolver.agent_baseline/1`, the named cross-tenant read; the
      same content again writes nothing. The platform organization has no people, so a
      baseline is never published there: a tenant publishes its own copy.
    * **Publishing is governed (ADR 0055).** `apply_publish` is a governed target
      (`AshAgent.Validations.Governed`): it runs only as its own invocation, and its
      effects declaration asks for four eyes, an administrator other than the person who
      asked. An organization whose only administrator is the requester may opt in to
      let them approve it themselves (`Organization.set_sole_administrator_approval`);
      the rule holds only while they are the sole administrator, and the approval is
      recorded as `approval_basis` `:sole_administrator`
      (`AshEnterprise.Execution.Approval`). `request_publish` asks for it through `invoke`
      (`AshEnterprise.Execution.Actions.RequestPublish`): it checks the draft first, so
      a draft that cannot be published opens no approval, and returns the request with
      its approval link. The approval binds the draft's `version_number`, so a draft
      revised while the approval waits goes stale. The publish then runs as the person
      who asked. Who the version's runs act as (the requester by default, or a named
      automation principal, ADR 0043) and whether they may start with no requester are
      arguments of the request, so the approver approves exactly those choices.
    * **Enabling an agent declared in code.** `enable_from_code`
      (`AshEnterprise.Execution.Actions.EnableFromCode`, `mix ash_enterprise.assistant.enable`
      for the assistant) registers the baseline, forks it and requests the publish, and
      on a second run reports where things stand instead of asking again.
    * **What else a publish requires here** (`AshEnterprise.Execution.Validations.Publishable`):
      the in-zone model profile (ADR 0042) and, for an automation authority, a principal
      this build declares (`AshEnterprise.Platform.AutomationPrincipal`).
    * **Authority.** Publishing chooses an agent's authority, so neither
      `request_publish` nor `apply_publish` reaches an automation principal through the
      grant union (`changes_authority`, ADR 0043): an agent never publishes an agent.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Execution,
    ownership: :organization_owned,
    lifecycle?: false,
    archival?: false,
    changes_authority: [:request_publish, :apply_publish, :enable_from_code],
    extra_extensions: [AshAgent.Effects],
    fragments: [AshAgent.AgentVersion]

  postgres do
    table "exec_agent_versions"
    repo AshEnterprise.Repo
  end

  actions do
    # What a person (or a tool) calls: a request for `apply_publish`, waiting on a
    # second administrator.
    action :request_publish, :map do
      description """
      Ask for a draft to be published. Nothing changes until an administrator other than
      the requester approves it; it then runs as the requester.
      """

      argument :record_id, :uuid, allow_nil?: false, public?: true

      argument :authority, :map do
        public? true

        description """
        Who the version's runs act as: `%{"type" => "requester"}` (the default) or
        `%{"type" => "automation", "name" => principal}`.
        """
      end

      argument :requesterless, :boolean do
        public? true

        description "Whether a run may start with no person asking. Only with an automation authority."
      end

      run AshEnterprise.Execution.Actions.RequestPublish
    end

    # The steps that turn a code agent on in a tenant, up to the request: never the
    # approval, never a start grant (`AshEnterprise.Execution.Actions.EnableFromCode`).
    action :enable_from_code, :map do
      description """
      Register an agent declared in code as a platform baseline, copy it into this tenant
      and ask for it to be published, unless that is already done or already asked.
      Approving the request and giving start grants remain people's acts.
      """

      argument :agent, :atom do
        allow_nil? false
        public? true
        description "The agent module (`use AshAgent.Agent`)."
      end

      run AshEnterprise.Execution.Actions.EnableFromCode
    end

    action :fork_for_tenant, :struct do
      description """
      Copy the latest platform baseline of `key` into this tenant as a draft, or return the
      tenant's latest version when it already holds that content.
      """

      constraints instance_of: __MODULE__
      argument :key, :string, allow_nil?: false, public?: true
      run AshEnterprise.Execution.Actions.ForkAgentVersion
    end
  end

  validations do
    # Publishing is a governed target (ADR 0055): it runs only as its invocation.
    validate {AshAgent.Validations.Governed, invocation: AshEnterprise.Execution.Invocation},
      on: :update,
      where: action_is(:apply_publish)

    validate AshEnterprise.Execution.Validations.Publishable,
      on: :update,
      where: action_is(:apply_publish)
  end

  # Publishing decides what an agent may do and who it acts as, so it waits for a
  # second administrator (ADR 0055, 0056). `request_publish` only invokes it.
  effects do
    action :apply_publish,
      kind: :edit,
      destructive?: false,
      open_world?: false,
      approval: :four_eyes,
      approver_role: :administrator,
      approval_expires_in: [days: 7],
      intent: :approve

    action :request_publish,
      kind: :edit,
      destructive?: false,
      open_world?: false,
      intent: :propose
  end
end
