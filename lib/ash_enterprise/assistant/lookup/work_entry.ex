defmodule AshEnterprise.Assistant.Lookup.WorkEntry do
  @moduledoc """
  One thing that happened in a piece of work, as the assistant answers "what happened"
  and "why": a row over `AshEnterprise.Execution.Entry`, read as the person.

  Two tools read these rows (`AshEnterprise.Assistant` declares them):

    * `trace` — every entry of one piece of work, oldest first, from a record's
      reference or a correlation id;
    * `explain` — one record (`subject`), what its status means and what it waits on,
      and the entries under it.

  Both are computed reads (`AshEnterprise.Assistant.Lookups.Work`) over
  `AshEnterprise.Execution.trace/2`, made as the person, behind the zone gate, so a run
  takes them in its loop and nothing is written (ADR 0057). An entry carries structure
  only (statuses, references, keys, tool names); no argument, result, message or model
  text is in it, so an answer built on these rows has no provider reasoning to repeat.

  ## What a row says

    * `role` — `subject` (the record `explain` was asked about), `entry`, or `missing`:
      something the trace could not read, cut short, or that was never recorded. A
      `missing` row is never "nothing happened": its `missing` text says what is not
      known and why.
    * `ref` — the reference to cite, when the record has a page the person can open:
      a run, an invocation or a process run opens in the explorer, a task on its
      surface. Rows that are parts of a record (an attempt, an effect, a journal step)
      have none; their `entry` names them.
    * `entry` — the entry's own reference, which `explain` takes.
    * `status` and `meaning` — one of the six shared statuses, and what it means.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Assistant,
    data_layer: Ash.DataLayer.Simple,
    ownership: :none,
    tenant?: false,
    lifecycle?: false,
    archival?: false,
    audit?: false,
    self_service: [:trace, :explain],
    extra_extensions: [AshAgent.Effects]

  alias AshEnterprise.Assistant.Lookups

  @record_ref ~r/\A[a-z_]+:[0-9a-fA-F-]{36}\z/

  resource do
    require_primary_key? false
  end

  attributes do
    attribute :role, :atom, public?: true, constraints: [one_of: [:subject, :entry, :missing]]
    attribute :ref, :string, public?: true
    attribute :entry, :string, public?: true
    attribute :at, :string, public?: true
    attribute :kind, :atom, public?: true
    attribute :status, :atom, public?: true
    attribute :meaning, :string, public?: true
    attribute :under, :string, public?: true
    attribute :definition, :string, public?: true
    attribute :by, :string, public?: true
    attribute :summary, :string, public?: true
    attribute :missing, :string, public?: true
  end

  actions do
    read :trace do
      description "Everything recorded about one piece of work that the person may read."

      argument :ref, :string do
        allow_nil? true
        constraints match: @record_ref

        description "A reference a tool returned (run:…, invocation:…, process_instance:…) " <>
                      "to trace from. Give this or correlation_id."
      end

      argument :correlation_id, :string do
        allow_nil? true
        constraints max_length: 200
        description "A correlation id, to trace every record made under it."
      end

      manual {Lookups.Work, op: :trace}
    end

    read :explain do
      description "Why one record stands as it does, from what was recorded about it."

      argument :ref, :string do
        allow_nil? false
        constraints match: @record_ref

        description "The reference to explain, as a tool returned it (a ref, or an entry " <>
                      "from trace)."
      end

      manual {Lookups.Work, op: :explain}
    end
  end

  effects do
    action :trace,
      kind: :read,
      read_only?: true,
      destructive?: false,
      idempotent?: true,
      open_world?: false,
      intent: :inspect

    action :explain,
      kind: :read,
      read_only?: true,
      destructive?: false,
      idempotent?: true,
      open_world?: false,
      intent: :inspect
  end
end
