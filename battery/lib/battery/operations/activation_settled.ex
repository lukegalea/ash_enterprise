defmodule Battery.Operations.ActivationSettled do
  @moduledoc """
  The message a provider read sends the processes waiting for an activation: a CloudEvents
  1.0 envelope (shaped like `Battery.Execution.RunFinished`), one row per delivery, written
  by `Battery.Operations.FollowUp` from what the provider SAID WHEN READ, never from what
  the webhook claimed. `subject` is the activation id; `data` carries the status.
  """

  use Ash.Resource,
    domain: Battery.Domain,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "battery_activation_settled"
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

  @doc "The envelope for `activation`, as the provider returned it on a read, for `delivery`."
  def envelope(delivery, activation) do
    %{
      event_id: delivery.id,
      source: "/operations/registry/activations/#{delivery.activation_id}",
      type: "registry.activation.settled",
      subject: delivery.activation_id,
      time: DateTime.utc_now(),
      data: %{"status" => activation["status"]}
    }
  end
end
