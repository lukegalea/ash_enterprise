defmodule AshEnterprise.Agents.AgentMessage do
  @moduledoc """
  One transcript line of a run (dogfood §6): the user's prompt, agent output
  streamed off the port, and tool traffic.

  `role :tool` carries tool requests the bridge forwards into pending
  `AshEnterprise.Agents.ToolInvocation` rows *and* bridge/runtime diagnostics
  (a missing binary, a nonzero exit) — anything spoken by the machinery rather
  than by the model or the operator.

  Append-only: transcript rows are never edited or soft-deleted; the run's
  terminal status is the record. `archival?: false`/`lifecycle?: false` for
  the same reason.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Agents,
    lifecycle?: false,
    archival?: false

  postgres do
    table "agent_messages"
    repo AshEnterprise.Repo
  end

  attributes do
    uuid_primary_key :id

    attribute :role, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:user, :agent, :tool]

      description """
      :user for the prompt, :agent for model output, :tool for tool requests
      and bridge diagnostics.
      """
    end

    attribute :text, :string do
      allow_nil? false
      public? true

      description "The line, verbatim: JSON-decoded text when the line carried it, raw line otherwise."
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :run, AshEnterprise.Agents.AgentRun do
      allow_nil? false
      public? true

      description "The run this line belongs to."
    end
  end

  actions do
    defaults [:read]

    read :for_run do
      description "The run's transcript in arrival order."

      argument :run_id, :uuid, allow_nil?: false

      filter expr(run_id == ^arg(:run_id))
      prepare build(sort: [inserted_at: :asc])
    end

    create :append do
      description "Appends one transcript line. Called by the bridge and by start_run's prompt record."

      # The bridge inherits the run's owner onto transcript rows, so a Basic
      # depth grant reaches the transcript through the same owner_id column
      # as the run itself.
      accept [:run_id, :role, :text, :owner_id, :owning_user_id]
    end
  end

  code_interface do
    define :append, action: :append
    define :for_run, action: :for_run, args: [:run_id]
  end
end
