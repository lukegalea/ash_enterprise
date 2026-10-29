defmodule AshEnterprise.Test.Execution.LeakyNote do
  @moduledoc """
  The canary for the no-network contract (`AshEnterprise.Test.Execution.NoNetwork`): a
  target declared internal (`open_world?: false`) whose action calls out from an
  `after_transaction` hook, through the Nango façade. That is the shape that breaks the
  internal path's guarantee: the hook runs outside the transaction that holds the
  effect, so a rolled-back effect can still have told someone it happened.

  The contract must catch it. It is kept out of the contract's inventory, which reads
  the registered domains, and checked on its own.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Test.Execution,
    ownership: :user_owned,
    tenant?: true,
    lifecycle?: false,
    archival?: false,
    lineage?: false,
    self_service: [:record_and_tell],
    extra_extensions: [AshAgent.Effects]

  postgres do
    table "canonical_tasks"
    repo AshEnterprise.Repo
    migrate? false
  end

  effects do
    action :record_and_tell,
      kind: :edit,
      destructive?: false,
      open_world?: false,
      intent: :execute
  end

  actions do
    create :record_and_tell do
      accept [:title]
      change set_attribute(:owner_id, actor(:id))
      change set_attribute(:source, "clinic_note")

      change fn changeset, _context ->
        Ash.Changeset.after_transaction(changeset, fn _changeset, result ->
          AshEnterprise.Integration.Nango.Proxy.request(%{
            method: :post,
            path: "/notices",
            body: %{"note" => "recorded"},
            provider_config_key: "referral-board",
            connection_id: "clinic"
          })

          result
        end)
      end
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :title, :string, allow_nil?: false, public?: true
    attribute :source, :string, allow_nil?: false, public?: true

    attribute :status, :atom do
      allow_nil? false
      public? true
      default :open
      constraints one_of: [:proposed, :open, :done, :cancelled]
    end

    attribute :plan, :atom do
      allow_nil? false
      public? true
      default :inbox
      constraints one_of: [:inbox, :today, :later]
    end

    update_timestamp :updated_at
  end
end
