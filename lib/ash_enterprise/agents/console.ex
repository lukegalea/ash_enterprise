defmodule AshEnterprise.Agents.Console do
  @moduledoc """
  The terminal's commands (the ACP prompts of
  `AshEnterprise.Acp.Commands`): each answers in a few lines of text for the
  transcript, built from ordinary reads **as the calling actor** — the same
  read actions, under the same policies, the matching web surface uses.

    * `today` — agenda, latest morning brief, pulse (`AshEnterprise.Agents.Today`)
    * `agenda` — one calendar window (`Canonical.Actions.AgendaDigest`)
    * `inbox` — Gmail or Slack conversations (`Canonical.Actions.InboxDigest`)
    * `people` — the directory, optionally searched (`Canonical.Actions.DirectoryDigest`)
    * `approvals` — tasks waiting on the actor, numbered (`Bpmn.Actions.QueueDigest`)
    * `accounts` — linked accounts and sync health (`Integration.Actions.HealthDigest`)
    * `action_items` / `todo` / `done` — the actor's own action items: the
      numbered list, quick capture, finishing one (`Canonical.Actions.ActionItemsDigest`)
    * `open` — any registry surface, behind its door (`Agents.Actions.OpenSurface`)
    * `help` — the commands the actor may run

  Why a resource of its own rather than generic actions on the resources they
  read: those resources grant row access by depth, and a depth grant is a
  *filter* — which Ash cannot apply to a generic action, so a digest declared
  there would fail for anyone without a global grant (and the canonical mail
  and people are owner-only, so for everyone). Here the action is authorized
  for any signed-in human, and everything it says comes out of reads that are
  filtered as that human. It reveals nothing a read would not.

  No rows and no data of its own. The only writes are `todo` and `done`, each
  the actor's own self-service action on their own task (ADR 0052),
  authorized as them.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Agents,
    data_layer: Ash.DataLayer.Simple,
    ownership: :none,
    tenant?: false,
    lifecycle?: false,
    archival?: false,
    audit?: false,
    policies?: false,
    extra_extensions: [AshAgent.Effects]

  # Generic actions only and no rows, but the platform's system attributes are
  # still fields, which trips Ash's primary-key check (as on Calendar.Sync).
  resource do
    require_primary_key? false
  end

  actions do
    action :today, :string do
      description "The whole day — agenda, latest brief, signals — as text."
      run {AshEnterprise.Agents.Actions.TodayReport, report: :digest}
    end

    action :agenda, :string do
      description "One calendar window as text."

      argument :window, :atom do
        allow_nil? false
        default :today
        constraints one_of: [:today, :tomorrow, :this_week, :upcoming]
      end

      run AshEnterprise.Canonical.Actions.AgendaDigest
    end

    action :inbox, :string do
      description "One message vertical's conversations as text; says why it is empty."

      argument :system, :atom do
        allow_nil? false
        default :gmail
        constraints one_of: [:gmail, :slack]
      end

      run AshEnterprise.Canonical.Actions.InboxDigest
    end

    action :people, :string do
      description "The people directory as text, optionally searched by name or address."
      argument :search, :string, allow_nil?: true
      run AshEnterprise.Canonical.Actions.DirectoryDigest
    end

    action :approvals, :string do
      description "The tasks waiting on the actor, numbered."
      run AshEnterprise.Bpmn.Actions.QueueDigest
    end

    action :action_items, :string do
      description "The actor's open action items, numbered Today, Inbox, Later; what waits on them."
      run {AshEnterprise.Canonical.Actions.ActionItemsDigest, op: :list}
    end

    action :todo, :string do
      description "Capture an action item into the actor's Inbox (their own `Task.capture`)."

      argument :text, :string do
        allow_nil? false
        constraints min_length: 1, max_length: 1024
      end

      run {AshEnterprise.Canonical.Actions.ActionItemsDigest, op: :capture}
    end

    action :done, :string do
      description "Mark one of the actor's own action items done (their own `Task.complete_mine`)."
      argument :record_id, :uuid, allow_nil?: false
      run {AshEnterprise.Canonical.Actions.ActionItemsDigest, op: :done}
    end

    action :accounts, :string do
      description "Linked accounts and their sync health. Never a connection id or content."
      run AshEnterprise.Integration.Actions.HealthDigest
    end

    action :lineage, :string do
      description "The lineage graph for a window as text: failed and running runs first."

      argument :window, :atom do
        allow_nil? false
        default :day
        constraints one_of: [:hour, :day, :week, :fortnight]
      end

      run AshEnterprise.Lineage.Actions.Digest
    end

    action :open, :string do
      description "Open a registry surface by key; says which, and where it lives on the web."
      argument :surface, :string, allow_nil?: false
      run AshEnterprise.Agents.Actions.OpenSurface
    end

    action :help, :string do
      description "The ACP commands the actor may run."
      run fn _input, context -> {:ok, AshEnterprise.Acp.Commands.help(context.actor)} end
    end
  end

  # What each command does (ADR 0057), which ACP reads for its tool kind and
  # whether it asks first. The digests read as the actor; `todo` and `done`
  # are the actor's own act on their own row, undone from the board, so none
  # asks. Generic actions are never `read_only?` (only an Ash read is).
  effects do
    action :today,
      kind: :read,
      destructive?: false,
      idempotent?: true,
      open_world?: false,
      intent: :inspect

    action :agenda,
      kind: :read,
      destructive?: false,
      idempotent?: true,
      open_world?: false,
      intent: :inspect

    action :inbox,
      kind: :read,
      destructive?: false,
      idempotent?: true,
      open_world?: false,
      intent: :inspect

    action :people,
      kind: :search,
      destructive?: false,
      idempotent?: true,
      open_world?: false,
      intent: :inspect

    action :approvals,
      kind: :read,
      destructive?: false,
      idempotent?: true,
      open_world?: false,
      intent: :inspect

    action :action_items,
      kind: :read,
      destructive?: false,
      idempotent?: true,
      open_world?: false,
      intent: :inspect

    action :accounts,
      kind: :read,
      destructive?: false,
      idempotent?: true,
      open_world?: false,
      intent: :inspect

    action :lineage,
      kind: :read,
      destructive?: false,
      idempotent?: true,
      open_world?: false,
      intent: :inspect

    action :open,
      kind: :read,
      destructive?: false,
      idempotent?: true,
      open_world?: false,
      intent: :inspect

    action :help,
      kind: :read,
      destructive?: false,
      idempotent?: true,
      open_world?: false,
      intent: :inspect

    action :todo, kind: :edit, destructive?: false, open_world?: false, intent: :execute

    action :done,
      kind: :edit,
      destructive?: false,
      idempotent?: true,
      open_world?: false,
      intent: :execute
  end

  # Declared in full (`policies?: false`): every command answers from reads
  # filtered as the actor, so any human actor may ask. Nothing here is row
  # access; a nil actor gets nothing.
  policies do
    policy always() do
      authorize_if actor_present()
    end

    # `lineage` fronts the Lineage surface, which has a door: the command is
    # offered (and runs) only where the surface would open.
    policy action(:lineage) do
      authorize_if {AshEnterprise.Surfaces.DoorOpen, door: :lineage}
    end
  end

  code_interface do
    define :today
    define :agenda, args: [{:optional, :window}]
    define :inbox, args: [{:optional, :system}]
    define :people, args: [{:optional, :search}]
    define :approvals
    define :action_items
    define :todo, args: [:text]
    define :done, args: [:record_id]
    define :accounts
    define :lineage, args: [{:optional, :window}]
    define :open, args: [:surface]
    define :help
  end
end
