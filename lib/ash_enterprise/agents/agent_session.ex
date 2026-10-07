defmodule AshEnterprise.Agents.AgentSession do
  @moduledoc """
  A persistent coding-agent session identity and lifecycle (dogfood §6).

  One row per (operator, workspace): the stable thing that outlives runs,
  terminal disconnects and process restarts. A run is a unit of work *inside*
  a session; approvals and messages hang off runs, never directly off the
  session.

  Base-resource opt-outs are the same shape as the E4 canonical resources and
  deliberate: `lifecycle?: false` because `status` below is this resource's own
  lifecycle (a Dataverse Active/Inactive pair beside it would be two answers to
  one question), and `archival?: false` because closing a session is a status
  transition (`:closed`), not a soft delete.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Agents,
    lifecycle?: false,
    archival?: false

  postgres do
    table "agents_sessions"
    repo AshEnterprise.Repo
  end

  attributes do
    uuid_primary_key :id

    attribute :title, :string do
      allow_nil? false
      public? true
      constraints max_length: 256

      description "Human-facing name: what this session is for."
    end

    attribute :status, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:active, :suspended, :closed]
      default :active

      description "active until suspended by an operator or closed for good."
    end

    attribute :workspace_path, :string do
      allow_nil? false
      public? true

      description """
      Absolute path the OMP process runs in — a repository checkout or an
      isolated worktree. The bridge `cd`s the port here; it is also the answer
      to "which tree did this agent touch".
      """
    end

    attribute :provider, :string do
      allow_nil? false
      public? true
      default "omp"
      constraints max_length: 64

      description "Which coding agent this session drives. Only omp is bridged today."
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  actions do
    defaults [:read]

    create :open do
      description "Opens a session for a workspace. The bridge reads workspace_path from here."

      accept [:title, :workspace_path, :provider]

      # Ownership is the operator who opened the session (see AccessRequest
      # :submit for why this is set here and not defaulted platform-wide).
      change set_attribute(:owner_id, actor(:id))
      change set_attribute(:owner_type, :user)
      change set_attribute(:owning_user_id, actor(:id))
    end

    update :suspend do
      description "An operator pauses the session. Live runs are cancelled separately."

      accept []

      validate attribute_equals(:status, :active) do
        message "only an active session can be suspended"
      end

      change set_attribute(:status, :suspended)
    end

    update :resume do
      description "Lifts a suspension."

      accept []

      validate attribute_equals(:status, :suspended) do
        message "only a suspended session can be resumed"
      end

      change set_attribute(:status, :active)
    end

    update :close do
      description "Closes the session for good. Runs and messages survive as history."

      accept []

      validate attribute_does_not_equal(:status, :closed) do
        message "the session is already closed"
      end

      change set_attribute(:status, :closed)
    end
  end

  code_interface do
    define :open, action: :open
    define :by_id, action: :read, get_by: [:id]
    define :suspend, action: :suspend
    define :resume, action: :resume
    define :close, action: :close
  end
end
