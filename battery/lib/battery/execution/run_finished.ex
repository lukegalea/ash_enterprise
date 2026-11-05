defmodule Battery.Execution.RunFinished do
  @moduledoc """
  The message a finished run sends the processes waiting for it: a CloudEvents 1.0
  envelope (`specversion`, `id`, `source`, `type`, `subject`, `time`, `datacontenttype`,
  `data`), one row per run, written in the transaction in which the run reaches a final
  state (`Battery.Execution.EmitRunFinished`). `id` is named `event_id` here because the
  primary key already is `id`; a consumer dedupes on `source` and `id`, which is the
  identity of this resource.

  A host's event log carries it to the processes (the battery's test hands the row to the
  engine's correlator as a host's sweep does). Only how the run ended travels: the run's
  input and output do not.
  """

  use Ash.Resource,
    domain: Battery.Domain,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "battery_run_finished"
    repo Battery.Repo
  end

  actions do
    defaults [:read]

    create :emit do
      accept [:event_id, :source, :type, :subject, :time, :data]
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :event_id, :string, allow_nil?: false, public?: true
    attribute :source, :string, allow_nil?: false, public?: true
    attribute :type, :string, allow_nil?: false, public?: true
    attribute :subject, :string, allow_nil?: false, public?: true
    attribute :time, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :data, :map, allow_nil?: false, public?: true
  end

  identities do
    identity :envelope, [:source, :event_id]
  end

  @doc "The envelope for a run that has reached a final state, as `emit` takes it."
  def envelope(run) do
    %{
      event_id: "#{run.id}:#{run.lease_epoch}",
      source: "/execution/runs/#{run.id}",
      type: "agent.run.finished",
      subject: run.id,
      time: DateTime.utc_now(),
      data: %{"status" => to_string(run.status)}
    }
  end
end
