defmodule AshEnterprise.Execution.Entry do
  @moduledoc """
  One thing that happened in a piece of work, as an operator follows it: computed, never
  stored. `trace` reads every source registered in `AshEnterprise.ExecutionSources` and
  answers the work's entries in the order they happened, so evidence, the judgment on it,
  the decision and its rule, the approval, each attempt and the effect read as one line.

  ## An entry

  The fields `AshAgent.Execution.Source` defines (`at`, `kind`, `status`, `blocked_on`,
  `source_ref`, `parent_ref`, `definition_ref`, `actor_label`, `cost`, `recorded?`,
  `summary`) and `source`, the name of the source it came from. `status` is one of the
  six shared statuses (`AshAgent.Execution.Status`); `recorded?` false reads as "not
  recorded", never as empty.

  ## `trace`

  Takes a `correlation_id`, or a `root_ref` (`"run:<id>"`, `"invocation:<id>"`,
  `"process_instance:<id>"`), and optionally `cursors`, the cursors a previous trace
  returned, by source name, to read the next page of those sources. Answers
  `%{entries: [entry], sources: [report]}`: the entries, oldest first, and for each source
  whether it was read whole (`complete`), has more (`more`, with its cursor), or could not
  be read (`failed`, `timed_out`, `unanswered`, with why). A source that could not be read
  also gives an `uncertain`, unrecorded entry of its own, so the gap shows on the timeline.

  ## Read as the viewer

  Every source reads through its resource's own read action as the caller, in the
  caller's tenant: a row the caller may not read is not in the trace and is not counted.
  Entries carry structure only (statuses, references, keys, rule ids, tool names);
  arguments, results, messages, judged text and decision inputs stay sealed in their
  records. `trace` is self-service (ADR 0052) because everything it answers came out of
  reads made as the caller; a read declared self-service here would be filtered on an
  owner this resource does not have.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Execution,
    data_layer: Ash.DataLayer.Simple,
    ownership: :none,
    tenant?: false,
    lifecycle?: false,
    archival?: false,
    audit?: false,
    self_service: [:trace]

  resource do
    require_primary_key? false
  end

  attributes do
    attribute :at, :utc_datetime_usec, public?: true, allow_nil?: false

    attribute :kind, :atom do
      public? true
      allow_nil? false
      constraints one_of: AshAgent.Execution.Source.kinds()
    end

    attribute :status, :atom do
      public? true
      allow_nil? false
      constraints one_of: AshAgent.Execution.Status.statuses()
    end

    attribute :blocked_on, :atom, public?: true
    attribute :source, :atom, public?: true
    attribute :source_ref, :string, public?: true, allow_nil?: false
    attribute :parent_ref, :string, public?: true
    attribute :definition_ref, :string, public?: true
    attribute :actor_label, :string, public?: true
    attribute :cost, :map, public?: true
    attribute :recorded?, :boolean, public?: true, allow_nil?: false, default: true
    attribute :summary, :string, public?: true
  end

  actions do
    action :trace, :map do
      description "What happened in one piece of work, in order, as the caller may read it."

      constraints fields: [
                    entries: [
                      type: {:array, :struct},
                      allow_nil?: false,
                      constraints: [items: [instance_of: __MODULE__]]
                    ],
                    sources: [type: {:array, :map}, allow_nil?: false]
                  ]

      argument :correlation_id, :string

      argument :root_ref, :string do
        constraints match: ~r/\A[a-z_]+:[0-9a-fA-F-]{36}\z/
      end

      argument :cursors, :map, default: %{}

      validate present([:correlation_id, :root_ref], exactly: 1) do
        message "give a correlation id or a root reference, not both"
      end

      run AshEnterprise.Execution.Entry.Trace
    end
  end
end
