defmodule AshEnterprise.Execution.ReleaseManifest do
  @moduledoc """
  A release (ADR 0058): an immutable set of the things that were tested together, named by
  digest, and the one pointer that says which set is live. In table
  `exec_release_manifests`.

  `AshBpmn` pins a process, `Process.Binding` pins one definition of a key, a band table is
  pinned by its publication. Nothing else pinned a set of processes, decisions, agents and
  tools that were tested together; this does.

  ## Lifecycle

      draft ── resolve ──▶ resolved ── request_release ──▶ requested ── promote ──▶ active
                                │ (the gate refuses: stays resolved,                │
                                │  with its gate_result)                  supersede / rollback
                                                                                    ▼
                                                              superseded ⇄ active, or rolled_back

    * **`draft`** names what the release is to contain: `requests`, each a `kind` (see
      `AshEnterprise.Execution.Release.Entries`) and a `key`. Numbered after the key's latest
      version; the person drafting is its author.
    * **`resolve`** pins the latest published of each request to an entry, an in-toto
      `ResourceDescriptor`, and records `manifest_digest`: the SHA-256 of the RFC 8785
      canonical JSON of the entries, ordered by kind and name. Entries are not written again.
    * **`request_release`** (the author only) runs the gate
      (`AshEnterprise.Execution.Release.Gate`) and records its result. A manifest that fails
      the gate stays `resolved` with the reasons in `gate_result`; one that passes is
      `requested`, and a four-eyes approval is asked for `promote`, from an administrator
      other than the author (the same rule as publishing an agent). The approval binds the
      manifest's `version_number`.
    * **`promote`** is a governed target (`AshAgent.Validations.Governed`): it runs only as
      its approved invocation, as the author. It re-checks the entries, becomes the one
      active manifest of its key (`identity :one_active`; the manifest it replaces is
      `superseded`) and binds each process and decision entry
      (`AshEnterprise.Execution.Release.Bindings`).
    * **`rollback`** makes an earlier `superseded` manifest active again, without a new
      approval, since it passed the gate and was approved when it was promoted. It re-checks
      the entries first: a manifest whose agent has since been retired cannot be rolled back
      to. The manifest it replaces is `rolled_back`.
    * **`export_attestation`** is the manifest as an in-toto Statement v1
      (`AshEnterprise.Execution.Release.Attestation`).

  ## What a release pins

  An instance of a process records the active manifest that covers its process as
  `release_manifest_id` when it starts and evaluates the decisions that manifest pins, so a
  decision published later does not move a case already running. An invocation records the
  manifest that covers its target and an approval binds the manifest's digest
  (`AshEnterprise.Execution.Manifests`).

  Organization-owned and audited. Neither `request_release`, `promote` nor `rollback` reaches
  an automation principal: an agent never releases itself.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Execution,
    ownership: :organization_owned,
    lifecycle?: false,
    archival?: false,
    changes_authority: [:draft, :resolve, :request_release, :check_gate, :promote, :rollback],
    machinery_only: [:supersede],
    extra_extensions: [AshStateMachine, AshAgent.Effects]

  alias AshEnterprise.Execution.{Actions, Changes, Release}
  alias AshEnterprise.Quality.Changes.NextVersion

  postgres do
    table "exec_release_manifests"
    repo AshEnterprise.Repo
    identity_wheres_to_sql one_active: "status = 'active'"
  end

  state_machine do
    state_attribute :status
    initial_states [:draft]
    default_initial_state :draft

    transitions do
      transition :resolve, from: :draft, to: :resolved
      transition :check_gate, from: [:resolved, :requested], to: :requested
      transition :promote, from: :requested, to: :active
      transition :supersede, from: :active, to: [:superseded, :rolled_back]
      transition :rollback, from: :superseded, to: :active
    end
  end

  actions do
    defaults [:read]

    read :active do
      description "The manifests that are live in the tenant, one for each key."
      filter expr(status == :active)
    end

    create :draft do
      description "A new draft of the release keyed `key`, numbered after its latest version."
      accept [:key, :requests]

      change set_attribute(:author_id, actor(:id))
      change NextVersion
      validate Release.Requests
    end

    update :resolve do
      description "Pin the latest published of each request, and take the digest of the result."
      accept []
      require_atomic? false

      change transition_state(:resolved)
      change Changes.ResolveEntries
    end

    # Runs the gate and keeps its result. Not for people to call: `request_release` does,
    # because a refusal must leave its reasons behind, which a failed action cannot.
    update :check_gate do
      description "Run the release gate; a manifest that passes is requested."
      accept []
      require_atomic? false

      change Changes.RunGate
    end

    # What a person calls: the gate, then a request for `promote` waiting on a second
    # administrator.
    action :request_release, :map do
      description """
      Ask for a resolved manifest to be released. The gate runs first, and a manifest that
      fails it stays as it is with the reasons recorded. One that passes opens an approval,
      which an administrator other than its author must grant; it then runs as the author.
      """

      argument :record_id, :uuid, allow_nil?: false, public?: true
      run Actions.RequestRelease
    end

    update :promote do
      description "Make the manifest the active one of its key. Only through its approved invocation."
      accept []
      require_atomic? false

      change transition_state(:active)
      change set_attribute(:promoted_at, &DateTime.utc_now/0)
      change {Changes.Activate, replaced: :superseded}
    end

    update :supersede do
      description "Retire the manifest a newer one replaces: `superseded`, or `rolled_back`."
      accept []
      require_atomic? false

      argument :to, :atom, allow_nil?: false, constraints: [one_of: [:superseded, :rolled_back]]
      change Changes.Retire
    end

    update :rollback do
      description "Make an earlier, superseded manifest the active one of its key again."
      accept []
      require_atomic? false

      change transition_state(:active)
      change set_attribute(:promoted_at, &DateTime.utc_now/0)
      change {Changes.Activate, replaced: :rolled_back}
    end

    action :export_attestation, :map do
      description "The manifest as an in-toto Statement v1."
      argument :record_id, :uuid, allow_nil?: false, public?: true
      run Actions.ExportAttestation
    end
  end

  validations do
    # Promotion is a governed target (ADR 0055): it runs only as its invocation.
    validate {AshAgent.Validations.Governed, invocation: AshEnterprise.Execution.Invocation},
      on: :update,
      where: action_is(:promote)
  end

  attributes do
    uuid_primary_key :id

    attribute :key, :string do
      allow_nil? false
      public? true
      constraints max_length: 255

      description "The release line, `clinic.credentialing`: one manifest of it is active at a time."
    end

    attribute :version, :integer do
      allow_nil? false
      public? true
      constraints min: 1
    end

    attribute :requests, {:array, :map} do
      allow_nil? false
      public? true
      default []

      description ~s(What the release is to contain: `%{"kind" => "agent", "key" => "clinic.triager"}`.)
    end

    attribute :entries, {:array, :map} do
      allow_nil? false
      public? true
      default []
      description "The `ResourceDescriptor`s the requests resolved to, set once, when resolved."
    end

    attribute :manifest_digest, :string do
      public? true
      description "SHA-256 of the RFC 8785 canonical JSON of the entries, set when resolved."
    end

    attribute :gate_result, :map do
      public? true
      description "What the release gate found, and the suite runs it rests on."
    end

    attribute :suite_run_ids, {:array, :uuid} do
      allow_nil? false
      public? true
      default []
    end

    attribute :author_id, :uuid do
      allow_nil? false
      public? true
      description "The person who drafted it. The approval excludes them."
    end

    attribute :promoted_at, :utc_datetime_usec, public?: true
  end

  identities do
    identity :unique_version, [:key, :version]
    identity :one_active, [:key], where: expr(status == :active)
  end

  # Releasing decides which agent, tools and rules run, so it waits for a second
  # administrator (ADR 0055, 0058). `request_release` only invokes it.
  effects do
    action :promote,
      kind: :edit,
      destructive?: false,
      open_world?: false,
      approval: :four_eyes,
      approver_role: :administrator,
      approval_expires_in: [days: 7],
      intent: :approve

    action :request_release,
      kind: :edit,
      destructive?: false,
      open_world?: false,
      intent: :propose
  end
end
