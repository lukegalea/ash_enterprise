defmodule AshEnterpriseWeb.A2ui.AccountsUI do
  @moduledoc """
  Accounts & syncs — the linked provider accounts and their sync health:
  provider, health (syncing / blocked · reason / paused), last sync, what
  each sync reaches, and the zone tags its records carry (data class,
  residency — read-only here). Structure only — never a connection id, never
  content.

  Row actions are the existing, policy-gated ones: Sync now
  (`LinkedAccount.sync_now`, which hands the account to its vertical's own
  `request_sync`), Unblock sync (`unblock_sync`), and Deactivate / Activate
  (pause and resume the account's syncs). Sync now also runs over a selection
  of rows (`bulk_actions`), once per account, as the actor. Each declares when it applies
  (`visible_when`); the handler re-checks that on every click, so a click that
  does not apply is refused with a message rather than run.

  Served at `/app/accounts` and, as the `accounts` prompt (read-only), over ACP.
  """

  use AshA2ui.Standalone

  a2ui do
    for_resource AshEnterprise.Integration.LinkedAccount
    surface_id "accounts"
    title "Accounts & syncs"
    record_label "linked account"
    spec_version "1.0"

    context :account do
      resource AshEnterprise.Integration.LinkedAccount
      picker false
    end

    component :table do
      fields [
        :provider,
        :lifecycle_status,
        :label,
        :health,
        :last_sync,
        :reach,
        :projection,
        :data_class,
        :residency
      ]

      read_action :read
      row_actions [:sync_now, :unblock_sync, :deactivate, :activate]
      # Sync now is the one act worth running over a selection: each account
      # still syncs through its own vertical, as the actor, and one that is
      # paused or blocked is skipped (`visible_when` below), not forced.
      bulk_actions [:sync_now]
      select_context :account

      row_layout do
        title :provider
        badge :lifecycle_status
        badge_text active: "Active", inactive: "Paused"
        meta [:label, :health, :last_sync, :reach, :projection, :data_class, :residency]
        columns 2
      end
    end

    component :detail, :account_detail do
      context :account

      fields [
        :provider,
        :lifecycle_status,
        :label,
        :health,
        :last_sync,
        :reach,
        :projection,
        :data_class,
        :residency,
        :scope
      ]
    end

    action :sync_now do
      visible_when lifecycle_status: :active, blocked: false
    end

    action :unblock_sync do
      visible_when blocked: true
    end

    action :deactivate do
      visible_when lifecycle_status: :active
    end

    action :activate do
      visible_when lifecycle_status: :inactive
    end

    field :provider do
      label "Provider"
    end

    field :lifecycle_status do
      label "State"
    end

    field :label do
      label "Account"
    end

    field :health do
      label "Health"
    end

    field :last_sync do
      label "Last sync"
    end

    field :reach do
      label "Reach"
    end

    field :projection do
      label "Projected"
    end

    field :data_class do
      label "Data class"
    end

    field :residency do
      label "Residency"
    end

    # Operator-only: the link (and its label) is there only for a reader who
    # may read erasure scopes.
    field :scope do
      label "Erasure scope"
      link :erasure_scope
      link_label :label
    end
  end
end

defmodule AshEnterpriseWeb.A2ui.ErasureUI do
  @moduledoc """
  Erasure scopes — every crypto-shredding scope (ADR 0024): kind, ref, label,
  status, when shredded and why. A scope opens in detail with its linked
  account, who opened and last changed it (links to Users), and how many of
  the reader's conversations, messages and events it seals. Operator-only by policy (the scope privileges
  are reserved to the Platform Operator), so anyone else sees an empty list.

  Shred is irreversible. It is a row action with a typed confirmation — the
  prompt asks for the scope's exact ref and a reason, and the existing
  `Scope.shred` action refuses anything but the exact ref and only lets a
  human with a write grant on erasure scopes through. Offered on active scopes
  only. Web only: the ACP `erasure` prompt is read-only.
  """

  use AshA2ui.Standalone

  a2ui do
    for_resource AshEnterprise.Erasure.Scope
    surface_id "erasure_scopes"
    title "Erasure scopes"
    record_label "erasure scope"
    spec_version "1.0"

    query :scopes do
      search_fields [:label, :ref]
      filters [:kind, :status]
      sortable [:created_on, :shredded_at, :label]
      default_sort created_on: :desc
      page_size 25
      max_page_size 100
    end

    component :table do
      fields [:label, :status, :kind, :ref, :opened_on, :shredded_on, :shred_reason]
      read_action :read
      query :scopes
      row_actions [:shred]
      select_context :scope

      row_layout do
        title :label
        badge :status
        badge_text active: "Active", shredded: "Shredded"
        meta [:kind, :ref, :opened_on, :shredded_on, :shred_reason]
        columns 2
      end
    end

    context :scope do
      resource AshEnterprise.Erasure.Scope
      picker false
    end

    component :detail, :scope_detail do
      context :scope

      fields [
        :label,
        :status,
        :kind,
        :ref,
        :account,
        :opened_on,
        :opened_by_label,
        :shredded_on,
        :changed_by_label,
        :shred_reason,
        :conversation_count,
        :message_count,
        :calendar_event_count
      ]
    end

    action :shred do
      prompt_fields [:confirm, :reason]

      prompt_title "Shred permanently: type this scope's ref in Confirm, and give a reason (audited). Its key is destroyed; this cannot be undone."

      visible_when status: :active
    end

    field :label do
      label "Scope"
    end

    field :ref do
      label "Ref"
    end

    field :opened_on do
      label "Opened"
    end

    field :shredded_on do
      label "Shredded"
    end

    field :shred_reason do
      label "Reason"
    end

    field :account do
      label "Linked account"
      link :linked_account
      link_label :label
    end

    field :opened_by_label do
      label "Opened by"
      link {:users, :created_by_id}
    end

    field :changed_by_label do
      label "Last changed by"
      link {:users, :modified_by_id}
    end

    field :conversation_count do
      label "Conversations sealed"
    end

    field :message_count do
      label "Messages sealed"
    end

    field :calendar_event_count do
      label "Events sealed"
    end
  end
end

defmodule AshEnterpriseWeb.A2ui.ErasureReadOnlyUI do
  @moduledoc """
  Erasure scopes, read-only — what the ACP `erasure` prompt shows. The same
  rows as `ErasureUI` under the same policies, with no row actions at all:
  shred is never offered over ACP (it lives on the web, behind a typed
  confirmation), so this surface carries no envelope that could ask for it.
  """

  use AshA2ui.Standalone

  a2ui do
    for_resource AshEnterprise.Erasure.Scope
    surface_id "erasure_scopes_read_only"
    title "Erasure scopes"
    record_label "erasure scope"
    spec_version "1.0"

    query :scopes do
      search_fields [:label, :ref]
      filters [:kind, :status]
      sortable [:created_on, :shredded_at, :label]
      default_sort created_on: :desc
      page_size 25
      max_page_size 100
    end

    component :table do
      fields [:label, :status, :kind, :ref, :opened_on, :shredded_on, :shred_reason]
      read_action :read
      query :scopes
      select_context :scope
    end

    context :scope do
      resource AshEnterprise.Erasure.Scope
      picker false
    end

    component :detail, :scope_detail do
      context :scope

      fields [
        :label,
        :status,
        :kind,
        :ref,
        :account,
        :opened_on,
        :opened_by_label,
        :shredded_on,
        :changed_by_label,
        :shred_reason,
        :conversation_count,
        :message_count,
        :calendar_event_count
      ]
    end

    field :label do
      label "Scope"
    end

    field :opened_on do
      label "Opened"
    end

    field :shredded_on do
      label "Shredded"
    end

    field :shred_reason do
      label "Reason"
    end

    field :account do
      label "Linked account"
      link :linked_account
      link_label :label
    end

    field :opened_by_label do
      label "Opened by"
      link {:users, :created_by_id}
    end

    field :changed_by_label do
      label "Last changed by"
      link {:users, :modified_by_id}
    end

    field :conversation_count do
      label "Conversations sealed"
    end

    field :message_count do
      label "Messages sealed"
    end

    field :calendar_event_count do
      label "Events sealed"
    end
  end
end
