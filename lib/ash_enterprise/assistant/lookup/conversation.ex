defmodule AshEnterprise.Assistant.Lookup.Conversation do
  @moduledoc """
  An email thread or Slack conversation as the person may read it, cited by `ref`.

  Computed, never stored: `find_conversations` is a manual read
  (`AshEnterprise.Assistant.Lookups.Conversations`) over the canonical reads, made
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
    self_service: [:find_conversations],
    extra_extensions: [AshAgent.Effects]

  alias AshEnterprise.Assistant.Lookups

  resource do
    require_primary_key? false
  end

  attributes do
    attribute :ref, :string, public?: true
    attribute :source, :string, public?: true
    attribute :kind, :string, public?: true
    attribute :subject, :string, public?: true
    attribute :last_activity, :string, public?: true
    attribute :messages, :integer, public?: true
    attribute :last_from, :string, public?: true
    attribute :last_preview, :string, public?: true
    attribute :needs_reply, :boolean, public?: true
  end

  actions do
    read :find_conversations do
      description "Email threads and Slack conversations, newest first."

      argument :source, :atom do
        allow_nil? true
        constraints one_of: [:gmail, :slack, :any]
        description "gmail, slack or any. Default any."
      end

      argument :person, :string do
        allow_nil? true
        description "A name or email of someone taking part."
      end

      argument :text, :string do
        allow_nil? true
        description "Text to find in the subject or the messages."
      end

      argument :window, :string do
        allow_nil? true
        description Lookups.Support.window_help() <> " Default: any time."
      end

      argument :needs_reply, :boolean do
        allow_nil? true
        description "true: only threads whose latest message is from someone else."
      end

      manual Lookups.Conversations
    end
  end

  effects do
    action :find_conversations,
      kind: :search,
      read_only?: true,
      destructive?: false,
      idempotent?: true,
      open_world?: false,
      intent: :inspect
  end
end
