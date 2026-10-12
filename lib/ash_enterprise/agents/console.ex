defmodule AshEnterprise.Agents.Console do
  @moduledoc """
  The terminal's read-only commands (the ACP prompts of
  `AshEnterprise.Acp.Commands`): each answers in a few lines of text for the
  transcript, built from ordinary reads **as the calling actor** — the same
  read actions, under the same policies, the matching web surface uses.

    * `today` — agenda, latest morning brief, pulse (`AshEnterprise.Agents.Today`)
    * `agenda` — one calendar window (`Canonical.Actions.AgendaDigest`)
    * `inbox` — Gmail or Slack conversations (`Canonical.Actions.InboxDigest`)
    * `people` — the directory, optionally searched (`Canonical.Actions.DirectoryDigest`)
    * `approvals` — tasks waiting on the actor, numbered (`Bpmn.Actions.QueueDigest`)
    * `accounts` — linked accounts and sync health (`Integration.Actions.HealthDigest`)
    * `help` — the commands the actor may run

  Why a resource of its own rather than generic actions on the resources they
  read: those resources grant row access by depth, and a depth grant is a
  *filter* — which Ash cannot apply to a generic action, so a digest declared
  there would fail for anyone without a global grant (and the canonical mail
  and people are owner-only, so for everyone). Here the action is authorized
  for any signed-in human, and everything it says comes out of reads that are
  filtered as that human. It reveals nothing a read would not.

  No rows, no data, nothing written.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Agents,
    data_layer: Ash.DataLayer.Simple,
    ownership: :none,
    tenant?: false,
    lifecycle?: false,
    archival?: false,
    audit?: false,
    policies?: false

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

    action :accounts, :string do
      description "Linked accounts and their sync health. Never a connection id or content."
      run AshEnterprise.Integration.Actions.HealthDigest
    end

    action :help, :string do
      description "The ACP commands the actor may run."
      run fn _input, context -> {:ok, AshEnterprise.Acp.Commands.help(context.actor)} end
    end
  end

  # Declared in full (`policies?: false`): every command answers from reads
  # filtered as the actor, so any human actor may ask. Nothing here is row
  # access; a nil actor gets nothing.
  policies do
    policy always() do
      authorize_if actor_present()
    end
  end

  code_interface do
    define :today
    define :agenda, args: [{:optional, :window}]
    define :inbox, args: [{:optional, :system}]
    define :people, args: [{:optional, :search}]
    define :approvals
    define :accounts
    define :help
  end
end
