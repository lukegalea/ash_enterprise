defmodule AshEnterprise.Assistant.Lookup.Message do
  @moduledoc """
  A message as the person may read it, cited by its conversation's `ref`.

  Computed, never stored: `read_messages` is a manual read
  (`AshEnterprise.Assistant.Lookups.Messages`) over the canonical reads, made
  as the person, behind the zone gate. See `AshEnterprise.Assistant.Lookup`.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Assistant,
    data_layer: Ash.DataLayer.Simple,
    ownership: :none,
    tenant?: false,
    lifecycle?: false,
    archival?: false,
    audit?: false,
    self_service: [:read_messages],
    extra_extensions: [AshAgent.Effects]

  alias AshEnterprise.Assistant.Lookups

  resource do
    require_primary_key? false
  end

  attributes do
    attribute :ref, :string, public?: true
    attribute :conversation, :string, public?: true
    attribute :from, :string, public?: true
    attribute :sent, :string, public?: true
    attribute :text, :string, public?: true
  end

  actions do
    read :read_messages do
      description "Messages, newest first, in one conversation or across all."

      argument :conversation, :string do
        allow_nil? true
        description "A conversation's ref (inbox:… or slack:…) from find_conversations."
      end

      argument :person, :string do
        allow_nil? true
        description "A sender's name or email."
      end

      argument :text, :string do
        allow_nil? true
        description "Text to find in the message."
      end

      argument :window, :string do
        allow_nil? true

        description Lookups.Support.window_help() <>
                      " Default last_30_days, or any time within one conversation."
      end

      manual Lookups.Messages
    end
  end

  effects do
    action :read_messages,
      kind: :read,
      read_only?: true,
      destructive?: false,
      idempotent?: true,
      open_world?: false,
      intent: :inspect
  end
end
