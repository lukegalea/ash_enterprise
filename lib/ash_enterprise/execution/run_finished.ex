defmodule AshEnterprise.Execution.RunFinished do
  @moduledoc """
  The message a finished agent run sends the processes waiting for it: a
  [CloudEvents 1.0](https://github.com/cloudevents/spec/blob/v1.0.2/cloudevents/spec.md)
  envelope, one row per run, written in the transaction in which the run reaches a final
  state (`AshEnterprise.Execution.Changes.EmitRunFinished`).

  ## Why a row, and why audited

  A process hears of the world through the audit log (`AshEnterprise.Audit.EventSource`),
  and a write is in the log if and only if it committed. So the message is a write: the
  run's final transition and its announcement commit together or not at all, and a worker
  that dies between the two leaves neither. The sweep that delivers messages reads the log
  from a cursor, so a message that is not delivered yet is delivered by the next sweep, and
  a message delivered twice wakes a waiting task once (the engine's claim of a parked token
  has one winner).

  ## The envelope

  | CloudEvents attribute | Column | Value |
  |---|---|---|
  | `specversion` | `specversion` | `"1.0"` |
  | `id` | `event_id` | `<run id>:<lease epoch>` |
  | `source` | `source` | the run's URI, `/execution/runs/<run id>` |
  | `type` | `type` | `"agent.run.finished"` |
  | `subject` | `subject` | the run's id, which a waiting task correlates on |
  | `time` | `time` | when the run finished |
  | `datacontenttype` | `datacontenttype` | `"application/json"` |
  | `data` | `data` | `status` (`completed`, `failed` or `cancelled`), and for a failed run its `failure_class` and `error_code` |

  `id` is named `event_id` here because the primary key already is `id`. A consumer dedupes
  on `source` and `id` together, which is the identity of this resource: a second envelope
  for the same run and epoch is refused.

  The run's `input` and `output` are sealed under an erasure scope (ADR 0024) and the
  audit log keeps a plaintext copy of every change, so neither travels in the message. A
  process that needs the answer reads it from the run, as the person who started it.

  Written only by the run (`emit` is machinery-only). Not exposed over any API.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Execution,
    ownership: :organization_owned,
    lifecycle?: false,
    archival?: false,
    machinery_only: [:emit]

  postgres do
    table "exec_run_finished"
    repo AshEnterprise.Repo
  end

  actions do
    defaults [:read]

    create :emit do
      description "Announce that a run reached a final state."
      accept [:event_id, :source, :type, :subject, :time, :data]
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :specversion, :string do
      allow_nil? false
      default "1.0"
      writable? false
      public? true
    end

    attribute :event_id, :string do
      allow_nil? false
      public? true
      description "CloudEvents `id`: the run's id and the lease epoch it finished under."
    end

    attribute :source, :string do
      allow_nil? false
      public? true
      description "CloudEvents `source`: the run's URI."
    end

    attribute :type, :string do
      allow_nil? false
      public? true
      description "CloudEvents `type`."
    end

    attribute :subject, :string do
      allow_nil? false
      public? true
      description "CloudEvents `subject`: the run's id."
    end

    attribute :time, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :datacontenttype, :string do
      allow_nil? false
      default "application/json"
      writable? false
      public? true
    end

    attribute :data, :map do
      allow_nil? false
      public? true
      description "CloudEvents `data`: how the run ended. Nothing the run said."
    end
  end

  identities do
    identity :envelope, [:source, :event_id]
  end

  @type_name "agent.run.finished"

  @doc "The `type` of every envelope this resource carries."
  @spec type() :: String.t()
  def type, do: @type_name

  @doc """
  The envelope for a run that has reached a final state, as `emit` takes it.
  """
  @spec envelope(struct()) :: map()
  def envelope(run) do
    %{
      event_id: "#{run.id}:#{run.lease_epoch}",
      source: "/execution/runs/#{run.id}",
      type: @type_name,
      subject: run.id,
      time: DateTime.utc_now(),
      data:
        %{"status" => to_string(run.status)}
        |> put_failure(run)
    }
  end

  defp put_failure(data, %{status: :failed} = run) do
    data
    |> Map.put("failure_class", run.failure_class && to_string(run.failure_class))
    |> Map.put("error_code", run.error_code)
  end

  defp put_failure(data, _run), do: data
end
